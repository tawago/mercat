const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const roles = @import("edge_roles.zig");
const fan_roles = @import("fan_roles.zig");
const crossings = @import("crossings.zig");
const ew = @import("edges_write.zig");
const ep = @import("edges_port.zig");
const aux = @import("aux.zig");
const prim = @import("prim");

const log = std.log.scoped(.@"mermaid_v2.raster.edges");

pub const RasterError = error{ OutOfMemory, OutOfBounds, MalformedPolyline };

pub const Move = ew.Move;
pub const straightMask = ew.straightMask;
pub const bitMask = ew.bitMask;
pub const reverse = ew.reverse;
pub const orMask = ew.orMask;
pub const segmentDir = ew.segmentDir;
pub const step = ew.step;
pub const pointInBounds = ew.pointInBounds;
pub const toCoord = ew.toCoord;
pub const writeEdgeCell = ew.writeEdgeCell;
pub const writeArrowCell = ew.writeArrowCell;
pub const drawPortStroke = ep.drawPortStroke;
pub const drawTargetPortStroke = ep.drawTargetPortStroke;
pub const Head = ep.Head;
pub const PortEnd = ep.PortEnd;

pub const EdgeRasterReport = struct {
    edges_written: u32 = 0,
    cells_lost: u32 = 0,
    heads_lost: u32 = 0,
    crossings: crossings.CrossingCounts = .{},
};

const EdgeWalkResult = struct {
    first_cell: ?sketch.Point = null,
    last_cell: ?sketch.Point = null,
    first_dir: ?Move = null,
    last_dir: ?Move = null,
    /// @guarded-by: edges_slide_test.zig "a decorated gap arrival stamps its head against the wall, run ink behind it"
    source_head: ?ep.Head = null,
    target_head: ?ep.Head = null,
};

fn carrierKindOnto(cell: *const lattice.Cell, edge: u32, c: ew.Coord, ctx: crossings.Ctx) lattice.CarrierKind {
    return crossings.carrierKindOnto(cell, ctx.bundle_sets, ctx.stamp_state, edge, null, crossings.cellAt(c.x, c.y));
}

/// @guarded-by: edges_test.zig "a co-member's corner arm into a head is refused, counted against the corner's edge, and the head keeps its state"
fn crossingKeepsFirstWriter(
    cell: *const lattice.Cell,
    incoming_edge: u32,
    incoming_mask: lattice.Neighbours,
    at: crossings.BundleCell,
    ctx: crossings.Ctx,
) bool {
    return switch (cell.occupant) {
        .edge_segment => |seg| crossings.segmentOverlap(
            ctx.counts,
            ctx.bundles,
            ctx.bundle_sets,
            seg.edge,
            cell.neighbours,
            incoming_edge,
            incoming_mask,
            at,
        ),
        .arrowhead => |a| crossings.headEntry(
            ctx.counts,
            ctx.bundles,
            ctx.bundle_sets,
            a.edge,
            a.dir,
            incoming_edge,
            incoming_mask,
            at,
        ),
        else => false,
    };
}

fn markSuppressed(cell: *lattice.Cell) void {
    if (cell.occupant != .arrowhead) cell.upgradeState(.crossing);
}

fn claimCornerCell(
    cell: *lattice.Cell,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    corner_mask: lattice.Neighbours,
) void {
    cell.occupant = .{ .edge_segment = .{ .edge = edge_id, .kind = kind, .role = role } };
    cell.neighbours = corner_mask;
    cell.stroke_kind = kind;
    cell.state = ew.roleState(role);
}

/// @guarded-by: edges_corner_test.zig
pub const RailEnds = struct { source: bool = false, target: bool = false };

fn railEnds(s: sketch.Sketch, edge: sketch.EdgePath) RailEnds {
    var ends: RailEnds = .{};
    if (edge.role != .member_stroke) return ends;
    for (s.rails) |rail| {
        const fan_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
        for (rail.taps) |tap| {
            if (tap.edge != edge.id or !tap.continues) continue;
            if (fan_in) ends.target = true else ends.source = true;
        }
    }
    return ends;
}

fn walkPolyline(
    lat: *lattice.Lattice,
    edge: sketch.EdgePath,
    ends: RailEnds,
    cells_lost: *u32,
    ctx: crossings.Ctx,
    sink: aux.Sink,
    rec: aux.Recorder,
) RasterError!EdgeWalkResult {
    const pts = edge.polyline;
    if (pts.len < 2) {
        log.debug(
            "mermaid_v2/raster/edges: edge {d} polyline has {d} points; skipping",
            .{ edge.id, pts.len },
        );
        return .{};
    }

    // @guarded-by: edges_test.zig "edge cells colliding with node-owned cells are counted as lost"
    var nontrivial: usize = 0;
    {
        var i: usize = 0;
        while (i + 1 < pts.len) : (i += 1) {
            if (segmentDir(pts[i], pts[i + 1])) |_| nontrivial += 1;
        }
    }
    if (nontrivial == 0) {
        log.debug(
            "mermaid_v2/raster/edges: edge {d} polyline is degenerate; skipping",
            .{edge.id},
        );
        return .{};
    }

    var result: EdgeWalkResult = .{};
    var prev_dir: ?Move = null;
    var seg_index: usize = 0;
    const ek = edge.kind;
    const erole = edge.role;

    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        const a = pts[i];
        const b = pts[i + 1];
        const dir_opt = segmentDir(a, b);
        if (dir_opt == null) continue;
        const dir = dir_opt.?;

        const is_last = seg_index == nontrivial - 1;
        seg_index += 1;

        // @guarded-by: edges_corner_test.zig "shared rail corner: sibling drops bending at one cell yield ┴, not a phantom ┼"
        if (prev_dir) |prev| {
            if (pointInBounds(a, lat)) {
                const c = toCoord(a);
                const cell = lat.at(c.x, c.y);
                const corner_mask = orMask(bitMask(reverse(prev)), bitMask(dir));
                switch (cell.occupant) {
                    .edge_segment => |seg| {
                        if (seg.edge != edge.id and crossings.segmentOverlap(
                            ctx.counts,
                            ctx.bundles,
                            ctx.bundle_sets,
                            seg.edge,
                            cell.neighbours,
                            edge.id,
                            corner_mask,
                            crossings.cellAt(c.x, c.y),
                        )) {
                            cell.upgradeState(.crossing);
                            ew.recordCarrier(rec, c.x, c.y, edge.id, .suppressed);
                        } else {
                            const own = seg.edge == edge.id;
                            // @guarded-by: edges_corner_test.zig "a route that doubles back keeps both visits' arms at the cell it re-enters"
                            if (!own) {
                                const grows = (cell.neighbours.toMask() | corner_mask.toMask()) != cell.neighbours.toMask();
                                cell.upgradeState(if (grows) .junction else .rail_interior);
                            }
                            cell.neighbours = orMask(cell.neighbours, corner_mask);
                            cell.occupant = .{ .edge_segment = .{
                                .edge = seg.edge,
                                .kind = seg.kind,
                                .role = roles.mergeRole(seg.role, erole),
                            } };
                            // @guarded-by: aux_test.zig "a corner arm merged onto a foreign run files a merged carrier; onto its own ink, nothing"
                            if (!own) ew.recordCarrier(rec, c.x, c.y, edge.id, crossings.carrierKindFor(seg.edge, edge.id, ctx.bundle_sets, ctx.stamp_state, crossings.cellAt(c.x, c.y)));
                            fan_roles.markShared(rec, cell, c.x, c.y, edge.id, erole);
                        }
                    },
                    .empty => {
                        claimCornerCell(cell, edge.id, ek, erole, corner_mask);
                    },
                    .cluster_border => {
                        if (ctx.mode == .bridge) {
                            // @guarded-by: edges_test.zig "corner arm onto a subgraph frame border is refused"
                            ctx.counts.b_border_fusion_refused += 1;
                            ew.recordIntrusion(rec, c.x, c.y, edge.id, .fusion_refused);
                        } else {
                            claimCornerCell(cell, edge.id, ek, erole, corner_mask);
                        }
                    },
                    else => {
                        if (crossingKeepsFirstWriter(cell, edge.id, corner_mask, crossings.cellAt(c.x, c.y), ctx)) {
                            markSuppressed(cell);
                            ew.recordCarrier(rec, c.x, c.y, edge.id, .suppressed);
                        } else {
                            writeEdgeCell(cell, edge.id, ek, erole, corner_mask, c.x, c.y, cells_lost, ctx.counts, carrierKindOnto(cell, edge.id, c, ctx), rec);
                            fan_roles.markShared(rec, cell, c.x, c.y, edge.id, erole);
                        }
                    },
                }
                if (result.first_cell == null) {
                    result.first_cell = a;
                    result.first_dir = dir;
                }
                result.last_cell = a;
                // @guarded-by: edges_test.zig "length-1 final segment after a corner points the terminal arrowhead into the port"
                result.last_dir = if (is_last) dir else prev;
            }
        }

        // @guarded-by: edges_test.zig "edge cells colliding with node-owned cells are counted as lost"
        var cursor = step(a, dir);
        while (true) {
            const at_b = cursor.x == b.x and cursor.y == b.y;
            if (at_b) break;

            if (pointInBounds(cursor, lat)) {
                const c = toCoord(cursor);
                const cell = lat.at(c.x, c.y);
                // @guarded-by: edges_test.zig "through-crossing bridges a subgraph frame border"
                // @guarded-by: edges_test.zig "cross mode: through-crossing welds the frame border (pre-slice-1)"
                const nxt = step(cursor, dir);
                const terminal_here = is_last and nxt.x == b.x and nxt.y == b.y;
                if (ctx.mode == .bridge and cell.occupant == .cluster_border and !terminal_here) {
                    ctx.counts.b_frame_bridge += 1;
                    ew.recordIntrusion(rec, c.x, c.y, edge.id, .bridge);
                } else if (crossingKeepsFirstWriter(cell, edge.id, straightMask(dir), crossings.cellAt(c.x, c.y), ctx)) {
                    markSuppressed(cell);
                    ew.recordCarrier(rec, c.x, c.y, edge.id, .suppressed);
                } else {
                    writeEdgeCell(cell, edge.id, ek, erole, straightMask(dir), c.x, c.y, cells_lost, ctx.counts, carrierKindOnto(cell, edge.id, c, ctx), rec);
                    fan_roles.markShared(rec, cell, c.x, c.y, edge.id, erole);
                }
                if (result.first_cell == null) {
                    result.first_cell = cursor;
                    result.first_dir = dir;
                }
                result.last_cell = cursor;
                result.last_dir = dir;
            }

            cursor = step(cursor, dir);
        }

        prev_dir = dir;
    }

    // @guarded-by: edges_port_test.zig "a head adjacent to the wall but pointing ALONG the route still tees it"
    // @guarded-by: edges_slide_test.zig "a decorated gap arrival stamps its head against the wall, run ink behind it"
    // @guarded-by: edges_test.zig "a member stroke paints neither port nor head at its rail end and both at a private end"
    if (!ends.source and edge.arrow_from != .none) if (result.first_cell) |fc| if (result.first_dir) |fd| {
        result.source_head = ep.slideHead(lat, pts[0], .{ .cell = fc, .dir = reverse(fd) });
    };
    if (!ends.target and edge.arrow_to != .none) if (result.last_cell) |lc| if (result.last_dir) |ld| {
        result.target_head = ep.slideHead(lat, pts[pts.len - 1], .{ .cell = lc, .dir = ld });
    };
    if (!ends.source) drawPortStroke(lat, pts, ek, edge.id, .{ .head = result.source_head, .role = erole }, sink);
    if (!ends.target) drawTargetPortStroke(lat, pts, ek, edge.id, .{ .head = result.target_head, .role = erole }, sink);

    return result;
}

pub fn rasterizeEdges(
    allocator: std.mem.Allocator,
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    subgraph_edges: prim.SubgraphEdges,
    sink: aux.Sink,
) RasterError!EdgeRasterReport {
    _ = allocator;
    var written: u32 = 0;
    var cells_lost: u32 = 0;
    var heads_lost: u32 = 0;
    var cross_counts: crossings.CrossingCounts = .{};
    const rec = aux.Recorder.init(sink, lat);
    const ctx: crossings.Ctx = .{
        .bundles = s.bundles,
        .bundle_sets = s.bundle_sets,
        .stamp_state = s.bundle_stamp_state,
        .counts = &cross_counts,
        .mode = subgraph_edges,
    };

    for (s.edges) |edge| {
        const r = try walkPolyline(lat, edge, railEnds(s, edge), &cells_lost, ctx, sink, rec);

        if (r.target_head) |h| {
            if (pointInBounds(h.cell, lat)) {
                const c = toCoord(h.cell);
                ew.writeArrowGuarded(lat.at(c.x, c.y), edge.id, edge.kind, edge.arrow_to, h.dir, straightMask(h.dir), c.x, c.y, &cells_lost, &heads_lost, ctx, rec);
            }
        }
        if (r.source_head) |h| {
            if (pointInBounds(h.cell, lat)) {
                const c = toCoord(h.cell);
                ew.writeArrowGuarded(lat.at(c.x, c.y), edge.id, edge.kind, edge.arrow_from, h.dir, straightMask(h.dir), c.x, c.y, &cells_lost, &heads_lost, ctx, rec);
            }
        }

        if (r.first_cell != null) written += 1;
    }

    fan_roles.resolveMasks(lat, s);

    return .{ .edges_written = written, .cells_lost = cells_lost, .heads_lost = heads_lost, .crossings = cross_counts };
}

test {
    _ = @import("edges_test.zig");
    _ = @import("edges_corner_test.zig");
}

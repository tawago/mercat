const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const roles = @import("edge_roles.zig");
const fan_roles = @import("fan_roles.zig");
const crossings = @import("crossings.zig");
const ew = @import("edges_write.zig");
const ep = @import("edges_port.zig");
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
    cells_lost: u32 = 0,
    crossings: crossings.CrossingCounts = .{},
};

const EdgeWalkResult = struct {
    first_cell: ?sketch.Point = null,
    last_cell: ?sketch.Point = null,
    first_dir: ?Move = null,
    last_dir: ?Move = null,
    source_head: ?ep.Head = null,
    target_head: ?ep.Head = null,
};

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
}

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
) RasterError!EdgeWalkResult {
    const pts = edge.polyline;
    if (pts.len < 2) {
        log.debug(
            "mermaid_v2/raster/edges: edge {d} polyline has {d} points; skipping",
            .{ edge.id, pts.len },
        );
        return .{};
    }

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

        if (prev_dir) |prev| {
            if (pointInBounds(a, lat)) {
                const c = toCoord(a);
                const cell = lat.at(c.x, c.y);
                const corner_mask = orMask(bitMask(reverse(prev)), bitMask(dir));
                switch (cell.occupant) {
                    .edge_segment => |seg| {
                        const refused = seg.edge != edge.id and crossings.segmentOverlap(
                            ctx.counts,
                            ctx.bundles,
                            ctx.bundle_sets,
                            seg.edge,
                            cell.neighbours,
                            edge.id,
                            corner_mask,
                            crossings.cellAt(c.x, c.y),
                        );
                        if (!refused) {
                            cell.neighbours = orMask(cell.neighbours, corner_mask);
                            cell.occupant = .{ .edge_segment = .{
                                .edge = seg.edge,
                                .kind = seg.kind,
                                .role = roles.mergeRole(seg.role, erole),
                            } };
                            fan_roles.markShared(cell, edge.id, erole);
                        }
                    },
                    .empty => claimCornerCell(cell, edge.id, ek, erole, corner_mask),
                    .cluster_border => if (ctx.mode != .bridge) claimCornerCell(cell, edge.id, ek, erole, corner_mask),
                    else => if (!crossingKeepsFirstWriter(cell, edge.id, corner_mask, crossings.cellAt(c.x, c.y), ctx)) {
                        writeEdgeCell(cell, edge.id, ek, erole, corner_mask, c.x, c.y, cells_lost);
                        fan_roles.markShared(cell, edge.id, erole);
                    },
                }
                if (result.first_cell == null) {
                    result.first_cell = a;
                    result.first_dir = dir;
                }
                result.last_cell = a;
                result.last_dir = if (is_last) dir else prev;
            }
        }

        var cursor = step(a, dir);
        while (true) {
            const at_b = cursor.x == b.x and cursor.y == b.y;
            if (at_b) break;

            if (pointInBounds(cursor, lat)) {
                const c = toCoord(cursor);
                const cell = lat.at(c.x, c.y);
                const nxt = step(cursor, dir);
                const terminal_here = is_last and nxt.x == b.x and nxt.y == b.y;
                const bridged = ctx.mode == .bridge and cell.occupant == .cluster_border and !terminal_here;
                if (!bridged and !crossingKeepsFirstWriter(cell, edge.id, straightMask(dir), crossings.cellAt(c.x, c.y), ctx)) {
                    writeEdgeCell(cell, edge.id, ek, erole, straightMask(dir), c.x, c.y, cells_lost);
                    fan_roles.markShared(cell, edge.id, erole);
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

    if (!ends.source and edge.arrow_from != .none) if (result.first_cell) |fc| if (result.first_dir) |fd| {
        result.source_head = ep.slideHead(lat, pts[0], .{ .cell = fc, .dir = reverse(fd) });
    };
    if (!ends.target and edge.arrow_to != .none) if (result.last_cell) |lc| if (result.last_dir) |ld| {
        result.target_head = ep.slideHead(lat, pts[pts.len - 1], .{ .cell = lc, .dir = ld });
    };
    if (!ends.source) drawPortStroke(lat, pts, ek, edge.id, .{ .head = result.source_head, .role = erole });
    if (!ends.target) drawTargetPortStroke(lat, pts, ek, edge.id, .{ .head = result.target_head, .role = erole });

    return result;
}

pub fn rasterizeEdges(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    subgraph_edges: prim.SubgraphEdges,
) RasterError!EdgeRasterReport {
    var cells_lost: u32 = 0;
    var cross_counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{
        .bundles = s.bundles,
        .bundle_sets = s.bundle_sets,
        .counts = &cross_counts,
        .mode = subgraph_edges,
    };

    for (s.edges) |edge| {
        const r = try walkPolyline(lat, edge, railEnds(s, edge), &cells_lost, ctx);

        if (r.target_head) |h| {
            if (pointInBounds(h.cell, lat)) {
                const c = toCoord(h.cell);
                ew.writeArrowGuarded(lat.at(c.x, c.y), edge.id, edge.kind, edge.arrow_to, h.dir, straightMask(h.dir), c.x, c.y, &cells_lost, ctx);
            }
        }
        if (r.source_head) |h| {
            if (pointInBounds(h.cell, lat)) {
                const c = toCoord(h.cell);
                ew.writeArrowGuarded(lat.at(c.x, c.y), edge.id, edge.kind, edge.arrow_from, h.dir, straightMask(h.dir), c.x, c.y, &cells_lost, ctx);
            }
        }
    }

    fan_roles.resolveMasks(lat, s);

    return .{ .cells_lost = cells_lost, .crossings = cross_counts };
}

test {
    _ = @import("edges_test.zig");
    _ = @import("edges_corner_test.zig");
}

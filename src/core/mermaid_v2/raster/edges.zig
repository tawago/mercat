//! Edge rasterizer for the mermaid_v2 pipeline. Walks each
//! `EdgePath.polyline` in a `Sketch`, writing `edge_segment`/`arrowhead`
//! cells into a `Lattice` with `Neighbours` bits for the painter's
//! junction table. Imports: `std`, `sketch.zig`, `lattice.zig`,
//! `edge_roles.zig`, `crossings.zig`, `edges_write.zig`, `aux.zig`, the `prim`
//! module only.
//! Role-merge precedence at shared-run cells (`edge_roles.zig`): fan_out_rail
//! > fan_out_dropper and fan_in_rail > fan_in_dropper, both over forward/
//! cluster_internal. A fan shared run is named by `raster/fan_roles.zig` as
//! the ink lands (`markShared`) and its fan-OUT strip resolved from the
//! Sketch's pivot geometry once the walk is done (`resolveMasks`) — never
//! re-derived from the finished grid.
//!
//! Side-table facts filed here (`lattice.Aux`): `.carrier` for ink the grid
//! cannot name, `.rail_member` for a fan peer riding a shared run (filed
//! by `fan_roles.markShared`, alongside the rail role it stamps), and
//! `.intrusion` at the two frame-border sites — the aggregate
//! `b_frame_bridge`/`b_border_fusion_refused` tallies count the same events
//! and are cross-checked against the records. No `.tap`: a peer-drawn fan's
//! branch point is implicit in a polyline corner, and this walk records what
//! it drew, never what it could infer (see `raster/rails.zig`).
//!
//! The per-cell claim contract (`writeEdgeCell`/`writeArrowCell`/
//! `writeArrowGuarded`) and the directional primitives live in
//! `edges_write.zig`, the port strokes and the head slide in
//! `edges_port.zig` (cap splits); the ones `raster/rails.zig` and the
//! raster tests reach as `edges.<name>` are re-exported below.
//! (`writeArrowGuarded` has no external caller, so this file uses it
//! directly as `ew.writeArrowGuarded` rather than re-exporting it.)

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

/// Summary of one edge-rasterization pass.
/// `cells_lost` counts every polyline/arrowhead cell that could not be
/// written because it collided with a node-owned or label cell — the
/// raster-time signature of an edge routed through geometry it does not
/// own. Summed into `RasterReport.edge_cells_lost`, which feeds selection
/// via `audit.zig` → `score.RasterCounts`.
pub const EdgeRasterReport = struct {
    edges_written: u32 = 0,
    cells_lost: u32 = 0,
    /// Terminal arrowheads refused at a node/label collision: the edge's
    /// declared decoration never ships. A strict subset of `cells_lost`
    /// events, tallied separately for the integrity report because a
    /// missing head loses the relation's orientation, not just one ink cell.
    heads_lost: u32 = 0,
    /// Crossing/transversal tallies (Amendment C: the transversal and arrowhead-sanctity rulings) plus the
    /// frame-solid border-bridge pair (`b_frame_bridge`/
    /// `b_border_fusion_refused`, D-CROSS owner ruling 2026-07-19). The two
    /// violation fields feed selection via `audit.zig` →
    /// `score.RasterCounts`; the rest flow raster → entry → diagnostics
    /// only.
    crossings: crossings.CrossingCounts = .{},
};

const EdgeWalkResult = struct {
    first_cell: ?sketch.Point = null,
    last_cell: ?sketch.Point = null,
    first_dir: ?Move = null,
    last_dir: ?Move = null,
    /// Where this edge's two arrowheads actually go, cell AND tip direction,
    /// POST-SLIDE (`edges_port.slideHead`). Derived once here and handed
    /// both to the port writers and to `rasterizeEdges`' stamp: nothing
    /// downstream re-derives a head position from the polyline.
    /// @guarded-by: edges_slide_test.zig "a decorated gap arrival stamps its head against the wall, run ink behind it"
    source_head: ?ep.Head = null,
    target_head: ?ep.Head = null,
};

/// The `CarrierKind` a merge of `edge` onto `cell` files, read from the one
/// shared answer (`crossings.carrierKind`) before the write. The gate above
/// letting a merge through is NOT that answer: the gate derives "may this
/// ink merge here" from the realized plan as well as the sets, the label
/// states what the stamped sets say and abstains where nothing was stamped.
/// Inferring `.merged_licensed` from the gate stated a licence nobody had
/// looked up.
fn carrierKindOnto(cell: *const lattice.Cell, edge: u32, c: ew.Coord, ctx: crossings.Ctx) lattice.CarrierKind {
    return crossings.carrierKindOnto(cell, ctx.bundle_sets, ctx.stamp_state, edge, null, crossings.cellAt(c.x, c.y));
}

/// Crossing-rule gate (Amendment C: transversal + arrowhead sanctity). Returns true when the existing
/// first-writer cell MUST be kept untouched (a transversal on a foreign run, a
/// refused arrowhead transit, or a lateral arm into a decoration cell —
/// refused for bundle co-members too), recording the classified event; false
/// to proceed with the pre-C merge. Applies to `edge_segment`/`arrowhead`
/// occupants only — other occupants are handled by the normal write path.
/// Every `true` return is a suppression: the incoming edge's ink runs
/// through the position and the cell will say nothing about it, so the
/// caller files a suppressed `.carrier` for it.
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

/// A refusal's mark on the kept cell: a run becomes a crossing (two paths
/// co-located, not joined); a decoration cell is never a crossing (ink
/// attribution) and keeps the state its own edge recorded.
fn markSuppressed(cell: *lattice.Cell) void {
    if (cell.occupant != .arrowhead) cell.upgradeState(.crossing);
}

/// Claim a pristine corner cell for `edge_id` with the corner mask (occupant
/// = edge_segment, neighbours replaced by `corner_mask`, stroke_kind = kind).
/// Shared by the `.empty` arm and the `.cross`-mode `.cluster_border`
/// else-branch of `walkPolyline`: welding a corner into a STILL-PRISTINE frame
/// border in `.cross` mode is byte-identical to claiming a blank cell, so that
/// "cross mode == empty behavior on a pristine border" equivalence is expressed
/// structurally — both arms call this one function.
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

/// Walk a single polyline.
///
/// Corner-cell convention: at a turn A → B, corner neighbours =
/// `bitMask(reverse(A)) | bitMask(B)` (@guarded-by: edges_corner_test.zig
/// "L-shaped corner has reverse-incoming + outgoing bits").
/// Which ends of a `.member_stroke` sit on a rail's continuing tap. Such
/// an end is no wall and carries no head: the rail's stem holds the head,
/// and the tap cell is the rail's own junction.
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

    // Count non-trivial segments so we know which is "last". // @guarded-by: edges_test.zig "edge cells colliding with node-owned cells are counted as lost"
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

        // Write the corner cell at `a`. The previous segment stops one
        // cell short of `a` (see the walk loop's `break at b`), so this is
        // the sole writer of the corner from THIS edge — a corner never
        // deposits a straight perpendicular arm here. That matters at a
        // shared rail corner (e.g. an undetected fan's sibling drops all
        // bend at the source column): the OR-merge onto a foreign owner
        // must not carry a spurious straight bit, or the rail renders `┼`
        // instead of `┴`. // @guarded-by: edges_corner_test.zig "shared rail corner: sibling drops bending at one cell yield ┴, not a phantom ┼"
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
                            // OR onto OWN ink too, not only onto a foreign
                            // run: this edge reaches a cell it already wrote
                            // only by coming BACK to it (a route that doubles
                            // back re-enters its own row or column), so both
                            // visits are real ink of one stroke. Replacing
                            // would drop the first visit's arms and sever the
                            // edge from itself — the corner turns here, it
                            // does not start here.
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
                            // Merging onto a FOREIGN run is id-dropping exactly
                            // as in `writeEdgeCell`'s `.edge_segment` arm: the
                            // corner arm goes into the mask, the cell keeps the
                            // first writer's id, and nothing on it says this
                            // edge turns here.
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
                            // Frame-solid border bridging (D-CROSS, owner ruling
                            // 2026-07-19): a corner arm onto a subgraph frame
                            // border would weld a tee (border {e,w} + corner
                            // arms → ┼/├/┤) INTO the frame. Refuse — the frame
                            // stays continuous, the corner contributes no bits.
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
                // The terminal arrowhead must point along the FINAL approach
                // into the target, i.e. this segment's outgoing direction
                // `dir` — not the corner's incoming direction `prev`. When
                // the final segment is a single cell (the target port sits
                // one cell past this corner), the walk loop below writes no
                // interior cell, so this corner is the arrowhead's cell and
                // this is the only place last_dir is set for it; recording
                // `prev` here would orient the arrowhead sideways, floating
                // it beside the box instead of into the port.
                // @guarded-by: edges_test.zig "length-1 final segment after a corner points the terminal arrowhead into the port"
                result.last_dir = if (is_last) dir else prev;
            }
        }

        // Walk (a, b); `b` is ALWAYS skipped, never drawn as a straight
        // cell: on the last segment it is the target perimeter, and on an
        // interior segment it is the next corner, which the corner-cell
        // writer above owns (drawing it straight here would leave a phantom
        // perpendicular arm at shared corners — see that comment). `a` is
        // skipped automatically since we start at step(a, dir).
        // @guarded-by: edges_test.zig "edge cells colliding with node-owned cells are counted as lost"
        var cursor = step(a, dir);
        while (true) {
            const at_b = cursor.x == b.x and cursor.y == b.y;
            if (at_b) break;

            if (pointInBounds(cursor, lat)) {
                const c = toCoord(cursor);
                const cell = lat.at(c.x, c.y);
                // Frame-solid border bridging (D-CROSS, owner ruling
                // 2026-07-19): in `.bridge` mode (the default) a THROUGH-GOING
                // segment crossing a subgraph frame border bridges it — the
                // frame glyph stays continuous, this edge contributes NO bits
                // and resumes on the far side. Only the FINAL cell of a
                // polyline that TERMINATES on the border keeps the merge
                // (writeEdgeCell's `.cluster_border` arm), a terminal arrival
                // into the cluster. The geometry cursors below still advance
                // through the skipped cell so the downstream arrowhead
                // placement is unaffected. In `.cross` mode this whole clause
                // is bypassed and the border is welded (pre-Slice-1 behavior).
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

    // Port strokes, LAST — after the walk, because the rule they obey is
    // head FACING and only the finished walk knows where the heads go and
    // which way they look: the heads resolved here (`arrow_to` on
    // `last_cell` along `last_dir`, `arrow_from` on `first_cell` along
    // `reverse(first_dir)`) are the very pairs `rasterizeEdges` stamps, so
    // the port gate and the glyph cannot disagree about where the tip looks
    // (never from the grid, which cannot tell this edge's head from a
    // foreign one). An undecorated end passes null and always merges. The
    // border cells (`pts[0]`/`pts[len-1]`) are the two positions the walk
    // never writes, so drawing the ports after it is order-independent.
    // @guarded-by: edges_port_test.zig "a head adjacent to the wall but pointing ALONG the route still tees it"
    //
    // THE SLIDE (`ep.slideHead`), applied here before either use: when the
    // polyline stops one cell short of a mergeable face, the head moves
    // FORWARD onto that gap so its tip abuts the wall directly — an
    // arrowhead is terminal and ink on its tip side is never legal. The cell
    // it vacates keeps the run ink the walk wrote there, and the slid tip
    // faces the border, so the facing gate leaves the wall plain.
    // @guarded-by: edges_slide_test.zig "a decorated gap arrival stamps its head against the wall, run ink behind it"
    // A member stroke's rail end: no head, no port — the rail owns both.
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

/// Walk every `EdgePath` in `s` and rasterize it into `lat`. Returns
/// the number of edges with at least one interior cell claimed, plus
/// the count of cells lost to collisions (see `EdgeRasterReport`).
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

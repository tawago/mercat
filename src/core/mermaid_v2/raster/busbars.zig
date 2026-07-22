//! Bus-bar rasterizer: paints each `sketch.BusBar` as one owned trunk (stem
//! + rail) plus direction-aware per-tap droppers; junction cells get explicit neighbour bits from tap
//! geometry so the painter's mask→glyph table yields `┬`/`┴`/`┼`/`├`.
//!
//! Ordering (see raster.zig): runs after nodes, before edges. Cell-claim
//! semantics match `edges.zig` (`writeEdgeCell`/`writeArrowCell`) for
//! collision accounting (`cells_lost`) and cluster-border overwrite.
//!
//! Allowed imports: std, prim, sketch, lattice, raster-internal siblings.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges_r = @import("edges.zig");

pub const Report = struct {
    /// Taps that claimed at least one cell (each tap represents one edge).
    taps_written: u32 = 0,
    /// Trunk/drop/arrow cells lost to node/label collisions.
    cells_lost: u32 = 0,
};

/// Rasterize every bus-bar in `s` into `lat`.
pub fn rasterizeBusBars(lat: *lattice.Lattice, s: sketch.Sketch) Report {
    var report: Report = .{};
    for (s.busbars) |bb| {
        drawBusBar(lat, bb, &report);
    }
    return report;
}

fn drawBusBar(lat: *lattice.Lattice, bb: sketch.BusBar, report: *Report) void {
    const trunk_edge = bb.taps[0].edge; // informational owner id for trunk cells
    const junction = bb.stem[bb.stem.len - 1];
    const fan_in = bb.role == .fan_in_rail or bb.role == .fan_in_trunk;
    const trunk_role: lattice.EdgeRole = if (fan_in) .fan_in_trunk else .fan_out_trunk;
    const tap_role: lattice.EdgeRole = if (fan_in) .fan_in_rail else .fan_out_rail;

    // Rail: every cell carries exactly its inward arm(s), from geometry.
    // guarded-by: busbars_test.zig "busbar junction bits are explicit: corner, tee, cross"
    const x0 = bb.rail[0].x;
    const x1 = bb.rail[1].x;
    const rail_y = bb.rail[0].y;
    var x = x0;
    while (x <= x1) : (x += 1) {
        const mask: lattice.Neighbours = .{ .e = x < x1, .w = x > x0 };
        claim(lat, .{ .x = x, .y = rail_y }, trunk_edge, bb.kind, trunk_role, mask, report);
    }

    // -- Stem: pivot exit bit into the node border, interior cells, and
    //    the stem arm OR'd into the junction (a rail cell).
    if (!fan_in) edges_r.mergeSourceBorder(lat, bb.stem, bb.kind);
    var i: usize = 0;
    var last_dir: ?edges_r.Move = null;
    while (i + 1 < bb.stem.len) : (i += 1) {
        const a = bb.stem[i];
        const b = bb.stem[i + 1];
        const dir = edges_r.segmentDir(a, b) orelse continue;
        if (last_dir) |prev| {
            claim(lat, a, trunk_edge, bb.kind, trunk_role, edges_r.orMask(edges_r.bitMask(edges_r.reverse(prev)), edges_r.bitMask(dir)), report);
        }
        var cursor = edges_r.step(a, dir);
        while (cursor.x != b.x or cursor.y != b.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, trunk_edge, bb.kind, trunk_role, edges_r.straightMask(dir), report);
        }
        last_dir = dir;
    }
    if (last_dir) |dir| {
        claim(lat, junction, trunk_edge, bb.kind, trunk_role, edges_r.bitMask(edges_r.reverse(dir)), report);
    }
    if (bb.pivot_arrow != .none) {
        var si: usize = 0;
        while (si + 1 < bb.stem.len) : (si += 1) {
            const dir = edges_r.segmentDir(bb.stem[si], bb.stem[si + 1]) orelse continue;
            const p = edges_r.step(bb.stem[0], dir);
            if (edges_r.pointInBounds(p, lat)) {
                const c = edges_r.toCoord(p);
                edges_r.writeArrowCell(lat.at(c.x, c.y), trunk_edge, bb.kind, edges_r.reverse(dir), edges_r.straightMask(dir), c.x, c.y, &report.cells_lost);
            }
            break;
        }
    }

    // -- Taps: drop arm OR'd into the rail cell, dropper cells, arrowhead
    //    on the last cell before the landing (the node perimeter).
    for (bb.taps) |tap| {
        if (fan_in) {
            const source_stub = [_]sketch.Point{ tap.landing, tap.at };
            edges_r.mergeSourceBorder(lat, &source_stub, bb.kind);
        }
        const dir = edges_r.segmentDir(tap.at, tap.landing) orelse continue;
        claim(lat, tap.at, tap.edge, bb.kind, trunk_role, edges_r.bitMask(dir), report);
        var wrote_any = false;
        var last_cell: ?sketch.Point = null;
        var cursor = edges_r.step(tap.at, dir);
        while (cursor.x != tap.landing.x or cursor.y != tap.landing.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, tap.edge, bb.kind, tap_role, edges_r.straightMask(dir), report);
            wrote_any = true;
            last_cell = cursor;
        }
        if (tap.arrow != .none) {
            if (last_cell) |p| {
                if (edges_r.pointInBounds(p, lat)) {
                    const c = edges_r.toCoord(p);
                    const arrow_dir = if (fan_in) edges_r.reverse(dir) else dir;
                    edges_r.writeArrowCell(lat.at(c.x, c.y), tap.edge, bb.kind, arrow_dir, edges_r.straightMask(dir), c.x, c.y, &report.cells_lost);
                }
            }
        }
        if (wrote_any) report.taps_written += 1;
    }
}

/// Claim one cell through the shared edge cell contract (OR-merge on
/// existing edge cells, overwrite cluster borders, count collisions).
fn claim(
    lat: *lattice.Lattice,
    p: sketch.Point,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    mask: lattice.Neighbours,
    report: *Report,
) void {
    if (!edges_r.pointInBounds(p, lat)) return;
    const c = edges_r.toCoord(p);
    edges_r.writeEdgeCell(lat.at(c.x, c.y), edge_id, kind, role, mask, c.x, c.y, &report.cells_lost);
}

test {
    _ = @import("busbars_test.zig");
}

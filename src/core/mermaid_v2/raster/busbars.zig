//! Bus-bar rasterizer: paints each `sketch.Rail` as one owned trunk (stem
//! + rail) plus direction-aware per-tap droppers; junction cells get explicit neighbour bits from tap
//! geometry so the painter's mask→glyph table yields `┬`/`┴`/`┼`/`├`.
//!
//! Ordering (see raster.zig): runs after nodes, before edges. Cell-claim
//! semantics match `edges.zig` (`writeEdgeCell`/`writeArrowCell`) for
//! collision accounting (`cells_lost`) and cluster-border overwrite.
//!
//! SIDE TABLE. A rail's taps have no `EdgePath` anywhere in the Sketch —
//! the shared run IS their geometry — so a member is invisible to the cell
//! grid except on its own dropper. This file therefore files the two
//! records that recover them: a `.rail_member` for every member riding a
//! shared-run cell the Cell does not name, and a `.tap` at each member's
//! branch cell. Both only where ink actually landed; a cell the rail lost
//! to a node or a label carries no membership.
//!
//! GAP (honest, not a to-do disguised as prose): peer-drawn fans — grid-
//! wrapped fan-OUT, declined fans, fan-IN routed as per-peer polylines —
//! reach the grid through `edges.zig` instead, which files their
//! `.rail_member` records but NO `.tap`. Their branch point is implicit in
//! a polyline corner, and the raster refuses to infer a fact the geometry
//! never states. Closing it means naming the branch in the Sketch.
//!
//! Allowed imports: std, prim, sketch, lattice, raster-internal siblings.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges_r = @import("edges.zig");
const ew = @import("edges_write.zig");
const aux = @import("aux.zig");

pub const Report = struct {
    /// Taps that claimed at least one cell (each tap represents one edge).
    taps_written: u32 = 0,
    /// Trunk/drop/arrow cells lost to node/label collisions.
    cells_lost: u32 = 0,
};

/// Rasterize every bus-bar in `s` into `lat`.
pub fn rasterizeRails(lat: *lattice.Lattice, s: sketch.Sketch, sink: aux.Sink) Report {
    var report: Report = .{};
    for (s.busbars) |bb| {
        drawRail(lat, bb, &report, sink);
    }
    return report;
}

fn drawRail(lat: *lattice.Lattice, bb: sketch.Rail, report: *Report, sink: aux.Sink) void {
    const rec = aux.Recorder.init(sink, lat);
    const crossbar_edge = bb.taps[0].edge; // informational owner id for shared-run cells
    const junction = bb.stem[bb.stem.len - 1];
    const fan_in = bb.role == .fan_in_dropper or bb.role == .fan_in_rail;
    const crossbar_role: lattice.EdgeRole = if (fan_in) .fan_in_rail else .fan_out_rail;
    const dropper_role: lattice.EdgeRole = if (fan_in) .fan_in_dropper else .fan_out_dropper;
    const polarity: lattice.RailPolarity = if (fan_in) .in else .out;

    // Rail: every cell carries exactly its inward arm(s), from geometry.
    // guarded-by: busbars_test.zig "busbar junction bits are explicit: corner, tee, cross"
    const x0 = bb.crossbar[0].x;
    const x1 = bb.crossbar[1].x;
    const rail_y = bb.crossbar[0].y;
    var x = x0;
    while (x <= x1) : (x += 1) {
        const mask: lattice.Neighbours = .{ .e = x < x1, .w = x > x0 };
        claim(lat, .{ .x = x, .y = rail_y }, crossbar_edge, bb.kind, crossbar_role, mask, report, rec);
    }

    // -- Stem: pivot exit bit into the node border, interior cells, and
    //    the stem arm OR'd into the junction (a rail cell).
    // The stem departs the pivot, so the port belongs to the run's owner id
    // (the same informational id the shared-run cells carry).
    if (!fan_in) edges_r.drawPortStroke(lat, bb.stem, bb.kind, crossbar_edge, sink);
    var i: usize = 0;
    var last_dir: ?edges_r.Move = null;
    while (i + 1 < bb.stem.len) : (i += 1) {
        const a = bb.stem[i];
        const b = bb.stem[i + 1];
        const dir = edges_r.segmentDir(a, b) orelse continue;
        if (last_dir) |prev| {
            claim(lat, a, crossbar_edge, bb.kind, crossbar_role, edges_r.orMask(edges_r.bitMask(edges_r.reverse(prev)), edges_r.bitMask(dir)), report, rec);
        }
        var cursor = edges_r.step(a, dir);
        while (cursor.x != b.x or cursor.y != b.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, crossbar_edge, bb.kind, crossbar_role, edges_r.straightMask(dir), report, rec);
        }
        last_dir = dir;
    }
    if (last_dir) |dir| {
        claim(lat, junction, crossbar_edge, bb.kind, crossbar_role, edges_r.bitMask(edges_r.reverse(dir)), report, rec);
    }
    if (bb.pivot_arrow != .none) {
        var si: usize = 0;
        while (si + 1 < bb.stem.len) : (si += 1) {
            const dir = edges_r.segmentDir(bb.stem[si], bb.stem[si + 1]) orelse continue;
            const p = edges_r.step(bb.stem[0], dir);
            if (edges_r.pointInBounds(p, lat)) {
                const c = edges_r.toCoord(p);
                edges_r.writeArrowCell(lat.at(c.x, c.y), crossbar_edge, bb.kind, bb.pivot_arrow, edges_r.reverse(dir), edges_r.straightMask(dir), c.x, c.y, &report.cells_lost, rec);
            }
            break;
        }
    }

    // -- Taps: drop arm OR'd into the rail cell, dropper cells, arrowhead
    //    on the last cell before the landing (the node perimeter).
    for (bb.taps) |tap| {
        if (fan_in) {
            const source_stub = [_]sketch.Point{ tap.landing, tap.at };
            edges_r.drawPortStroke(lat, &source_stub, bb.kind, tap.edge, sink);
        }
        const dir = edges_r.segmentDir(tap.at, tap.landing) orelse continue;
        claim(lat, tap.at, tap.edge, bb.kind, crossbar_role, edges_r.bitMask(dir), report, rec);
        // The branch itself: the cell just grew this tap's drop arm, and
        // nothing on it says whose arm that is (the run belongs to the
        // shared owner id, and the mask is a merge). A tap with no drop
        // reached `continue` above and files nothing — the record follows
        // the ink, not the Sketch.
        // guarded-by: busbars_test.zig "a rail files its members on the shared run and a tap at each branch cell"
        if (inkAt(lat, tap.at)) |c| ew.recordTap(rec, c.x, c.y, tap.edge, polarity);
        var wrote_any = false;
        var last_cell: ?sketch.Point = null;
        var cursor = edges_r.step(tap.at, dir);
        while (cursor.x != tap.landing.x or cursor.y != tap.landing.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, tap.edge, bb.kind, dropper_role, edges_r.straightMask(dir), report, rec);
            wrote_any = true;
            last_cell = cursor;
        }
        if (tap.arrow != .none) {
            if (last_cell) |p| {
                if (edges_r.pointInBounds(p, lat)) {
                    const c = edges_r.toCoord(p);
                    const arrow_dir = if (fan_in) edges_r.reverse(dir) else dir;
                    edges_r.writeArrowCell(lat.at(c.x, c.y), tap.edge, bb.kind, tap.arrow, arrow_dir, edges_r.straightMask(dir), c.x, c.y, &report.cells_lost, rec);
                }
            }
        }
        if (wrote_any) report.taps_written += 1;
    }

    recordMembership(lat, bb, polarity, rec);
}

/// Coordinates of `p` when the cell there carries edge ink, else null.
/// Membership is a claim about ink: a position the rail never won (a node,
/// a label, out of bounds) has no riders to record.
fn inkAt(lat: *const lattice.Lattice, p: sketch.Point) ?ew.Coord {
    if (!edges_r.pointInBounds(p, lat)) return null;
    const c = edges_r.toCoord(p);
    return switch (lat.atConst(c.x, c.y).occupant) {
        .edge_segment, .arrowhead => c,
        else => null,
    };
}

/// File `.rail_member` records over the rail's whole shared run: the stem
/// (every member's ink leaves the pivot through it) and the crossbar (a
/// member rides it between the junction and its own branch cell, and no
/// further). Runs last, over the finished ink, so a cell lost to a
/// collision records nobody.
///
/// The member the Cell already names is skipped: that one IS on the grid,
/// and restating it would put a second, staleable copy of a Cell field on
/// the side table (lattice.zig's anti-desync law). Droppers are skipped for
/// the same reason — a dropper carries exactly one member and says so.
/// guarded-by: busbars_test.zig "a rail files its members on the shared run and a tap at each branch cell"
fn recordMembership(
    lat: *const lattice.Lattice,
    bb: sketch.Rail,
    polarity: lattice.RailPolarity,
    rec: aux.Recorder,
) void {
    if (rec.sink == null) return;
    const junction = bb.stem[bb.stem.len - 1];

    var si: usize = 0;
    while (si + 1 < bb.stem.len) : (si += 1) {
        const dir = edges_r.segmentDir(bb.stem[si], bb.stem[si + 1]) orelse continue;
        // Half-open [a, b): each stem point is visited once, and the
        // junction is reached below as a crossbar cell.
        var cursor = bb.stem[si];
        while (cursor.x != bb.stem[si + 1].x or cursor.y != bb.stem[si + 1].y) : (cursor = edges_r.step(cursor, dir)) {
            recordMembersAt(lat, cursor, bb, junction, polarity, rec);
        }
    }

    var x = bb.crossbar[0].x;
    while (x <= bb.crossbar[1].x) : (x += 1) {
        recordMembersAt(lat, .{ .x = x, .y = bb.crossbar[0].y }, bb, junction, polarity, rec);
    }
}

/// One shared-run cell: file every member whose ink rides it and whom the
/// Cell does not name.
fn recordMembersAt(
    lat: *const lattice.Lattice,
    p: sketch.Point,
    bb: sketch.Rail,
    junction: sketch.Point,
    polarity: lattice.RailPolarity,
    rec: aux.Recorder,
) void {
    if (!edges_r.pointInBounds(p, lat)) return;
    const c = edges_r.toCoord(p);
    const named: u32 = switch (lat.atConst(c.x, c.y).occupant) {
        .edge_segment => |seg| seg.edge,
        .arrowhead => |head| head.edge,
        // A position the rail never won (a node, a label) carries no ink,
        // so it carries no riders either.
        else => return,
    };
    for (bb.taps) |tap| {
        if (tap.edge == named) continue;
        // On the crossbar a member rides only the stretch between the
        // junction and its own branch; the far side of the rail conducts
        // somebody else entirely.
        if (p.y == bb.crossbar[0].y and !onStretch(p.x, junction.x, tap.at.x)) continue;
        ew.recordRailMember(rec, c.x, c.y, tap.edge, polarity);
    }
}

fn onStretch(v: i32, a: i32, b: i32) bool {
    return v >= @min(a, b) and v <= @max(a, b);
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
    rec: aux.Recorder,
) void {
    if (!edges_r.pointInBounds(p, lat)) return;
    const c = edges_r.toCoord(p);
    edges_r.writeEdgeCell(lat.at(c.x, c.y), edge_id, kind, role, mask, c.x, c.y, &report.cells_lost, rec);
}

test {
    _ = @import("busbars_test.zig");
}

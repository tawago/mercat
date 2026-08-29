//! Rail rasterizer: paints each `sketch.Rail` as one owned trunk (stem
//! + crossbar) plus direction-aware per-tap droppers; junction cells get explicit neighbour bits from tap
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
const crossings = @import("crossings.zig");
const ledger = @import("../base/ledger.zig");
const aux = @import("aux.zig");

/// The channel identity a rail needs in order to STATE the licence on
/// every carrier it files. A rail's cells are the one merge path in the
/// raster that never consulted the crossing rule — it does not need to, it
/// owns its geometry — so without this the records it leaves could not say
/// whether a junction glyph it painted over someone else's ink was legal.
/// Carried, never acted on: nothing here refuses a merge or moves a byte.
///
/// `channel` is the CURRENT rail's own identity, stamped on the Sketch by the
/// producer (`sketch_channels.stamp`) and swapped per rail by
/// `rasterizeRails`. It is what makes this a lookup: the writer already knows
/// which channel its ink speaks for and does not reconstruct it from a
/// membership scan. `roster` answers the same question for whoever it MEETS.
/// guarded-by: rails_test2.zig "a rail reports licensed or foreign without changing bytes"
const Chan = struct {
    roster: []const ledger.CoSet = &.{},
    channel: ledger.ChannelId = ledger.no_channel,
    stamp_state: sketch.ChannelStampState = .unattempted,
};

/// The merged-carrier flavour for whatever the cell at `c` ALREADY names,
/// against `incoming`. Read before the write: afterwards the cell names the
/// first writer either way and the pair is unrecoverable. A cell naming
/// nobody files no carrier, so its value is `.merged_untested` — never
/// `.merged_licensed`, which would state a licence no one asked for.
///
/// Both sides are read as identities. The rail's own is `chan.channel` when
/// the producer filed one; where it did not, `incoming` still has the channel
/// every edge has, and the comparison is the same comparison.
///
/// ABSTAINS unless the producer's transaction completed AND every roster set
/// is numbered. A failed/refused re-stamp deliberately preserves the old
/// payload, so neither a nonzero rail name nor a numbered roster is sufficient
/// without `.complete`; the inverse inconsistency also abstains.
/// guarded-by: rails.zig "licenceAt trusts identity only after a complete consistent stamp"
fn licenceAt(lat: *const lattice.Lattice, c: ew.Coord, incoming: u32, chan: Chan) lattice.CarrierKind {
    const held: u32 = switch (lat.atConst(c.x, c.y).occupant) {
        .edge_segment => |seg| seg.edge,
        .arrowhead => |h| h.edge,
        else => return .merged_untested,
    };
    if (chan.stamp_state != .complete or !ledger.rosterNumbered(chan.roster)) return .merged_untested;
    if (held == incoming) return .merged_licensed;
    const at = crossings.cellAt(c.x, c.y);
    const mine = if (chan.channel != ledger.no_channel)
        chan.channel
    else
        crossings.channelAt(chan.roster, incoming, at);
    return if (mine == crossings.channelAt(chan.roster, held, at))
        .merged_licensed
    else
        .merged_foreign;
}

pub const Report = struct {
    /// Taps that claimed at least one cell (each tap represents one edge).
    taps_written: u32 = 0,
    /// Trunk/drop/arrow cells lost to node/label collisions.
    cells_lost: u32 = 0,
    /// Rail pivot/tap arrowheads refused at a collision — same contract as
    /// `edges.EdgeRasterReport.heads_lost`.
    heads_lost: u32 = 0,
};

/// Rasterize every rail in `s` into `lat`.
pub fn rasterizeRails(lat: *lattice.Lattice, s: sketch.Sketch, sink: aux.Sink) Report {
    var report: Report = .{};
    for (s.rails) |bb| {
        drawRail(lat, bb, &report, .{
            .roster = s.co_sets,
            .channel = bb.channel,
            .stamp_state = s.channel_stamp_state,
        }, sink);
    }
    return report;
}

fn drawRail(lat: *lattice.Lattice, bb: sketch.Rail, report: *Report, chan: Chan, sink: aux.Sink) void {
    const rec = aux.Recorder.init(sink, lat);
    const crossbar_edge = bb.taps[0].edge; // informational owner id for shared-run cells
    const junction = bb.stem[bb.stem.len - 1];
    const fan_in = bb.role == .fan_in_dropper or bb.role == .fan_in_rail;
    const crossbar_role: lattice.EdgeRole = if (fan_in) .fan_in_rail else .fan_out_rail;
    const dropper_role: lattice.EdgeRole = if (fan_in) .fan_in_dropper else .fan_out_dropper;
    const polarity: lattice.RailPolarity = if (fan_in) .in else .out;

    // Rail: every cell carries exactly its inward arm(s), from geometry.
    // guarded-by: rails_test.zig "rail junction bits are explicit: corner, tee, cross"
    const x0 = bb.crossbar[0].x;
    const x1 = bb.crossbar[1].x;
    const rail_y = bb.crossbar[0].y;
    var x = x0;
    while (x <= x1) : (x += 1) {
        const mask: lattice.Neighbours = .{ .e = x < x1, .w = x > x0 };
        claim(lat, .{ .x = x, .y = rail_y }, crossbar_edge, bb.kind, crossbar_role, mask, report, chan, rec);
    }

    // -- Stem: pivot exit bit into the node border, interior cells, and
    //    the stem arm OR'd into the junction (a rail cell).
    // The stem departs the pivot, so the port belongs to the run's owner id
    // (the same informational id the shared-run cells carry).
    // The pivot end is decorated exactly when `pivot_arrow` is declared, and
    // its head is stamped one cell out from `stem[0]` pointing back down the
    // stem (see the stamping block below, which reads the same geometry).
    // The port tee is dropped only when that head's TIP FACES the border
    // cell — the redundant-tee case; any other head keeps its tee so the
    // stem still visibly attaches.
    // guarded-by: rails_test.zig "a pivot head facing the border leaves it pristine; a detached one tees"
    const pivot_head = pivotHead(bb);
    const pivot_end: edges_r.PortEnd = .{ .head = pivot_head, .role = crossbar_role };
    if (!fan_in) edges_r.drawPortStroke(lat, bb.stem, bb.kind, crossbar_edge, pivot_end, sink);
    // Fan-IN: the pivot is the TARGET — its port cell is stem[0], reached
    // from the stem side, so the arrival stroke comes from the reversed
    // two-point stub (uniform port erasure, both ends of every run).
    if (fan_in and bb.stem.len >= 2) {
        const pivot_stub = [_]sketch.Point{ bb.stem[1], bb.stem[0] };
        edges_r.drawTargetPortStroke(lat, &pivot_stub, bb.kind, crossbar_edge, pivot_end, sink);
    }
    var i: usize = 0;
    var last_dir: ?edges_r.Move = null;
    while (i + 1 < bb.stem.len) : (i += 1) {
        const a = bb.stem[i];
        const b = bb.stem[i + 1];
        const dir = edges_r.segmentDir(a, b) orelse continue;
        if (last_dir) |prev| {
            claim(lat, a, crossbar_edge, bb.kind, crossbar_role, edges_r.orMask(edges_r.bitMask(edges_r.reverse(prev)), edges_r.bitMask(dir)), report, chan, rec);
        }
        var cursor = edges_r.step(a, dir);
        while (cursor.x != b.x or cursor.y != b.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, crossbar_edge, bb.kind, crossbar_role, edges_r.straightMask(dir), report, chan, rec);
        }
        last_dir = dir;
    }
    if (last_dir) |dir| {
        claim(lat, junction, crossbar_edge, bb.kind, crossbar_role, edges_r.bitMask(edges_r.reverse(dir)), report, chan, rec);
    }
    if (pivot_head) |h| {
        if (pivotStemDir(bb)) |dir| {
            if (edges_r.pointInBounds(h.cell, lat)) {
                const c = edges_r.toCoord(h.cell);
                const lic = licenceAt(lat, c, crossbar_edge, chan);
                edges_r.writeArrowCell(lat.at(c.x, c.y), crossbar_edge, bb.kind, bb.pivot_arrow, h.dir, edges_r.straightMask(dir), c.x, c.y, &report.cells_lost, &report.heads_lost, lic, rec);
            }
        }
    }

    // -- Taps: drop arm OR'd into the rail cell, dropper cells, arrowhead
    //    on the last cell before the landing (the node perimeter).
    for (bb.taps) |tap| {
        // The MEMBER end of a tap is decorated exactly when `tap.arrow` is
        // declared: fan-OUT stamps that head pointing INTO the landing,
        // fan-IN stamps it reversed (a back-arrow at the member). Either
        // way the head lands on the tap's LAST dropper cell with its tip
        // toward the landing (fan-OUT) or away from it (fan-IN), so the port
        // tee is dropped only when that tip FACES the landing — the same
        // rule the polyline ports obey. A tap whose dropper stops short of
        // the wall, or whose head looks the other way, keeps its tee.
        // guarded-by: rails_test.zig "a tap head facing the landing leaves the member border pristine; an undecorated tap tees it"
        const tap_head = tapHead(tap, fan_in);
        const tap_end: edges_r.PortEnd = .{ .head = tap_head, .role = dropper_role };
        if (fan_in) {
            const source_stub = [_]sketch.Point{ tap.landing, tap.at };
            edges_r.drawPortStroke(lat, &source_stub, bb.kind, tap.edge, tap_end, sink);
        } else {
            // Fan-OUT: each tap terminates on its member's TARGET border at
            // `tap.landing`; merge the arrival arm there (symmetric with the
            // fan-IN source stub above — no cell is painted twice, the two
            // stubs end on different nodes' borders).
            const target_stub = [_]sketch.Point{ tap.at, tap.landing };
            edges_r.drawTargetPortStroke(lat, &target_stub, bb.kind, tap.edge, tap_end, sink);
        }
        const dir = edges_r.segmentDir(tap.at, tap.landing) orelse continue;
        claim(lat, tap.at, tap.edge, bb.kind, crossbar_role, edges_r.bitMask(dir), report, chan, rec);
        // The branch itself: the cell just grew this tap's drop arm, and
        // nothing on it says whose arm that is (the run belongs to the
        // shared owner id, and the mask is a merge). A tap with no drop
        // reached `continue` above and files nothing — the record follows
        // the ink, not the Sketch.
        // guarded-by: rails_test.zig "a rail files its members on the shared run and a tap at each branch cell"
        if (inkAt(lat, tap.at)) |c| ew.recordTap(rec, c.x, c.y, tap.edge, polarity);
        var wrote_any = false;
        var cursor = edges_r.step(tap.at, dir);
        while (cursor.x != tap.landing.x or cursor.y != tap.landing.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, tap.edge, bb.kind, dropper_role, edges_r.straightMask(dir), report, chan, rec);
            wrote_any = true;
        }
        // `tapHead` IS the loop's last cursor plus the tip direction stamped
        // here — derived once so the port gate above and this stamp cannot
        // disagree about where the head is or which way it looks.
        if (tap.arrow != .none) {
            if (tap_head) |h| {
                if (edges_r.pointInBounds(h.cell, lat)) {
                    const c = edges_r.toCoord(h.cell);
                    const lic = licenceAt(lat, c, tap.edge, chan);
                    edges_r.writeArrowCell(lat.at(c.x, c.y), tap.edge, bb.kind, tap.arrow, h.dir, edges_r.straightMask(dir), c.x, c.y, &report.cells_lost, &report.heads_lost, lic, rec);
                }
            }
        }
        if (wrote_any) report.taps_written += 1;
    }

    recordMembership(lat, bb, polarity, rec);
}

/// The stem's first real direction — the axis the pivot head points along.
fn pivotStemDir(bb: sketch.Rail) ?edges_r.Move {
    var si: usize = 0;
    while (si + 1 < bb.stem.len) : (si += 1) {
        if (edges_r.segmentDir(bb.stem[si], bb.stem[si + 1])) |d| return d;
    }
    return null;
}

/// The pivot arrowhead: stamped one step out from `stem[0]` along the stem,
/// pointing BACK at the pivot. Null when the pivot end carries no head.
/// Sole derivation: both the port gate and the arrow stamp read it, so the
/// tip direction the gate tests is the one the painter draws.
fn pivotHead(bb: sketch.Rail) ?edges_r.Head {
    if (bb.pivot_arrow == .none) return null;
    const dir = pivotStemDir(bb) orelse return null;
    return .{ .cell = edges_r.step(bb.stem[0], dir), .dir = edges_r.reverse(dir) };
}

/// A tap's arrowhead: the LAST dropper cell, one step back from the landing,
/// pointing INTO the landing on a fan-OUT and away from it on a fan-IN (a
/// back-arrow at the member). Null when the tap carries no head, has no
/// direction, or has no dropper at all (`at` already abuts `landing`, so
/// the loop writes nothing and no head is stamped).
fn tapHead(tap: sketch.Tap, fan_in: bool) ?edges_r.Head {
    if (tap.arrow == .none) return null;
    const dir = edges_r.segmentDir(tap.at, tap.landing) orelse return null;
    const first = edges_r.step(tap.at, dir);
    if (first.x == tap.landing.x and first.y == tap.landing.y) return null;
    return .{
        .cell = edges_r.step(tap.landing, edges_r.reverse(dir)),
        .dir = if (fan_in) edges_r.reverse(dir) else dir,
    };
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
/// guarded-by: rails_test.zig "a rail files its members on the shared run and a tap at each branch cell"
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
///
/// The merge itself is unconditional, exactly as before: a rail owns its
/// geometry and the crossing rule is not asked to approve it. `chan` only
/// supplies the licence the resulting carrier record STATES, so a later
/// reader can tell a rail welding onto a channel-mate from a rail welding
/// onto a stranger. Refusing the latter would change every fan render and
/// is not this file's decision to take.
fn claim(
    lat: *lattice.Lattice,
    p: sketch.Point,
    edge_id: u32,
    kind: lattice.EdgeKind,
    role: lattice.EdgeRole,
    mask: lattice.Neighbours,
    report: *Report,
    chan: Chan,
    rec: aux.Recorder,
) void {
    if (!edges_r.pointInBounds(p, lat)) return;
    const c = edges_r.toCoord(p);
    const lic = licenceAt(lat, c, edge_id, chan);
    edges_r.writeEdgeCell(lat.at(c.x, c.y), edge_id, kind, role, mask, c.x, c.y, &report.cells_lost, lic, rec);
}

test "licenceAt trusts identity only after a complete consistent stamp" {
    const std_testing = std.testing;
    var lat = lattice.Lattice{
        .width = 1,
        .height = 1,
        .cells = try std_testing.allocator.alloc(lattice.Cell, 1),
    };
    defer std_testing.allocator.free(lat.cells);
    lat.cells[0] = lattice.Cell.empty;
    lat.at(0, 0).occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid, .role = .forward } };

    var members = [_]ledger.EdgeId{ 0, 1 };
    const unstamped = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &members }};
    const c: ew.Coord = .{ .x = 0, .y = 0 };

    const stamped = try ledger.numberChannels(std_testing.allocator, &unstamped);
    defer std_testing.allocator.free(stamped);

    // A transaction failure/refusal can leave this fully numbered, nonzero
    // payload behind. State still makes every identity answer abstain.
    for ([_]sketch.ChannelStampState{ .unattempted, .out_of_memory, .rail_invariant }) |state| {
        const chan: Chan = .{ .roster = stamped, .channel = 1, .stamp_state = state };
        try std_testing.expectEqual(lattice.CarrierKind.merged_untested, licenceAt(&lat, c, 1, chan));
    }

    // Complete state cannot rescue an inconsistent, partly unnumbered roster.
    const inconsistent: Chan = .{ .roster = &unstamped, .channel = 1, .stamp_state = .complete };
    try std_testing.expectEqual(lattice.CarrierKind.merged_untested, licenceAt(&lat, c, 1, inconsistent));

    const complete: Chan = .{ .roster = stamped, .channel = 1, .stamp_state = .complete };
    try std_testing.expectEqual(lattice.CarrierKind.merged_licensed, licenceAt(&lat, c, 1, complete));
    const off_roster: Chan = .{ .roster = stamped, .channel = 2, .stamp_state = .complete };
    try std_testing.expectEqual(lattice.CarrierKind.merged_foreign, licenceAt(&lat, c, 2, off_roster));
}

test {
    _ = @import("rails_test.zig");
}

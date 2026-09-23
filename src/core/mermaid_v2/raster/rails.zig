const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges_r = @import("edges.zig");
const ew = @import("edges_write.zig");
const crossings = @import("crossings.zig");
const ledger = @import("../base/ledger.zig");
const aux = @import("aux.zig");

/// @guarded-by: rails_test2.zig "a rail reports licensed or foreign without changing bytes"
const Chan = struct {
    bundle_sets: []const ledger.Bundle = &.{},
    bundle: ledger.BundleId = ledger.no_bundle,
    stamp_state: sketch.BundleStampState = .unattempted,
};

/// @guarded-by: rails.zig "carrierKindAt trusts identity only after a complete consistent stamp"
fn carrierKindAt(lat: *const lattice.Lattice, c: ew.Coord, incoming: u32, chan: Chan) lattice.CarrierKind {
    const rail: ?ledger.BundleId = if (chan.bundle != ledger.no_bundle) chan.bundle else null;
    return crossings.carrierKindOnto(lat.atConst(c.x, c.y), chan.bundle_sets, chan.stamp_state, incoming, rail, crossings.cellAt(c.x, c.y));
}

pub const Report = struct {
    taps_written: u32 = 0,
    cells_lost: u32 = 0,
    heads_lost: u32 = 0,
    crossings: crossings.CrossingCounts = .{},
};

pub fn rasterizeRails(lat: *lattice.Lattice, s: sketch.Sketch, sink: aux.Sink) Report {
    var report: Report = .{};
    for (s.rails) |rail| {
        drawRail(lat, rail, &report, .{
            .bundle_sets = s.bundle_sets,
            .bundle = rail.bundle,
            .stamp_state = s.bundle_stamp_state,
        }, sink);
    }
    return report;
}

fn drawRail(lat: *lattice.Lattice, rail: sketch.Rail, report: *Report, chan: Chan, sink: aux.Sink) void {
    const rec = aux.Recorder.init(sink, lat);
    const crossbar_edge = rail.taps[0].edge;
    const junction = rail.stem[rail.stem.len - 1];
    const fan_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
    const crossbar_role: lattice.EdgeRole = if (fan_in) .fan_in_rail else .fan_out_rail;
    const dropper_role: lattice.EdgeRole = if (fan_in) .fan_in_dropper else .fan_out_dropper;
    const polarity: lattice.RailPolarity = if (fan_in) .in else .out;

    // @guarded-by: rails_test.zig "rail junction bits are explicit: corner, tee, cross"
    const x0 = rail.crossbar[0].x;
    const x1 = rail.crossbar[1].x;
    const rail_y = rail.crossbar[0].y;
    var x = x0;
    while (x <= x1) : (x += 1) {
        const mask: lattice.Neighbours = .{ .e = x < x1, .w = x > x0 };
        claim(lat, .{ .x = x, .y = rail_y }, crossbar_edge, rail.kind, crossbar_role, mask, report, chan, rec);
    }

    // @guarded-by: rails_test.zig "a pivot head facing the border leaves it pristine; a detached one tees"
    const pivot_head = pivotHead(rail);
    const pivot_end: edges_r.PortEnd = .{ .head = pivot_head, .role = crossbar_role };
    if (!fan_in) edges_r.drawPortStroke(lat, rail.stem, rail.kind, crossbar_edge, pivot_end, sink);
    if (fan_in and rail.stem.len >= 2) {
        const pivot_stub = [_]sketch.Point{ rail.stem[1], rail.stem[0] };
        edges_r.drawTargetPortStroke(lat, &pivot_stub, rail.kind, crossbar_edge, pivot_end, sink);
    }
    var i: usize = 0;
    var last_dir: ?edges_r.Move = null;
    while (i + 1 < rail.stem.len) : (i += 1) {
        const a = rail.stem[i];
        const b = rail.stem[i + 1];
        const dir = edges_r.segmentDir(a, b) orelse continue;
        if (last_dir) |prev| {
            claim(lat, a, crossbar_edge, rail.kind, crossbar_role, edges_r.orMask(edges_r.bitMask(edges_r.reverse(prev)), edges_r.bitMask(dir)), report, chan, rec);
        }
        var cursor = edges_r.step(a, dir);
        while (cursor.x != b.x or cursor.y != b.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, crossbar_edge, rail.kind, crossbar_role, edges_r.straightMask(dir), report, chan, rec);
        }
        last_dir = dir;
    }
    if (last_dir) |dir| {
        claim(lat, junction, crossbar_edge, rail.kind, crossbar_role, edges_r.bitMask(edges_r.reverse(dir)), report, chan, rec);
    }
    if (pivot_head) |h| {
        if (pivotStemDir(rail)) |dir| {
            if (edges_r.pointInBounds(h.cell, lat)) {
                const c = edges_r.toCoord(h.cell);
                const lic = carrierKindAt(lat, c, crossbar_edge, chan);
                edges_r.writeArrowCell(lat.at(c.x, c.y), crossbar_edge, rail.kind, rail.pivot_arrow, h.dir, edges_r.straightMask(dir), c.x, c.y, &report.cells_lost, &report.heads_lost, &report.crossings, lic, rec);
            }
        }
    }

    for (rail.taps) |tap| {
        // @guarded-by: rails_test.zig "a tap head facing the landing leaves the member border pristine; an undecorated tap tees it"
        // @guarded-by: rails_test.zig "a continuing tap claims its junction arm and paints neither port nor head"
        const tap_head = if (tap.continues) null else tapHead(tap, fan_in);
        const tap_end: edges_r.PortEnd = .{ .head = tap_head, .role = dropper_role };
        if (tap.continues) {} else if (fan_in) {
            const source_stub = [_]sketch.Point{ tap.landing, tap.at };
            edges_r.drawPortStroke(lat, &source_stub, rail.kind, tap.edge, tap_end, sink);
        } else {
            const target_stub = [_]sketch.Point{ tap.at, tap.landing };
            edges_r.drawTargetPortStroke(lat, &target_stub, rail.kind, tap.edge, tap_end, sink);
        }
        const dir = edges_r.segmentDir(tap.at, tap.landing) orelse continue;
        claim(lat, tap.at, tap.edge, rail.kind, crossbar_role, edges_r.bitMask(dir), report, chan, rec);
        // @guarded-by: rails_test.zig "a rail files its members on the shared run and a tap at each branch cell"
        if (inkAt(lat, tap.at)) |c| ew.recordTap(rec, c.x, c.y, tap.edge, polarity);
        var wrote_any = false;
        var cursor = edges_r.step(tap.at, dir);
        while (cursor.x != tap.landing.x or cursor.y != tap.landing.y) : (cursor = edges_r.step(cursor, dir)) {
            claim(lat, cursor, tap.edge, rail.kind, dropper_role, edges_r.straightMask(dir), report, chan, rec);
            wrote_any = true;
        }
        if (tap.arrow != .none and !tap.continues) {
            if (tap_head) |h| {
                if (edges_r.pointInBounds(h.cell, lat)) {
                    const c = edges_r.toCoord(h.cell);
                    const lic = carrierKindAt(lat, c, tap.edge, chan);
                    edges_r.writeArrowCell(lat.at(c.x, c.y), tap.edge, rail.kind, tap.arrow, h.dir, edges_r.straightMask(dir), c.x, c.y, &report.cells_lost, &report.heads_lost, &report.crossings, lic, rec);
                }
            }
        }
        if (wrote_any) report.taps_written += 1;
    }

    recordMembership(lat, rail, polarity, rec);
}

fn pivotStemDir(rail: sketch.Rail) ?edges_r.Move {
    var si: usize = 0;
    while (si + 1 < rail.stem.len) : (si += 1) {
        if (edges_r.segmentDir(rail.stem[si], rail.stem[si + 1])) |d| return d;
    }
    return null;
}

fn pivotHead(rail: sketch.Rail) ?edges_r.Head {
    if (rail.pivot_arrow == .none) return null;
    const dir = pivotStemDir(rail) orelse return null;
    return .{ .cell = edges_r.step(rail.stem[0], dir), .dir = edges_r.reverse(dir) };
}

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

fn inkAt(lat: *const lattice.Lattice, p: sketch.Point) ?ew.Coord {
    if (!edges_r.pointInBounds(p, lat)) return null;
    const c = edges_r.toCoord(p);
    return switch (lat.atConst(c.x, c.y).occupant) {
        .edge_segment, .arrowhead => c,
        else => null,
    };
}

/// @guarded-by: rails_test.zig "a rail files its members on the shared run and a tap at each branch cell"
fn recordMembership(
    lat: *const lattice.Lattice,
    rail: sketch.Rail,
    polarity: lattice.RailPolarity,
    rec: aux.Recorder,
) void {
    if (rec.sink == null) return;
    const junction = rail.stem[rail.stem.len - 1];

    var si: usize = 0;
    while (si + 1 < rail.stem.len) : (si += 1) {
        const dir = edges_r.segmentDir(rail.stem[si], rail.stem[si + 1]) orelse continue;
        var cursor = rail.stem[si];
        while (cursor.x != rail.stem[si + 1].x or cursor.y != rail.stem[si + 1].y) : (cursor = edges_r.step(cursor, dir)) {
            recordMembersAt(lat, cursor, rail, junction, polarity, rec);
        }
    }

    var x = rail.crossbar[0].x;
    while (x <= rail.crossbar[1].x) : (x += 1) {
        recordMembersAt(lat, .{ .x = x, .y = rail.crossbar[0].y }, rail, junction, polarity, rec);
    }
}

fn recordMembersAt(
    lat: *const lattice.Lattice,
    p: sketch.Point,
    rail: sketch.Rail,
    junction: sketch.Point,
    polarity: lattice.RailPolarity,
    rec: aux.Recorder,
) void {
    if (!edges_r.pointInBounds(p, lat)) return;
    const c = edges_r.toCoord(p);
    const named: u32 = switch (lat.atConst(c.x, c.y).occupant) {
        .edge_segment => |seg| seg.edge,
        .arrowhead => |head| head.edge,
        else => return,
    };
    for (rail.taps) |tap| {
        if (tap.edge == named) continue;
        if (p.y == rail.crossbar[0].y and !onStretch(p.x, junction.x, tap.at.x)) continue;
        ew.recordRailMember(rec, c.x, c.y, tap.edge, polarity);
    }
}

fn onStretch(v: i32, a: i32, b: i32) bool {
    return v >= @min(a, b) and v <= @max(a, b);
}

/// @guarded-by: rails_test.zig "a rail arm into a foreign head is refused and counted against the rail"
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
    const lic = carrierKindAt(lat, c, edge_id, chan);
    edges_r.writeEdgeCell(lat.at(c.x, c.y), edge_id, kind, role, mask, c.x, c.y, &report.cells_lost, &report.crossings, lic, rec);
}

test "carrierKindAt trusts identity only after a complete consistent stamp" {
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
    const unstamped = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &members }};
    const c: ew.Coord = .{ .x = 0, .y = 0 };

    const stamped = try ledger.numberBundles(std_testing.allocator, &unstamped);
    defer std_testing.allocator.free(stamped);

    for ([_]sketch.BundleStampState{ .unattempted, .out_of_memory, .rail_invariant }) |state| {
        const chan: Chan = .{ .bundle_sets = stamped, .bundle = 1, .stamp_state = state };
        try std_testing.expectEqual(lattice.CarrierKind.merged_untested, carrierKindAt(&lat, c, 1, chan));
    }

    const inconsistent: Chan = .{ .bundle_sets = &unstamped, .bundle = 1, .stamp_state = .complete };
    try std_testing.expectEqual(lattice.CarrierKind.merged_untested, carrierKindAt(&lat, c, 1, inconsistent));

    const complete: Chan = .{ .bundle_sets = stamped, .bundle = 1, .stamp_state = .complete };
    try std_testing.expectEqual(lattice.CarrierKind.merged_licensed, carrierKindAt(&lat, c, 1, complete));
    const off_sets: Chan = .{ .bundle_sets = stamped, .bundle = 2, .stamp_state = .complete };
    try std_testing.expectEqual(lattice.CarrierKind.merged_foreign, carrierKindAt(&lat, c, 2, off_sets));
}

test {
    _ = @import("rails_test.zig");
}

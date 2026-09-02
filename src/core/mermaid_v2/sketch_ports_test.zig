//! Unit tests for sketch_ports.zig — the geometric port-share bundle
//! derivation. Hand-built EdgePaths only: the point of the module is that it
//! reads nothing but the polylines it is handed.

const std = @import("std");
const sketch = @import("sketch.zig");
const sketch_ports = @import("sketch_ports.zig");
const sketch_bundles = @import("sketch_bundles.zig");
const ledger = @import("base/ledger.zig");

fn edge(id: sketch.EdgeId, poly: []const sketch.Point) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 1,
        .polyline = poly,
        .port_from = .{ .node = 0, .side = .south, .offset = 0 },
        .port_to = .{ .node = 1, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    };
}

fn p(x: i32, y: i32) sketch.Point {
    return .{ .x = x, .y = y };
}

/// The single set whose members are exactly `want`, order-insensitive.
fn expectOneSet(sets: []const ledger.Bundle, want: []const sketch.EdgeId) !void {
    try std.testing.expectEqual(@as(usize, 1), sets.len);
    try std.testing.expectEqual(ledger.BundleOrigin.port_share, sets[0].origin);
    try std.testing.expectEqual(want.len, sets[0].members.len);
    for (want) |w| {
        var saw = false;
        for (sets[0].members) |m| {
            if (m == w) saw = true;
        }
        try std.testing.expect(saw);
    }
}

test "shared departure port groups its edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = [_]sketch.Point{ p(5, 3), p(5, 8), p(1, 8) };
    const two = [_]sketch.Point{ p(5, 3), p(5, 8), p(9, 8) };
    const edges = [_]sketch.EdgePath{ edge(0, &one), edge(1, &two) };

    const sets = try sketch_ports.portShareBundles(a, &edges);
    try expectOneSet(sets, &.{ 0, 1 });
}

test "an arrival and a departure at one point share the port regardless of polarity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const arrival = [_]sketch.Point{ p(0, 9), p(7, 9), p(7, 2) };
    const departure = [_]sketch.Point{ p(7, 2), p(7, 6), p(12, 6) };
    const edges = [_]sketch.EdgePath{ edge(3, &arrival), edge(4, &departure) };

    const sets = try sketch_ports.portShareBundles(a, &edges);
    try expectOneSet(sets, &.{ 3, 4 });
}

test "independent ports do not group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const across = [_]sketch.Point{ p(0, 5), p(9, 5) };
    const down = [_]sketch.Point{ p(4, 0), p(4, 9) };
    const edges = [_]sketch.EdgePath{ edge(0, &across), edge(1, &down) };

    try std.testing.expectEqual(
        @as(usize, 0),
        (try sketch_ports.portShareBundles(a, &edges)).len,
    );
}

test "an edge sharing two ports lands in two sets, never one fused set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zero = [_]sketch.Point{ p(2, 0), p(2, 4) };
    const one = [_]sketch.Point{ p(2, 4), p(8, 4) };
    const two = [_]sketch.Point{ p(8, 4), p(8, 9) };
    const edges = [_]sketch.EdgePath{ edge(0, &zero), edge(1, &one), edge(2, &two) };

    const sets = try sketch_ports.portShareBundles(a, &edges);
    try std.testing.expectEqual(@as(usize, 2), sets.len);
    try std.testing.expect(ledger.bundleMembers(sets, 0, 1));
    try std.testing.expect(ledger.bundleMembers(sets, 1, 2));
    try std.testing.expect(!ledger.bundleMembers(sets, 0, 2));
}

test "degenerate and invisible edges license nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one_point = [_]sketch.Point{p(5, 3)};
    const closed = [_]sketch.Point{ p(5, 3), p(6, 3), p(5, 3) };
    const real = [_]sketch.Point{ p(5, 3), p(5, 9) };
    var ghost = edge(9, &real);
    ghost.kind = .invisible;
    const edges = [_]sketch.EdgePath{ edge(0, &one_point), edge(1, &closed), edge(2, &real), ghost };

    try std.testing.expectEqual(
        @as(usize, 0),
        (try sketch_ports.portShareBundles(a, &edges)).len,
    );
}

test "appendPortShares keeps the existing sets ahead of the derived ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = [_]sketch.Point{ p(5, 3), p(5, 8) };
    const two = [_]sketch.Point{ p(5, 3), p(9, 8) };
    const edges = [_]sketch.EdgePath{ edge(0, &one), edge(1, &two) };
    const existing = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &.{ 7, 8 } }};

    const sets = try sketch_ports.appendPortShares(a, &existing, &edges);
    try std.testing.expectEqual(@as(usize, 2), sets.len);
    try std.testing.expectEqual(ledger.BundleOrigin.fan_rail, sets[0].origin);
    try std.testing.expectEqual(ledger.BundleOrigin.port_share, sets[1].origin);
    try std.testing.expect(ledger.bundleMembers(sets, 7, 8));
    try std.testing.expect(ledger.bundleMembers(sets, 0, 1));
}

test "appendPortShares replaces stale port-share origins instead of creating first-match duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = [_]sketch.Point{ p(5, 3), p(5, 8) };
    const two = [_]sketch.Point{ p(5, 3), p(9, 8) };
    const edges = [_]sketch.EdgePath{ edge(20, &one), edge(21, &two) };
    const stale = [_]ledger.Bundle{
        .{ .origin = .port_share, .bundle = 77, .members = &.{ 0, 1 }, .cells = &.{.{ .x = 99, .y = 99 }} },
        .{ .origin = .fan_rail, .bundle = 88, .members = &.{ 7, 8 } },
    };

    const sets = try sketch_ports.appendPortShares(a, &stale, &edges);
    try std.testing.expectEqual(@as(usize, 2), sets.len);
    try std.testing.expectEqual(ledger.BundleOrigin.fan_rail, sets[0].origin);
    try std.testing.expectEqual(ledger.BundleOrigin.port_share, sets[1].origin);
    try std.testing.expectEqual(ledger.no_bundle, sets[1].bundle);
    try std.testing.expectEqualSlices(sketch.EdgeId, &.{ 20, 21 }, sets[1].members);
    try std.testing.expect(!ledger.bundleMembers(sets, 0, 1));
}

test "final geometry alone defines shifted pair ids, cells, and bundle agreement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = [_]sketch.Point{ p(15, 23), p(15, 26), p(11, 26) };
    const second = [_]sketch.Point{ p(15, 23), p(15, 26), p(19, 26) };
    const edges = [_]sketch.EdgePath{ edge(100, &first), edge(101, &second) };
    const old = [_]ledger.Bundle{.{
        .origin = .port_share,
        .bundle = 9,
        .members = &.{ 0, 1 },
        .cells = &.{.{ .x = 99, .y = 99 }},
        .pairwise = &.{.{ .a = 0, .b = 1, .cells = &.{.{ .x = 99, .y = 99 }} }},
    }};

    const raw = try sketch_ports.appendPortShares(a, &old, &edges);
    var final: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 20, .h = 30 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &edges,
        .bundle_sets = raw,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
    sketch_bundles.stamp(a, &final);
    try std.testing.expectEqual(sketch.BundleStampState.complete, final.bundle_stamp_state);
    try std.testing.expectEqual(@as(usize, 1), final.bundle_sets.len);
    try std.testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101 }, final.bundle_sets[0].members);
    try std.testing.expectEqual(@as(sketch.EdgeId, 100), final.bundle_sets[0].pairwise.?[0].a);
    try std.testing.expectEqual(@as(sketch.EdgeId, 101), final.bundle_sets[0].pairwise.?[0].b);
    try std.testing.expect(ledger.bundlesAgree(final.bundle_sets, 100, 101, .{ .x = 15, .y = 25 }));
    try std.testing.expect(!ledger.bundlesAgree(final.bundle_sets, 100, 101, .{ .x = 99, .y = 99 }));
}

test "no edges, no sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        (try sketch_ports.portShareBundles(arena.allocator(), &.{})).len,
    );
}

test "a port share licenses only its shared approach" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const arrival = [_]sketch.Point{ p(33, 22), p(21, 22), p(21, 14), p(30, 14), p(30, 12) };
    const departure = [_]sketch.Point{ p(30, 12), p(30, 15), p(9, 15) };
    const edges = [_]sketch.EdgePath{ edge(9, &arrival), edge(11, &departure) };

    const sets = try sketch_ports.portShareBundles(a, &edges);
    try std.testing.expectEqual(@as(usize, 1), sets.len);
    for ([_]sketch.Point{ p(30, 12), p(30, 13), p(30, 14) }) |cell| {
        try std.testing.expect(ledger.bundleMembersAt(sets, 9, 11, .{ .x = cell.x, .y = cell.y }));
    }
    try std.testing.expect(!ledger.bundleMembersAt(sets, 9, 11, .{ .x = 21, .y = 15 }));
    try std.testing.expect(ledger.bundleMembers(sets, 9, 11));
}

test "three members at one port group into one set, but a third member's approach licenses nothing between the other two" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const a_path = [_]sketch.Point{ p(5, 3), p(5, 8), p(1, 8) };
    const b_path = [_]sketch.Point{ p(5, 3), p(5, 8), p(9, 8) };
    const c_path = [_]sketch.Point{ p(5, 3), p(9, 3), p(9, 7), p(2, 7) };
    const edges = [_]sketch.EdgePath{ edge(0, &a_path), edge(1, &b_path), edge(2, &c_path) };

    const sets = try sketch_ports.portShareBundles(a, &edges);
    try expectOneSet(sets, &.{ 0, 1, 2 });

    try std.testing.expect(ledger.bundleMembers(sets, 0, 1));
    try std.testing.expect(ledger.bundleMembers(sets, 0, 2));
    try std.testing.expect(ledger.bundleMembers(sets, 1, 2));

    try std.testing.expect(ledger.bundleMembersAt(sets, 0, 1, .{ .x = 5, .y = 7 }));

    try std.testing.expect(!ledger.bundleMembersAt(sets, 0, 2, .{ .x = 5, .y = 7 }));
    try std.testing.expect(!ledger.bundleMembersAt(sets, 1, 2, .{ .x = 5, .y = 7 }));

    try std.testing.expect(ledger.bundleMembersAt(sets, 0, 2, .{ .x = 5, .y = 3 }));
    try std.testing.expect(ledger.bundleMembersAt(sets, 1, 2, .{ .x = 5, .y = 3 }));
}

test "a first-class rail member and path share only their exact final approach" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem = [_]sketch.Point{ p(5, 1), p(5, 5) };
    const taps = [_]sketch.Tap{
        .{ .edge = 20, .node = 1, .at = p(2, 5), .landing = p(2, 9) },
        .{ .edge = 21, .node = 2, .at = p(8, 5), .landing = p(8, 9) },
    };
    const rails_buf = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ p(2, 5), p(8, 5) },
        .taps = &taps,
        .kind = .solid,
    }};
    const bridge_points = [_]sketch.Point{ p(5, 1), p(5, 4), p(11, 4) };
    const edges = [_]sketch.EdgePath{edge(30, &bridge_points)};

    const sets = try sketch_ports.portShareBundlesFromGeometry(a, &edges, &rails_buf);
    try std.testing.expectEqual(@as(usize, 1), sets.len);
    try std.testing.expectEqualSlices(sketch.EdgeId, &.{ 30, 20, 21 }, sets[0].members);
    try std.testing.expect(ledger.bundleMembersAt(sets, 20, 30, .{ .x = 5, .y = 3 }));
    try std.testing.expect(!ledger.bundleMembersAt(sets, 20, 30, .{ .x = 5, .y = 5 }));
    try std.testing.expect(ledger.bundleMembersAt(sets, 21, 30, .{ .x = 5, .y = 3 }));
    try std.testing.expect(!ledger.bundleMembersAt(sets, 20, 21, .{ .x = 2, .y = 5 }));

    var duplicate = edge(20, &bridge_points);
    duplicate.id = 20;
    const traces = try sketch_ports.finalCarrierTraces(a, &.{duplicate}, &rails_buf);
    var edge_twenty: usize = 0;
    for (traces) |trace| {
        if (trace.id == 20) edge_twenty += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), edge_twenty);
    try std.testing.expect(!traces[0].rail);
}

test "a rail member and path at one port with no common run license no merge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem = [_]sketch.Point{ p(5, 1), p(5, 5) };
    const taps = [_]sketch.Tap{.{ .edge = 20, .node = 1, .at = p(2, 5), .landing = p(2, 9) }};
    const rails_buf = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ p(2, 5), p(5, 5) },
        .taps = &taps,
        .kind = .solid,
    }};
    const bridge_points = [_]sketch.Point{ p(5, 1), p(6, 1), p(11, 4) };
    const edges = [_]sketch.EdgePath{edge(30, &bridge_points)};

    const sets = try sketch_ports.portShareBundlesFromGeometry(a, &edges, &rails_buf);
    try std.testing.expectEqual(@as(usize, 0), sets.len);

    const structural = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &.{20} }};
    var final: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 20, .h = 12 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &edges,
        .rails = &rails_buf,
        .bundle_sets = try sketch_ports.rebuildFinalPortShares(a, &structural, &edges, &rails_buf),
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
    sketch_bundles.stamp(a, &final);
    try std.testing.expectEqual(sketch.BundleStampState.complete, final.bundle_stamp_state);
    try std.testing.expect(!ledger.bundlesAgree(final.bundle_sets, 20, 30, .{ .x = 5, .y = 1 }));
}

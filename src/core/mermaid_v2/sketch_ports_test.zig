//! Unit tests for sketch_ports.zig — the geometric port-share co-set
//! derivation. Hand-built EdgePaths only: the point of the module is that it
//! reads nothing but the polylines it is handed.

const std = @import("std");
const sketch = @import("sketch.zig");
const sketch_ports = @import("sketch_ports.zig");
const sketch_channels = @import("sketch_channels.zig");
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
fn expectOneSet(sets: []const ledger.CoSet, want: []const sketch.EdgeId) !void {
    try std.testing.expectEqual(@as(usize, 1), sets.len);
    try std.testing.expectEqual(ledger.CoOrigin.port_share, sets[0].origin);
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

    // Both leave (5,3) — the same south port of one node — then split.
    const one = [_]sketch.Point{ p(5, 3), p(5, 8), p(1, 8) };
    const two = [_]sketch.Point{ p(5, 3), p(5, 8), p(9, 8) };
    const edges = [_]sketch.EdgePath{ edge(0, &one), edge(1, &two) };

    const sets = try sketch_ports.portShareCoSets(a, &edges);
    try expectOneSet(sets, &.{ 0, 1 });
}

test "an arrival and a departure at one point share the port regardless of polarity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A cycle return TERMINATES at (7,2); a forward edge DEPARTS from it.
    // Polarity is not a channel property: the ink at the port is one run.
    const arrival = [_]sketch.Point{ p(0, 9), p(7, 9), p(7, 2) };
    const departure = [_]sketch.Point{ p(7, 2), p(7, 6), p(12, 6) };
    const edges = [_]sketch.EdgePath{ edge(3, &arrival), edge(4, &departure) };

    const sets = try sketch_ports.portShareCoSets(a, &edges);
    try expectOneSet(sets, &.{ 3, 4 });
}

test "independent ports do not group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The runs CROSS at (4,5), but no terminal coincides: a true transversal
    // between unrelated channels, which must stay unrelated.
    const across = [_]sketch.Point{ p(0, 5), p(9, 5) };
    const down = [_]sketch.Point{ p(4, 0), p(4, 9) };
    const edges = [_]sketch.EdgePath{ edge(0, &across), edge(1, &down) };

    try std.testing.expectEqual(
        @as(usize, 0),
        (try sketch_ports.portShareCoSets(a, &edges)).len,
    );
}

test "an edge sharing two ports lands in two sets, never one fused set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Edge 1 shares its head port with edge 0 and its tail port with edge 2.
    // Union-find would license edges 0 and 2 to share ink along a run neither
    // producer ever agreed on, so the sets stay separate.
    const zero = [_]sketch.Point{ p(2, 0), p(2, 4) };
    const one = [_]sketch.Point{ p(2, 4), p(8, 4) };
    const two = [_]sketch.Point{ p(8, 4), p(8, 9) };
    const edges = [_]sketch.EdgePath{ edge(0, &zero), edge(1, &one), edge(2, &two) };

    const sets = try sketch_ports.portShareCoSets(a, &edges);
    try std.testing.expectEqual(@as(usize, 2), sets.len);
    try std.testing.expect(ledger.coMembers(sets, 0, 1));
    try std.testing.expect(ledger.coMembers(sets, 1, 2));
    try std.testing.expect(!ledger.coMembers(sets, 0, 2));
}

test "degenerate and invisible edges license nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one_point = [_]sketch.Point{p(5, 3)};
    const closed = [_]sketch.Point{ p(5, 3), p(6, 3), p(5, 3) }; // first == last
    const real = [_]sketch.Point{ p(5, 3), p(5, 9) };
    var ghost = edge(9, &real);
    ghost.kind = .invisible;
    const edges = [_]sketch.EdgePath{ edge(0, &one_point), edge(1, &closed), edge(2, &real), ghost };

    // Only edge 2 qualifies at (5,3); a single member is not a share.
    try std.testing.expectEqual(
        @as(usize, 0),
        (try sketch_ports.portShareCoSets(a, &edges)).len,
    );
}

test "appendPortShares keeps the existing sets ahead of the derived ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = [_]sketch.Point{ p(5, 3), p(5, 8) };
    const two = [_]sketch.Point{ p(5, 3), p(9, 8) };
    const edges = [_]sketch.EdgePath{ edge(0, &one), edge(1, &two) };
    const existing = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &.{ 7, 8 } }};

    const sets = try sketch_ports.appendPortShares(a, &existing, &edges);
    try std.testing.expectEqual(@as(usize, 2), sets.len);
    try std.testing.expectEqual(ledger.CoOrigin.fan_rail, sets[0].origin);
    try std.testing.expectEqual(ledger.CoOrigin.port_share, sets[1].origin);
    try std.testing.expect(ledger.coMembers(sets, 7, 8));
    try std.testing.expect(ledger.coMembers(sets, 0, 1));
}

test "appendPortShares replaces stale port-share origins instead of creating first-match duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one = [_]sketch.Point{ p(5, 3), p(5, 8) };
    const two = [_]sketch.Point{ p(5, 3), p(9, 8) };
    const edges = [_]sketch.EdgePath{ edge(20, &one), edge(21, &two) };
    const stale = [_]ledger.CoSet{
        .{ .origin = .port_share, .channel = 77, .members = &.{ 0, 1 }, .cells = &.{.{ .x = 99, .y = 99 }} },
        .{ .origin = .fan_rail, .channel = 88, .members = &.{ 7, 8 } },
    };

    const sets = try sketch_ports.appendPortShares(a, &stale, &edges);
    try std.testing.expectEqual(@as(usize, 2), sets.len);
    try std.testing.expectEqual(ledger.CoOrigin.fan_rail, sets[0].origin);
    try std.testing.expectEqual(ledger.CoOrigin.port_share, sets[1].origin);
    try std.testing.expectEqual(ledger.no_channel, sets[1].channel);
    try std.testing.expectEqualSlices(sketch.EdgeId, &.{ 20, 21 }, sets[1].members);
    try std.testing.expect(!ledger.coMembers(sets, 0, 1));
}

test "final geometry alone defines shifted pair ids, cells, and channel agreement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Old ids and the distant old cell are deliberately unrelated to final
    // geometry. Final ids 100/101 share only the approach (15,23)..(15,26).
    const first = [_]sketch.Point{ p(15, 23), p(15, 26), p(11, 26) };
    const second = [_]sketch.Point{ p(15, 23), p(15, 26), p(19, 26) };
    const edges = [_]sketch.EdgePath{ edge(100, &first), edge(101, &second) };
    const old = [_]ledger.CoSet{.{
        .origin = .port_share,
        .channel = 9,
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
        .co_sets = raw,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
    sketch_channels.stamp(a, &final);
    try std.testing.expectEqual(sketch.ChannelStampState.complete, final.channel_stamp_state);
    try std.testing.expectEqual(@as(usize, 1), final.co_sets.len);
    try std.testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101 }, final.co_sets[0].members);
    try std.testing.expectEqual(@as(sketch.EdgeId, 100), final.co_sets[0].pairwise.?[0].a);
    try std.testing.expectEqual(@as(sketch.EdgeId, 101), final.co_sets[0].pairwise.?[0].b);
    try std.testing.expect(ledger.channelsAgree(final.co_sets, 100, 101, .{ .x = 15, .y = 25 }));
    try std.testing.expect(!ledger.channelsAgree(final.co_sets, 100, 101, .{ .x = 99, .y = 99 }));
}

test "no edges, no sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        (try sketch_ports.portShareCoSets(arena.allocator(), &.{})).len,
    );
}

test "a port share licenses only its shared approach" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The shape that made a naive port-wide set fabricate a `┼`: an arrival
    // terminates at the port (30,12) after running west along y=14, and a
    // departure leaves that same port south and then turns west along y=15,
    // recrossing the arrival's column at (21,15). They share the port and the
    // stem (30,12)..(30,14) — and nothing at (21,15).
    const arrival = [_]sketch.Point{ p(33, 22), p(21, 22), p(21, 14), p(30, 14), p(30, 12) };
    const departure = [_]sketch.Point{ p(30, 12), p(30, 15), p(9, 15) };
    const edges = [_]sketch.EdgePath{ edge(9, &arrival), edge(11, &departure) };

    const sets = try sketch_ports.portShareCoSets(a, &edges);
    try std.testing.expectEqual(@as(usize, 1), sets.len);
    // Licensed: the port and the common stem above it.
    for ([_]sketch.Point{ p(30, 12), p(30, 13), p(30, 14) }) |cell| {
        try std.testing.expect(ledger.coMembersAt(sets, 9, 11, .{ .x = cell.x, .y = cell.y }));
    }
    // Not licensed: the distant transversal, which must stay a plain crossing.
    try std.testing.expect(!ledger.coMembersAt(sets, 9, 11, .{ .x = 21, .y = 15 }));
    // Position-blind, the pair still reads as co-members.
    try std.testing.expect(ledger.coMembers(sets, 9, 11));
}

test "three members at one port group into one set, but a third member's approach licenses nothing between the other two" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A and B share the whole stem out of port (5,3): (5,3)..(5,8). C also
    // terminates at (5,3), but leaves east, loops south, and crosses A/B's
    // stem PERPENDICULAR at (5,7) — far from the port, and never walked
    // together with A or B there. All three are one channel (transitively,
    // one physical port), but (5,7) is a stranger meeting for the pairs
    // (A,C) and (B,C), and must stay a plain transversal.
    const a_path = [_]sketch.Point{ p(5, 3), p(5, 8), p(1, 8) };
    const b_path = [_]sketch.Point{ p(5, 3), p(5, 8), p(9, 8) };
    const c_path = [_]sketch.Point{ p(5, 3), p(9, 3), p(9, 7), p(2, 7) };
    const edges = [_]sketch.EdgePath{ edge(0, &a_path), edge(1, &b_path), edge(2, &c_path) };

    const sets = try sketch_ports.portShareCoSets(a, &edges);
    try expectOneSet(sets, &.{ 0, 1, 2 });

    // Transitive identity: all three are declared co-members, position-blind.
    try std.testing.expect(ledger.coMembers(sets, 0, 1));
    try std.testing.expect(ledger.coMembers(sets, 0, 2));
    try std.testing.expect(ledger.coMembers(sets, 1, 2));

    // A and B genuinely share the whole stem, including (5,7).
    try std.testing.expect(ledger.coMembersAt(sets, 0, 1, .{ .x = 5, .y = 7 }));

    // C never walked (5,7) with A, nor with B — a third member's own
    // approach to A and to B separately must not license a cell between A
    // and C, or between B and C, that neither pair ever agreed on.
    try std.testing.expect(!ledger.coMembersAt(sets, 0, 2, .{ .x = 5, .y = 7 }));
    try std.testing.expect(!ledger.coMembersAt(sets, 1, 2, .{ .x = 5, .y = 7 }));

    // All three do agree at the port itself.
    try std.testing.expect(ledger.coMembersAt(sets, 0, 2, .{ .x = 5, .y = 3 }));
    try std.testing.expect(ledger.coMembersAt(sets, 1, 2, .{ .x = 5, .y = 3 }));
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
    const bars = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ p(2, 5), p(8, 5) },
        .taps = &taps,
        .kind = .solid,
    }};
    const bridge_points = [_]sketch.Point{ p(5, 1), p(5, 4), p(11, 4) };
    const edges = [_]sketch.EdgePath{edge(30, &bridge_points)};

    const sets = try sketch_ports.portShareCoSetsFromGeometry(a, &edges, &bars);
    try std.testing.expectEqual(@as(usize, 1), sets.len);
    try std.testing.expectEqualSlices(sketch.EdgeId, &.{ 30, 20, 21 }, sets[0].members);
    try std.testing.expect(ledger.coMembersAt(sets, 20, 30, .{ .x = 5, .y = 3 }));
    try std.testing.expect(!ledger.coMembersAt(sets, 20, 30, .{ .x = 5, .y = 5 }));
    try std.testing.expect(ledger.coMembersAt(sets, 21, 30, .{ .x = 5, .y = 3 }));
    try std.testing.expect(!ledger.coMembersAt(sets, 20, 21, .{ .x = 2, .y = 5 }));

    // Malformed dual representation cannot duplicate one semantic edge in
    // the carrier population; the explicit EdgePath wins over the rail tap.
    var duplicate = edge(20, &bridge_points);
    duplicate.id = 20;
    const traces = try sketch_ports.finalCarrierTraces(a, &.{duplicate}, &bars);
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
    const bars = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ p(2, 5), p(5, 5) },
        .taps = &taps,
        .kind = .solid,
    }};
    const bridge_points = [_]sketch.Point{ p(5, 1), p(6, 1), p(11, 4) };
    const edges = [_]sketch.EdgePath{edge(30, &bridge_points)};

    const sets = try sketch_ports.portShareCoSetsFromGeometry(a, &edges, &bars);
    try std.testing.expectEqual(@as(usize, 0), sets.len);

    const structural = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &.{20} }};
    var final: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 20, .h = 12 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &edges,
        .rails = &bars,
        .co_sets = try sketch_ports.rebuildFinalPortShares(a, &structural, &edges, &bars),
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
    sketch_channels.stamp(a, &final);
    try std.testing.expectEqual(sketch.ChannelStampState.complete, final.channel_stamp_state);
    try std.testing.expect(!ledger.channelsAgree(final.co_sets, 20, 30, .{ .x = 5, .y = 1 }));
}

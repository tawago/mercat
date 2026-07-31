//! Unit tests for sketch_ports.zig — the geometric port-share co-set
//! derivation. Hand-built EdgePaths only: the point of the module is that it
//! reads nothing but the polylines it is handed.

const std = @import("std");
const sketch = @import("sketch.zig");
const sketch_ports = @import("sketch_ports.zig");
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

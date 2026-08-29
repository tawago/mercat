const std = @import("std");
const clearance = @import("route_clearance.zig");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");

fn node(id: u32, x: i32, y: i32, w: u32, h: u32) sk.NodePlacement {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = w, .h = h }, .shape = .rect, .lines = &.{}, .cluster_id = null };
}

test "F-A: separated run rejects a foreign node border row and accepts the clear row below" {
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 14, 0, 5, 3),
        node(2, 6, 2, 7, 3),
    };
    const border_hug = [_]sk.Point{ .{ .x = 4, .y = 1 }, .{ .x = 4, .y = 2 }, .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 1 } };
    const clear = [_]sk.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 5 }, .{ .x = 14, .y = 5 }, .{ .x = 14, .y = 2 } };
    try std.testing.expect(clearance.touchesForeignNode(&border_hug, &placements, 0, 1));
    try std.testing.expect(!clearance.touchesForeignNode(&clear, &placements, 0, 1));
}

test "F-A: clearInvisiblePath skips a foreign border-collinear dogleg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 14, 0, 5, 3),
        node(2, 6, 2, 7, 3),
    };
    const poly = try clearance.clearInvisiblePath(
        arena.allocator(),
        0,
        .invisible,
        placements[0],
        placements[1],
        .{ .node = 0, .side = .east, .offset = 2 },
        .{ .node = 1, .side = .west, .offset = 2 },
        &placements,
        &.{},
        .{},
    );
    try std.testing.expect(!clearance.touchesForeignNode(poly, &placements, 0, 1));
}

test "reserved departures exempt same selected trunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 6, 5, 3),
    };
    // Edge 0's reserved off-node departure: south port offset 2 -> port (2,2), off (2,3).
    const edge_ports = [_]struct { edge: pb.EdgeId, source: sk.Port }{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 } },
    };
    // Edge 1 (being routed) crosses that reserved departure cell (2,3).
    const poly = [_]sk.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };

    // No join attribution: the foreign departure blocks the route.
    try std.testing.expect(try clearance.conflictsReservedDepartures(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{},
    ));

    // Both edges are members of the same selected trunk: their shared departure
    // must not be treated as a foreign obstacle to one another.
    const members = [_]pb.EdgeId{ 0, 1 };
    const selected = [_]pb.SelectedJoin{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &members }};
    try std.testing.expect(!try clearance.conflictsReservedDepartures(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{ .selected_joins = &selected },
    ));
}

test "a co-realized edge's port allocation reserves no departure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 6, 5, 3),
    };
    // Edge 0's allocated departure cell is (2,3); edge 1's route crosses it.
    const edge_ports = [_]struct { edge: pb.EdgeId, source: sk.Port }{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 } },
    };
    const poly = [_]sk.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };

    // Edge 0 routed on its own: the departure is real ink and blocks.
    try std.testing.expect(try clearance.conflictsReservedDepartures(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{},
    ));

    // Edge 0 co-realized: its whole rendering is a rail span — no polyline,
    // no port — so its allocation must reserve nothing.
    const co = [_]pb.EdgeId{0};
    try std.testing.expect(!try clearance.conflictsReservedDepartures(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{ .co_realized = &co },
    ));
}

test "polylineClears refuses every clearance violation regardless of membership disposition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 10, 5, 3),
        node(2, 10, 4, 5, 3), // foreign node
    };
    const taps = [_]sk.Tap{.{ .edge = 7, .node = 1, .at = .{ .x = 2, .y = 6 }, .landing = .{ .x = 2, .y = 10 }, .arrow = .filled }};
    const stem = [_]sk.Point{ .{ .x = 8, .y = 6 }, .{ .x = 2, .y = 6 } };
    const rails = [_]sk.Rail{.{
        .pivot = 5,
        .stem = &stem,
        .crossbar = .{ .{ .x = 2, .y = 6 }, .{ .x = 2, .y = 6 } },
        .taps = &taps,
        .kind = .solid,
    }};
    const edge_ports = [_]struct { edge: pb.EdgeId, source: sk.Port }{};

    // The routed edge 0 targets tap node 1; cell (2,9) is that tap's
    // arrowhead cell (one step off the landing toward the rail).
    const over_arrow = [_]sk.Point{ .{ .x = 4, .y = 9 }, .{ .x = 2, .y = 9 } };
    // A run whose interior leg crosses foreign node 2's box (x=12, rows 4..6).
    const through_foreign = [_]sk.Point{ .{ .x = 4, .y = 1 }, .{ .x = 12, .y = 1 }, .{ .x = 12, .y = 8 }, .{ .x = 4, .y = 8 } };
    // Clear of the rail, its junctions, the foreign box, and the arrow cell.
    const clear = [_]sk.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 8 } };

    const with_independent = pb.RealizedJoins{ .memberships = &[_]pb.RealizedEdgeMembership{
        .{ .edge = 7, .source = .{ .independent = .{ .permission_group = 0, .reason = .not_selected } }, .target = null },
    } };
    const all_selected = pb.RealizedJoins{ .memberships = &[_]pb.RealizedEdgeMembership{
        .{ .edge = 7, .source = .{ .selected = 0 }, .target = null },
    } };

    inline for ([2]pb.RealizedJoins{ with_independent, all_selected }) |joins| {
        try std.testing.expect(!try clearance.polylineClears(a, 0, .solid, &over_arrow, &.{}, &rails, &placements, &edge_ports, joins, 0, 1));
        try std.testing.expect(!try clearance.polylineClears(a, 0, .solid, &through_foreign, &.{}, &rails, &placements, &edge_ports, joins, 0, 1));
        try std.testing.expect(try clearance.polylineClears(a, 0, .solid, &clear, &.{}, &rails, &placements, &edge_ports, joins, 0, 1));
    }
}

test "the detour search widens once per already-routed path, never past the ceiling" {
    // Nothing routed yet: the search still gets its two tracks (one per side)
    // so a first detour can dodge the boxes it is going around.
    try std.testing.expectEqual(@as(u32, 2), clearance.detourLimit(0));
    // One track per side per already-placed path — the only obstacles a wider
    // detour can be dodging.
    try std.testing.expectEqual(@as(u32, 4), clearance.detourLimit(1));
    try std.testing.expectEqual(@as(u32, 20), clearance.detourLimit(9));
    // The ceiling holds: a huge graph never buys unbounded frame.
    try std.testing.expectEqual(@as(u32, 64), clearance.detourLimit(31));
    try std.testing.expectEqual(@as(u32, 64), clearance.detourLimit(10_000));
}

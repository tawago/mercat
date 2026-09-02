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

test "reserved departures exempt same selected rail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 6, 5, 3),
    };
    const edge_ports = [_]struct { edge: pb.EdgeId, source: sk.Port, source_decorated: bool = false }{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 } },
    };
    const poly = [_]sk.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };

    try std.testing.expect(try clearance.conflictsReservedDepartures(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{},
    ));

    const members = [_]pb.EdgeId{ 0, 1 };
    const selected = [_]pb.SelectedBundle{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &members }};
    try std.testing.expect(!try clearance.conflictsReservedDepartures(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{ .selected_bundles = &selected },
    ));
}

test "a discharged edge's port allocation reserves no departure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 6, 5, 3),
    };
    const edge_ports = [_]struct { edge: pb.EdgeId, source: sk.Port, source_decorated: bool = false }{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 } },
    };
    const poly = [_]sk.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };

    try std.testing.expect(try clearance.conflictsReservedDepartures(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{},
    ));

    const co = [_]pb.EdgeId{0};
    try std.testing.expect(!try clearance.conflictsReservedDepartures(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{ .discharged = &co },
    ));
}

test "a reserved departure blocks collinear occupancy and admits a perpendicular crossing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 6, 5, 3),
    };
    const edge_ports = [_]struct { edge: pb.EdgeId, source: sk.Port, source_decorated: bool = false }{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 } },
    };

    const collinear = [_]sk.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };
    try std.testing.expect(try clearance.conflictsReservedDepartures(a, 1, &collinear, &placements, &edge_ports, .{}));

    const bend = [_]sk.Point{ .{ .x = 8, .y = 3 }, .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };
    try std.testing.expect(try clearance.conflictsReservedDepartures(a, 1, &bend, &placements, &edge_ports, .{}));

    const crossing = [_]sk.Point{ .{ .x = 8, .y = 3 }, .{ .x = 0, .y = 3 } };
    try std.testing.expect(!try clearance.conflictsReservedDepartures(a, 1, &crossing, &placements, &edge_ports, .{}));
}

test "a decorated departure cell blocks even a perpendicular crossing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 6, 5, 3),
    };
    const edge_ports = [_]struct { edge: pb.EdgeId, source: sk.Port, source_decorated: bool = false }{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 }, .source_decorated = true },
    };
    const crossing = [_]sk.Point{ .{ .x = 8, .y = 3 }, .{ .x = 0, .y = 3 } };
    try std.testing.expect(try clearance.conflictsReservedDepartures(a, 1, &crossing, &placements, &edge_ports, .{}));
}

test "a detour's port run never crosses the route's own box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 5),
        node(1, 0, 40, 5, 5),
        node(2, -20, 5, 60, 30),
    };
    const poly = try clearance.outsideDetour(
        a,
        .TD,
        placements[0],
        placements[1],
        .{ .node = 0, .side = .south, .offset = 2 },
        .{ .node = 1, .side = .north, .offset = 2 },
        &placements,
        0,
    );
    try std.testing.expect(poly[1].y >= 5);
    try std.testing.expect(poly[poly.len - 2].y <= 39);
}

test "polylineClears refuses every clearance violation regardless of membership disposition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 10, 5, 3),
        node(2, 10, 4, 5, 3),
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
    const edge_ports = [_]struct { edge: pb.EdgeId, source: sk.Port, source_decorated: bool = false }{};

    const over_arrow = [_]sk.Point{ .{ .x = 4, .y = 9 }, .{ .x = 2, .y = 9 } };
    const through_foreign = [_]sk.Point{ .{ .x = 4, .y = 1 }, .{ .x = 12, .y = 1 }, .{ .x = 12, .y = 8 }, .{ .x = 4, .y = 8 } };
    const clear = [_]sk.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 8 } };

    const with_independent = pb.RealizedBundles{ .memberships = &[_]pb.RealizedEdgeMembership{
        .{ .edge = 7, .source = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } }, .target = null },
    } };
    const all_selected = pb.RealizedBundles{ .memberships = &[_]pb.RealizedEdgeMembership{
        .{ .edge = 7, .source = .{ .selected = 0 }, .target = null },
    } };

    inline for ([2]pb.RealizedBundles{ with_independent, all_selected }) |bundles| {
        try std.testing.expect(!try clearance.polylineClears(a, 0, .solid, &over_arrow, &.{}, &rails, &placements, &edge_ports, bundles, 0, 1));
        try std.testing.expect(!try clearance.polylineClears(a, 0, .solid, &through_foreign, &.{}, &rails, &placements, &edge_ports, bundles, 0, 1));
        try std.testing.expect(try clearance.polylineClears(a, 0, .solid, &clear, &.{}, &rails, &placements, &edge_ports, bundles, 0, 1));
    }
}

test "the detour search widens once per already-routed path, never past the ceiling" {
    try std.testing.expectEqual(@as(u32, 2), clearance.detourLimit(0));
    try std.testing.expectEqual(@as(u32, 4), clearance.detourLimit(1));
    try std.testing.expectEqual(@as(u32, 20), clearance.detourLimit(9));
    try std.testing.expectEqual(@as(u32, 64), clearance.detourLimit(31));
    try std.testing.expectEqual(@as(u32, 64), clearance.detourLimit(10_000));
}

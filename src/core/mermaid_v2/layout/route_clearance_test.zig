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

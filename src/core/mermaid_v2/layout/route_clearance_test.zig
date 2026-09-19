const std = @import("std");
const clearance = @import("route_clearance.zig");
const detour = @import("route_detour.zig");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");

const EP = struct { edge: pb.EdgeId, source: sk.Port, target: sk.Port = .{ .node = 99, .side = .north, .offset = 0 }, source_decorated: bool = false, target_decorated: bool = false };

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
    const poly = try detour.clearInvisiblePath(
        arena.allocator(),
        0,
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
    const edge_ports = [_]EP{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 } },
    };
    const poly = [_]sk.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };

    try std.testing.expect(try clearance.conflictsReservedTerminals(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{},
    ));

    const members = [_]pb.EdgeId{ 0, 1 };
    const selected = [_]pb.SelectedBundle{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &members }};
    try std.testing.expect(!try clearance.conflictsReservedTerminals(
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
    const edge_ports = [_]EP{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 } },
    };
    const poly = [_]sk.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };

    try std.testing.expect(try clearance.conflictsReservedTerminals(
        arena.allocator(),
        1,
        &poly,
        &placements,
        &edge_ports,
        .{},
    ));

    const co = [_]pb.EdgeId{0};
    try std.testing.expect(!try clearance.conflictsReservedTerminals(
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
    const edge_ports = [_]EP{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 } },
    };

    const collinear = [_]sk.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };
    try std.testing.expect(try clearance.conflictsReservedTerminals(a, 1, &collinear, &placements, &edge_ports, .{}));

    const bend = [_]sk.Point{ .{ .x = 8, .y = 3 }, .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 8 } };
    try std.testing.expect(try clearance.conflictsReservedTerminals(a, 1, &bend, &placements, &edge_ports, .{}));

    const crossing = [_]sk.Point{ .{ .x = 8, .y = 3 }, .{ .x = 0, .y = 3 } };
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &crossing, &placements, &edge_ports, .{}));
}

test "a decorated departure cell blocks even a perpendicular crossing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 6, 5, 3),
    };
    const edge_ports = [_]EP{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 }, .source_decorated = true },
    };
    const crossing = [_]sk.Point{ .{ .x = 8, .y = 3 }, .{ .x = 0, .y = 3 } };
    try std.testing.expect(try clearance.conflictsReservedTerminals(a, 1, &crossing, &placements, &edge_ports, .{}));
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
    const poly = try detour.outsideDetour(
        a,
        .TD,
        placements[0],
        placements[1],
        .{ .node = 0, .side = .south, .offset = 2 },
        .{ .node = 1, .side = .north, .offset = 2 },
        &placements,
        0,
        .{},
        .{},
    );
    try std.testing.expect(poly.?[1].y >= 5);
    try std.testing.expect(poly.?[poly.?.len - 2].y <= 39);
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
    const edge_ports = [_]EP{};

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
        try std.testing.expect(!try clearance.polylineClears(a, 0, &over_arrow, &.{}, &rails, &placements, &edge_ports, bundles, 0, 1));
        try std.testing.expect(!try clearance.polylineClears(a, 0, &through_foreign, &.{}, &rails, &placements, &edge_ports, bundles, 0, 1));
        try std.testing.expect(try clearance.polylineClears(a, 0, &clear, &.{}, &rails, &placements, &edge_ports, bundles, 0, 1));
    }
}

test "the detour search widens once per already-routed path, never past the ceiling" {
    try std.testing.expectEqual(@as(u32, 2), detour.detourLimit(0));
    try std.testing.expectEqual(@as(u32, 4), detour.detourLimit(1));
    try std.testing.expectEqual(@as(u32, 20), detour.detourLimit(9));
    try std.testing.expectEqual(@as(u32, 64), detour.detourLimit(31));
    try std.testing.expectEqual(@as(u32, 64), detour.detourLimit(10_000));
}

test "a decorated arrival cell blocks even a perpendicular crossing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 10, 5, 3),
    };
    const target: sk.Port = .{ .node = 1, .side = .north, .offset = 2 };
    const source: sk.Port = .{ .node = 0, .side = .south, .offset = 2 };
    const crossing = [_]sk.Point{ .{ .x = 8, .y = 9 }, .{ .x = 0, .y = 9 } };
    const plain = [_]EP{.{ .edge = 0, .source = source, .target = target }};
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &crossing, &placements, &plain, .{}));
    const decorated = [_]EP{.{ .edge = 0, .source = source, .target = target, .target_decorated = true }};
    try std.testing.expect(try clearance.conflictsReservedTerminals(a, 1, &crossing, &placements, &decorated, .{}));
    const collinear = [_]sk.Point{ .{ .x = 2, .y = 5 }, .{ .x = 2, .y = 10 } };
    try std.testing.expect(try clearance.conflictsReservedTerminals(a, 1, &collinear, &placements, &plain, .{}));
}

test "a decorated terminal's lateral neighbours refuse a foreign arm toward the head, admit a parallel through-run and a bend turning away" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 10, 5, 3),
    };
    const decorated = [_]EP{.{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 }, .target = .{ .node = 1, .side = .north, .offset = 2 }, .target_decorated = true }};
    const toward = [_]sk.Point{ .{ .x = 8, .y = 9 }, .{ .x = 3, .y = 9 } };
    try std.testing.expect(try clearance.conflictsReservedTerminals(a, 1, &toward, &placements, &decorated, .{}));
    const into = [_]sk.Point{ .{ .x = 3, .y = 5 }, .{ .x = 3, .y = 9 }, .{ .x = 0, .y = 9 } };
    try std.testing.expect(try clearance.conflictsReservedTerminals(a, 1, &into, &placements, &decorated, .{}));
    const parallel = [_]sk.Point{ .{ .x = 3, .y = 5 }, .{ .x = 3, .y = 14 } };
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &parallel, &placements, &decorated, .{}));
    const away = [_]sk.Point{ .{ .x = 3, .y = 5 }, .{ .x = 3, .y = 9 }, .{ .x = 8, .y = 9 } };
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &away, &placements, &decorated, .{}));
    const away_back = [_]sk.Point{ .{ .x = 8, .y = 9 }, .{ .x = 3, .y = 9 }, .{ .x = 3, .y = 5 } };
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &away_back, &placements, &decorated, .{}));
    const plain = [_]EP{.{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 }, .target = .{ .node = 1, .side = .north, .offset = 2 } }};
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &toward, &placements, &plain, .{}));
    const side_placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 12, 0, 5, 3),
    };
    const east_decorated = [_]EP{.{ .edge = 0, .source = .{ .node = 0, .side = .east, .offset = 1 }, .target = .{ .node = 1, .side = .west, .offset = 1 }, .target_decorated = true }};
    const side_toward = [_]sk.Point{ .{ .x = 11, .y = 6 }, .{ .x = 11, .y = 2 } };
    try std.testing.expect(try clearance.conflictsReservedTerminals(a, 1, &side_toward, &side_placements, &east_decorated, .{}));
    const side_bend = [_]sk.Point{ .{ .x = 11, .y = 6 }, .{ .x = 11, .y = 2 }, .{ .x = 7, .y = 2 } };
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &side_bend, &side_placements, &east_decorated, .{}));
    const side_parallel = [_]sk.Point{ .{ .x = 6, .y = 2 }, .{ .x = 16, .y = 2 } };
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &side_parallel, &side_placements, &east_decorated, .{}));
    const side_away = [_]sk.Point{ .{ .x = 7, .y = 2 }, .{ .x = 11, .y = 2 }, .{ .x = 11, .y = 6 } };
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &side_away, &side_placements, &east_decorated, .{}));
}

test "reservations hold with no realized memberships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 10, 5, 3),
    };
    const decorated = [_]EP{.{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 }, .target = .{ .node = 1, .side = .north, .offset = 2 }, .target_decorated = true }};
    const crossing = [_]sk.Point{ .{ .x = 8, .y = 9 }, .{ .x = 0, .y = 9 } };
    const clear = [_]sk.Point{ .{ .x = 8, .y = 6 }, .{ .x = 0, .y = 6 } };
    try std.testing.expect(!try clearance.polylineClears(a, 1, &crossing, &.{}, &.{}, &placements, &decorated, .{}, 0, 1));
    try std.testing.expect(try clearance.polylineClears(a, 1, &clear, &.{}, &.{}, &placements, &decorated, .{}, 0, 1));
}

test "two edges the plan attached to one port do not reserve that port's cell against each other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 10, 5, 3),
        node(2, 10, 10, 5, 3),
    };
    const shared: sk.Port = .{ .node = 0, .side = .south, .offset = 2 };
    const ports = [_]EP{
        .{ .edge = 0, .source = shared, .target = .{ .node = 1, .side = .north, .offset = 2 }, .source_decorated = true },
        .{ .edge = 1, .source = shared, .target = .{ .node = 2, .side = .north, .offset = 2 }, .source_decorated = true },
    };
    const departs = [_]sk.Point{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 }, .{ .x = 12, .y = 6 }, .{ .x = 12, .y = 10 } };
    try std.testing.expect(!try clearance.conflictsReservedTerminals(a, 1, &departs, &placements, &ports, .{}));
}

test "a rail honours a foreign decorated terminal's reservation and ignores its own members'" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 10, 0, 5, 3),
        node(1, 0, 10, 5, 3),
        node(2, 20, 10, 5, 3),
        node(3, 10, 10, 5, 3),
    };
    const stem = [_]sk.Point{ .{ .x = 12, .y = 2 }, .{ .x = 12, .y = 7 } };
    const taps = [_]sk.Tap{
        .{ .edge = 0, .node = 1, .at = .{ .x = 2, .y = 7 }, .landing = .{ .x = 2, .y = 10 } },
        .{ .edge = 1, .node = 2, .at = .{ .x = 22, .y = 7 }, .landing = .{ .x = 22, .y = 10 } },
    };
    const rail: sk.Rail = .{ .pivot = 0, .stem = &stem, .crossbar = .{ .{ .x = 2, .y = 7 }, .{ .x = 22, .y = 7 } }, .taps = &taps, .kind = .solid };
    const pivot: sk.Port = .{ .node = 0, .side = .south, .offset = 2 };
    const members = [_]EP{
        .{ .edge = 0, .source = pivot, .target = .{ .node = 1, .side = .north, .offset = 2 }, .target_decorated = true },
        .{ .edge = 1, .source = pivot, .target = .{ .node = 2, .side = .north, .offset = 2 }, .target_decorated = true },
    };
    try std.testing.expect(!try clearance.railConflictsReservedTerminals(a, rail, &placements, &members, .{}));
    const tall = [_]sk.NodePlacement{
        node(0, 10, 0, 5, 3),
        node(1, 0, 10, 5, 3),
        node(2, 20, 10, 5, 3),
        node(3, 14, 8, 5, 3),
    };
    const foreign_plain = [_]EP{.{ .edge = 7, .source = .{ .node = 0, .side = .south, .offset = 0 }, .target = .{ .node = 3, .side = .north, .offset = 2 } }};
    try std.testing.expect(!try clearance.railConflictsReservedTerminals(a, rail, &tall, &foreign_plain, .{}));
    const foreign_decorated = [_]EP{.{ .edge = 7, .source = .{ .node = 0, .side = .south, .offset = 0 }, .target = .{ .node = 3, .side = .north, .offset = 2 }, .target_decorated = true }};
    try std.testing.expect(try clearance.railConflictsReservedTerminals(a, rail, &tall, &foreign_decorated, .{}));
    const shares_landing = [_]EP{.{ .edge = 7, .source = .{ .node = 3, .side = .south, .offset = 2 }, .target = .{ .node = 1, .side = .north, .offset = 2 }, .target_decorated = true }};
    try std.testing.expect(!try clearance.railConflictsReservedTerminals(a, rail, &placements, &shares_landing, .{}));
}

test "an outside detour bends two cells out from a decorated end and one from a plain end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 5),
        node(1, 0, 40, 5, 5),
    };
    const from: sk.Port = .{ .node = 0, .side = .south, .offset = 2 };
    const to: sk.Port = .{ .node = 1, .side = .north, .offset = 2 };
    const plain = (try detour.outsideDetour(a, .TD, placements[0], placements[1], from, to, &placements, 0, .{}, .{})).?;
    try std.testing.expectEqual(@as(i32, 5), plain[1].y);
    try std.testing.expectEqual(@as(i32, 39), plain[4].y);
    const decorated = (try detour.outsideDetour(a, .TD, placements[0], placements[1], from, to, &placements, 0, .{ .from = true, .to = true }, .{})).?;
    try std.testing.expectEqual(@as(i32, 6), decorated[1].y);
    try std.testing.expectEqual(@as(i32, 38), decorated[4].y);
}

test "a pushed detour run takes the next gap row and is null where the push meets a box" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 5),
        node(1, 0, 40, 5, 5),
        node(2, -30, 8, 40, 3),
    };
    const from: sk.Port = .{ .node = 0, .side = .south, .offset = 2 };
    const to: sk.Port = .{ .node = 1, .side = .north, .offset = 2 };
    const pushed = (try detour.outsideDetour(a, .TD, placements[0], placements[1], from, to, &placements, 0, .{}, .{ .source_extra = 2 })).?;
    try std.testing.expectEqual(@as(i32, 7), pushed[1].y);
    try std.testing.expectEqual(@as(i32, 7), pushed[2].y);
    try std.testing.expectEqual(@as(i32, 39), pushed[4].y);
    try std.testing.expect((try detour.outsideDetour(a, .TD, placements[0], placements[1], from, to, &placements, 0, .{}, .{ .source_extra = 3 })) == null);
    const target_pushed = (try detour.outsideDetour(a, .TD, placements[0], placements[1], from, to, &placements, 0, .{}, .{ .target_extra = 1 })).?;
    try std.testing.expectEqual(@as(i32, 38), target_pushed[3].y);
    try std.testing.expectEqual(@as(i32, 5), target_pushed[1].y);
}

test "decorated terminal pseudo-boxes cover the head cell and its laterals for foreign edges only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 10, 5, 3),
    };
    const ports = [_]EP{
        .{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 }, .target = .{ .node = 1, .side = .north, .offset = 2 }, .target_decorated = true },
        .{ .edge = 1, .source = .{ .node = 1, .side = .east, .offset = 1 }, .target = .{ .node = 0, .side = .east, .offset = 1 } },
    };
    const foreign = try clearance.withDecoratedTerminalBoxes(a, 5, &placements, &ports, .{});
    try std.testing.expectEqual(@as(usize, 3), foreign.len);
    try std.testing.expectEqual(sk.Rect{ .x = 1, .y = 9, .w = 3, .h = 1 }, foreign[2].rect);
    const own = try clearance.withDecoratedTerminalBoxes(a, 0, &placements, &ports, .{});
    try std.testing.expectEqual(@as(usize, 2), own.len);
}

test "members of one fused union do not block each other" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const laid = [_]sk.Point{ .{ .x = 5, .y = 1 }, .{ .x = 8, .y = 1 }, .{ .x = 8, .y = 8 } };
    const existing = [_]sk.EdgePath{.{ .id = 0, .from = 0, .to = 1, .polyline = &laid, .port_from = .{ .node = 0, .side = .east, .offset = 1 }, .port_to = .{ .node = 1, .side = .west, .offset = 1 }, .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid }};
    const candidate = [_]sk.Point{ .{ .x = 5, .y = 1 }, .{ .x = 8, .y = 1 }, .{ .x = 8, .y = 15 } };
    try std.testing.expect(try clearance.conflicts(a, 1, &candidate, &existing, .{}));
    const both = [_]pb.EdgeId{ 0, 1 };
    const unions = [_][]const pb.EdgeId{&both};
    try std.testing.expect(!try clearance.conflicts(a, 1, &candidate, &existing, .{ .fused = &unions }));
}

test "a route through a foreign box is refused with no realized memberships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sk.NodePlacement{
        node(0, 0, 0, 5, 3),
        node(1, 0, 20, 5, 3),
        node(2, 0, 10, 5, 3),
    };
    const ports = [_]EP{.{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 }, .target = .{ .node = 1, .side = .north, .offset = 2 } }};
    const through = [_]sk.Point{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 }, .{ .x = 3, .y = 6 }, .{ .x = 3, .y = 16 }, .{ .x = 2, .y = 16 }, .{ .x = 2, .y = 20 } };
    try std.testing.expect(!try clearance.polylineClears(a, 0, &through, &.{}, &.{}, &placements, &ports, .{}, 0, 1));
    const beside = [_]sk.Point{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 5 }, .{ .x = 8, .y = 5 }, .{ .x = 8, .y = 17 }, .{ .x = 2, .y = 17 }, .{ .x = 2, .y = 20 } };
    try std.testing.expect(try clearance.polylineClears(a, 0, &beside, &.{}, &.{}, &placements, &ports, .{}, 0, 1));
}

test "a route may cross a rail's run but never lie along it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stem = [_]sk.Point{ .{ .x = 7, .y = 2 }, .{ .x = 7, .y = 6 } };
    const rails = [_]sk.Rail{.{ .pivot = 5, .stem = &stem, .crossbar = .{ .{ .x = 2, .y = 6 }, .{ .x = 12, .y = 6 } }, .taps = &.{}, .kind = .solid }};
    const across = [_]sk.Point{ .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 10 } };
    try std.testing.expect(!try clearance.ridesRail(a, &across, &rails));
    const along_bar = [_]sk.Point{ .{ .x = 0, .y = 6 }, .{ .x = 20, .y = 6 } };
    try std.testing.expect(try clearance.ridesRail(a, &along_bar, &rails));
    const along_stem = [_]sk.Point{ .{ .x = 7, .y = 0 }, .{ .x = 7, .y = 10 } };
    try std.testing.expect(try clearance.ridesRail(a, &along_stem, &rails));
    const corner = [_]sk.Point{ .{ .x = 12, .y = 0 }, .{ .x = 12, .y = 6 }, .{ .x = 20, .y = 6 } };
    try std.testing.expect(!try clearance.ridesRail(a, &corner, &rails));
}

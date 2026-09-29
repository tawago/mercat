const std = @import("std");
const fan = @import("fan.zig");
const fan_grid = @import("fan_grid.zig");

const testing = std.testing;
const TestGeom = struct { x: i32, y: i32, w: u32, h: u32, layer: u32 = 0 };

test "wrapWideFanIn wrap decision uses the minimal 1-cell fit gap, not h_spacing" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 20, .y = 10, .w = 10, .h = 3 },
        .{ .x = 0, .y = 0, .w = 10, .h = 3 },
        .{ .x = 14, .y = 0, .w = 10, .h = 3 },
        .{ .x = 28, .y = 0, .w = 10, .h = 3 },
    };
    fan.wrapWideFanIn(TestGeom, &fans, &geom, 35, 4, 2);
    try testing.expectEqual(@as(u32, 1), fans[0].rows);
}

test "wrapWideFanIn floors the placement gap at 3 when h_spacing halves to 2" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 20, .y = 10, .w = 10, .h = 3 },
        .{ .x = 0, .y = 0, .w = 10, .h = 3 },
        .{ .x = 12, .y = 0, .w = 10, .h = 3 },
        .{ .x = 24, .y = 0, .w = 10, .h = 3 },
        .{ .x = 36, .y = 0, .w = 10, .h = 3 },
    };
    fan.wrapWideFanIn(TestGeom, &fans, &geom, 30, 2, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    const col0_right = geom[1].x + @as(i32, @intCast(geom[1].w));
    try testing.expectEqual(@as(i32, 3), geom[2].x - col0_right);
}

test "wrapWideFanOut legacy grid centres EACH row independently under the pivot" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 60, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 10, .h = 3 },
        .{ .x = 14, .y = 6, .w = 10, .h = 3 },
        .{ .x = 28, .y = 6, .w = 6, .h = 3 },
        .{ .x = 38, .y = 6, .w = 6, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 30, 4, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    try testing.expectEqual(@as(i32, 58), geom[1].x);
    try testing.expectEqual(@as(i32, 72), geom[2].x);
    try testing.expectEqual(@as(i32, 62), geom[3].x);
    try testing.expectEqual(@as(i32, 72), geom[4].x);
}

test "wrapWideFanOut P5 pack finds a 2-column layout the old widest-slot math missed (29/25/25 @ budget 58)" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 100, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 29, .h = 3 },
        .{ .x = 33, .y = 6, .w = 25, .h = 3 },
        .{ .x = 62, .y = 6, .w = 25, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 58, 4, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    const p1_cx = geom[1].x + @divTrunc(@as(i32, @intCast(geom[1].w)), 2);
    const p3_cx = geom[3].x + @divTrunc(@as(i32, @intCast(geom[3].w)), 2);
    try testing.expectEqual(p1_cx, p3_cx);
    try testing.expectEqual(@as(i32, 4), geom[2].x - (geom[1].x + @as(i32, @intCast(geom[1].w))));
}

test "wrapWideFanOut variable per-column widths avoid re-overflow from 2 narrow columns" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 100, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 5, .h = 3 },
        .{ .x = 9, .y = 6, .w = 25, .h = 3 },
        .{ .x = 38, .y = 6, .w = 5, .h = 3 },
        .{ .x = 47, .y = 6, .w = 25, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 40, 4, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    const leftmost = geom[1].x;
    const rightmost = geom[2].x + @as(i32, @intCast(geom[2].w));
    try testing.expectEqual(@as(i32, 34), rightmost - leftmost);
}

test "wrapWideFanOut falls back to a single column matching the legacy per-box centering" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 100, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 40, .h = 3 },
        .{ .x = 44, .y = 6, .w = 35, .h = 3 },
        .{ .x = 83, .y = 6, .w = 30, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 50, 4, 2);
    try testing.expectEqual(@as(u32, 3), fans[0].rows);
    const pivot_cx = geom[0].x + @divTrunc(@as(i32, @intCast(geom[0].w)), 2);
    for (1..4) |i| {
        const want_x = pivot_cx - @divTrunc(@as(i32, @intCast(geom[i].w)), 2);
        try testing.expectEqual(want_x, geom[i].x);
    }
}

test "wrapWideFanOut leaves a fitting fan as a single row" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 20, .y = 0, .w = 10, .h = 3 },
        .{ .x = 0, .y = 6, .w = 10, .h = 3 },
        .{ .x = 14, .y = 6, .w = 10, .h = 3 },
        .{ .x = 28, .y = 6, .w = 10, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 80, 4, 2);
    try testing.expectEqual(@as(u32, 1), fans[0].rows);
    try testing.expectEqual(@as(i32, 6), geom[1].y);
    try testing.expectEqual(@as(i32, 6), geom[3].y);
}

test "wrapWideFanOut grids a fan that overflows the budget" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
        .{ .edge_id = 5, .peer_idx = 5, .role = .middle },
        .{ .edge_id = 6, .peer_idx = 6, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 60, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 20, .h = 3 },
        .{ .x = 24, .y = 6, .w = 20, .h = 3 },
        .{ .x = 48, .y = 6, .w = 20, .h = 3 },
        .{ .x = 72, .y = 6, .w = 20, .h = 3 },
        .{ .x = 96, .y = 6, .w = 20, .h = 3 },
        .{ .x = 120, .y = 6, .w = 20, .h = 3 },
        .{ .x = 60, .y = 200, .w = 20, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 60, 4, 2);
    try testing.expect(fans[0].rows >= 2);
    var distinct_y = std.AutoHashMapUnmanaged(i32, void).empty;
    defer distinct_y.deinit(testing.allocator);
    for (1..7) |i| try distinct_y.put(testing.allocator, geom[i].y, {});
    try testing.expect(distinct_y.count() >= 2);
    try testing.expect(geom[7].y > 200);
}

test "wrapWideFanIn centres a narrow box on its column's centre, not flush to a wide neighbour" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 100, .y = 10, .w = 20, .h = 3 },
        .{ .x = 0, .y = 0, .w = 20, .h = 3 },
        .{ .x = 24, .y = 0, .w = 25, .h = 3 },
        .{ .x = 53, .y = 0, .w = 20, .h = 3 },
        .{ .x = 77, .y = 0, .w = 15, .h = 3 },
    };
    fan.wrapWideFanIn(TestGeom, &fans, &geom, 50, 4, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    try testing.expectEqual(@as(i32, 5), geom[4].x - geom[2].x);
}

test "a gridded fan keeps three gap rows between its rows at halved spacing" {
    try testing.expectEqual(@as(i32, 6), fan_grid.rowStep(3, 1));
    try testing.expectEqual(@as(i32, 6), fan_grid.rowStep(3, 2));
    try testing.expectEqual(@as(i32, 8), fan_grid.rowStep(3, 4));
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
        .{ .edge_id = 5, .peer_idx = 5, .role = .middle },
        .{ .edge_id = 6, .peer_idx = 6, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 60, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 20, .h = 3 },
        .{ .x = 24, .y = 6, .w = 20, .h = 3 },
        .{ .x = 48, .y = 6, .w = 20, .h = 3 },
        .{ .x = 72, .y = 6, .w = 20, .h = 3 },
        .{ .x = 96, .y = 6, .w = 20, .h = 3 },
        .{ .x = 120, .y = 6, .w = 20, .h = 3 },
        .{ .x = 60, .y = 200, .w = 20, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 60, 4, 1);
    try testing.expect(fans[0].rows >= 2);
    var min_y: i32 = std.math.maxInt(i32);
    var next_y: i32 = std.math.maxInt(i32);
    for (1..7) |i| min_y = @min(min_y, geom[i].y);
    for (1..7) |i| if (geom[i].y > min_y) {
        next_y = @min(next_y, geom[i].y);
    };
    try testing.expectEqual(@as(i32, 6), next_y - min_y);
}

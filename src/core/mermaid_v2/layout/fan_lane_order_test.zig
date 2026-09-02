//! Unit tests for layout/fan_lane_order.zig — stem-corner clearance ordering.

const std = @import("std");
const order = @import("fan_lane_order.zig");

const testing = std.testing;

fn lanesOf(rails: []const order.Rail, out: []u32) void {
    for (rails, out) |t, *slot| slot.* = t.lane;
}

test "a gap with no shared stem column keeps the packer's lanes" {
    var t0_taps = [_]i32{ 1, 20 };
    var t1_taps = [_]i32{ 3, 22 };
    var rails = [_]order.Rail{
        .{ .gap = 0, .lane = 0, .fan_in = true, .stem_x = 10, .tap_xs = &t0_taps },
        .{ .gap = 0, .lane = 1, .fan_in = true, .stem_x = 30, .tap_xs = &t1_taps },
    };
    try order.reorder(testing.allocator, &rails);
    try testing.expectEqual(@as(u32, 0), rails[0].lane);
    try testing.expectEqual(@as(u32, 1), rails[1].lane);
}

test "a stem crossed by a foreign tap is ordered below it" {
    var t0_taps = [_]i32{ 10, 33, 56 };
    var t1_taps = [_]i32{ 12, 35, 58 };
    var rails = [_]order.Rail{
        .{ .gap = 0, .lane = 0, .fan_in = true, .stem_x = 33, .tap_xs = &t0_taps },
        .{ .gap = 0, .lane = 1, .fan_in = true, .stem_x = 56, .tap_xs = &t1_taps },
    };
    try order.reorder(testing.allocator, &rails);
    try testing.expectEqual(@as(u32, 0), rails[1].lane);
    try testing.expectEqual(@as(u32, 1), rails[0].lane);
}

test "the directed all-to-all's three arrival rails get a clearing order" {
    var t0 = [_]i32{ 8, 31, 54 };
    var t1 = [_]i32{ 10, 33, 56 };
    var t2 = [_]i32{ 12, 35, 58 };
    var rails = [_]order.Rail{
        .{ .gap = 0, .lane = 0, .fan_in = true, .stem_x = 10, .tap_xs = &t0 },
        .{ .gap = 0, .lane = 1, .fan_in = true, .stem_x = 33, .tap_xs = &t1 },
        .{ .gap = 0, .lane = 2, .fan_in = true, .stem_x = 56, .tap_xs = &t2 },
    };
    try order.reorder(testing.allocator, &rails);
    var lanes: [3]u32 = undefined;
    lanesOf(&rails, &lanes);
    try testing.expect(lanes[0] != lanes[1] and lanes[1] != lanes[2] and lanes[0] != lanes[2]);
    try testing.expect(lanes[1] > lanes[0]);
    try testing.expect(lanes[1] > lanes[2]);
    for (rails, 0..) |k, ki| {
        for (rails, 0..) |j, ji| {
            if (ki == ji) continue;
            var shared = false;
            for (j.tap_xs) |x| {
                if (x == k.stem_x) shared = true;
            }
            if (shared) try testing.expect(k.lane < j.lane);
        }
    }
}

test "a precedence cycle leaves the packer's lanes untouched" {
    var t0 = [_]i32{ 5, 40 };
    var t1 = [_]i32{ 19, 60 };
    var rails = [_]order.Rail{
        .{ .gap = 0, .lane = 0, .fan_in = true, .stem_x = 19, .tap_xs = &t0 },
        .{ .gap = 0, .lane = 1, .fan_in = true, .stem_x = 5, .tap_xs = &t1 },
    };
    try order.reorder(testing.allocator, &rails);
    try testing.expectEqual(@as(u32, 0), rails[0].lane);
    try testing.expectEqual(@as(u32, 1), rails[1].lane);
}

test "a mixed-direction gap is left alone" {
    var t0 = [_]i32{ 10, 33 };
    var t1 = [_]i32{ 12, 35 };
    var rails = [_]order.Rail{
        .{ .gap = 0, .lane = 0, .fan_in = true, .stem_x = 33, .tap_xs = &t0 },
        .{ .gap = 0, .lane = 1, .fan_in = false, .stem_x = 10, .tap_xs = &t1 },
    };
    try order.reorder(testing.allocator, &rails);
    try testing.expectEqual(@as(u32, 0), rails[0].lane);
    try testing.expectEqual(@as(u32, 1), rails[1].lane);
}

test "rails in different gaps are ordered independently" {
    var g0a = [_]i32{ 10, 33 };
    var g0b = [_]i32{ 12, 35 };
    var g1a = [_]i32{ 4, 9 };
    var rails = [_]order.Rail{
        .{ .gap = 0, .lane = 0, .fan_in = true, .stem_x = 33, .tap_xs = &g0a },
        .{ .gap = 0, .lane = 1, .fan_in = true, .stem_x = 10, .tap_xs = &g0b },
        .{ .gap = 1, .lane = 0, .fan_in = true, .stem_x = 99, .tap_xs = &g1a },
    };
    try order.reorder(testing.allocator, &rails);
    try testing.expectEqual(@as(u32, 0), rails[2].lane);
    try testing.expect(rails[0].lane != rails[1].lane);
}

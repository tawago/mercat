const std = @import("std");
const lanes = @import("lanes.zig");
const sketch = @import("../sketch.zig");

fn claim(lo: u32, hi: u32, base: i32) lanes.LaneClaim {
    return .{ .lo = lo, .hi = hi, .base = base };
}

fn np(id: u32, x: i32, y: i32, w: u32, h: u32) sketch.NodePlacement {
    return .{
        .id = id,
        .rect = .{ .x = x, .y = y, .w = w, .h = h },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
}

test "assign: mutually disjoint spans share one lane at max base" {
    const a = std.testing.allocator;
    const ds = [_]lanes.LaneClaim{ claim(0, 1, 5), claim(2, 3, 6), claim(4, 5, 4) };
    var asg = try lanes.assign(a, &ds, 1);
    defer asg.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), asg.lane_pos.len);
    try std.testing.expectEqual(@as(i32, 6), asg.posOf(0));
    try std.testing.expectEqual(@as(i32, 6), asg.posOf(1));
    try std.testing.expectEqual(@as(i32, 6), asg.posOf(2));
}

test "assign: mutually overlapping spans stack into distinct outer lanes" {
    const a = std.testing.allocator;
    const ds = [_]lanes.LaneClaim{ claim(0, 4, 5), claim(1, 3, 5), claim(2, 2, 5) };
    var asg = try lanes.assign(a, &ds, 1);
    defer asg.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), asg.lane_pos.len);
    try std.testing.expectEqual(@as(i32, 5), asg.posOf(0));
    try std.testing.expectEqual(@as(i32, 6), asg.posOf(1));
    try std.testing.expectEqual(@as(i32, 7), asg.posOf(2));
}

test "assign: greedy 4-claim hand example with a tie" {
    const a = std.testing.allocator;
    const ds = [_]lanes.LaneClaim{
        claim(0, 1, 5), claim(2, 3, 7), claim(1, 2, 6), claim(4, 5, 7),
    };
    var asg = try lanes.assign(a, &ds, 1);
    defer asg.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), asg.lane_pos.len);
    try std.testing.expectEqual(@as(u32, 0), asg.lane_of[0]);
    try std.testing.expectEqual(@as(u32, 0), asg.lane_of[1]);
    try std.testing.expectEqual(@as(u32, 1), asg.lane_of[2]);
    try std.testing.expectEqual(@as(u32, 0), asg.lane_of[3]);
    try std.testing.expectEqual(@as(i32, 7), asg.posOf(0));
    try std.testing.expectEqual(@as(i32, 8), asg.posOf(2));
    try std.testing.expectEqual(@as(i32, 7), asg.posOf(3));
}

test "clearRunBase: vertical run parks just past endpoints when unobstructed" {
    const ps = [_]sketch.NodePlacement{
        np(1, 0, 0, 5, 3),
        np(2, 0, 10, 5, 3),
    };
    try std.testing.expectEqual(
        @as(?i32, 6),
        lanes.clearRunBase(false, &ps, 1, 2, 1),
    );
}

test "clearRunBase: vertical run dodges a blocking rect" {
    const ps = [_]sketch.NodePlacement{
        np(1, 0, 0, 5, 3),
        np(2, 0, 10, 5, 3),
        np(3, 6, 5, 5, 3),
    };
    try std.testing.expectEqual(
        @as(?i32, 12),
        lanes.clearRunBase(false, &ps, 1, 2, 1),
    );
}

test "clearRunBase: horizontal run gives the transposed answer" {
    const ps = [_]sketch.NodePlacement{
        np(1, 0, 0, 3, 5),
        np(2, 10, 0, 3, 5),
        np(3, 5, 6, 3, 5),
    };
    try std.testing.expectEqual(
        @as(?i32, 12),
        lanes.clearRunBase(true, &ps, 1, 2, 1),
    );
}

test "clearRunBase: missing endpoint placement returns null" {
    const ps = [_]sketch.NodePlacement{np(1, 0, 0, 5, 3)};
    try std.testing.expectEqual(
        @as(?i32, null),
        lanes.clearRunBase(false, &ps, 1, 99, 1),
    );
}

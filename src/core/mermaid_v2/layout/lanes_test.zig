//! Unit tests for `lanes.zig` — lane packing, gutter query, and the
//! obstacle-aware clear-run search (including axis parameterization).

const std = @import("std");
const lanes = @import("lanes.zig");
const sketch = @import("../sketch.zig");

fn dem(lo: u32, hi: u32, base: i32) lanes.Demand {
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
    const ds = [_]lanes.Demand{ dem(0, 1, 5), dem(2, 3, 6), dem(4, 5, 4) };
    var asg = try lanes.assign(a, &ds, 1);
    defer asg.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), asg.lane_pos.len);
    // Shared lane sits at the max member base.
    try std.testing.expectEqual(@as(i32, 6), asg.posOf(0));
    try std.testing.expectEqual(@as(i32, 6), asg.posOf(1));
    try std.testing.expectEqual(@as(i32, 6), asg.posOf(2));
}

test "assign: mutually overlapping spans stack into distinct outer lanes" {
    const a = std.testing.allocator;
    const ds = [_]lanes.Demand{ dem(0, 4, 5), dem(1, 3, 5), dem(2, 2, 5) };
    var asg = try lanes.assign(a, &ds, 1);
    defer asg.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), asg.lane_pos.len);
    // Equal bases are floored apart by stack_gap, inner to outer.
    try std.testing.expectEqual(@as(i32, 5), asg.posOf(0));
    try std.testing.expectEqual(@as(i32, 6), asg.posOf(1));
    try std.testing.expectEqual(@as(i32, 7), asg.posOf(2));
}

test "assign: greedy 4-demand hand example with a tie" {
    const a = std.testing.allocator;
    // In-order greedy packing (order is the tie-break contract):
    //   #0 [0,1] b5 → opens lane 0
    //   #1 [2,3] b7 → disjoint from #0 → joins lane 0 (max_base 7)
    //   #2 [1,2] b6 → overlaps BOTH lane-0 members → opens lane 1
    //   #3 [4,5] b7 → disjoint from #0 and #1 → joins lane 0; its base 7
    //                 TIES the lane's max_base and must not move the lane.
    const ds = [_]lanes.Demand{
        dem(0, 1, 5), dem(2, 3, 7), dem(1, 2, 6), dem(4, 5, 7),
    };
    var asg = try lanes.assign(a, &ds, 1);
    defer asg.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), asg.lane_pos.len);
    try std.testing.expectEqual(@as(u32, 0), asg.lane_of[0]);
    try std.testing.expectEqual(@as(u32, 0), asg.lane_of[1]);
    try std.testing.expectEqual(@as(u32, 1), asg.lane_of[2]);
    try std.testing.expectEqual(@as(u32, 0), asg.lane_of[3]);
    // Lane 0 resolves at max base 7; lane 1's own base (6) is INSIDE lane 0,
    // so it is floored to 7 + stack_gap = 8.
    try std.testing.expectEqual(@as(i32, 7), asg.posOf(0));
    try std.testing.expectEqual(@as(i32, 8), asg.posOf(2));
    try std.testing.expectEqual(@as(i32, 7), asg.posOf(3));
}

test "gutter: reports lane count and outermost position without placements" {
    const a = std.testing.allocator;
    const ds = [_]lanes.Demand{ dem(0, 4, 5), dem(1, 3, 5) };
    const g = try lanes.gutter(a, &ds, 1);
    try std.testing.expectEqual(@as(u32, 2), g.lanes);
    try std.testing.expectEqual(@as(i32, 6), g.outermost);

    const empty = try lanes.gutter(a, &.{}, 1);
    try std.testing.expectEqual(@as(u32, 0), empty.lanes);
    try std.testing.expectEqual(@as(i32, 0), empty.outermost);
}

test "clearRunBase: vertical run parks just past endpoints when unobstructed" {
    const ps = [_]sketch.NodePlacement{
        np(1, 0, 0, 5, 3),
        np(2, 0, 10, 5, 3),
    };
    // Start = max endpoint right edge (5) + pad (1) = 6, immediately clear.
    try std.testing.expectEqual(
        @as(?i32, 6),
        lanes.clearRunBase(false, &ps, 1, 2, 1),
    );
}

test "clearRunBase: vertical run dodges a blocking rect" {
    const ps = [_]sketch.NodePlacement{
        np(1, 0, 0, 5, 3),
        np(2, 0, 10, 5, 3),
        // Blocker between the two endpoint rows: x [6,11), y [5,8). Inflated
        // by pad+1 = 2 on the cross (x) axis it occupies columns [4,13), so
        // the first column whose run clears it is 12.
        np(3, 6, 5, 5, 3),
    };
    try std.testing.expectEqual(
        @as(?i32, 12),
        lanes.clearRunBase(false, &ps, 1, 2, 1),
    );
}

test "clearRunBase: horizontal run gives the transposed answer" {
    // The vertical scenario above with every rect transposed (x<->y, w<->h);
    // horizontal=true must yield the same cross position, now as a y-row.
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

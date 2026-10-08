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

test "assign colours spans greedily: disjoint spans share a lane at the max base, overlapping ones stack outward" {
    const a = std.testing.allocator;
    const Row = struct { claims: []const lanes.LaneClaim, lanes: usize, lane_of: []const u32, pos: []const i32 };
    const rows = [_]Row{
        .{ .claims = &.{ claim(0, 1, 5), claim(2, 3, 6), claim(4, 5, 4) }, .lanes = 1, .lane_of = &.{ 0, 0, 0 }, .pos = &.{ 6, 6, 6 } },
        .{ .claims = &.{ claim(0, 4, 5), claim(1, 3, 5), claim(2, 2, 5) }, .lanes = 3, .lane_of = &.{ 0, 1, 2 }, .pos = &.{ 5, 6, 7 } },
        // A hand example with a tie.
        .{ .claims = &.{ claim(0, 1, 5), claim(2, 3, 7), claim(1, 2, 6), claim(4, 5, 7) }, .lanes = 2, .lane_of = &.{ 0, 0, 1, 0 }, .pos = &.{ 7, 7, 8, 7 } },
    };
    for (rows) |row| {
        var asg = try lanes.assign(a, row.claims, 1);
        defer asg.deinit(a);
        try std.testing.expectEqual(row.lanes, asg.lane_pos.len);
        try std.testing.expectEqualSlices(u32, row.lane_of, asg.lane_of);
        for (row.pos, 0..) |want, i| try std.testing.expectEqual(want, asg.posOf(i));
    }
}

test "clearRunBase parks a run just past its endpoints, or past a blocking rect, on either axis" {
    const rows = [_]struct { horizontal: bool, ps: []const sketch.NodePlacement, want: i32 }{
        .{ .horizontal = false, .ps = &.{ np(1, 0, 0, 5, 3), np(2, 0, 10, 5, 3) }, .want = 6 },
        .{ .horizontal = false, .ps = &.{ np(1, 0, 0, 5, 3), np(2, 0, 10, 5, 3), np(3, 6, 5, 5, 3) }, .want = 12 },
        .{ .horizontal = true, .ps = &.{ np(1, 0, 0, 3, 5), np(2, 10, 0, 3, 5), np(3, 5, 6, 3, 5) }, .want = 12 },
    };
    for (rows) |row| try std.testing.expectEqual(@as(?i32, row.want), lanes.clearRunBase(row.horizontal, row.ps, 1, 2, 1));
}

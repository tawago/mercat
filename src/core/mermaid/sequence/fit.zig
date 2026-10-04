const std = @import("std");
const Direction = @import("../types.zig").Direction;

/// One rung of the sequence fit ladder.
pub const Spacing = struct {
    participant: u32,
    padding: u32,
    direction: ?Direction = null,
};

const tb_auto = [_]Spacing{
    .{ .participant = 8, .padding = 2 },
    .{ .participant = 4, .padding = 2 },
    .{ .participant = 2, .padding = 2 },
    .{ .participant = 2, .padding = 1, .direction = .LR },
};

/// Rungs in the order they are tried until one fits the width: default, reduced and tight
/// spacing, then, for a top-down diagram with no written direction, a tight left-to-right one.
pub fn ladder(base_direction: Direction, direction_explicit: bool) []const Spacing {
    return if (!direction_explicit and base_direction == .TB) &tb_auto else tb_auto[0..3];
}

test "an undirected top-down diagram ends on a tight left-to-right rung" {
    const rungs = ladder(.TB, false);
    try std.testing.expectEqual(@as(usize, 4), rungs.len);
    try std.testing.expectEqualSlices(Spacing, &tb_auto, rungs);
    try std.testing.expectEqual(@as(u32, 8), rungs[0].participant);
    try std.testing.expectEqual(@as(u32, 4), rungs[1].participant);
    try std.testing.expectEqual(@as(u32, 2), rungs[2].participant);
    try std.testing.expectEqual(Spacing{ .participant = 2, .padding = 1, .direction = .LR }, rungs[3]);
}

test "a written direction or a left-to-right one keeps the three spacing rungs" {
    for ([_]struct { Direction, bool }{ .{ .TB, true }, .{ .LR, true }, .{ .LR, false } }) |case| {
        const rungs = ladder(case[0], case[1]);
        try std.testing.expectEqualSlices(Spacing, tb_auto[0..3], rungs);
    }
}

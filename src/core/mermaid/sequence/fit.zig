const std = @import("std");
const Direction = @import("../types.zig").Direction;

/// One rung of the sequence fit ladder.
pub const Spacing = struct {
    participant: u32,
    padding: u32,
    direction: ?Direction = null,
    wrap: bool = false,
};

const s8 = Spacing{ .participant = 8, .padding = 2 };
const s4 = Spacing{ .participant = 4, .padding = 2 };
const s2 = Spacing{ .participant = 2, .padding = 2 };
const lr_tight = Spacing{ .participant = 2, .padding = 1, .direction = .LR };
const w8 = Spacing{ .participant = 8, .padding = 2, .wrap = true };
const w4 = Spacing{ .participant = 4, .padding = 2, .wrap = true };
const w2 = Spacing{ .participant = 2, .padding = 2, .wrap = true };

const auto_tb = [_]Spacing{ s8, s4, s2, lr_tight, w8, w4, w2 };
const written = [_]Spacing{ s8, s4, s2, w8, w4, w2 };

/// Rungs in the order they are tried until one fits the width: default, reduced and tight
/// spacing, then, for a top-down diagram with no written direction, a tight left-to-right one,
/// then the top-down rungs again with message labels wrapped.
pub fn ladder(base_direction: Direction, direction_explicit: bool) []const Spacing {
    if (!direction_explicit and base_direction == .TB) return &auto_tb;
    if (base_direction == .LR) return written[0..3];
    return &written;
}

fn expectWrapRungsLast(rungs: []const Spacing) !void {
    var seen_wrap = false;
    for (rungs) |rung| {
        if (seen_wrap) try std.testing.expect(rung.wrap);
        seen_wrap = seen_wrap or rung.wrap;
    }
}

test "an undirected top-down diagram tries a tight left-to-right rung before wrapping" {
    const rungs = ladder(.TB, false);
    try std.testing.expectEqualSlices(Spacing, &.{ s8, s4, s2, lr_tight, w8, w4, w2 }, rungs);
    try std.testing.expectEqual(Spacing{ .participant = 2, .padding = 1, .direction = .LR }, rungs[3]);
    try expectWrapRungsLast(rungs);
}

test "a written top-down direction wraps after the three spacing rungs" {
    for ([_]Direction{ .TB, .TD, .BT, .RL }) |direction| {
        const rungs = ladder(direction, true);
        try std.testing.expectEqualSlices(Spacing, &.{ s8, s4, s2, w8, w4, w2 }, rungs);
        try expectWrapRungsLast(rungs);
    }
}

test "left to right keeps the three spacing rungs and never wraps" {
    for ([_]bool{ true, false }) |explicit| {
        try std.testing.expectEqualSlices(Spacing, &.{ s8, s4, s2 }, ladder(.LR, explicit));
    }
}

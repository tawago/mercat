const std = @import("std");
const Direction = @import("../types.zig").Direction;

pub const Rung = enum { top_down, left_right };

const top_down_only = [_]Rung{.top_down};
const left_right_only = [_]Rung{.left_right};
const flip = [_]Rung{ .top_down, .left_right };

pub fn ladder(direction: Direction, explicit: bool, needs_top_down: bool) []const Rung {
    if (needs_top_down) return &top_down_only;
    if (!explicit) return &flip;
    if (direction == .LR) return &left_right_only;
    return &top_down_only;
}

test "the flip comes after the top-down degradations and never happens with activations, fragments or notes" {
    try std.testing.expectEqualSlices(Rung, &flip, ladder(.TB, false, false));
    for ([_]Direction{ .TB, .TD, .BT, .RL, .LR }) |direction| {
        for ([_]bool{ true, false }) |explicit| {
            try std.testing.expectEqualSlices(Rung, &top_down_only, ladder(direction, explicit, true));
        }
    }
    try std.testing.expectEqualSlices(Rung, &left_right_only, ladder(.LR, true, false));
    try std.testing.expectEqualSlices(Rung, &top_down_only, ladder(.TD, true, false));
}

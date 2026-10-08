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

test "wrap rungs come last, left to right never wraps, and an undirected top-down diagram tries left to right first" {
    for ([_]Direction{ .TB, .TD, .BT, .RL, .LR }) |direction| {
        for ([_]bool{ true, false }) |explicit| {
            const rungs = ladder(direction, explicit);
            try expectWrapRungsLast(rungs);
            if (direction == .LR) {
                for (rungs) |rung| try std.testing.expect(!rung.wrap);
            }
        }
    }
    const auto = ladder(.TB, false);
    const first_wrap = for (auto, 0..) |rung, i| {
        if (rung.wrap) break i;
    } else auto.len;
    var tight_lr = false;
    for (auto[0..first_wrap]) |rung| tight_lr = tight_lr or rung.direction == .LR;
    try std.testing.expect(tight_lr);
    try std.testing.expect(first_wrap < auto.len);
}

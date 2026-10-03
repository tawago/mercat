const Direction = @import("../types.zig").Direction;

/// One rung of the sequence fit ladder.
pub const Spacing = struct {
    participant: u32,
    padding: u32,
    direction: ?Direction = null,
};

/// Rungs in the order they are tried until one fits the width: default, reduced and tight
/// spacing, then, for a top-down diagram with no written direction, a tight left-to-right one.
pub fn ladder(base_direction: Direction, direction_explicit: bool) [4]?Spacing {
    return .{
        .{ .participant = 8, .padding = 2 },
        .{ .participant = 4, .padding = 2 },
        .{ .participant = 2, .padding = 2 },
        if (!direction_explicit and base_direction == .TB) .{ .participant = 2, .padding = 1, .direction = .LR } else null,
    };
}

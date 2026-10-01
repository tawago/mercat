const std = @import("std");
const sketch = @import("../sketch.zig");
const types = @import("bridge_types.zig");

const Pt = sketch.Point;

fn pending(exit: sketch.Dir4, start: Pt, end: Pt) types.Pending {
    return .{
        .cross = .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .gf = 10,
        .gt = 11,
        .from_rect = .{ .x = 0, .y = 0, .w = 4, .h = 3 },
        .to_rect = .{ .x = 0, .y = 20, .w = 4, .h = 3 },
        .to_box = .{ .x = 0, .y = 20, .w = 4, .h = 3 },
        .sides = .{ .exit = exit, .entry = switch (exit) {
            .south => .north,
            .north => .south,
            .east => .west,
            .west => .east,
        } },
        .start = start,
        .end = end,
        .off_from = 0,
        .off_to = 0,
        .from_frame = null,
        .to_frame = null,
        .pref = null,
    };
}

test "bounds run from the exit port to the entry port along the flow, and a jog is clamped inside them" {
    const down = pending(.south, .{ .x = 1, .y = 2 }, .{ .x = 5, .y = 20 });
    try std.testing.expectEqual([2]i32{ 2, 20 }, down.bounds());
    const up = pending(.north, .{ .x = 1, .y = 20 }, .{ .x = 5, .y = 2 });
    try std.testing.expectEqual([2]i32{ 2, 20 }, up.bounds());
    const right = pending(.east, .{ .x = 3, .y = 1 }, .{ .x = 30, .y = 4 });
    try std.testing.expectEqual([2]i32{ 3, 30 }, right.bounds());
    const left = pending(.west, .{ .x = 30, .y = 1 }, .{ .x = 3, .y = 4 });
    try std.testing.expectEqual([2]i32{ 3, 30 }, left.bounds());

    var p = down;
    try std.testing.expectEqual(@as(?i32, null), p.clampedJog());
    p.jog = 0;
    try std.testing.expectEqual(@as(?i32, 3), p.clampedJog());
    p.jog = 99;
    try std.testing.expectEqual(@as(?i32, 19), p.clampedJog());
    p.jog = 11;
    try std.testing.expectEqual(@as(?i32, 11), p.clampedJog());
}

test "an elbow is the straight line without a jog and four corners with one" {
    var p = pending(.south, .{ .x = 1, .y = 2 }, .{ .x = 5, .y = 20 });
    try std.testing.expectEqualSlices(Pt, &.{ .{ .x = 1, .y = 2 }, .{ .x = 5, .y = 20 } }, p.elbow().slice());
    p.jog = 11;
    try std.testing.expectEqualSlices(Pt, &.{ .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 11 }, .{ .x = 5, .y = 11 }, .{ .x = 5, .y = 20 } }, p.elbow().slice());
    var side = pending(.east, .{ .x = 3, .y = 1 }, .{ .x = 30, .y = 4 });
    side.jog = 12;
    try std.testing.expectEqualSlices(Pt, &.{ .{ .x = 3, .y = 1 }, .{ .x = 12, .y = 1 }, .{ .x = 12, .y = 4 }, .{ .x = 30, .y = 4 } }, side.elbow().slice());
}

test "resetJog wants the row above the target box and drops the jog, or wants none when the ports are aligned" {
    var p = pending(.south, .{ .x = 1, .y = 2 }, .{ .x = 5, .y = 20 });
    p.jog = 7;
    p.resetJog();
    try std.testing.expectEqual(@as(?i32, 18), p.pref);
    try std.testing.expectEqual(@as(?i32, null), p.jog);
    p.end.x = 1;
    p.resetJog();
    try std.testing.expectEqual(@as(?i32, null), p.pref);

    var back = pending(.north, .{ .x = 1, .y = 20 }, .{ .x = 5, .y = 2 });
    back.to_box = .{ .x = 0, .y = 0, .w = 4, .h = 3 };
    back.resetJog();
    try std.testing.expectEqual(@as(?i32, 4), back.pref);
}

test "two bridges share an anchor in one drawn frame, or at one bare node" {
    var a = pending(.south, .{ .x = 1, .y = 2 }, .{ .x = 5, .y = 20 });
    var b = a;
    b.gt = 12;
    try std.testing.expect(!a.sameAnchor(b));
    b.gt = a.gt;
    try std.testing.expect(a.sameAnchor(b));

    a.to_frame = 7;
    b.gt = 12;
    try std.testing.expect(!a.sameAnchor(b));
    b.to_frame = 7;
    try std.testing.expect(a.sameAnchor(b));
    b.to_frame = 8;
    try std.testing.expect(!a.sameAnchor(b));
}

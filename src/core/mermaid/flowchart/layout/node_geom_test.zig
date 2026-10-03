const std = @import("std");
const NodeGeom = @import("node_geom.zig").NodeGeom;

const testing = std.testing;

test "right is the first column past the box" {
    const g: NodeGeom = .{ .x = -3, .y = 0, .w = 5, .h = 3, .layer = 0 };
    try testing.expectEqual(@as(i32, 2), g.right());
}

test "centerX is the middle column for an odd width and the right of the two middle columns for an even one" {
    const odd: NodeGeom = .{ .x = 2, .y = 0, .w = 5, .h = 3, .layer = 0 };
    const even: NodeGeom = .{ .x = 2, .y = 0, .w = 6, .h = 3, .layer = 0 };
    try testing.expectEqual(@as(i32, 4), odd.centerX());
    try testing.expectEqual(@as(i32, 5), even.centerX());
}

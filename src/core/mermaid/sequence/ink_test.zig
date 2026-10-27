const std = @import("std");
const ink = @import("ink.zig");

const testing = std.testing;

test "an illegal overwrite fails the drawing, and a cell off the canvas is its own failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var grid = try ink.Ink.init(arena.allocator(), 4, 1);
    try grid.put(1, 0, '┆', .lifeline);
    try grid.put(1, 0, '─', .stroke);
    try testing.expectError(error.InkConflict, grid.text(0, 0, .{ .bytes = "ab", .width = 2 }, .label));
    try testing.expectError(error.OffCanvas, grid.put(4, 0, 'x', .label));
}

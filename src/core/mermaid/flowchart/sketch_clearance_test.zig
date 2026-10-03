const std = @import("std");
const sketch = @import("sketch.zig");
const sketch_clearance = @import("sketch_clearance.zig");

const NodePlacement = sketch.NodePlacement;

test "clearLine prefers a margined line over a closer touch-free-only line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const want: i32 = 50;
    var list = std.ArrayList(NodePlacement){};
    var next_id: u32 = 0;
    var row: i32 = want - 20;
    while (row <= want + 20) : (row += 1) {
        const open = row == want - 3 or (row >= want - 11 and row <= want - 7);
        if (open) continue;
        try list.append(alloc, .{
            .id = next_id,
            .rect = .{ .x = 0, .y = row, .w = 10, .h = 1 },
            .shape = .rect,
            .lines = &.{},
            .cluster_id = null,
        });
        next_id += 1;
    }
    const placements = try list.toOwnedSlice(alloc);

    const got = sketch_clearance.clearLine(true, want, 0, 5, placements, 9999, 9998, .{ .margin = true });
    try std.testing.expect(got != want - 3);
    try std.testing.expectEqual(want - 8, got);
}

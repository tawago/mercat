const std = @import("std");
const sketch = @import("../sketch.zig");
const bridge_fans = @import("bridge_fans.zig");
const types = @import("bridge_types.zig");

fn crossing(id: u32, from: u32, to: u32, kind: sketch.EdgeKind) types.Crossing {
    return .{ .id = id, .from = from, .to = to, .kind = kind, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = id + 10 };
}

test "groups are the pivot's crossings in input order, two or more, without self-loops or invisible ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]types.Crossing{
        crossing(0, 1, 5, .solid),
        crossing(1, 2, 6, .solid),
        crossing(2, 1, 7, .solid),
        crossing(3, 1, 1, .solid),
        crossing(4, 1, 8, .invisible),
        crossing(5, 2, 9, .dotted),
        crossing(6, 3, 5, .solid),
    };
    const out = try bridge_fans.groups(a, &crossings, .source);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2 }, out[0]);
    try std.testing.expectEqualSlices(usize, &.{ 1, 5 }, out[1]);

    const into = try bridge_fans.groups(a, &crossings, .target);
    try std.testing.expectEqual(@as(usize, 1), into.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 6 }, into[0]);
}

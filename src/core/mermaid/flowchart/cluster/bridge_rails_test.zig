const std = @import("std");
const sketch = @import("../sketch.zig");
const bridge_rails = @import("bridge_rails.zig");

const Pt = sketch.Point;

test "realizedRail accepts a shared stem with disjoint tails and refuses re-contact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem_west = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 2, .y = 4 }, .{ .x = 2, .y = 9 } };
    const stem_east = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 16, .y = 4 }, .{ .x = 16, .y = 9 } };
    var pa = path(&stem_west);
    var pb = path(&stem_east);
    try std.testing.expect(try bridge_rails.realizedRail(a, &.{ pa, pb }, .source));
    try std.testing.expect(!try bridge_rails.realizedRail(a, &.{ pa, pb }, .target));

    const other = [_]Pt{ .{ .x = 11, .y = 0 }, .{ .x = 11, .y = 9 } };
    pb = path(&other);
    try std.testing.expect(!try bridge_rails.realizedRail(a, &.{ pa, pb }, .source));

    const recross = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 16, .y = 4 }, .{ .x = 16, .y = 6 }, .{ .x = 2, .y = 6 }, .{ .x = 2, .y = 8 } };
    pa = path(&stem_west);
    pb = path(&recross);
    try std.testing.expect(!try bridge_rails.realizedRail(a, &.{ pa, pb }, .source));
}

test "realizedRail read from the target end accepts a fan-in rail, a straight member included, and refuses re-contact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const from_west = [_]Pt{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const from_east = [_]Pt{ .{ .x = 16, .y = 0 }, .{ .x = 16, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const straight = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 9 } };
    const pw = path(&from_west);
    const pe = path(&from_east);
    const ps = path(&straight);
    try std.testing.expect(try bridge_rails.realizedRail(a, &.{ pw, pe, ps }, .target));
    try std.testing.expect(!try bridge_rails.realizedRail(a, &.{ pw, pe, ps }, .source));

    const retouch = [_]Pt{ .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 3 }, .{ .x = 16, .y = 3 }, .{ .x = 16, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const pr = path(&retouch);
    try std.testing.expect(!try bridge_rails.realizedRail(a, &.{ pw, pr }, .target));
}

fn path(poly: []const Pt) sketch.EdgePath {
    return .{
        .id = 0,
        .from = 0,
        .to = 1,
        .polyline = poly,
        .port_from = .{ .node = 0, .side = .south, .offset = 0 },
        .port_to = .{ .node = 1, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    };
}

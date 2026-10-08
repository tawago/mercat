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

    // A fan-in rail read from the source end is no rail.
    const from_west = [_]Pt{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const from_east = [_]Pt{ .{ .x = 16, .y = 0 }, .{ .x = 16, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    try std.testing.expect(!try bridge_rails.realizedRail(a, &.{ path(&from_west), path(&from_east) }, .source));
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

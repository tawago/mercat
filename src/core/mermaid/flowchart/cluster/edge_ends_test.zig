const std = @import("std");
const sketch = @import("../sketch.zig");
const edge_ends = @import("edge_ends.zig");

fn path(id: sketch.EdgeId, from: sketch.NodeId, to: sketch.NodeId) sketch.EdgePath {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .polyline = &.{},
        .port_from = .{ .node = from, .side = .south, .offset = 0 },
        .port_to = .{ .node = to, .side = .north, .offset = 0 },
        .arrow_from = .open,
        .arrow_to = .filled,
        .label = null,
        .kind = .dotted,
    };
}

fn rail(role: sketch.EdgeRole, taps: []const sketch.Tap) sketch.Rail {
    return .{
        .pivot = 7,
        .stem = &.{},
        .crossbar = .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 } },
        .taps = taps,
        .kind = .thick,
        .role = role,
        .pivot_arrow = .circle,
    };
}

const origin: sketch.Point = .{ .x = 0, .y = 0 };

test "a fan-out tap runs from the pivot, a fan-in tap runs into it" {
    const taps = [_]sketch.Tap{.{ .edge = 9, .node = 2, .at = origin, .landing = origin, .arrow = .cross }};
    const out = edge_ends.find(&.{}, &.{rail(.fan_out_dropper, &taps)}, 9).?;
    try std.testing.expectEqual(@as(sketch.NodeId, 7), out.from);
    try std.testing.expectEqual(@as(sketch.NodeId, 2), out.to);
    try std.testing.expectEqual([2]sketch.ArrowKind{ .circle, .cross }, out.arrows);
    try std.testing.expectEqual(sketch.EdgeKind.thick, out.kind);

    for ([_]sketch.EdgeRole{ .fan_in_dropper, .fan_in_rail }) |role| {
        const in = edge_ends.find(&.{}, &.{rail(role, &taps)}, 9).?;
        try std.testing.expectEqual(@as(sketch.NodeId, 2), in.from);
        try std.testing.expectEqual(@as(sketch.NodeId, 7), in.to);
        try std.testing.expectEqual([2]sketch.ArrowKind{ .cross, .circle }, in.arrows);
    }
}

test "a path wins over a tap with the same edge id, and an unknown id finds nothing" {
    const taps = [_]sketch.Tap{.{ .edge = 3, .node = 2, .at = origin, .landing = origin }};
    const e = edge_ends.find(&.{path(3, 1, 8)}, &.{rail(.fan_out_dropper, &taps)}, 3).?;
    try std.testing.expectEqual(@as(sketch.NodeId, 1), e.from);
    try std.testing.expectEqual(@as(sketch.NodeId, 8), e.to);
    try std.testing.expectEqual(sketch.EdgeKind.dotted, e.kind);
    try std.testing.expectEqual([2]sketch.ArrowKind{ .open, .filled }, e.arrows);
    try std.testing.expect(edge_ends.find(&.{path(3, 1, 8)}, &.{rail(.fan_out_dropper, &taps)}, 4) == null);
}

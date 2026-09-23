const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const member_stroke = @import("member_stroke.zig");
const port_plan = @import("port_plan.zig");

const testing = std.testing;

fn inkRun(id: sg.EdgeId, row: i32, points: []sketch.Point) sketch.EdgePath {
    points[0] = .{ .x = -40, .y = row };
    points[1] = .{ .x = 60, .y = row };
    return .{ .id = id, .from = 50, .to = 51, .polyline = points, .port_from = .{ .node = 50, .side = .south, .offset = 0 }, .port_to = .{ .node = 51, .side = .north, .offset = 0 }, .arrow_from = .none, .arrow_to = .none, .label = null, .kind = .solid, .role = .forward };
}

test "a long member whose stroke clears nowhere leaves its rail instead of shipping a refused stroke" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 11, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 10, .y = 20, .w = 11, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const edge = sg.Edge{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    const start = sketch.Point{ .x = 5, .y = 5 };
    const end = sketch.Point{ .x = 15, .y = 20 };
    var rows: [12][2]sketch.Point = undefined;
    var existing: [12]sketch.EdgePath = undefined;
    for (&existing, 0..) |*e, i| e.* = inkRun(@intCast(10 + i), @intCast(7 + i), &rows[i]);
    const plan = port_plan.Plan{};
    const clear = try member_stroke.route(a, edge, start, end, 17, 7, 18, existing[0..1], &.{}, &placements, plan, .{}, &.{});
    try testing.expect(clear != null);
    try testing.expect(clear.?[1].y != 7);
    const none = try member_stroke.route(a, edge, start, end, 17, 7, 18, &existing, &.{}, &placements, plan, .{}, &.{});
    try testing.expect(none == null);
}

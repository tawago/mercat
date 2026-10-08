const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const options = @import("options.zig");
const pressure = @import("pressure.zig");
const NodeGeom = @import("node_geom.zig").NodeGeom;

const testing = std.testing;

test "flushLeftRows' connector-stretch floor stops short of the margin instead of stretching a connector" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layer2 = [_]u32{3};
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 0, .reversed = false },
        .{ .from = 2, .to = 3, .edge = 1, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 30, .y = 5, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 50, .y = 5, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 10, .w = 10, .h = 3, .layer = 2 },
    };
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    pressure.flushLeftRows(empty_g, &geom, lg);

    try testing.expectEqual(@as(i32, 5), geom[1].x);
    try testing.expectEqual(@as(i32, 25), geom[2].x);
}

fn bboxOf(geom: []const NodeGeom) i64 {
    var min_x: i32 = std.math.maxInt(i32);
    var max_r: i32 = std.math.minInt(i32);
    for (geom) |g| {
        if (g.x < min_x) min_x = g.x;
        const r = g.x + @as(i32, @intCast(g.w));
        if (r > max_r) max_r = r;
    }
    return @as(i64, max_r) - @as(i64, min_x);
}

fn chain(nodes: []sugiyama.LayerNode, layers: [][]u32, edges: []sugiyama.LayerEdge, real_index: *std.AutoHashMapUnmanaged(sg.NodeId, u32)) sugiyama.LayeredGraph {
    return .{
        .nodes = nodes,
        .layers = layers,
        .edges = edges,
        .reversed_edges = &.{},
        .real_index = real_index.*,
        .arena = null,
    };
}

test "run moves nodes only when the options ask for flush-left and the direction is authored TD" {
    const sg_nodes = [_]sg.Node{
        .{ .id = 10, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 11, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 12, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const sg_edges = [_]sg.Edge{
        .{ .id = 0, .from = 10, .to = 11, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 10, .to = 12, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const graph = sg.SemGraph{ .direction = .TD, .nodes = &sg_nodes, .edges = &sg_edges, .clusters = &.{}, .classes = &.{}, .arena = null };

    var real_index: std.AutoHashMapUnmanaged(sg.NodeId, u32) = .empty;
    defer real_index.deinit(testing.allocator);
    try real_index.put(testing.allocator, 10, 0);
    try real_index.put(testing.allocator, 11, 1);
    try real_index.put(testing.allocator, 12, 2);
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 10 }, .{ .real = 11 }, .{ .real = 12 } };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 0, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 1, .reversed = false },
    };
    const lg = chain(&nodes, &layers, &edges, &real_index);
    const start = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 30, .y = 5, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 45, .y = 5, .w = 10, .h = 3, .layer = 1 },
    };
    var gaps = [_]u32{2};

    var centred = start;
    try pressure.run(testing.allocator, graph, lg, &centred, &.{}, &gaps, .{ .justify = .center }, true);
    try testing.expectEqualSlices(NodeGeom, &start, &centred);

    var rotated = start;
    try pressure.run(testing.allocator, graph, lg, &rotated, &.{}, &gaps, .{ .justify = .flush_left }, false);
    try testing.expectEqualSlices(NodeGeom, &start, &rotated);

    var flushed = start;
    try pressure.run(testing.allocator, graph, lg, &flushed, &.{}, &gaps, .{ .justify = .flush_left }, true);
    try testing.expectEqual(@as(i32, 5), flushed[1].x);
    try testing.expectEqual(@as(i32, 20), flushed[2].x);
    try testing.expectEqual(@as(i32, 0), flushed[0].x);
    try testing.expect(bboxOf(&flushed) < bboxOf(&start));

    // A row with a single child has nothing to flush, so it never moves.
    var lone_nodes = [_]sugiyama.LayerNode{ .{ .real = 20 }, .{ .real = 21 } };
    var lone0 = [_]u32{0};
    var lone1 = [_]u32{1};
    var lone_layers = [_][]u32{ &lone0, &lone1 };
    var lone_edges = [_]sugiyama.LayerEdge{.{ .from = 0, .to = 1, .edge = 0, .reversed = false }};
    var lone_index: std.AutoHashMapUnmanaged(sg.NodeId, u32) = .empty;
    const lone_lg = chain(&lone_nodes, &lone_layers, &lone_edges, &lone_index);
    const lone_start = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 50, .y = 5, .w = 10, .h = 3, .layer = 1 },
    };
    var lone = lone_start;
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    pressure.flushLeftRows(empty_g, &lone, lone_lg);
    try testing.expectEqualSlices(NodeGeom, &lone_start, &lone);
}

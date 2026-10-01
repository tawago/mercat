const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const layer_axis = @import("layer_axis.zig");
const NodeGeom = @import("node_geom.zig").NodeGeom;

const testing = std.testing;

fn layered(nodes: []sugiyama.LayerNode, layers: [][]u32) sugiyama.LayeredGraph {
    return .{
        .nodes = nodes,
        .layers = layers,
        .edges = &.{},
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
}

test "heights: a layer is as tall as its tallest node, virtual nodes included" {
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 1 }, .{ .real = 2 }, .{ .virtual = .{ .edge = 9, .index = 0 } } };
    var layer0 = [_]u32{ 0, 1 };
    var layer1 = [_]u32{2};
    var layers = [_][]u32{ &layer0, &layer1 };
    const geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 5, .h = 3, .layer = 0 },
        .{ .x = 9, .y = 0, .w = 5, .h = 7, .layer = 0 },
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .layer = 1 },
    };
    const h = try layer_axis.heights(testing.allocator, layered(&nodes, &layers), &geom);
    defer testing.allocator.free(h);
    try testing.expectEqualSlices(u32, &.{ 7, 1 }, h);
}

test "gaps: one gap between each pair of layers, as tall as the vertical spacing in TD and 4 once rotated" {
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 } };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{1};
    var layer2 = [_]u32{2};
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    const lg = layered(&nodes, &layers);

    const td = try layer_axis.gaps(testing.allocator, .TD, lg, 2);
    defer testing.allocator.free(td);
    try testing.expectEqualSlices(u32, &.{ 2, 2 }, td);

    const lr = try layer_axis.gaps(testing.allocator, .LR, lg, 2);
    defer testing.allocator.free(lr);
    try testing.expectEqualSlices(u32, &.{ 4, 4 }, lr);

    var one_layers = [_][]u32{&layer0};
    const single = try layer_axis.gaps(testing.allocator, .TD, layered(&nodes, &one_layers), 2);
    defer testing.allocator.free(single);
    try testing.expectEqual(@as(usize, 0), single.len);
}

test "assignY adds to the y a node already has, so a second pass stacks on the first" {
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{1};
    var layers = [_][]u32{ &layer0, &layer1 };
    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 5, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 0, .w = 5, .h = 3, .layer = 1 },
    };
    const layer_h = [_]u32{ 3, 3 };
    const gaps = [_]u32{2};

    layer_axis.assignY(&geom, &layers, &layer_h, &gaps);
    try testing.expectEqual(@as(i32, 0), geom[0].y);
    try testing.expectEqual(@as(i32, 5), geom[1].y);

    layer_axis.assignY(&geom, &layers, &layer_h, &gaps);
    try testing.expectEqual(@as(i32, 0), geom[0].y);
    try testing.expectEqual(@as(i32, 10), geom[1].y);
}

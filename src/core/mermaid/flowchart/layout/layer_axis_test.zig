const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const layout = @import("../layout.zig");
const pack_mod = @import("gap_rows_pack.zig");
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
    const h = try layout.heights(testing.allocator, layered(&nodes, &layers), &geom);
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

    const td = try layout.gaps(testing.allocator, .TD, lg, 2);
    defer testing.allocator.free(td);
    try testing.expectEqualSlices(u32, &.{ 2, 2 }, td);

    const lr = try layout.gaps(testing.allocator, .LR, lg, 2);
    defer testing.allocator.free(lr);
    try testing.expectEqualSlices(u32, &.{ 4, 4 }, lr);

    var one_layers = [_][]u32{&layer0};
    const single = try layout.gaps(testing.allocator, .TD, layered(&nodes, &one_layers), 2);
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

    layout.assignY(&geom, &layers, &layer_h, &gaps);
    try testing.expectEqual(@as(i32, 0), geom[0].y);
    try testing.expectEqual(@as(i32, 5), geom[1].y);

    layout.assignY(&geom, &layers, &layer_h, &gaps);
    try testing.expectEqual(@as(i32, 0), geom[0].y);
    try testing.expectEqual(@as(i32, 10), geom[1].y);
}

test "restack: the ledger's extra rows widen the gaps, push the nodes under a sub-gap down, and move the later sub-gaps with them" {
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 10 }, .{ .real = 11 }, .{ .real = 12 }, .{ .real = 13 } };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{3};
    var layers = [_][]u32{ &layer0, &layer1 };
    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 3, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 5, .w = 3, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 10, .w = 3, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 0, .w = 3, .h = 3, .layer = 1 },
    };
    var layer_h = [_]u32{ 13, 3 };
    var v_sp_per_gap = [_]u32{2};
    const accounts = [_]pack_mod.GapAccount{
        .{ .base = 2, .rows_used = 1, .base_used = false },
        .{ .base = 2, .rows_used = 2, .base_used = false },
        .{ .base = 2, .rows_used = 0, .base_used = false },
    };
    var sub_gaps = [_]pack_mod.SubGap{
        .{ .gap = 1, .layer = 0, .top = 5, .far = 3, .base = 2 },
        .{ .gap = 2, .layer = 0, .top = 10, .far = 8, .base = 2 },
    };
    const rows: pack_mod.Ledger = .{ .gaps = &accounts, .sub_gaps = &sub_gaps };

    layout.restack(layered(&nodes, &layers), &geom, &layer_h, &v_sp_per_gap, rows);

    try testing.expectEqualSlices(u32, &.{3}, &v_sp_per_gap);
    try testing.expectEqualSlices(u32, &.{ 15, 3 }, &layer_h);
    try testing.expectEqual(@as(i32, 0), geom[0].y);
    try testing.expectEqual(@as(i32, 7), geom[1].y);
    try testing.expectEqual(@as(i32, 12), geom[2].y);
    try testing.expectEqual(@as(i32, 18), geom[3].y);
    try testing.expectEqual(@as(i32, 7), sub_gaps[0].top);
    try testing.expectEqual(@as(i32, 3), sub_gaps[0].far);
    try testing.expectEqual(@as(i32, 12), sub_gaps[1].top);
    try testing.expectEqual(@as(i32, 10), sub_gaps[1].far);
}

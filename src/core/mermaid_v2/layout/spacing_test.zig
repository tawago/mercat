const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const spacing = @import("spacing.zig");

const testing = std.testing;

test "clusterHPad forwards prim.framePadX exactly, at every scale" {
    for ([_]u8{ 0, 1, 2, 3 }) |scale| {
        try testing.expectEqual(prim.framePadX(scale), spacing.clusterHPad(scale));
    }
}

test "interLayerSpacing: interior intra-cluster edge floors a base=2 gap to 3" {
    const nodes = [_]sg.Node{
        .{ .id = 1, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 10 },
        .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 10 },
    };
    const edges = [_]sg.Edge{
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const clusters = [_]sg.Cluster{
        .{ .id = 10, .raw_id = "S", .label = "S", .parent = null, .members = &.{ 1, 2 }, .sub_clusters = &.{} },
    };
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, graph);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), lg.layers.len);
    try testing.expectEqual(@as(u32, 3), spacing.interLayerSpacing(graph, lg, 0, 1, 2));
    try testing.expectEqual(@as(u32, 2), spacing.interLayerSpacing(graph, lg, 1, 5, 2));
}

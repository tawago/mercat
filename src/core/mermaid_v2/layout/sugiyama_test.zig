//! Tests for `sugiyama.zig`, split out to keep that file under the
//! 500-line cap enforced by `tools/lint_imports.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");

const assignLayers = sugiyama.assignLayers;
const testing = std.testing;

fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{
        .id = id,
        .raw_id = raw,
        .label = raw,
        .shape = .rect,
        .classes = &.{},
        .cluster = null,
    };
}

fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
    };
}

test "linear chain assigns sequential layers" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2) };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), lg.layerCount());
    try testing.expectEqual(@as(usize, 1), lg.layers[0].len);
    try testing.expectEqual(@as(usize, 1), lg.layers[1].len);
    try testing.expectEqual(@as(usize, 1), lg.layers[2].len);
    try testing.expectEqual(@as(usize, 3), lg.nodeCount());
    for (lg.nodes) |n| try testing.expect(n == .real);
    try testing.expectEqual(@as(usize, 0), lg.reversed_edges.len);
}

test "diamond" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C"), mkNode(3, "D"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1),
        mkEdge(1, 0, 2),
        mkEdge(2, 1, 3),
        mkEdge(3, 2, 3),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), lg.layerCount());
    try testing.expectEqual(@as(usize, 1), lg.layers[0].len);
    try testing.expectEqual(@as(usize, 2), lg.layers[1].len);
    try testing.expectEqual(@as(usize, 1), lg.layers[2].len);
    try testing.expectEqual(@as(usize, 0), lg.reversed_edges.len);
}

test "cycle removed" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 0) };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), lg.reversed_edges.len);
    try testing.expectEqual(@as(usize, 2), lg.layerCount());
    for (lg.nodes) |n| try testing.expect(n == .real);
}

test "long edge inserts virtuals" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C"), mkNode(3, "D"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1),
        mkEdge(1, 0, 2),
        mkEdge(2, 2, 3),
        mkEdge(3, 0, 3),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), lg.layerCount());
    var virtuals: usize = 0;
    for (lg.nodes) |n| switch (n) {
        .virtual => virtuals += 1,
        .real => {},
    };
    try testing.expectEqual(@as(usize, 1), virtuals);
    try testing.expectEqual(@as(usize, 5), lg.nodeCount());
    for (lg.edges) |e| {
        var lf: usize = std.math.maxInt(usize);
        var lt: usize = std.math.maxInt(usize);
        for (lg.layers, 0..) |row, li| {
            for (row) |idx| {
                if (idx == e.from) lf = li;
                if (idx == e.to) lt = li;
            }
        }
        try testing.expect(lf != std.math.maxInt(usize));
        try testing.expect(lt != std.math.maxInt(usize));
        try testing.expect(lt == lf + 1);
    }
}

test "long edge inserts two virtuals" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C"), mkNode(3, "D"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1),
        mkEdge(1, 1, 2),
        mkEdge(2, 2, 3),
        mkEdge(3, 0, 3),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), lg.layerCount());
    var virtuals: usize = 0;
    for (lg.nodes) |n| switch (n) {
        .virtual => virtuals += 1,
        .real => {},
    };
    try testing.expectEqual(@as(usize, 2), virtuals);
}

test "self-loop excluded from LayeredGraph but still drawn by routing.zig from graph.edges" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B") };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 0),
        mkEdge(1, 0, 1),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), lg.edges.len);
    try testing.expectEqual(@as(sg.EdgeId, 1), lg.edges[0].edge);
    try testing.expectEqual(@as(usize, 2), lg.layerCount());

    var still_has_self_loop = false;
    for (g.edges) |e| {
        if (e.from == e.to) still_has_self_loop = true;
    }
    try testing.expect(still_has_self_loop);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 0, .y = 6, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const geom = [_]routing.NodeGeom{
        .{ .x = 0, .y = 0, .w = 7, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 6, .w = 7, .h = 3, .layer = 1 },
    };
    const result = try routing.buildEdges(aa, g, lg, &geom, &placements, &.{}, .{});

    var saw_self_loop = false;
    for (result.edges) |e| {
        if (e.id == 0) {
            try testing.expectEqual(sketch.EdgeRole.self_loop, e.role);
            try testing.expectEqual(@as(sketch.NodeId, 0), e.from);
            try testing.expectEqual(@as(sketch.NodeId, 0), e.to);
            saw_self_loop = true;
        }
    }
    try testing.expect(saw_self_loop);
}

test "iterative cycle-removal DFS handles a very deep chain without stack overflow" {
    const n: usize = 20_000;
    const nodes = try testing.allocator.alloc(sg.Node, n);
    defer testing.allocator.free(nodes);
    const edges = try testing.allocator.alloc(sg.Edge, n - 1);
    defer testing.allocator.free(edges);
    for (nodes, 0..) |*node, i| node.* = mkNode(@intCast(i), "N");
    for (edges, 0..) |*edge, i| edge.* = mkEdge(@intCast(i), @intCast(i), @intCast(i + 1));

    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = nodes,
        .edges = edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(n, lg.layerCount());
    for (lg.layers) |row| try testing.expectEqual(@as(usize, 1), row.len);
}

test "empty graph errors" {
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &.{},
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    try testing.expectError(error.EmptyGraph, assignLayers(testing.allocator, g));
}

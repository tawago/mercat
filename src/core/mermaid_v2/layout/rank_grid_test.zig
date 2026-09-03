//! Tests for `rank_grid.zig`'s invariants — split out to keep the file
//! under the 500-line cap. Builds synthetic `LayeredGraph`s by hand and
//! drives only the public `reflowWideRanks` entry point, observing effects
//! on `geom` (private helpers like `layerWrappedByFan` are file-private to
//! rank_grid.zig and not reachable from here).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const components = @import("components.zig");
const rank_grid = @import("rank_grid.zig");

const testing = std.testing;
const NodeGeom = components.NodeGeom;

fn mkGraph(nodes: []sugiyama.LayerNode, layers: [][]u32, edges: []sugiyama.LayerEdge) sugiyama.LayeredGraph {
    return .{
        .nodes = nodes,
        .layers = layers,
        .edges = edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
}

test "reflowWideRanks: a second wide layer's base_y reflects the first wide layer's shift, and a leaf further down cascades through both" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 10 }, .{ .real = 11 }, .{ .real = 12 }, .{ .real = 13 },
        .{ .real = 20 }, .{ .real = 21 }, .{ .real = 22 }, .{ .real = 23 },
        .{ .real = 30 },
    };
    var layer0 = [_]u32{ 0, 1, 2, 3 };
    var layer1 = [_]u32{ 4, 5, 6, 7 };
    var layer2 = [_]u32{8};
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 4, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 5, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 6, .edge = 102, .reversed = false },
        .{ .from = 3, .to = 7, .edge = 103, .reversed = false },
        .{ .from = 4, .to = 8, .edge = 200, .reversed = false },
        .{ .from = 5, .to = 8, .edge = 201, .reversed = false },
        .{ .from = 6, .to = 8, .edge = 202, .reversed = false },
        .{ .from = 7, .to = 8, .edge = 203, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 20, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 40, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 60, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 40, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 60, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 200, .w = 6, .h = 3, .layer = 2 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    try testing.expectEqual(@as(i32, 106), geom[4].y);

    try testing.expectEqual(@as(i32, 212), geom[8].y);
}

test "reflowWideRanks: a same-layer virtual node's (oversized) width never enters the column/packing math and its position is untouched" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 },                              .{ .real = 2 }, .{ .real = 3 }, .{ .real = 4 },
        .{ .virtual = .{ .edge = 99, .index = 0 } }, .{ .real = 5 }, .{ .real = 6 }, .{ .real = 7 },
        .{ .real = 8 },
    };
    var layer0 = [_]u32{ 0, 1, 2, 3, 4 };
    var layer1 = [_]u32{ 5, 6, 7, 8 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 5, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 6, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 7, .edge = 102, .reversed = false },
        .{ .from = 3, .to = 8, .edge = 103, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 20, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 40, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 60, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 999, .y = 0, .w = 100, .h = 50, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 10, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 30, .y = 100, .w = 6, .h = 3, .layer = 1 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    var rows = std.AutoHashMapUnmanaged(i32, void).empty;
    defer rows.deinit(testing.allocator);
    for (0..4) |i| try rows.put(testing.allocator, geom[i].y, {});
    try testing.expectEqual(@as(usize, 2), rows.count());

    try testing.expectEqual(@as(i32, 999), geom[4].x);
    try testing.expectEqual(@as(i32, 0), geom[4].y);
}

test "reflowWideRanks: nodes drifted far apart by centering are compacted even though their tight packed width already fits the budget" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 },
        .{ .real = 4 }, .{ .real = 5 }, .{ .real = 6 },
    };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 4, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 5, .edge = 102, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 4, .h = 3, .layer = 0 },
        .{ .x = 50, .y = 0, .w = 4, .h = 3, .layer = 0 },
        .{ .x = 100, .y = 0, .w = 4, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 4, .h = 3, .layer = 1 },
        .{ .x = 6, .y = 100, .w = 4, .h = 3, .layer = 1 },
        .{ .x = 12, .y = 100, .w = 4, .h = 3, .layer = 1 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    var xs = [_]i32{ geom[0].x, geom[1].x, geom[2].x };
    std.mem.sort(i32, &xs, {}, std.sort.asc(i32));
    try testing.expectEqual(xs[0] + 4 + 2, xs[1]);
    try testing.expectEqual(xs[1] + 4 + 2, xs[2]);
}

test "reflowWideRanks: a row exactly at the compact_floor boundary compacts to one row; one unit past it stacks into a grid" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 },
        .{ .real = 4 }, .{ .real = 5 }, .{ .real = 6 },
    };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 4, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 5, .edge = 102, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    {
        var geom = [_]NodeGeom{
            .{ .x = 0, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 300, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 600, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 0, .y = 100, .w = 6, .h = 3, .layer = 1 },
            .{ .x = 30, .y = 100, .w = 6, .h = 3, .layer = 1 },
            .{ .x = 60, .y = 100, .w = 6, .h = 3, .layer = 1 },
        };
        rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 80, 2, 1);
        try testing.expectEqual(geom[0].y, geom[1].y);
        try testing.expectEqual(geom[0].y, geom[2].y);
    }

    {
        var geom = [_]NodeGeom{
            .{ .x = 0, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 300, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 600, .y = 0, .w = 23, .h = 3, .layer = 0 },
            .{ .x = 0, .y = 100, .w = 6, .h = 3, .layer = 1 },
            .{ .x = 30, .y = 100, .w = 6, .h = 3, .layer = 1 },
            .{ .x = 60, .y = 100, .w = 6, .h = 3, .layer = 1 },
        };
        rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 80, 2, 1);
        var rows = std.AutoHashMapUnmanaged(i32, void).empty;
        defer rows.deinit(testing.allocator);
        for (0..3) |i| try rows.put(testing.allocator, geom[i].y, {});
        try testing.expect(rows.count() >= 2);
    }
}

test "reflowWideRanks: the widest-node column formula still forces >=2 rows even when the naive per-node-count formula would leave one" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 },
        .{ .real = 4 }, .{ .real = 5 }, .{ .real = 6 },
    };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 4, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 5, .edge = 102, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 30, .h = 3, .layer = 0 },
        .{ .x = 400, .y = 0, .w = 30, .h = 3, .layer = 0 },
        .{ .x = 800, .y = 0, .w = 30, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 200, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 40, .y = 200, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 80, .y = 200, .w = 6, .h = 3, .layer = 1 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 100, 2, 1);

    var rows = std.AutoHashMapUnmanaged(i32, void).empty;
    defer rows.deinit(testing.allocator);
    for (0..3) |i| try rows.put(testing.allocator, geom[i].y, {});
    try testing.expectEqual(@as(usize, 2), rows.count());

    var row_w = std.AutoHashMapUnmanaged(i32, u32).empty;
    defer row_w.deinit(testing.allocator);
    for (0..3) |i| {
        const gp = row_w.getPtr(geom[i].y);
        if (gp) |p| p.* += geom[i].w else try row_w.put(testing.allocator, geom[i].y, geom[i].w);
    }
    var it = row_w.valueIterator();
    while (it.next()) |w| try testing.expect(w.* <= 100);
}

test "reflowWideRanks: row_step (max_h + the grid gap) keeps a tall sub-row three rows clear of the row below it" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 }, .{ .real = 4 },
        .{ .real = 5 }, .{ .real = 6 }, .{ .real = 7 }, .{ .real = 8 },
    };
    var layer0 = [_]u32{ 0, 1, 2, 3 };
    var layer1 = [_]u32{ 4, 5, 6, 7 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 4, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 5, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 6, .edge = 102, .reversed = false },
        .{ .from = 3, .to = 7, .edge = 103, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 8, .h = 9, .layer = 0 },
        .{ .x = 20, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 40, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 60, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 30, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 60, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 90, .y = 100, .w = 6, .h = 3, .layer = 1 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    const row0_y = geom[0].y;
    const row1_y = geom[2].y;
    try testing.expect(row1_y > row0_y);
    // v_spacing 1 would give a two-row gap; the grid keeps three (fan_grid.GRID_GAP_ROWS).
    try testing.expectEqual(@as(i32, 12), row1_y - row0_y);
    try testing.expect(row0_y + 9 < row1_y);
}

test "reflowWideRanks: two edge-free sibling nodes (all-roots AND all-leaves) are left untouched" {
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 1 }, .{ .real = 2 } };
    var layer0 = [_]u32{ 0, 1 };
    var layers = [_][]u32{&layer0};
    var edges = [_]sugiyama.LayerEdge{};
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 100, .y = 0, .w = 6, .h = 3, .layer = 0 },
    };
    const before = geom;

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    try testing.expectEqualSlices(NodeGeom, &before, &geom);
}

test "reflowWideRanks: a rank fed from above that ALSO converges to one child is not exempted as pure fan-IN — it still grids" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 },
        .{ .real = 3 }, .{ .real = 4 },
        .{ .real = 5 },
    };
    var layer0 = [_]u32{ 0, 1 };
    var layer1 = [_]u32{ 2, 3 };
    var layer2 = [_]u32{4};
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 2, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 3, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 4, .edge = 200, .reversed = false },
        .{ .from = 3, .to = 4, .edge = 201, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 20, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 12, .y = 100, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 200, .w = 6, .h = 3, .layer = 2 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    try testing.expect(geom[2].y != geom[3].y);
}

test "rank-grid pushes only strictly-below nodes by added_h; same-layer and above nodes are untouched" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 10 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
        .{ .real = 5 },
        .{ .virtual = .{ .edge = 50, .index = 0 } },
        .{ .real = 11 },
        .{ .virtual = .{ .edge = 51, .index = 0 } },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var layer2 = [_]u32{ 7, 8 };
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 100, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 101, .reversed = false },
        .{ .from = 0, .to = 3, .edge = 102, .reversed = false },
        .{ .from = 0, .to = 4, .edge = 103, .reversed = false },
        .{ .from = 0, .to = 5, .edge = 104, .reversed = false },
        .{ .from = 1, .to = 7, .edge = 200, .reversed = false },
        .{ .from = 2, .to = 7, .edge = 201, .reversed = false },
        .{ .from = 3, .to = 7, .edge = 202, .reversed = false },
        .{ .from = 4, .to = 7, .edge = 203, .reversed = false },
        .{ .from = 5, .to = 7, .edge = 204, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 40, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 60, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 80, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 100, .w = 0, .h = 0, .layer = 1 },
        .{ .x = 0, .y = 150, .w = 6, .h = 3, .layer = 2 },
        .{ .x = 0, .y = 150, .w = 0, .h = 0, .layer = 2 },
    };

    const base_y = geom[1].y;
    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    const added_h = geom[7].y - 150;
    try testing.expect(added_h > 0);

    try testing.expectEqual(@as(i32, 0), geom[0].y);
    try testing.expectEqual(base_y, geom[6].y);
    try testing.expectEqual(@as(i32, 150) + added_h, geom[7].y);
    try testing.expectEqual(@as(i32, 150) + added_h, geom[8].y);
}

test "rank-grid leaves a wrapped fan-OUT layer as one row but still grids an over-wide multi-pivot sibling layer" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
        .{ .real = 5 },
        .{ .real = 6 },
        .{ .real = 7 },
        .{ .real = 8 },
        .{ .real = 9 },
        .{ .real = 10 },
        .{ .real = 11 },
        .{ .real = 12 },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2, 3, 4 };
    var layer2 = [_]u32{ 5, 6, 7, 8 };
    var layer3 = [_]u32{ 9, 10, 11, 12 };
    var layers = [_][]u32{ &layer0, &layer1, &layer2, &layer3 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 100, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 101, .reversed = false },
        .{ .from = 0, .to = 3, .edge = 102, .reversed = false },
        .{ .from = 0, .to = 4, .edge = 103, .reversed = false },
        .{ .from = 5, .to = 9, .edge = 200, .reversed = false },
        .{ .from = 6, .to = 10, .edge = 201, .reversed = false },
        .{ .from = 7, .to = 11, .edge = 202, .reversed = false },
        .{ .from = 8, .to = 12, .edge = 203, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 20, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 20, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 40, .y = 20, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 60, .y = 20, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 40, .w = 8, .h = 3, .layer = 2 },
        .{ .x = 20, .y = 40, .w = 8, .h = 3, .layer = 2 },
        .{ .x = 40, .y = 40, .w = 8, .h = 3, .layer = 2 },
        .{ .x = 60, .y = 40, .w = 8, .h = 3, .layer = 2 },
        .{ .x = 0, .y = 60, .w = 6, .h = 3, .layer = 3 },
        .{ .x = 20, .y = 60, .w = 6, .h = 3, .layer = 3 },
        .{ .x = 40, .y = 60, .w = 6, .h = 3, .layer = 3 },
        .{ .x = 60, .y = 60, .w = 6, .h = 3, .layer = 3 },
    };
    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    const c_y = geom[1].y;
    for (1..5) |i| try testing.expectEqual(c_y, geom[i].y);

    var distinct_rows = std.AutoHashMapUnmanaged(i32, void).empty;
    defer distinct_rows.deinit(testing.allocator);
    for (5..9) |i| try distinct_rows.put(testing.allocator, geom[i].y, {});
    try testing.expect(distinct_rows.count() >= 2);
}

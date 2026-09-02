//! Tests for decascade.zig. Discovered by decascade.zig via `test { _ = @import }`.
//!
//! Builds `sugiyama.LayeredGraph` + `NodeGeom` slices by hand (rather than
//! running the full `assignLayers` pipeline) so each test can pin exact
//! drift/collision/fork geometry and exercise `deCascade` in isolation. The
//! `graph: sg.SemGraph` parameter is unused by `deCascade` (`_ = graph;`),
//! so every test passes the same empty dummy graph.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const decascade = @import("decascade.zig");

const testing = std.testing;
const NodeGeom = routing.NodeGeom;

const dummy_graph = sg.SemGraph{
    .direction = .TD,
    .nodes = &.{},
    .edges = &.{},
    .clusters = &.{},
    .classes = &.{},
    .arena = null,
};

fn geomAt(x: i32, y: i32, w: u32, h: u32, layer: u32) NodeGeom {
    return .{ .x = x, .y = y, .w = w, .h = h, .layer = layer };
}

fn lgOf(nodes: []sugiyama.LayerNode, layers: [][]u32, edges: []sugiyama.LayerEdge) sugiyama.LayeredGraph {
    return .{
        .nodes = nodes,
        .layers = layers,
        .edges = edges,
        .reversed_edges = &.{},
        .real_index = .empty,
        .arena = null,
    };
}

fn edge(from: u32, to: u32) sugiyama.LayerEdge {
    return .{ .from = from, .to = to, .edge = from, .reversed = false };
}

test "deCascade anchors on the most-drifted rail, not the first-drifted one" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
        .{ .real = 5 },
        .{ .real = 6 },
        .{ .real = 7 },
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var l3 = [_]u32{ 4, 5 };
    var l4 = [_]u32{6};
    var l5 = [_]u32{7};
    var layers = [_][]u32{ &l0, &l1, &l2, &l3, &l4, &l5 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2),
        edge(2, 3),
        edge(4, 6),
        edge(6, 7),
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0),
        geomAt(6, 0, 2, 1, 0),
        geomAt(6, 2, 2, 1, 1),
        geomAt(6, 4, 2, 1, 2),
        geomAt(0, 6, 2, 1, 3),
        geomAt(30, 6, 2, 1, 3),
        geomAt(30, 8, 2, 1, 4),
        geomAt(30, 10, 2, 1, 5),
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 0), geom[6].x);
    try testing.expectEqual(@as(i32, 0), geom[7].x);
    try testing.expectEqual(@as(i32, 6), geom[2].x);
    try testing.expectEqual(@as(i32, 6), geom[3].x);
}

test "deCascade head climb stops exactly at a multi-node fork layer" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
    };
    var l0 = [_]u32{0};
    var l1 = [_]u32{ 1, 2 };
    var l2 = [_]u32{3};
    var l3 = [_]u32{4};
    var layers = [_][]u32{ &l0, &l1, &l2, &l3 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 1),
        edge(1, 3),
        edge(3, 4),
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0),
        geomAt(6, 2, 2, 1, 1),
        geomAt(20, 2, 2, 1, 1),
        geomAt(6, 4, 2, 1, 2),
        geomAt(6, 6, 2, 1, 3),
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 0), geom[3].x);
    try testing.expectEqual(@as(i32, 0), geom[4].x);
    try testing.expectEqual(@as(i32, 6), geom[1].x);
    try testing.expectEqual(@as(i32, 20), geom[2].x);
    try testing.expectEqual(@as(i32, 0), geom[0].x);
}

test "deCascade no-ops when the drifted rail head is a true source (no forward parent)" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
    };
    var l0 = [_]u32{0};
    var l1 = [_]u32{1};
    var l2 = [_]u32{2};
    var layers = [_][]u32{ &l0, &l1, &l2 };
    var edges = [_]sugiyama.LayerEdge{
        edge(1, 2),
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0),
        geomAt(6, 2, 2, 1, 1),
        geomAt(6, 4, 2, 1, 2),
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 0), geom[0].x);
    try testing.expectEqual(@as(i32, 6), geom[1].x);
    try testing.expectEqual(@as(i32, 6), geom[2].x);
}

test "deCascade rail walk stops at a branch instead of treating it as rail-straight" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
        .{ .real = 5 },
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{ 3, 4 };
    var l3 = [_]u32{5};
    var layers = [_][]u32{ &l0, &l1, &l2, &l3 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2),
        edge(2, 3),
        edge(3, 5),
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0),
        geomAt(20, 0, 2, 1, 0),
        geomAt(6, 2, 2, 1, 1),
        geomAt(6, 4, 2, 1, 2),
        geomAt(15, 4, 2, 1, 2),
        geomAt(6, 6, 2, 1, 3),
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 6), geom[2].x);
    try testing.expectEqual(@as(i32, 6), geom[3].x);
    try testing.expectEqual(@as(i32, 6), geom[5].x);
}

test "deCascade does not fire for a lone drifted single-node layer (hi==lo)" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var layers = [_][]u32{ &l0, &l1, &l2 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2),
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0),
        geomAt(20, 0, 2, 1, 0),
        geomAt(6, 2, 2, 1, 1),
        geomAt(0, 4, 2, 1, 2),
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 6), geom[2].x);
}

test "deCascade flood-forward never pulls a node above the run into the unit" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var layers = [_][]u32{ &l0, &l1, &l2 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2),
        edge(2, 3),
        edge(3, 1),
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0),
        geomAt(20, 0, 2, 1, 0),
        geomAt(6, 2, 2, 1, 1),
        geomAt(6, 4, 2, 1, 2),
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 0), geom[2].x);
    try testing.expectEqual(@as(i32, 0), geom[3].x);
    try testing.expectEqual(@as(i32, 20), geom[1].x);
}

test "deCascade collision floor clamps the slide short of a fixed sibling's right edge" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
        .{ .real = 5 },
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var l3 = [_]u32{ 4, 5 };
    var layers = [_][]u32{ &l0, &l1, &l2, &l3 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2),
        edge(2, 3),
        edge(3, 4),
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0),
        geomAt(50, 0, 2, 1, 0),
        geomAt(30, 2, 2, 1, 1),
        geomAt(30, 4, 2, 1, 2),
        geomAt(30, 6, 2, 1, 3),
        geomAt(20, 6, 4, 1, 3),
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 26), geom[2].x);
    try testing.expectEqual(@as(i32, 26), geom[3].x);
    try testing.expectEqual(@as(i32, 26), geom[4].x);
    try testing.expectEqual(@as(i32, 20), geom[5].x);
}

test "deCascade entry-corridor drop uses the tallest fork-layer sibling, not just the overlapping one" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var l3 = [_]u32{4};
    var layers = [_][]u32{ &l0, &l1, &l2, &l3 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2),
        edge(2, 3),
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 4, 3, 0),
        geomAt(60, 0, 4, 10, 0),
        geomAt(20, 10, 2, 2, 1),
        geomAt(20, 20, 2, 2, 2),
        geomAt(0, 30, 2, 2, 3),
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 0), geom[2].x);
    try testing.expectEqual(@as(i32, 20), geom[2].y);
    try testing.expectEqual(@as(i32, 30), geom[3].y);
    try testing.expectEqual(@as(i32, 40), geom[4].y);
    try testing.expectEqual(@as(i32, 0), geom[0].y);
    try testing.expectEqual(@as(i32, 0), geom[1].y);
}

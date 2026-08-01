//! Unit tests for `cluster/split.zig` that need no layout-zone privileges.
//! Aggregated from entry.zig, the established `x.zig` -> `x_test.zig` pattern.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const split = @import("split.zig");

/// One top-level node fanning into two members of one subgraph, with the
/// arrowheads of each crossing chosen by the caller.
fn crossingGraph(
    nodes: *[3]sg.Node,
    edges: *[2]sg.Edge,
    members: *[2]sg.NodeId,
    clusters: *[1]sg.Cluster,
    first_arrow: sg.ArrowEnd,
    second_arrow: sg.ArrowEnd,
) sg.SemGraph {
    nodes[0] = .{ .id = 0, .raw_id = "P", .label = "P", .shape = .rect, .classes = &.{}, .cluster = null };
    nodes[1] = .{ .id = 1, .raw_id = "a", .label = "a", .shape = .rect, .classes = &.{}, .cluster = 100 };
    nodes[2] = .{ .id = 2, .raw_id = "b", .label = "b", .shape = .rect, .classes = &.{}, .cluster = 100 };
    edges[0] = .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = first_arrow, .label = null };
    edges[1] = .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = second_arrow, .label = null };
    members[0] = 1;
    members[1] = 2;
    clusters[0] = .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = members, .sub_clusters = &.{} };
    return .{ .direction = .TD, .nodes = nodes, .edges = edges, .clusters = clusters, .classes = &.{}, .arena = null };
}

/// The outer graph's placement edges: everything `buildOuter` emitted for the
/// cross-border crossings. The outer piece is the one with no cluster id.
fn outerEdges(sr: split.SplitResult) []const sg.Edge {
    for (sr.pieces) |p| {
        if (p.cluster_id == null) return p.graph.edges;
    }
    return &.{};
}

test "a placement edge records the directedness of the crossings it stands for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes: [3]sg.Node = undefined;
    var edges: [2]sg.Edge = undefined;
    var members: [2]sg.NodeId = undefined;
    var clusters: [1]sg.Cluster = undefined;

    // Directed crossings: the placement edge stays bare (it drives layout and
    // is never painted) but must not read as arrow-free ink.
    const directed = crossingGraph(&nodes, &edges, &members, &clusters, .filled, .filled);
    const sr_d = try split.split(a, directed);
    const outer_d = outerEdges(sr_d);
    try std.testing.expect(outer_d.len >= 1);
    for (outer_d) |e| {
        try std.testing.expectEqual(sg.ArrowEnd.none, e.arrow_to);
        try std.testing.expect(e.stands_for_directed);
        try std.testing.expect(!sg.arrowFree(e));
    }

    // Arrow-free crossings: nothing to stand for, so the proxy answers
    // arrow-free and the rail-closure law applies to it as declared.
    const undirected = crossingGraph(&nodes, &edges, &members, &clusters, .none, .none);
    const sr_u = try split.split(a, undirected);
    const outer_u = outerEdges(sr_u);
    try std.testing.expect(outer_u.len >= 1);
    for (outer_u) |e| {
        try std.testing.expect(!e.stands_for_directed);
        try std.testing.expect(sg.arrowFree(e));
    }
}

test "one directed crossing is enough to mark a deduped placement edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes: [3]sg.Node = undefined;
    var edges: [2]sg.Edge = undefined;
    var members: [2]sg.NodeId = undefined;
    var clusters: [1]sg.Cluster = undefined;

    // Both crossings share the outer pair (P, super-S), so ONE placement edge
    // stands for both. The arrow-free one is seen first: the directed one that
    // follows still has to be able to speak for the shared proxy.
    const mixed = crossingGraph(&nodes, &edges, &members, &clusters, .none, .filled);
    const sr = try split.split(a, mixed);
    const outer = outerEdges(sr);
    try std.testing.expectEqual(@as(usize, 1), outer.len);
    try std.testing.expect(outer[0].stands_for_directed);
}

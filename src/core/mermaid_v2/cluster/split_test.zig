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

test "every piece edge carries its root origin; placement edges carry none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Top-level T0->T1, intra-cluster A->B, cross-border T0->A.
    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "T0", .label = "T0", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "T1", .label = "T1", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 2, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 7 },
        .{ .id = 3, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 7 },
    };
    const edges = [_]sg.Edge{
        .{ .id = 0, .from = 2, .to = 3, .kind = .dotted, .arrow_from = .none, .arrow_to = .filled, .label = "x" },
        .{ .id = 1, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .open, .label = "y" },
        .{ .id = 2, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sg.NodeId{ 2, 3 };
    const clusters = [_]sg.Cluster{
        .{ .id = 7, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{} },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &clusters, .classes = &.{}, .arena = null };

    const sr = try split.split(a, g);
    for (sr.pieces) |p| {
        for (p.graph.edges) |e| {
            if (e.origin == sg.SENTINEL) {
                // Only synthetic placement edges are origin-free.
                try std.testing.expect(p.cluster_id == null);
                try std.testing.expect(split.idAt(p.orig_ids, e.from) == sg.SENTINEL or
                    split.idAt(p.orig_ids, e.to) == sg.SENTINEL);
                continue;
            }
            const root = edges[e.origin];
            try std.testing.expectEqual(root.from, split.idAt(p.orig_ids, e.from));
            try std.testing.expectEqual(root.to, split.idAt(p.orig_ids, e.to));
            try std.testing.expectEqual(root.kind, e.kind);
            try std.testing.expectEqual(root.arrow_from, e.arrow_from);
            try std.testing.expectEqual(root.arrow_to, e.arrow_to);
            try std.testing.expectEqual(root.label, e.label);
        }
    }
}

test "origin chains through a nested cut to the root id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // S contains sub-cluster T; the deep edge lives inside T. A preceding
    // top-level edge (root id 0) forces the deep edge's root id (1) to differ
    // from its piece-local id (0) at every level, so plain `e.id` chaining
    // cannot masquerade as origin chaining.
    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "A1", .label = "A1", .shape = .rect, .classes = &.{}, .cluster = 1 },
        .{ .id = 1, .raw_id = "A2", .label = "A2", .shape = .rect, .classes = &.{}, .cluster = 1 },
        .{ .id = 2, .raw_id = "X", .label = "X", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 3, .raw_id = "Y", .label = "Y", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sg.Edge{
        .{ .id = 0, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = "top" },
        .{ .id = 1, .from = 0, .to = 1, .kind = .thick, .arrow_from = .none, .arrow_to = .filled, .label = "deep" },
    };
    const mt = [_]sg.NodeId{ 0, 1 };
    const clusters = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "S", .label = "S", .parent = null, .members = &.{}, .sub_clusters = &.{} },
        .{ .id = 1, .raw_id = "T", .label = "T", .parent = 0, .members = &mt, .sub_clusters = &.{} },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &clusters, .classes = &.{}, .arena = null };

    const sr = try split.split(a, g);
    const child = sr.pieces[1].graph; // S's subtree, T now top-level in it
    try std.testing.expectEqual(@as(usize, 1), child.edges.len);
    try std.testing.expectEqual(@as(sg.EdgeId, 1), child.edges[0].origin);

    const sr2 = try split.split(a, child);
    const grandchild = sr2.pieces[1].graph;
    try std.testing.expectEqual(@as(usize, 1), grandchild.edges.len);
    try std.testing.expectEqual(@as(sg.EdgeId, 1), grandchild.edges[0].origin);
    try std.testing.expectEqualStrings("deep", grandchild.edges[0].label.?);
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

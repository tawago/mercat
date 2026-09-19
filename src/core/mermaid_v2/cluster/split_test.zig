const std = @import("std");
const sg = @import("../sem_graph.zig");
const split = @import("split.zig");

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

    const directed = crossingGraph(&nodes, &edges, &members, &clusters, .filled, .filled);
    const sr_d = try split.split(a, directed, .{});
    const outer_d = outerEdges(sr_d);
    try std.testing.expect(outer_d.len >= 1);
    for (outer_d) |e| {
        try std.testing.expectEqual(sg.ArrowEnd.none, e.arrow_to);
        try std.testing.expectEqual(sg.StandsFor.forward_one_way, e.stands_for);
        try std.testing.expect(!sg.arrowFree(e));
        try std.testing.expect(sg.forwardOneWayHead(e));
    }

    const decorated = crossingGraph(&nodes, &edges, &members, &clusters, .circle, .circle);
    const sr_c = try split.split(a, decorated, .{});
    const outer_c = outerEdges(sr_c);
    try std.testing.expect(outer_c.len >= 1);
    for (outer_c) |e| {
        try std.testing.expectEqual(sg.StandsFor.arrow_free, e.stands_for);
        try std.testing.expect(sg.arrowFree(e));
        try std.testing.expect(!sg.forwardOneWayHead(e));
    }

    const undirected = crossingGraph(&nodes, &edges, &members, &clusters, .none, .none);
    const sr_u = try split.split(a, undirected, .{});
    const outer_u = outerEdges(sr_u);
    try std.testing.expect(outer_u.len >= 1);
    for (outer_u) |e| {
        try std.testing.expectEqual(sg.StandsFor.arrow_free, e.stands_for);
        try std.testing.expect(sg.arrowFree(e));
    }
}

test "every piece edge carries its root origin; placement edges carry none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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

    const sr = try split.split(a, g, .{});
    for (sr.pieces) |p| {
        for (p.graph.edges) |e| {
            if (e.origin == sg.SENTINEL) {
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

    const sr = try split.split(a, g, .{});
    const child = sr.pieces[1].graph;
    try std.testing.expectEqual(@as(usize, 1), child.edges.len);
    try std.testing.expectEqual(@as(sg.EdgeId, 1), child.edges[0].origin);

    const sr2 = try split.split(a, child, .{});
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

    const mixed = crossingGraph(&nodes, &edges, &members, &clusters, .none, .filled);
    const sr = try split.split(a, mixed, .{});
    const outer = outerEdges(sr);
    try std.testing.expectEqual(@as(usize, 1), outer.len);
    try std.testing.expectEqual(sg.StandsFor.directed, outer[0].stands_for);
    try std.testing.expect(!sg.arrowFree(outer[0]));
    try std.testing.expect(!sg.forwardOneWayHead(outer[0]));
}

test "identity split for clusterless graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &.{},
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    const result = try split.split(a, g, .{});
    try std.testing.expect(result.isFlat());
}

test "single-level disjoint subgraphs cut into outer + children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 0 },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 0 },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = 1 },
        .{ .id = 3, .raw_id = "D", .label = "D", .shape = .rect, .classes = &.{}, .cluster = 1 },
        .{ .id = 4, .raw_id = "T", .label = "T", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const m0 = [_]sg.NodeId{ 0, 1 };
    const m1 = [_]sg.NodeId{ 2, 3 };
    const clusters = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "c0", .label = "C0", .parent = null, .members = &m0, .sub_clusters = &.{} },
        .{ .id = 1, .raw_id = "c1", .label = "C1", .parent = null, .members = &m1, .sub_clusters = &.{} },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &clusters, .classes = &.{}, .arena = null };

    const r = try split.split(a, g, .{});
    try std.testing.expect(!r.isFlat());
    try std.testing.expectEqual(@as(usize, 3), r.pieces.len);
    try std.testing.expectEqual(@as(usize, 2), r.supers.len);

    try std.testing.expectEqual(@as(usize, 2), r.pieces[1].graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), r.pieces[1].graph.edges.len);
    try std.testing.expectEqual(@as(usize, 3), r.pieces[0].graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), r.pieces[0].graph.edges.len);
    try std.testing.expectEqual(@as(usize, 1), r.supers[0].child_piece);
    try std.testing.expectEqual(@as(usize, 2), r.supers[1].child_piece);
}

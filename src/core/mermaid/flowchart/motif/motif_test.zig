const std = @import("std");
const sg = @import("../sem_graph.zig");
const motif = @import("../motif.zig");
const pack = @import("pack.zig");

fn node(id: sg.NodeId, cluster: ?sg.ClusterId) sg.Node {
    return .{
        .id = id,
        .raw_id = "n",
        .label = "n",
        .shape = .rect,
        .classes = &.{},
        .cluster = cluster,
    };
}

fn edge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
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

fn graphOf(nodes: []const sg.Node, edges: []const sg.Edge, clusters: []const sg.Cluster) sg.SemGraph {
    return .{
        .direction = .TD,
        .nodes = nodes,
        .edges = edges,
        .clusters = clusters,
        .classes = &.{},
        .arena = null,
    };
}

fn findKind(tree: motif.MotifTree, kind: motif.MotifKind) ?motif.Motif {
    for (tree.motifs) |m| {
        if (m.kind == kind) return m;
    }
    return null;
}

fn countKind(tree: motif.MotifTree, kind: motif.MotifKind) usize {
    var n: usize = 0;
    for (tree.motifs) |m| {
        if (m.kind == kind) n += 1;
    }
    return n;
}

fn expectPartition(tree: motif.MotifTree, graph: sg.SemGraph) !void {
    for (graph.nodes) |n| {
        var owners: usize = 0;
        for (tree.motifs) |m| {
            for (m.members) |mid| {
                if (mid == n.id) owners += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), owners);
    }
}

test "non-parallel shapes decompose to a partition with no parallel motif, and pack declines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const four = [_]sg.Node{ node(0, null), node(1, null), node(2, null), node(3, null) };
    const lone_members = [_]sg.NodeId{0};
    const lone_cluster = [_]sg.Cluster{.{
        .id = 0,
        .raw_id = "c",
        .label = "C",
        .parent = null,
        .members = &lone_members,
        .sub_clusters = &.{},
    }};
    const graphs = [_]sg.SemGraph{
        // chain, hub fan-out, diamond (packing it would be visibly wrong)
        graphOf(&four, &.{ edge(0, 0, 1), edge(1, 1, 2), edge(2, 2, 3) }, &.{}),
        graphOf(&four, &.{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 0, 3) }, &.{}),
        graphOf(&four, &.{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 1, 3), edge(3, 2, 3) }, &.{}),
        graphOf(&.{node(0, null)}, &.{}, &.{}),
        graphOf(&.{node(0, 0)}, &.{}, &lone_cluster),
    };
    for (graphs) |g| {
        const tree = try motif.decompose(a, g);
        try expectPartition(tree, g);
        try std.testing.expectEqual(@as(usize, 0), countKind(tree, .parallel));
        try std.testing.expectEqual(@as(?sg.SemGraph, null), try pack.transform(a, g, tree));
    }
}

test "cluster cuts the tree: no motif spans the border" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, null), node(1, 0), node(2, 0) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 1, 2) };
    const members = [_]sg.NodeId{ 1, 2 };
    const clusters = [_]sg.Cluster{.{
        .id = 0,
        .raw_id = "c",
        .label = "C",
        .parent = null,
        .members = &members,
        .sub_clusters = &.{},
    }};
    const g = graphOf(&nodes, &edges, &clusters);

    const tree = try motif.decompose(a, g);
    const cm = findKind(tree, .cluster) orelse return error.NoClusterMotif;
    try std.testing.expectEqual(@as(?sg.ClusterId, 0), cm.cluster_id);
    try std.testing.expectEqual(@as(usize, 0), cm.members.len);
    for (tree.motifs) |m| {
        var inside = false;
        var outside = false;
        for (m.members) |mid| {
            if (mid == 0) outside = true else inside = true;
        }
        try std.testing.expect(!(inside and outside));
    }
    try expectPartition(tree, g);
}

test "microservices-shaped scope: merge node hoisted, pairs fuse into parallel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{
        node(0, null), node(1, null), node(2, null), node(3, null),
        node(4, null), node(5, null), node(6, null), node(7, null),
    };
    const edges = [_]sg.Edge{
        edge(0, 0, 1), edge(1, 2, 3), edge(2, 4, 5), edge(3, 6, 7),
        edge(4, 2, 6), edge(5, 4, 6),
    };
    const g = graphOf(&nodes, &edges, &.{});

    const tree = try motif.decompose(a, g);
    const par = findKind(tree, .parallel) orelse return error.NoParallelMotif;
    try std.testing.expectEqual(@as(usize, 8), par.members.len);
    try std.testing.expectEqual(@as(usize, 1), tree.roots.len);
    try expectPartition(tree, g);
}

test "partition invariant on a random-ish 15-node graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{
        node(0, null),  node(1, null),  node(2, null),  node(3, null),
        node(4, null),  node(5, null),  node(6, null),  node(7, null),
        node(8, 0),     node(9, 0),     node(10, null), node(11, null),
        node(12, null), node(13, null), node(14, null),
    };
    const edges = [_]sg.Edge{
        edge(0, 0, 1),   edge(1, 1, 2),    edge(2, 2, 3),
        edge(3, 3, 4),   edge(4, 3, 5),    edge(5, 3, 6),
        edge(6, 6, 7),   edge(7, 7, 6),    edge(8, 5, 8),
        edge(9, 8, 9),   edge(10, 9, 10),  edge(11, 4, 11),
        edge(12, 5, 11), edge(13, 12, 13), edge(14, 11, 11),
    };
    const members = [_]sg.NodeId{ 8, 9 };
    const clusters = [_]sg.Cluster{.{
        .id = 0,
        .raw_id = "c",
        .label = "C",
        .parent = null,
        .members = &members,
        .sub_clusters = &.{},
    }};
    const g = graphOf(&nodes, &edges, &clusters);

    const tree = try motif.decompose(a, g);
    try expectPartition(tree, g);
}

test "branching cluster vertex wraps in prime; the cluster motif stays pure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, null), node(1, null), node(2, 0) };
    const edges = [_]sg.Edge{ edge(0, 2, 0), edge(1, 2, 1) };
    const members = [_]sg.NodeId{2};
    const clusters = [_]sg.Cluster{.{
        .id = 0,
        .raw_id = "c",
        .label = "C",
        .parent = null,
        .members = &members,
        .sub_clusters = &.{},
    }};
    const g = graphOf(&nodes, &edges, &clusters);

    const tree = try motif.decompose(a, g);
    try std.testing.expectEqual(@as(usize, 1), tree.roots.len);
    const root = tree.motifs[tree.roots[0]];
    try std.testing.expectEqual(motif.MotifKind.prime, root.kind);
    var found_cluster = false;
    for (root.children) |ci| {
        const c = tree.motifs[ci];
        if (c.kind != .cluster) continue;
        found_cluster = true;
        try std.testing.expectEqual(@as(?sg.ClusterId, 0), c.cluster_id);
        try std.testing.expectEqual(@as(usize, 0), c.members.len);
    }
    try std.testing.expect(found_cluster);
    try expectPartition(tree, g);
}

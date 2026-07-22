//! motif/motif_test.zig — unit tests for the MotifTree decomposition.
//!
//! Hand-built SemGraphs only (no parser dependency — the motif zone may
//! not import parse/). Each test pins one classification rule from
//! motif/classify.zig; the partition test pins the global invariant.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const motif = @import("../motif.zig");

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

/// Assert every graph node id appears in exactly one motif's members.
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

test "pure chain of 4 decomposes to one spine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, null), node(1, null), node(2, null), node(3, null) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 1, 2), edge(2, 2, 3) };
    const g = graphOf(&nodes, &edges, &.{});

    const tree = try motif.decompose(a, g);
    try std.testing.expectEqual(@as(usize, 1), tree.motifs.len);
    const m = tree.motifs[tree.roots[0]];
    try std.testing.expectEqual(motif.MotifKind.spine, m.kind);
    try std.testing.expectEqual(@as(usize, 4), m.members.len);
    try std.testing.expectEqual(@as(?sg.NodeId, 0), m.entry);
    try std.testing.expectEqual(@as(u32, 4), m.covered);
    try expectPartition(tree, g);
}

test "hub fan-out classifies as fan absorbing the spokes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, null), node(1, null), node(2, null), node(3, null) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 0, 3) };
    const g = graphOf(&nodes, &edges, &.{});

    const tree = try motif.decompose(a, g);
    try std.testing.expectEqual(@as(usize, 1), tree.motifs.len);
    const m = tree.motifs[tree.roots[0]];
    try std.testing.expectEqual(motif.MotifKind.fan, m.kind);
    try std.testing.expectEqual(@as(usize, 4), m.members.len);
    try std.testing.expectEqual(@as(?sg.NodeId, 0), m.entry);
    try expectPartition(tree, g);
}

test "two isomorphic 2-node pipelines under a root fuse into parallel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 0 -> 1 -> 2 ; 0 -> 3 -> 4
    const nodes = [_]sg.Node{
        node(0, null), node(1, null), node(2, null), node(3, null), node(4, null),
    };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 1, 2), edge(2, 0, 3), edge(3, 3, 4) };
    const g = graphOf(&nodes, &edges, &.{});

    const tree = try motif.decompose(a, g);
    const par = findKind(tree, .parallel) orelse return error.NoParallelMotif;
    // Simple-path branches are absorbed as direct members: {1,2,3,4}.
    try std.testing.expectEqual(@as(usize, 4), par.members.len);
    try std.testing.expectEqual(@as(u32, 4), par.covered);
    // Both branches enter from the pivot: 2 external ins, 0 outs.
    try std.testing.expectEqual(@as(u32, 2), par.ext_in);
    try std.testing.expectEqual(@as(u32, 0), par.ext_out);
    // The pivot itself stays an atom whose child is the parallel motif.
    const pivot = tree.motifs[tree.roots[0]];
    try std.testing.expectEqual(motif.MotifKind.atom, pivot.kind);
    try std.testing.expectEqual(@as(usize, 1), pivot.children.len);
    try expectPartition(tree, g);
}

test "diamond classifies as fan (documented choice)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A -> B, C ; B, C -> D. The merge sink D is a single-vertex dominator
    // child of A (2 parents => hoisted to the pivot), so A has three
    // leaf-ish children and the whole diamond is one fan.
    const nodes = [_]sg.Node{ node(0, null), node(1, null), node(2, null), node(3, null) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 1, 3), edge(3, 2, 3) };
    const g = graphOf(&nodes, &edges, &.{});

    const tree = try motif.decompose(a, g);
    try std.testing.expectEqual(@as(usize, 1), tree.motifs.len);
    const m = tree.motifs[tree.roots[0]];
    try std.testing.expectEqual(motif.MotifKind.fan, m.kind);
    try std.testing.expectEqual(@as(usize, 4), m.members.len);
    try expectPartition(tree, g);
}

test "cluster cuts the tree: no motif spans the border" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 0 (top) -> 1 -> 2, with 1,2 inside cluster 0. Without the cluster
    // this would be one 3-spine; the border must split it.
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
    try std.testing.expectEqual(@as(u32, 2), cm.covered);
    try std.testing.expectEqual(@as(u32, 1), cm.ext_in); // the border edge
    // No motif directly owns nodes from both sides of the border.
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

test "single node is an atom" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{node(0, null)};
    const g = graphOf(&nodes, &.{}, &.{});

    const tree = try motif.decompose(a, g);
    try std.testing.expectEqual(@as(usize, 1), tree.motifs.len);
    try std.testing.expectEqual(motif.MotifKind.atom, tree.motifs[0].kind);
    try std.testing.expectEqual(@as(usize, 1), tree.motifs[0].members.len);
    try expectPartition(tree, g);
}

test "microservices-shaped scope: merge node hoisted, pairs fuse into parallel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Four service->DB pairs where two services also feed a shared node
    // (0->1, 2->3, 4->5, 6->7, plus 2->6 and 4->6): node 6 has two parents,
    // so it is dominated by neither service and hoists to the scope root as
    // its own pair — the 01-plan prediction in miniature.
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

    // Mixed structure: a chain, a fan, a cycle, a cluster with two members,
    // an isolated node, and a couple of merge edges.
    const nodes = [_]sg.Node{
        node(0, null), node(1, null), node(2, null),  node(3, null),
        node(4, null), node(5, null), node(6, null),  node(7, null),
        node(8, 0),    node(9, 0),    node(10, null), node(11, null),
        node(12, null), node(13, null), node(14, null),
    };
    const edges = [_]sg.Edge{
        edge(0, 0, 1),   edge(1, 1, 2),  edge(2, 2, 3), // chain
        edge(3, 3, 4),   edge(4, 3, 5),  edge(5, 3, 6), // fan
        edge(6, 6, 7),   edge(7, 7, 6), // 2-cycle
        edge(8, 5, 8),   edge(9, 8, 9), // into the cluster
        edge(10, 9, 10), // out of the cluster
        edge(11, 4, 11), edge(12, 5, 11), // merge
        edge(13, 12, 13), // detached 2-chain
        edge(14, 11, 11), // self-loop (dropped by scope build)
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

    // Sanity: covered of all roots sums to the full node count.
    var covered: u32 = 0;
    for (tree.roots) |r| covered += tree.motifs[r].covered;
    try std.testing.expectEqual(@as(u32, 15), covered);
}

test "lone cluster vertex classifies as the cluster motif directly (not wrapped)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Top-level scope has no plain nodes: its sole vertex is one cluster
    // holding a single member, so the scope root IS that cluster vertex
    // with nothing downstream.
    const nodes = [_]sg.Node{node(0, 0)};
    const members = [_]sg.NodeId{0};
    const clusters = [_]sg.Cluster{.{
        .id = 0,
        .raw_id = "c",
        .label = "C",
        .parent = null,
        .members = &members,
        .sub_clusters = &.{},
    }};
    const g = graphOf(&nodes, &.{}, &clusters);

    const tree = try motif.decompose(a, g);
    try std.testing.expectEqual(@as(usize, 1), tree.roots.len);
    const root = tree.motifs[tree.roots[0]];
    // The special case: the root IS the cluster motif, never a prime/atom
    // wrapper around it.
    try std.testing.expectEqual(motif.MotifKind.cluster, root.kind);
    try std.testing.expectEqual(@as(?sg.ClusterId, 0), root.cluster_id);
    try expectPartition(tree, g);
}

test "branching cluster vertex wraps in prime; the cluster motif stays pure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Cluster C(0) holds member M, which feeds two independent top-level
    // nodes D, E (M -> D, M -> E). At the top scope, C is an opaque vertex
    // whose dominator children are D and E: a branching cluster pivot.
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
    // One of the prime's children is the pure cluster motif: no members of
    // its own — cluster motifs otherwise stay pure subgraph interiors.
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

test "dump emits begin/end markers and one line per motif" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, null), node(1, null), node(2, null), node(3, null) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 1, 2), edge(2, 2, 3) };
    const g = graphOf(&nodes, &edges, &.{});

    const tree = try motif.decompose(a, g);
    const text = try motif.dump(a, g, tree);
    try std.testing.expect(std.mem.startsWith(u8, text, "mercat-motifs: begin nodes=4"));
    try std.testing.expect(std.mem.indexOf(u8, text, "- spine size=4 members=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mercat-motifs: end motifs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "nonprime=4/4") != null);
}

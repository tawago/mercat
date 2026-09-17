//! motif/pack.zig — TD/BT motif-block packing via synthetic clusters.
//!
//! Pure transform: SemGraph + MotifTree in, transformed SemGraph out (or
//! null when not applicable). Each absorbed `parallel` motif's branches
//! get one fresh synthetic cluster: `members` = branch nodes, whose
//! `Node.cluster` is reassigned to it (the cut key `cluster/split.zig`
//! uses, making cut-layout-stitch treat the branch as one rigid unit);
//! `parent` = the branch's shared enclosing cluster. Synthetic clusters
//! cost nothing (`Cluster.synthetic`: no pad/border/label), letting outer
//! levers (e.g. rank_grid) tile the branch row into sub-rows. Result feeds
//! the live score search as one candidate (select.zig).
//!
//! Scope: absorbed `parallel` motifs, TD/BT graphs only.
//! Lint zone: motif — std, prim, sem_graph, motif-internal only.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const types = @import("types.zig");
const scope = @import("scope.zig");

/// Return a packed copy of `graph` with one synthetic cluster per parallel
/// branch, or null when packing does not apply (non-vertical direction, or
/// no absorbed parallel motif in `tree`). All new storage comes from `a`
/// (arena expected); untouched slices are borrowed from the input graph.
pub fn transform(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    tree: types.MotifTree,
) error{OutOfMemory}!?sg.SemGraph {
    switch (graph.direction) {
        .TD, .BT => {},
        .LR, .RL => return null,
    }

    const Branch = struct { parent: ?sg.ClusterId, nodes: []const sg.NodeId };
    var branches: std.ArrayListUnmanaged(Branch) = .empty;
    for (tree.motifs) |m| {
        if (m.kind != .parallel or m.branches.len < 2) continue;
        for (m.branches) |run| {
            if (run.len < 2) continue; // a 1-node branch gains nothing rigid
            const parent: ?sg.ClusterId = scope.clusterOf(graph, run[0]);
            // Defensive: all branch nodes must share one enclosing cluster. // guarded-by: pack.zig "parallel branch straddling two clusters: transform skips it (defensive)"
            var consistent = true;
            for (run[1..]) |nid| {
                if (!scope.eqOpt(scope.clusterOf(graph, nid), parent)) {
                    consistent = false;
                    break;
                }
            }
            if (!consistent) continue;
            try branches.append(a, .{ .parent = parent, .nodes = run });
        }
    }
    if (branches.items.len == 0) return null;

    var next_id: sg.ClusterId = 0;
    for (graph.clusters) |c| {
        if (c.id >= next_id) next_id = c.id + 1;
    }

    // node id -> synthetic cluster id (dense map over node ids).
    var max_node_id: usize = 0;
    for (graph.nodes) |n| max_node_id = @max(max_node_id, @as(usize, n.id));
    const reassign = try a.alloc(?sg.ClusterId, max_node_id + 1);
    @memset(reassign, null);

    const synth = try a.alloc(sg.Cluster, branches.items.len);
    for (branches.items, 0..) |b, i| {
        const cid = next_id;
        next_id += 1;
        for (b.nodes) |nid| reassign[nid] = cid;
        synth[i] = .{
            .id = cid,
            .raw_id = try std.fmt.allocPrint(a, "__pack{d}", .{cid}),
            .label = "",
            .parent = b.parent,
            .members = b.nodes,
            .sub_clusters = &.{},
            .direction = null, // inherit: branch stacks along the flow axis
            .synthetic = true,
        };
    }

    const nodes = try a.alloc(sg.Node, graph.nodes.len);
    for (graph.nodes, 0..) |n, i| {
        nodes[i] = n;
        if (reassign[n.id]) |cid| nodes[i].cluster = cid;
    }

    // Rebuild existing clusters: parents of injected branches lose those
    // nodes from `members` and gain the synthetic ids in `sub_clusters`.
    const clusters = try a.alloc(sg.Cluster, graph.clusters.len + synth.len);
    for (graph.clusters, 0..) |c, i| {
        clusters[i] = c;
        var lost = false;
        for (c.members) |m| {
            if (reassign[m] != null) {
                lost = true;
                break;
            }
        }
        if (lost) {
            var kept: std.ArrayListUnmanaged(sg.NodeId) = .empty;
            for (c.members) |m| {
                if (reassign[m] == null) try kept.append(a, m);
            }
            clusters[i].members = try kept.toOwnedSlice(a);
        }
        var gained: std.ArrayListUnmanaged(sg.ClusterId) = .empty;
        for (synth) |s| {
            if (scope.eqOpt(s.parent, c.id)) try gained.append(a, s.id);
        }
        if (gained.items.len > 0) {
            try gained.insertSlice(a, 0, c.sub_clusters);
            clusters[i].sub_clusters = try gained.toOwnedSlice(a);
        }
    }
    for (synth, graph.clusters.len..) |s, i| clusters[i] = s;

    var out = graph;
    out.nodes = nodes;
    out.clusters = clusters;
    return out;
}

// ====================================================================
// Tests
// ====================================================================

const motif = @import("../motif.zig");

/// Two isomorphic 2-node branches under a fork: A -> B1 -> C1, A -> B2 -> C2.
/// classify absorbs them as one parallel motif with recorded branches.
fn parallelNodes() [5]sg.Node {
    var out: [5]sg.Node = undefined;
    const raw = [_][]const u8{ "A", "B1", "C1", "B2", "C2" };
    for (raw, 0..) |r, i| {
        out[i] = .{ .id = @intCast(i), .raw_id = r, .label = r, .shape = .rect, .classes = &.{}, .cluster = null };
    }
    return out;
}

fn parallelEdges() [4]sg.Edge {
    const pairs = [_][2]sg.NodeId{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 3 }, .{ 3, 4 } };
    var out: [4]sg.Edge = undefined;
    for (pairs, 0..) |p, i| {
        out[i] = .{ .id = @intCast(i), .from = p[0], .to = p[1], .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    }
    return out;
}

test "parallel TD graph: one synthetic cluster per branch, members reassigned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = parallelNodes();
    const edges = parallelEdges();
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };

    const tree = try motif.decompose(a, g);
    const packed_g = (try transform(a, g, tree)) orelse return error.ExpectedPack;

    try std.testing.expectEqual(@as(usize, 2), packed_g.clusters.len);
    for (packed_g.clusters) |c| {
        try std.testing.expect(c.synthetic);
        try std.testing.expectEqual(@as(usize, 2), c.members.len);
        try std.testing.expectEqual(@as(?sg.ClusterId, null), c.parent);
        try std.testing.expectEqualStrings("", c.label);
        for (c.members) |m| {
            try std.testing.expectEqual(@as(?sg.ClusterId, c.id), packed_g.nodes[m].cluster);
        }
    }
    // The fork node A stays top-level; the original graph is untouched.
    try std.testing.expectEqual(@as(?sg.ClusterId, null), packed_g.nodes[0].cluster);
    try std.testing.expectEqual(@as(?sg.ClusterId, null), g.nodes[1].cluster);
}

test "LR graph: transform declines (null)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = parallelNodes();
    const edges = parallelEdges();
    const g: sg.SemGraph = .{ .direction = .LR, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const tree = try motif.decompose(a, g);
    try std.testing.expectEqual(@as(?sg.SemGraph, null), try transform(a, g, tree));
}

test "no parallel motif: transform declines (null)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Plain 3-chain: spine, no parallel.
    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const tree = try motif.decompose(a, g);
    try std.testing.expectEqual(@as(?sg.SemGraph, null), try transform(a, g, tree));
}

test "parallel branch straddling two clusters: transform skips it (defensive)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two nodes in two DIFFERENT clusters, hand-fed as one parallel motif's
    // branch. Per-scope decomposition never produces this in practice (every
    // scope's vertices share one enclosing cluster by construction), so this
    // drives the defensive consistency check directly: if it were removed,
    // transform would wrongly reassign node 1 out of cluster 2 into a fresh
    // synthetic cluster parented under cluster 1 instead of skipping.
    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 1 },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 2 },
    };
    const m1 = [_]sg.NodeId{0};
    const m2 = [_]sg.NodeId{1};
    const clusters = [_]sg.Cluster{
        .{ .id = 1, .raw_id = "c1", .label = "C1", .parent = null, .members = &m1, .sub_clusters = &.{} },
        .{ .id = 2, .raw_id = "c2", .label = "C2", .parent = null, .members = &m2, .sub_clusters = &.{} },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &.{}, .clusters = &clusters, .classes = &.{}, .arena = null };

    const run = [_]sg.NodeId{ 0, 1 };
    const branches = [_][]const sg.NodeId{&run};
    const motifs = [_]types.Motif{.{
        .kind = .parallel,
        .members = &run,
        .entry = null,
        .cluster_id = null,
        .ext_in = 0,
        .ext_out = 0,
        .covered = 0,
        .children = &.{},
        .branches = &branches,
    }};
    const tree: types.MotifTree = .{ .motifs = &motifs, .roots = &[_]usize{0}, .node_count = 2 };

    // No consistent branch survives the check, so transform declines
    // entirely rather than mis-decomposing the straddling branch.
    try std.testing.expectEqual(@as(?sg.SemGraph, null), try transform(a, g, tree));
}

test "parallel nested in a real cluster: parent wiring correct (microservices shape)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Cluster M (id 7) holds two isomorphic 2-node branches fed from a
    // top-level node A: A -> B1 -> C1, A -> B2 -> C2 with B*,C* in M.
    var nodes = parallelNodes();
    for (nodes[1..]) |*n| n.cluster = 7;
    const edges = parallelEdges();
    const members = [_]sg.NodeId{ 1, 2, 3, 4 };
    const clusters = [_]sg.Cluster{
        .{ .id = 7, .raw_id = "M", .label = "M", .parent = null, .members = &members, .sub_clusters = &.{} },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &clusters, .classes = &.{}, .arena = null };

    const tree = try motif.decompose(a, g);
    const packed_g = (try transform(a, g, tree)) orelse return error.ExpectedPack;

    try std.testing.expectEqual(@as(usize, 3), packed_g.clusters.len); // M + 2 synthetic
    const m = packed_g.clusters[0];
    try std.testing.expect(!m.synthetic);
    // M keeps no direct members (all four went into branch clusters) and
    // registers both synthetic children.
    try std.testing.expectEqual(@as(usize, 0), m.members.len);
    try std.testing.expectEqual(@as(usize, 2), m.sub_clusters.len);
    for (packed_g.clusters[1..]) |c| {
        try std.testing.expect(c.synthetic);
        try std.testing.expectEqual(@as(?sg.ClusterId, 7), c.parent);
        try std.testing.expectEqual(@as(usize, 2), c.members.len);
    }
}

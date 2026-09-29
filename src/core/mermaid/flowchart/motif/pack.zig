const std = @import("std");
const sg = @import("../sem_graph.zig");
const types = @import("types.zig");
const scope = @import("scope.zig");

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
            if (run.len < 2) continue;
            const parent: ?sg.ClusterId = graph.clusterOf(run[0]);
            // guarded-by: pack_test.zig "parallel branch straddling two clusters: transform skips it (defensive)"
            var consistent = true;
            for (run[1..]) |nid| {
                if (!scope.eqOpt(graph.clusterOf(nid), parent)) {
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
            .direction = null,
            .synthetic = true,
        };
    }

    const nodes = try a.alloc(sg.Node, graph.nodes.len);
    for (graph.nodes, 0..) |n, i| {
        nodes[i] = n;
        if (reassign[n.id]) |cid| nodes[i].cluster = cid;
    }

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

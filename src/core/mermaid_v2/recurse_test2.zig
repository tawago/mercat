//! recurse_test2.zig — continuation of recurse_test.zig, split at the
//! mermaid_v2 500-line cap. Same zone privileges (cluster/ + layout/); the
//! shared merged-Sketch helpers are imported from recurse_test.zig.

const std = @import("std");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const recurse = @import("recurse.zig");
const rt = @import("recurse_test.zig");
const assertUniqueEdgeIds = rt.assertUniqueEdgeIds;
const clusterOf = rt.clusterOf;

/// The merged placement whose label reads `name`, or null.
fn placementNamed(s: sketch.Sketch, name: []const u8) ?sketch.NodePlacement {
    for (s.nodes) |p| {
        if (p.lines.len != 0 and std.mem.eql(u8, p.lines[0], name)) return p;
    }
    return null;
}

// An outer fan whose targets are SUBGRAPHS: the outer piece's fan co-set
// names the outer PLACEMENT edges, and stitch drops exactly those (they
// touch a super-node) in favour of bridge EdgePaths keyed by crossing id.
// Unless the set is rewritten through that swap, its members resolve to
// nothing in the merged Sketch and the ink those edges legally share loses
// its permission record.
// Fan-into-subgraphs fixture: Top fans out into two sibling subgraphs
// (Top -> a1 in S, Top -> b1 in R), each subgraph a two-node chain. In the
// OUTER piece both targets are super-nodes one layer below Top, so the outer
// layout sees a two-peer fan whose members are placement edges — the exact
// edges stitch drops in favour of bridges.
fn fanIntoTwoSubgraphsGraph(
    nodes_buf: []sem_graph.Node,
    edges_buf: []sem_graph.Edge,
    members_s: []sem_graph.NodeId,
    members_r: []sem_graph.NodeId,
    clusters_buf: []sem_graph.Cluster,
) sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    const names = [_][]const u8{ "Top", "a1", "a2", "b1", "b2" };
    const owners = [_]?sem_graph.ClusterId{ null, 100, 100, 200, 200 };
    for (names, 0..) |nm, i| {
        nodes_buf[i] = .{ .id = @intCast(i), .raw_id = nm, .label = nm, .shape = NS.rect, .classes = &.{}, .cluster = owners[i] };
    }
    const pairs = [_][2]sem_graph.NodeId{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 3 }, .{ 3, 4 } };
    for (pairs, 0..) |p, i| {
        edges_buf[i] = .{ .id = @intCast(i), .from = p[0], .to = p[1], .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    }
    members_s[0] = 1;
    members_s[1] = 2;
    members_r[0] = 3;
    members_r[1] = 4;
    clusters_buf[0] = .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = members_s, .sub_clusters = &.{}, .direction = null };
    clusters_buf[1] = .{ .id = 200, .raw_id = "R", .label = "R", .parent = null, .members = members_r, .sub_clusters = &.{}, .direction = null };
    return .{
        .direction = .TD,
        .nodes = nodes_buf,
        .edges = edges_buf,
        .clusters = clusters_buf,
        .classes = &.{},
        .arena = null,
    };
}

// An outer fan whose targets are SUBGRAPHS: the outer piece's fan co-set
// names the outer PLACEMENT edges, and stitch drops exactly those (they
// touch a super-node) in favour of bridge EdgePaths keyed by crossing id.
// Unless the set is rewritten through that swap, its members resolve to
// nothing in the merged Sketch and the ink those edges legally share loses
// its permission record.
test "an outer fan into sibling subgraphs names its bridges, not the dropped placement edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_s: [2]sem_graph.NodeId = undefined;
    var members_r: [2]sem_graph.NodeId = undefined;
    var clusters_buf: [2]sem_graph.Cluster = undefined;
    const graph = fanIntoTwoSubgraphsGraph(&nodes_buf, &edges_buf, &members_s, &members_r, &clusters_buf);

    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });
    const top = placementNamed(s, "Top") orelse return error.TopNotPlaced;

    var owners = try assertUniqueEdgeIds(a, s);
    defer owners.deinit();

    // A qualifying set: at least two members that still carry geometry, all
    // leaving Top, at least two of them landing INSIDE a cluster — i.e. the
    // bridges that replaced Top's dropped placement edges.
    var found = false;
    for (s.co_sets) |set| {
        var live: usize = 0;
        var into_clusters: usize = 0;
        for (set.members) |m| {
            const owner = owners.get(m) orelse continue;
            if (owner != top.id) break;
            live += 1;
            for (s.edges) |e| {
                if (e.id != m) continue;
                if (try clusterOf(s, e.to) != null) into_clusters += 1;
            }
        } else if (live >= 2 and into_clusters >= 2) found = true;
        if (found) break;
    }
    try std.testing.expect(found);
}

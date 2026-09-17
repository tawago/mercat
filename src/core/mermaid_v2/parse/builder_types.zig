//! Intermediate (builder) types used during `parse.zig`'s single-pass
//! construction of SemGraph nodes, clusters, and classes. Separate from
//! the public sem_graph types so the parser can mutate them freely while
//! the graph is under construction, then freeze them via `materializeNodes`
//! / `materializeClusters`.
//!
//! Imports: only `std`, `../sem_graph.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");

pub const NodeBuilder = struct {
    id: sg.NodeId,
    raw_id: []const u8,
    label: []const u8,
    shape: sg.NodeShape,
    classes: std.ArrayList(sg.ClassId),
    cluster: ?sg.ClusterId,
};

pub const ClusterBuilder = struct {
    id: sg.ClusterId,
    raw_id: []const u8,
    label: []const u8,
    parent: ?sg.ClusterId,
    members: std.ArrayList(sg.NodeId),
    sub_clusters: std.ArrayList(sg.ClusterId),
    direction: ?sg.Direction,
};

/// Drop clusters that ended the parse with no members and no surviving
/// sub-clusters, remapping ids in `clusters` and `nodes` in place. Such
/// clusters arise legally — e.g. `subgraph S` whose statements only
/// re-reference nodes already owned by an earlier cluster (a node keeps
/// its FIRST cluster), or a literally empty `subgraph S\nend` — and the
/// layout pipeline rejects an empty child graph, so they must not reach
/// the SemGraph. Descending-id order handles nesting in one pass: a
/// sub-cluster is always created after (id greater than) its parent.
pub fn pruneEmptyClusters(
    a: std.mem.Allocator,
    nodes: []NodeBuilder,
    clusters: *std.ArrayList(ClusterBuilder),
) error{OutOfMemory}!void {
    const n = clusters.items.len;
    if (n == 0) return;
    const dropped = try a.alloc(bool, n);
    defer a.free(dropped);
    @memset(dropped, false);
    var any = false;
    var cid: usize = n;
    while (cid > 0) {
        cid -= 1;
        const c = &clusters.items[cid];
        if (c.members.items.len > 0) continue;
        var kept_sub = false;
        for (c.sub_clusters.items) |sc| {
            if (!dropped[sc]) { kept_sub = true; break; }
        }
        if (kept_sub) continue;
        dropped[cid] = true;
        any = true;
    }
    if (!any) return;

    const remap = try a.alloc(sg.ClusterId, n);
    defer a.free(remap);
    var new_id: sg.ClusterId = 0;
    for (dropped, 0..) |d, i| {
        remap[i] = new_id;
        if (!d) new_id += 1;
    }
    var w: usize = 0;
    for (0..n) |i| {
        if (dropped[i]) continue;
        var c = clusters.items[i];
        c.id = remap[i];
        // A kept cluster's parent is always kept (it has a kept child). // guarded-by: parse_test.zig "nested subgraph: parent survives via kept child with no own members"
        if (c.parent) |p| c.parent = remap[p];
        var sw: usize = 0;
        for (c.sub_clusters.items) |sc| {
            if (dropped[sc]) continue;
            c.sub_clusters.items[sw] = remap[sc];
            sw += 1;
        }
        c.sub_clusters.shrinkRetainingCapacity(sw);
        clusters.items[w] = c;
        w += 1;
    }
    clusters.shrinkRetainingCapacity(w);
    // Dropped clusters have no members, so only remapping is needed here. // guarded-by: parse_test.zig "dropped empty cluster leaves no dangling node->cluster reference"
    for (nodes) |*node| {
        if (node.cluster) |c| node.cluster = remap[c];
    }
}

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
            if (!dropped[sc]) {
                kept_sub = true;
                break;
            }
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
        // guarded-by: parse_test.zig "nested subgraph: parent survives via kept child with no own members"
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
    // guarded-by: parse_test.zig "dropped empty cluster leaves no dangling node->cluster reference"
    for (nodes) |*node| {
        if (node.cluster) |c| node.cluster = remap[c];
    }
}

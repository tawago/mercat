//! The graph under construction: nodes, edges and subgraphs in source order, plus what a subgraph
//! endpoint needs to name one member. A skipped line is undone with `begin` and `rollback`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const token = @import("token.zig");

const NodeId = sg.NodeId;
const ClusterId = sg.ClusterId;

pub const Role = enum { source, target };

const ClusterRec = struct {
    raw_id: []const u8,
    label: []const u8,
    parent: ?ClusterId,
    direction: ?sg.Direction = null,
    /// Root subgraphs have depth 1.
    depth: u32,
    /// The last subgraph opened inside this one; null while it is open.
    end: ?ClusterId = null,
    members: std.ArrayList(NodeId) = .empty,
    subs: std.ArrayList(ClusterId) = .empty,
};

const Undo = struct { node: NodeId, side: u1, old: u32 };

pub const Mark = struct { nodes: usize, edges: usize };

pub const Built = struct {
    nodes: []const sg.Node,
    edges: []const sg.Edge,
    clusters: []const sg.Cluster,
};

pub const Builder = struct {
    a: std.mem.Allocator,
    nodes: std.ArrayList(sg.Node) = .empty,
    /// Per node, the depth of the deepest subgraph holding both ends of an edge that leaves it
    /// (side 0) or enters it (side 1); 0 when there is none.
    links: std.ArrayList([2]u32) = .empty,
    edges: std.ArrayList(sg.Edge) = .empty,
    clusters: std.ArrayList(ClusterRec) = .empty,
    node_ids: std.StringHashMapUnmanaged(NodeId) = .empty,
    cluster_ids: std.StringHashMapUnmanaged(ClusterId) = .empty,
    /// The innermost open subgraph.
    open: ?ClusterId = null,
    undo: std.ArrayList(Undo) = .empty,

    pub fn init(a: std.mem.Allocator) Builder {
        return .{ .a = a };
    }

    /// The node for `raw_id`, created in the open subgraph when it is new.
    pub fn node(b: *Builder, raw_id: []const u8) error{OutOfMemory}!NodeId {
        if (b.node_ids.get(raw_id)) |id| return id;
        const id: NodeId = @intCast(b.nodes.items.len);
        try b.nodes.append(b.a, .{
            .id = id,
            .raw_id = raw_id,
            .label = raw_id,
            .shape = .rect,
            .classes = &.{},
            .cluster = b.open,
        });
        try b.links.append(b.a, .{ 0, 0 });
        try b.node_ids.put(b.a, raw_id, id);
        if (b.open) |c| try b.clusters.items[c].members.append(b.a, id);
        return id;
    }

    pub fn declare(b: *Builder, id: NodeId, shape: sg.NodeShape, label: ?[]const u8) void {
        b.nodes.items[id].shape = shape;
        if (label) |text| b.nodes.items[id].label = text;
    }

    pub fn addEdge(b: *Builder, from: NodeId, to: NodeId, link: token.Link, label: ?[]const u8) error{OutOfMemory}!void {
        const id: sg.EdgeId = @intCast(b.edges.items.len);
        try b.edges.append(b.a, .{
            .id = id,
            .from = from,
            .to = to,
            .kind = link.kind,
            .arrow_from = link.from,
            .arrow_to = link.to,
            .label = label,
        });
        const depth = b.commonDepth(from, to);
        if (depth == 0) return;
        for ([2]NodeId{ from, to }, 0..) |n, side| {
            const deepest = &b.links.items[n][side];
            if (deepest.* >= depth) continue;
            try b.undo.append(b.a, .{ .node = n, .side = @intCast(side), .old = deepest.* });
            deepest.* = depth;
        }
    }

    pub fn openCluster(b: *Builder, raw_id: []const u8, label: []const u8) error{OutOfMemory}!void {
        const id: ClusterId = @intCast(b.clusters.items.len);
        const depth: u32 = if (b.open) |p| b.clusters.items[p].depth + 1 else 1;
        try b.clusters.append(b.a, .{ .raw_id = raw_id, .label = label, .parent = b.open, .depth = depth });
        if (raw_id.len > 0) try b.cluster_ids.put(b.a, raw_id, id);
        if (b.open) |p| try b.clusters.items[p].subs.append(b.a, id);
        b.open = id;
    }

    /// Closes the innermost open subgraph; false when none is open.
    pub fn closeCluster(b: *Builder) bool {
        const id = b.open orelse return false;
        const c = &b.clusters.items[id];
        c.end = @intCast(b.clusters.items.len - 1);
        b.open = c.parent;
        return true;
    }

    /// The latest subgraph written with this id.
    pub fn clusterNamed(b: *const Builder, raw_id: []const u8) ?ClusterId {
        return b.cluster_ids.get(raw_id);
    }

    pub fn setDirection(b: *Builder, direction: sg.Direction) void {
        if (b.open) |c| b.clusters.items[c].direction = direction;
    }

    /// The node a subgraph endpoint stands for, read against the nodes and edges so far. A source
    /// is the last member with no edge to another member, a target the first member with no edge
    /// from another member; failing that, the last (source) or first (target) member. Null when
    /// the subgraph holds no node yet.
    pub fn representative(b: *const Builder, cluster: ClusterId, role: Role) ?NodeId {
        const depth = b.clusters.items[cluster].depth;
        var fallback: ?NodeId = null;
        switch (role) {
            .source => {
                var i = b.nodes.items.len;
                while (i > 0) {
                    i -= 1;
                    if (!b.inside(i, cluster)) continue;
                    if (fallback == null) fallback = @intCast(i);
                    if (b.links.items[i][0] < depth) return @intCast(i);
                }
            },
            .target => for (0..b.nodes.items.len) |i| {
                if (!b.inside(i, cluster)) continue;
                if (fallback == null) fallback = @intCast(i);
                if (b.links.items[i][1] < depth) return @intCast(i);
            },
        }
        return fallback;
    }

    /// Whether the node is in `cluster` or a subgraph nested anywhere below it. Subgraphs are
    /// numbered as they open, so the ones below a subgraph are the numbers just after it.
    fn inside(b: *const Builder, node_index: usize, cluster: ClusterId) bool {
        const holder = b.nodes.items[node_index].cluster orelse return false;
        const last = b.clusters.items[cluster].end orelse b.clusters.items.len - 1;
        return cluster <= holder and holder <= last;
    }

    /// Depth of the smallest subgraph holding both nodes; 0 when there is none.
    fn commonDepth(b: *const Builder, a: NodeId, other: NodeId) u32 {
        var x = b.nodes.items[a].cluster orelse return 0;
        var y = b.nodes.items[other].cluster orelse return 0;
        while (x != y) {
            const cx = b.clusters.items[x];
            const cy = b.clusters.items[y];
            if (cx.depth >= cy.depth) {
                x = cx.parent orelse return 0;
            } else {
                y = cy.parent orelse return 0;
            }
        }
        return b.clusters.items[x].depth;
    }

    /// Starts a line that may be undone.
    pub fn begin(b: *Builder) Mark {
        b.undo.clearRetainingCapacity();
        return .{ .nodes = b.nodes.items.len, .edges = b.edges.items.len };
    }

    /// Drops the nodes and edges added since `begin`. A node that existed before keeps the shape
    /// and label the line gave it.
    pub fn rollback(b: *Builder, mark: Mark) void {
        while (b.undo.pop()) |u| b.links.items[u.node][u.side] = u.old;
        while (b.nodes.items.len > mark.nodes) {
            const n = b.nodes.pop().?;
            _ = b.links.pop();
            _ = b.node_ids.remove(n.raw_id);
            if (n.cluster) |c| _ = b.clusters.items[c].members.pop();
        }
        b.edges.shrinkRetainingCapacity(mark.edges);
    }

    /// The finished graph: subgraphs that hold no node, directly or below, are dropped and the
    /// rest renumbered.
    pub fn finish(b: *Builder) error{OutOfMemory}!Built {
        const n = b.clusters.items.len;
        const keep = try b.a.alloc(bool, n);
        var i = n;
        while (i > 0) {
            i -= 1;
            const c = b.clusters.items[i];
            keep[i] = c.members.items.len > 0;
            for (c.subs.items) |s| keep[i] = keep[i] or keep[s];
        }
        const renumber = try b.a.alloc(ClusterId, n);
        var kept: ClusterId = 0;
        for (keep, renumber) |k, *r| {
            r.* = kept;
            if (k) kept += 1;
        }
        const clusters = try b.a.alloc(sg.Cluster, kept);
        for (b.clusters.items, keep, renumber) |*c, k, id| {
            if (!k) continue;
            var subs: usize = 0;
            for (c.subs.items) |s| {
                if (!keep[s]) continue;
                c.subs.items[subs] = renumber[s];
                subs += 1;
            }
            c.subs.shrinkRetainingCapacity(subs);
            clusters[id] = .{
                .id = id,
                .raw_id = c.raw_id,
                .label = c.label,
                .parent = if (c.parent) |p| renumber[p] else null,
                .members = try c.members.toOwnedSlice(b.a),
                .sub_clusters = try c.subs.toOwnedSlice(b.a),
                .direction = c.direction,
            };
        }
        for (b.nodes.items) |*node_rec| {
            if (node_rec.cluster) |c| node_rec.cluster = renumber[c];
        }
        return .{
            .nodes = try b.nodes.toOwnedSlice(b.a),
            .edges = try b.edges.toOwnedSlice(b.a),
            .clusters = clusters,
        };
    }
};

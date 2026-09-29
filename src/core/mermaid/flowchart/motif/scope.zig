const std = @import("std");
const sg = @import("../sem_graph.zig");

pub const Vert = union(enum) {
    node: sg.NodeId,
    cluster: sg.ClusterId,
};

pub const Scope = struct {
    verts: []const Vert,
    edges: []const [2]u32,
};

pub fn build(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    parent: ?sg.ClusterId,
) error{OutOfMemory}!Scope {
    var verts: std.ArrayListUnmanaged(Vert) = .empty;

    // guarded-by: scope.zig "vertex order: direct members then child clusters, both in graph order"
    for (graph.nodes) |n| {
        if (eqOpt(n.cluster, parent)) try verts.append(a, .{ .node = n.id });
    }
    for (graph.clusters) |c| {
        if (eqOpt(c.parent, parent)) try verts.append(a, .{ .cluster = c.id });
    }

    var edges: std.ArrayListUnmanaged([2]u32) = .empty;
    for (graph.edges) |e| {
        const rf = repOf(graph, verts.items, parent, e.from) orelse continue;
        const rt = repOf(graph, verts.items, parent, e.to) orelse continue;
        if (rf == rt) continue;
        if (!hasEdge(edges.items, rf, rt)) try edges.append(a, .{ rf, rt });
    }

    return .{
        .verts = try verts.toOwnedSlice(a),
        .edges = try edges.toOwnedSlice(a),
    };
}

pub fn eqOpt(x: ?u32, y: ?u32) bool {
    if (x == null and y == null) return true;
    if (x == null or y == null) return false;
    return x.? == y.?;
}

fn hasEdge(edges: []const [2]u32, f: u32, t: u32) bool {
    for (edges) |e| {
        if (e[0] == f and e[1] == t) return true;
    }
    return false;
}

fn repOf(
    graph: sg.SemGraph,
    verts: []const Vert,
    parent: ?sg.ClusterId,
    id: sg.NodeId,
) ?u32 {
    const nc = clusterOf(graph, id);
    if (eqOpt(nc, parent)) return vertOfNode(verts, id);
    var cur: sg.ClusterId = nc orelse return null;
    while (true) {
        const c = clusterById(graph, cur) orelse return null;
        if (eqOpt(c.parent, parent)) return vertOfCluster(verts, cur);
        cur = c.parent orelse return null;
    }
}

pub fn clusterOf(graph: sg.SemGraph, id: sg.NodeId) ?sg.ClusterId {
    for (graph.nodes) |n| {
        if (n.id == id) return n.cluster;
    }
    return null;
}

fn clusterById(graph: sg.SemGraph, cid: sg.ClusterId) ?sg.Cluster {
    for (graph.clusters) |c| {
        if (c.id == cid) return c;
    }
    return null;
}

fn vertOfNode(verts: []const Vert, id: sg.NodeId) ?u32 {
    for (verts, 0..) |v, i| {
        switch (v) {
            .node => |nid| if (nid == id) return @intCast(i),
            .cluster => {},
        }
    }
    return null;
}

fn vertOfCluster(verts: []const Vert, cid: sg.ClusterId) ?u32 {
    for (verts, 0..) |v, i| {
        switch (v) {
            .cluster => |c| if (c == cid) return @intCast(i),
            .node => {},
        }
    }
    return null;
}

test "vertex order: direct members then child clusters, both in graph order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "M1", .label = "M1", .shape = .rect, .classes = &.{}, .cluster = 7 },
        .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 3, .raw_id = "M2", .label = "M2", .shape = .rect, .classes = &.{}, .cluster = 7 },
        .{ .id = 4, .raw_id = "N1", .label = "N1", .shape = .rect, .classes = &.{}, .cluster = 3 },
    };
    const m3 = [_]sg.NodeId{4};
    const m7 = [_]sg.NodeId{ 1, 3 };
    const clusters = [_]sg.Cluster{
        .{ .id = 3, .raw_id = "c3", .label = "C3", .parent = 7, .members = &m3, .sub_clusters = &.{} },
        .{ .id = 99, .raw_id = "c99", .label = "C99", .parent = null, .members = &.{}, .sub_clusters = &.{} },
        .{ .id = 7, .raw_id = "c7", .label = "C7", .parent = null, .members = &m7, .sub_clusters = &[_]sg.ClusterId{3} },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &.{}, .clusters = &clusters, .classes = &.{}, .arena = null };

    const top = try build(a, g, null);
    try std.testing.expectEqual(@as(usize, 4), top.verts.len);
    try std.testing.expectEqual(@as(sg.NodeId, 0), top.verts[0].node);
    try std.testing.expectEqual(@as(sg.NodeId, 2), top.verts[1].node);
    try std.testing.expectEqual(@as(sg.ClusterId, 99), top.verts[2].cluster);
    try std.testing.expectEqual(@as(sg.ClusterId, 7), top.verts[3].cluster);

    const inner = try build(a, g, 7);
    try std.testing.expectEqual(@as(usize, 3), inner.verts.len);
    try std.testing.expectEqual(@as(sg.NodeId, 1), inner.verts[0].node);
    try std.testing.expectEqual(@as(sg.NodeId, 3), inner.verts[1].node);
    try std.testing.expectEqual(@as(sg.ClusterId, 3), inner.verts[2].cluster);
}

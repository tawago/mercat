const std = @import("std");
const sg = @import("../sem_graph.zig");
const pack = @import("pack.zig");
const types = @import("types.zig");
const motif = @import("../motif.zig");

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
    const packed_g = (try pack.transform(a, g, tree)) orelse return error.ExpectedPack;

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
    try std.testing.expectEqual(@as(?sg.SemGraph, null), try pack.transform(a, g, tree));
}

test "no parallel motif: transform declines (null)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
    try std.testing.expectEqual(@as(?sg.SemGraph, null), try pack.transform(a, g, tree));
}

test "parallel branch straddling two clusters: transform skips it (defensive)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

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
        .children = &.{},
        .branches = &branches,
    }};
    const tree: types.MotifTree = .{ .motifs = &motifs, .roots = &[_]usize{0} };

    try std.testing.expectEqual(@as(?sg.SemGraph, null), try pack.transform(a, g, tree));
}

test "parallel nested in a real cluster: parent wiring correct (microservices shape)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes = parallelNodes();
    for (nodes[1..]) |*n| n.cluster = 7;
    const edges = parallelEdges();
    const members = [_]sg.NodeId{ 1, 2, 3, 4 };
    const clusters = [_]sg.Cluster{
        .{ .id = 7, .raw_id = "M", .label = "M", .parent = null, .members = &members, .sub_clusters = &.{} },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &clusters, .classes = &.{}, .arena = null };

    const tree = try motif.decompose(a, g);
    const packed_g = (try pack.transform(a, g, tree)) orelse return error.ExpectedPack;

    try std.testing.expectEqual(@as(usize, 3), packed_g.clusters.len);
    const m = packed_g.clusters[0];
    try std.testing.expect(!m.synthetic);
    try std.testing.expectEqual(@as(usize, 0), m.members.len);
    try std.testing.expectEqual(@as(usize, 2), m.sub_clusters.len);
    for (packed_g.clusters[1..]) |c| {
        try std.testing.expect(c.synthetic);
        try std.testing.expectEqual(@as(?sg.ClusterId, 7), c.parent);
        try std.testing.expectEqual(@as(usize, 2), c.members.len);
    }
}

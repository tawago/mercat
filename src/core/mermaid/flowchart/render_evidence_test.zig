const std = @import("std");
const ledger = @import("base/ledger.zig");
const rail_star = @import("base/rail_star.zig");
const sg = @import("sem_graph.zig");
const sketch = @import("sketch.zig");
const coords = @import("layout.zig");
const permits_mod = @import("ledger/permits.zig");
const raster = @import("raster.zig");
const painter = @import("paint.zig");
const select = @import("select.zig");

const testing = std.testing;

fn node(id: u32, name: []const u8, cluster: ?u32) sg.Node {
    return .{ .id = id, .raw_id = name, .label = name, .shape = .rect, .classes = &.{}, .cluster = cluster };
}

fn edge(id: u32, from: u32, to: u32) sg.Edge {
    return styledEdge(id, from, to, .solid, .none, .filled, null);
}

fn styledEdge(id: u32, from: u32, to: u32, kind: sg.EdgeKind, from_arrow: sg.ArrowEnd, to_arrow: sg.ArrowEnd, label: ?[]const u8) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = kind, .arrow_from = from_arrow, .arrow_to = to_arrow, .label = label };
}

fn graph(direction: sg.Direction, nodes: []const sg.Node, edges: []const sg.Edge, clusters: []const sg.Cluster) sg.SemGraph {
    return .{ .direction = direction, .nodes = nodes, .edges = edges, .clusters = clusters, .classes = &.{}, .arena = null };
}

fn productionLayout(a: std.mem.Allocator, g: sg.SemGraph) !sketch.Sketch {
    const built = try permits_mod.build(a, g, .joined);
    return coords.layout(a, g, .{ .bundle_permits = &built.plan });
}

fn declaredGeometry(s: sketch.Sketch) usize {
    var n = s.edges.len;
    for (s.rails) |rail| n += rail.taps.len;
    return n;
}

fn expectTerminalEvidence(a: std.mem.Allocator, g: sg.SemGraph, s: sketch.Sketch, arrows: usize) !void {
    const report = try raster.rasterize(a, s, .bridge);
    try testing.expectEqual(g.edges.len, declaredGeometry(s));
    try testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
    try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    const output = try painter.paint(a, report.lattice, 200);
    try testing.expectEqual(arrows, std.mem.count(u8, output, "▼"));
}

test "port plan: two and three identical arrows survive raster and paint" {
    inline for (.{ 2, 3 }) |n| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nodes = [_]sg.Node{ node(0, "S", null), node(1, "A", null) };
        var edges: [n]sg.Edge = undefined;
        for (&edges, 0..) |*item, i| item.* = edge(@intCast(i), 0, 1);
        const g = graph(.TD, &nodes, &edges, &.{});
        const s = try productionLayout(a, g);
        try expectTerminalEvidence(a, g, s, n);
    }
}

test "port plan: a labelled duplicate plus a distinct leaf survives raster and paint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "S", null), node(1, "A", null), node(2, "B", null) };
    var edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 1), edge(2, 0, 2) };
    edges[0].label = "dup";
    edges[1].label = "dup";
    const g = graph(.TD, &nodes, &edges, &.{});
    const s = try productionLayout(a, g);
    try expectTerminalEvidence(a, g, s, 3);
}

test "port plan: a rail-excluded duplicate leaf survives raster and paint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "S", null), node(1, "A", null), node(2, "B", null) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 1), edge(2, 0, 2) };
    const g = graph(.TD, &nodes, &edges, &.{});
    const s = try productionLayout(a, g);
    try expectTerminalEvidence(a, g, s, 3);
}

test "fan provenance: the claim record changes no painted byte" {
    const nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null), node(3, "C", null) };
    const edges = [_]sg.Edge{ edge(10, 0, 1), edge(11, 0, 2), edge(12, 0, 3) };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try coords.layout(a, graph(.TD, &nodes, &edges, &.{}), .{});
    try testing.expectEqual(@as(usize, 1), s.rail_claims.len);

    const with_report = try raster.rasterize(a, s, .bridge);
    const with_bytes = try painter.paint(a, with_report.lattice, s.budget.max_width);
    var without = s;
    without.rail_claims = &.{};
    const without_report = try raster.rasterize(a, without, .bridge);
    const without_bytes = try painter.paint(a, without_report.lattice, without.budget.max_width);
    try testing.expectEqualStrings(with_bytes, without_bytes);
}

test "fan provenance: a labeled fan-in into a cluster drops no label" {
    const clustered_nodes = [_]sg.Node{ node(0, "A", null), node(1, "B", null), node(2, "T", 7) };
    const clustered_edges = [_]sg.Edge{
        styledEdge(20, 0, 2, .solid, .none, .filled, "left"),
        styledEdge(21, 1, 2, .solid, .none, .filled, "right"),
    };
    const clusters = [_]sg.Cluster{.{ .id = 7, .raw_id = "G", .label = "G", .parent = null, .members = &.{2}, .sub_clusters = &.{} }};
    var peer_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer peer_arena.deinit();
    const peer = try coords.layout(peer_arena.allocator(), graph(.TD, &clustered_nodes, &clustered_edges, &clusters), .{});
    try testing.expectEqual(@as(usize, 1), peer.rail_claims.len);
    const report = try raster.rasterize(peer_arena.allocator(), peer, .bridge);
    try testing.expectEqual(@as(u32, 0), report.labels_dropped);
}

test "fan provenance: a duplicate leaf drops no label on flat and clustered peer paths" {
    const plain_nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null) };
    const edges = [_]sg.Edge{
        styledEdge(10, 0, 1, .solid, .none, .filled, null),
        styledEdge(11, 0, 1, .solid, .none, .circle, "private"),
        styledEdge(12, 0, 2, .solid, .none, .filled, null),
    };
    const cluster = [_]sg.Cluster{.{ .id = 7, .raw_id = "G", .label = "G", .parent = null, .members = &.{2}, .sub_clusters = &.{} }};
    const clustered_nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", 7) };

    inline for (.{ graph(.TD, &plain_nodes, &edges, &.{}), graph(.TD, &clustered_nodes, &edges, &cluster) }) |g| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const s = try coords.layout(arena.allocator(), g, .{});
        try testing.expectEqual(@as(usize, 1), s.rail_claims.len);
        const report = try raster.rasterize(arena.allocator(), s, .bridge);
        try testing.expectEqual(@as(u32, 0), report.labels_dropped);
    }
}

test "fan provenance: plan selection preserves the winning claims" {
    const nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2) };
    const groups = [_]ledger.CandidateBundle{.{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 0, 1 } }};
    const memberships = [_]ledger.BundleMembership{
        .{ .edge = 0, .source_group = 0, .target_group = null },
        .{ .edge = 1, .source_group = 0, .target_group = null },
    };
    const permits: ledger.BundlePermits = .{ .policy = .joined, .groups = &groups, .memberships = &memberships };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const winner = try select.choose(arena.allocator(), graph(.TD, &nodes, &edges, &.{}), &permits, 120, .bridge);

    try testing.expectEqual(@as(usize, 1), winner.sketch.rail_claims.len);
    try testing.expectEqual(@as(rail_star.RailClaimId, 1), winner.sketch.rail_claims[0].id);
    try testing.expect(rail_star.check(winner.sketch.rail_claims[0]).isValid());
}

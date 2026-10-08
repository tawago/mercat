const std = @import("std");
const sg = @import("sem_graph.zig");
const sketch = @import("sketch.zig");
const coords = @import("layout.zig");
const permits_mod = @import("ledger/permits.zig");
const raster = @import("raster.zig");
const painter = @import("paint.zig");

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

test "port plan: two and three identical arrows, and a duplicate (labelled or not) beside a distinct leaf, survive raster and paint" {
    const Case = struct { dups: usize, leaf: bool = false, label: ?[]const u8 = null };
    for ([_]Case{ .{ .dups = 2 }, .{ .dups = 3 }, .{ .dups = 2, .leaf = true, .label = "dup" }, .{ .dups = 2, .leaf = true } }) |c| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nodes = [_]sg.Node{ node(0, "S", null), node(1, "A", null), node(2, "B", null) };
        var edges: [4]sg.Edge = undefined;
        for (edges[0..c.dups], 0..) |*item, i| {
            item.* = edge(@intCast(i), 0, 1);
            item.label = c.label;
        }
        if (c.leaf) edges[c.dups] = edge(@intCast(c.dups), 0, 2);
        const n = c.dups + @intFromBool(c.leaf);
        const g = graph(.TD, nodes[0 .. 2 + @as(usize, @intFromBool(c.leaf))], edges[0..n], &.{});
        const s = try productionLayout(a, g);
        try expectTerminalEvidence(a, g, s, n);
    }
}

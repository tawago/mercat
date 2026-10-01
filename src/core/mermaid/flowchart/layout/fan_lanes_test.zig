const std = @import("std");
const testing = std.testing;
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const fan = @import("fan.zig");
const fan_lanes = @import("fan_lanes.zig");
const pb = @import("../base/ledger.zig");
const gap_rows = @import("gap_rows.zig");
const port_plan = @import("port_plan.zig");
const NodeGeom = @import("node_geom.zig").NodeGeom;

pub const Geom = struct { x: i32, w: u32, y: i32 = 0, h: u32 = 1 };

pub fn buildPiece(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const Geom,
    fans: []const fan.Fan,
    bundles: pb.RealizedBundles,
    plan: port_plan.Plan,
    bases: []const u32,
    supers: []const gap_rows.Super,
    departures: []const sg.NodeId,
) !gap_rows.Ledger {
    const placed = try a.alloc(NodeGeom, geom.len);
    for (geom, placed) |g, *out| out.* = .{ .x = g.x, .y = g.y, .w = g.w, .h = g.h, .layer = 0 };
    for (lg.layers, 0..) |row, layer| for (row) |idx| {
        placed[idx].layer = @intCast(layer);
    };
    var indexed = lg;
    indexed.real_index = .empty;
    for (lg.nodes, 0..) |node, idx| switch (node) {
        .real => |id| try indexed.real_index.put(a, id, @intCast(idx)),
        .virtual => {},
    };
    return gap_rows.buildPiece(a, graph, indexed, placed, fans, bundles, plan, bases, supers, departures);
}

pub fn mkLg(
    nodes: []sugiyama.LayerNode,
    layers: [][]u32,
    edges: []sugiyama.LayerEdge,
    reversed: []sg.EdgeId,
) sugiyama.LayeredGraph {
    return .{
        .nodes = nodes,
        .layers = layers,
        .edges = edges,
        .reversed_edges = reversed,
        .real_index = .empty,
        .arena = null,
    };
}

pub fn mkGraph(a: std.mem.Allocator, ledges: []const sugiyama.LayerEdge) !sg.SemGraph {
    const es = try a.alloc(sg.Edge, ledges.len);
    for (ledges, es) |le, *e| e.* = .{
        .id = le.edge,
        .from = le.from,
        .to = le.to,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
    };
    return .{ .direction = .TD, .nodes = &.{}, .edges = es, .clusters = &.{}, .classes = &.{}, .arena = null };
}

pub fn laneOfPivot(fans: []const fan.Fan, dir: fan.Direction, pivot: u32) u32 {
    for (fans) |f| {
        if (f.direction == dir and f.pivot_idx == pivot) return f.lane;
    }
    @panic("fan not found");
}

test "incomplete overlapping fans get separate lanes" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 },
        .{ .real = 3 }, .{ .real = 4 }, .{ .real = 5 },
    };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 100 },
        .{ .from = 0, .to = 4, .reversed = false, .edge = 101 },
        .{ .from = 1, .to = 4, .reversed = false, .edge = 200 },
        .{ .from = 2, .to = 4, .reversed = false, .edge = 201 },
        .{ .from = 2, .to = 5, .reversed = false, .edge = 202 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);

    const geom = [_]Geom{
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 },
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 },
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});

    const lane_a = laneOfPivot(fans, .out, 0);
    const lane_c = laneOfPivot(fans, .out, 2);
    try testing.expect(lane_a != lane_c);
    try testing.expectEqual(@as(u32, 0), laneOfPivot(fans, .in, 4));

    const ledger = try buildPiece(aa, graph, lg, &geom, fans, .{}, .{}, &.{2}, &.{}, &.{});
    try testing.expectEqual(@as(u32, 2), ledger.gaps[0].rows_used);
    try testing.expectEqual(@as(u32, 2), ledger.extraRows(0));
    try testing.expectEqual(@as(?i32, null), ledger.rowOfFan(4, .in));
}

test "lane-separated rails take distinct ledger rows and the gap reserves exactly those" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 },
        .{ .real = 3 }, .{ .real = 4 }, .{ .real = 5 },
    };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 100 },
        .{ .from = 0, .to = 4, .reversed = false, .edge = 101 },
        .{ .from = 1, .to = 4, .reversed = false, .edge = 200 },
        .{ .from = 2, .to = 4, .reversed = false, .edge = 201 },
        .{ .from = 2, .to = 5, .reversed = false, .edge = 202 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 },
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
    const ledger = try buildPiece(aa, graph, lg, &geom, fans, .{}, .{}, &.{2}, &.{}, &.{});
    const row_a = ledger.rowOfFan(0, .out) orelse return error.MissingRail;
    const row_c = ledger.rowOfFan(2, .out) orelse return error.MissingRail;
    try testing.expect(row_a != row_c);
    try testing.expectEqual(@as(u32, 2), ledger.gaps[0].rows_used);
    try testing.expectEqual(@as(u32, 2), ledger.extraRows(0));
}

pub fn mkBareGraph(a: std.mem.Allocator, ledges: []const sugiyama.LayerEdge, extra: []const sg.Edge) !sg.SemGraph {
    const es = try a.alloc(sg.Edge, ledges.len + extra.len);
    for (ledges, es[0..ledges.len]) |le, *e| e.* = .{
        .id = le.edge,
        .from = le.from,
        .to = le.to,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
    };
    @memcpy(es[ledges.len..], extra);
    return .{ .direction = .TD, .nodes = &.{}, .edges = es, .clusters = &.{}, .classes = &.{}, .arena = null };
}

fn peerLanes(fans: []const fan.Fan, dir: fan.Direction, pivot: u32, out: []u32) void {
    for (fans) |f| {
        if (f.direction != dir or f.pivot_idx != pivot) continue;
        for (f.peers, 0..) |p, i| out[i] = p.lane;
    }
}

test "a clustered undirected fan with no declared leaf pairs unfuses onto separate lanes" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 },
        .{ .real = 3 },
    };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{3};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 10 },
        .{ .from = 1, .to = 3, .reversed = false, .edge = 11 },
        .{ .from = 2, .to = 3, .reversed = false, .edge = 12 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 }, .{ .x = 9, .w = 3 },
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        const graph = try mkBareGraph(aa, &edges, &.{});
        const fans = try fan.detect(aa, graph, lg);
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
        var lanes = [_]u32{ 0, 0, 0 };
        peerLanes(fans, .in, 3, &lanes);
        try testing.expect(lanes[0] != lanes[1]);
        try testing.expect(lanes[1] != lanes[2]);
        try testing.expect(lanes[0] != lanes[2]);
    }

    {
        const clique = [_]sg.Edge{
            .{ .id = 20, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null },
            .{ .id = 21, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null },
            .{ .id = 22, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null },
        };
        const graph = try mkBareGraph(aa, &edges, &clique);
        const fans = try fan.detect(aa, graph, lg);
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
        var lanes = [_]u32{ 9, 9, 9 };
        peerLanes(fans, .in, 3, &lanes);
        for (lanes) |l| try testing.expectEqual(@as(u32, 0), l);
    }
}

test "a clustered DIRECTED fan is untouched by the closure licence" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 } };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{3};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 10 },
        .{ .from = 1, .to = 3, .reversed = false, .edge = 11 },
        .{ .from = 2, .to = 3, .reversed = false, .edge = 12 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 }, .{ .x = 9, .w = 3 },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
    var lanes = [_]u32{ 9, 9, 9 };
    peerLanes(fans, .in, 3, &lanes);
    for (lanes) |l| try testing.expectEqual(@as(u32, 0), l);
}

test "a fan of placement proxies for directed crossings is untouched by the closure licence" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 } };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{3};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 10 },
        .{ .from = 1, .to = 3, .reversed = false, .edge = 11 },
        .{ .from = 2, .to = 3, .reversed = false, .edge = 12 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 }, .{ .x = 9, .w = 3 },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const graph = try mkBareGraph(aa, &edges, &.{});
    for (@constCast(graph.edges)) |*e| e.stands_for = .forward_one_way;

    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
    var lanes = [_]u32{ 9, 9, 9 };
    peerLanes(fans, .in, 3, &lanes);
    for (lanes) |l| try testing.expectEqual(@as(u32, 0), l);
}

test "a salvaged fan's excluded members never land on the kept rail's lane" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 } };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{3};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 10 },
        .{ .from = 1, .to = 3, .reversed = false, .edge = 11 },
        .{ .from = 2, .to = 3, .reversed = false, .edge = 12 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 }, .{ .x = 9, .w = 3 } };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);

    var rail = [_]u32{ 10, 11 };
    const selected = [_]sg.EdgeId{ 10, 11 };
    _ = selected;
    const bundles: @import("../base/ledger.zig").RealizedBundles = .{
        .selected_bundles = &.{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &rail }},
        .memberships = &.{
            .{ .edge = 10, .source = null, .target = .{ .selected = 0 } },
            .{ .edge = 11, .source = null, .target = .{ .selected = 0 } },
            .{ .edge = 12, .source = null, .target = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } } },
        },
    };
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, bundles);
    var lanes = [_]u32{ 9, 9, 9 };
    peerLanes(fans, .in, 3, &lanes);
    try testing.expectEqual(@as(u32, 0), lanes[0]);
    try testing.expectEqual(@as(u32, 0), lanes[1]);
    try testing.expect(lanes[2] != 0);
}

test "a gap whose departures all defer lane-separates the arrival rails that draw its rails" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 },
        .{ .real = 3 }, .{ .real = 4 },
    };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{ 3, 4 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 0 },
        .{ .from = 0, .to = 4, .reversed = false, .edge = 1 },
        .{ .from = 1, .to = 3, .reversed = false, .edge = 2 },
        .{ .from = 1, .to = 4, .reversed = false, .edge = 3 },
        .{ .from = 2, .to = 4, .reversed = false, .edge = 4 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 18, .w = 3 },
        .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 },
    };

    var x_members = [_]pb.EdgeId{ 0, 2 };
    var y_members = [_]pb.EdgeId{ 1, 3, 4 };
    var selected = [_]pb.SelectedBundle{
        .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &x_members },
        .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &y_members },
    };
    var memberships: [5]pb.RealizedEdgeMembership = undefined;
    for (&memberships, 0..) |*m, i| m.* = .{
        .edge = @intCast(i),
        .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .not_selected } },
        .target = .{ .selected = if (i == 0 or i == 2) 0 else 1 },
    };
    const bundles: pb.RealizedBundles = .{ .selected_bundles = &selected, .memberships = &memberships };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, bundles);
    try testing.expect(laneOfPivot(fans, .in, 3) != 0);
    try testing.expect(laneOfPivot(fans, .in, 3) != laneOfPivot(fans, .in, 4));
}

test "two clustered rails implying one declared leaf pair both refuse" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 },
        .{ .real = 2 }, .{ .real = 3 },
    };
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 } };
    const declared_pair = [_]sg.Edge{
        .{ .id = 20, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null },
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    {
        var edges = [_]sugiyama.LayerEdge{
            .{ .from = 0, .to = 2, .reversed = false, .edge = 10 },
            .{ .from = 1, .to = 2, .reversed = false, .edge = 11 },
            .{ .from = 0, .to = 3, .reversed = false, .edge = 12 },
            .{ .from = 1, .to = 3, .reversed = false, .edge = 13 },
        };
        var reversed = [_]sg.EdgeId{};
        const lg = mkLg(&nodes, &layers, &edges, &reversed);
        const graph = try mkBareGraph(aa, &edges, &declared_pair);
        const fans = try fan.detect(aa, graph, lg);
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});

        var z_lanes = [_]u32{ 0, 0 };
        peerLanes(fans, .in, 2, &z_lanes);
        var w_lanes = [_]u32{ 0, 0 };
        peerLanes(fans, .in, 3, &w_lanes);
        try testing.expect(z_lanes[0] != z_lanes[1]);
        try testing.expect(w_lanes[0] != w_lanes[1]);
    }

    {
        var edges = [_]sugiyama.LayerEdge{
            .{ .from = 0, .to = 2, .reversed = false, .edge = 10 },
            .{ .from = 1, .to = 2, .reversed = false, .edge = 11 },
        };
        var reversed = [_]sg.EdgeId{};
        const lg = mkLg(&nodes, &layers, &edges, &reversed);
        const graph = try mkBareGraph(aa, &edges, &declared_pair);
        const fans = try fan.detect(aa, graph, lg);
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});

        var z_lanes = [_]u32{ 9, 9 };
        peerLanes(fans, .in, 2, &z_lanes);
        for (z_lanes) |l| try testing.expectEqual(@as(u32, 0), l);
    }
}

fn twoByTwo() struct { nodes: [4]sugiyama.LayerNode, edges: [4]sugiyama.LayerEdge } {
    return .{
        .nodes = .{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 } },
        .edges = .{
            .{ .from = 0, .to = 2, .reversed = false, .edge = 0 },
            .{ .from = 0, .to = 3, .reversed = false, .edge = 1 },
            .{ .from = 1, .to = 2, .reversed = false, .edge = 2 },
            .{ .from = 1, .to = 3, .reversed = false, .edge = 3 },
        },
    };
}

test "an arrow-free group whose declared set is complete still separates" {
    const a = testing.allocator;
    var fixture = twoByTwo();
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 } };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkBareGraph(aa, &fixture.edges, &.{});
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
    try testing.expect(laneOfPivot(fans, .out, 0) != laneOfPivot(fans, .out, 1));
}

test "a directed group whose declared set is complete keeps one shared row" {
    const a = testing.allocator;
    var fixture = twoByTwo();
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 } };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &fixture.edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
    for (fans) |f| try testing.expectEqual(@as(u32, 0), f.lane);
}

test "a directed group whose declared set is short of complete still separates" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 },
        .{ .real = 2 }, .{ .real = 3 },
        .{ .real = 4 },
    };
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3, 4 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 2, .reversed = false, .edge = 0 },
        .{ .from = 0, .to = 3, .reversed = false, .edge = 1 },
        .{ .from = 0, .to = 4, .reversed = false, .edge = 2 },
        .{ .from = 1, .to = 2, .reversed = false, .edge = 3 },
        .{ .from = 1, .to = 3, .reversed = false, .edge = 4 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 },  .{ .x = 20, .w = 3 },
        .{ .x = 10, .w = 3 }, .{ .x = 20, .w = 3 },
        .{ .x = 40, .w = 3 },
    };

    var x_members = [_]pb.EdgeId{3};
    var y_members = [_]pb.EdgeId{4};
    var selected = [_]pb.SelectedBundle{
        .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &x_members },
        .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &y_members },
    };
    var memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .not_selected } }, .target = null },
        .{ .edge = 1, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .not_selected } }, .target = null },
        .{ .edge = 2, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .not_selected } }, .target = null },
        .{ .edge = 3, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .not_selected } }, .target = .{ .selected = 0 } },
        .{ .edge = 4, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .not_selected } }, .target = .{ .selected = 1 } },
    };
    const bundles: pb.RealizedBundles = .{ .selected_bundles = &selected, .memberships = &memberships };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, bundles);
    try testing.expect(laneOfPivot(fans, .out, 0) != laneOfPivot(fans, .out, 1));
}

fn fiveOfSix() struct { nodes: [5]sugiyama.LayerNode, edges: [5]sugiyama.LayerEdge } {
    return .{
        .nodes = .{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 }, .{ .real = 4 } },
        .edges = .{
            .{ .from = 0, .to = 3, .reversed = false, .edge = 0 },
            .{ .from = 0, .to = 4, .reversed = false, .edge = 1 },
            .{ .from = 1, .to = 3, .reversed = false, .edge = 2 },
            .{ .from = 1, .to = 4, .reversed = false, .edge = 3 },
            .{ .from = 2, .to = 3, .reversed = false, .edge = 4 },
        },
    };
}

fn runFiveOfSix(cx_c: i32, bundles: pb.RealizedBundles) !bool {
    const a = testing.allocator;
    var fixture = fiveOfSix();
    var row0 = [_]u32{ 0, 2, 1 };
    var row1 = [_]u32{ 3, 4 };
    var layers = [_][]u32{ &row0, &row1 };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 },  .{ .x = 40, .w = 3 }, .{ .x = cx_c - 1, .w = 3 },
        .{ .x = 20, .w = 3 }, .{ .x = 40, .w = 3 },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &fixture.edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, bundles);
    return laneOfPivot(fans, .out, 0) != laneOfPivot(fans, .out, 1);
}

test "a peer on its pivot's own column never shrinks a group into looking complete" {
    try testing.expect(try runFiveOfSix(21, .{}));
    try testing.expect(try runFiveOfSix(31, .{}));
}

test "a discharged edge never shrinks a group into looking complete" {
    var co = [_]pb.EdgeId{4};
    try testing.expect(try runFiveOfSix(31, .{ .discharged = &co }));
}

test "a two-sided group whose heads are direction-invariant still separates" {
    const a = testing.allocator;
    for ([_][2]sg.ArrowEnd{
        .{ .circle, .circle },
        .{ .cross, .cross },
    }) |heads| {
        var fixture = twoByTwo();
        var row0 = [_]u32{ 0, 1 };
        var row1 = [_]u32{ 2, 3 };
        var layers = [_][]u32{ &row0, &row1 };
        var reversed = [_]sg.EdgeId{};
        const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
        const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 20, .w = 3 }, .{ .x = 10, .w = 3 }, .{ .x = 30, .w = 3 } };
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const es = try aa.alloc(sg.Edge, fixture.edges.len);
        for (fixture.edges, es) |le, *e| e.* = .{
            .id = le.edge,
            .from = le.from,
            .to = le.to,
            .kind = .solid,
            .arrow_from = heads[0],
            .arrow_to = heads[1],
            .label = null,
        };
        const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = es, .clusters = &.{}, .classes = &.{}, .arena = null };
        const fans = try fan.detect(aa, graph, lg);
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
        try testing.expect(laneOfPivot(fans, .out, 0) != laneOfPivot(fans, .out, 1));
    }
}

test "a two-sided group of double-headed members loses the star licence outright" {
    const a = testing.allocator;
    var fixture = twoByTwo();
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 20, .w = 3 }, .{ .x = 10, .w = 3 }, .{ .x = 30, .w = 3 } };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const es = try aa.alloc(sg.Edge, fixture.edges.len);
    for (fixture.edges, es) |le, *e| e.* = .{
        .id = le.edge,
        .from = le.from,
        .to = le.to,
        .kind = .solid,
        .arrow_from = .open,
        .arrow_to = .open,
        .label = null,
    };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = es, .clusters = &.{}, .classes = &.{}, .arena = null };
    const fans = try fan.detect(aa, graph, lg);
    for (fans) |f| {
        for (f.peers) |p| try testing.expect(!p.shared);
    }
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{});
}

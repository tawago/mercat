//! Tests for fan_lanes.zig (incomplete-bipartite lane separation). Discovered
//! via fan_lanes.zig's `test { _ = @import }`.

const std = @import("std");
const testing = std.testing;
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const fan = @import("fan.zig");
const fan_lanes = @import("fan_lanes.zig");
const pb = @import("../base/ledger.zig");
const gap_rows = @import("gap_rows.zig");

/// Minimal geometry element: `assignLanes` only reads centre columns (x + w/2).
pub const Geom = struct { x: i32, w: u32, y: i32 = 0, h: u32 = 1 };

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

/// Build a minimal SemGraph whose `edges` mirror the layer edges (all solid);
/// `assignLanes` only reads edge id + kind.
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
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);

    const lane_a = laneOfPivot(fans, .out, 0);
    const lane_c = laneOfPivot(fans, .out, 2);
    try testing.expect(lane_a != lane_c);
    try testing.expectEqual(@as(u32, 0), laneOfPivot(fans, .in, 4));

    // The two separated rails conflict, so the row ledger stacks them and
    // the gap reserves exactly those two rows; the fan-IN's members are
    // drawn by the rails and claim nothing of their own.
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, fans, .{}, .{}, &.{2}, &.{}, &.{});
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
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, fans, .{}, .{}, &.{2}, &.{}, &.{});
    const row_a = ledger.rowOfFan(0, .out) orelse return error.MissingRail;
    const row_c = ledger.rowOfFan(2, .out) orelse return error.MissingRail;
    try testing.expect(row_a != row_c);
    try testing.expectEqual(@as(u32, 2), ledger.gaps[0].rows_used);
    for (ledger.gaps) |g| try testing.expectEqual(g.rows_used -| g.free, ledger.extraRows(0));
}

/// Like `mkGraph` but every edge is fully arrow-free (`A --- B`) — the shape
/// the shared-rail closure licence judges. `extra` appends declarations that are
/// NOT layer edges (the leaf-pair backers).
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
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
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
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
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
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
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
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
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
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, bundles, null);
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
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, bundles, null);
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
        var report: pb.ClosureCounts = .{};
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, &report);

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
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);

        var z_lanes = [_]u32{ 9, 9 };
        peerLanes(fans, .in, 2, &z_lanes);
        for (z_lanes) |l| try testing.expectEqual(@as(u32, 0), l);
    }
}

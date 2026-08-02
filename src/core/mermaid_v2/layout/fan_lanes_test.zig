//! Tests for fan_lanes.zig (incomplete-bipartite lane separation). Discovered
//! via fan_lanes.zig's `test { _ = @import }`.

const std = @import("std");
const testing = std.testing;
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const fan = @import("fan.zig");
const fan_lanes = @import("fan_lanes.zig");
const pb = @import("../base/ledger.zig");

/// Minimal geometry element: `assignLanes` only reads centre columns (x + w/2).
const Geom = struct { x: i32, w: u32 };

fn mkLg(
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
fn mkGraph(a: std.mem.Allocator, ledges: []const sugiyama.LayerEdge) !sg.SemGraph {
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

fn laneOfPivot(fans: []const fan.Fan, dir: fan.Direction, pivot: u32) u32 {
    for (fans) |f| {
        if (f.direction == dir and f.pivot_idx == pivot) return f.lane;
    }
    @panic("fan not found");
}

test "incomplete overlapping fans get separate lanes" {
    // A->X, A->Y, B->Y, C->Y, C->Z. Two fan-OUTs (A: X,Y and C: Y,Z) whose
    // rails abut at Y's column; their union {A,C}×{X,Y,Z} declares 4 of 6
    // possible pairs → INCOMPLETE → the two trunks must land on distinct lanes.
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, // A B C (layer 0)
        .{ .real = 3 }, .{ .real = 4 }, .{ .real = 5 }, // X Y Z (layer 1)
    };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 100 }, // A->X
        .{ .from = 0, .to = 4, .reversed = false, .edge = 101 }, // A->Y
        .{ .from = 1, .to = 4, .reversed = false, .edge = 200 }, // B->Y
        .{ .from = 2, .to = 4, .reversed = false, .edge = 201 }, // C->Y
        .{ .from = 2, .to = 5, .reversed = false, .edge = 202 }, // C->Z
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);

    // Columns: A/X @ centre 1, B/Y @ centre 10, C/Z @ centre 19.
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

    const lane_a = laneOfPivot(fans, .out, 0); // fan-OUT A
    const lane_c = laneOfPivot(fans, .out, 2); // fan-OUT C
    try testing.expect(lane_a != lane_c); // distinct rails, no fusion
    try testing.expectEqual(@as(u32, 0), laneOfPivot(fans, .in, 4)); // fan-IN Y draws no rail → lane 0

    // extraRowsPerGap reserves 2 rows for the two-lane gap.
    const extras = try fan.extraRowsPerGap(aa, lg, fans);
    try testing.expectEqual(@as(usize, 1), extras.len);
    try testing.expectEqual(@as(u32, 2), extras[0]);
}

test "lane assignment reserves one extra gap row per lane" {
    // Same graph as above — asserts the reservation contract that
    // fan.extraRowsPerGap honours fan.lane (the guarded-by target for it).
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
    var max_lane: u32 = 0;
    for (fans) |f| max_lane = @max(max_lane, f.lane);
    const extras = try fan.extraRowsPerGap(aa, lg, fans);
    try testing.expectEqual(max_lane + 1, extras[0]);
}

test "complete K3,3 mesh lane-separates its stars instead of fusing one bus" {
    // Three sources fully connected to three targets. Completeness is no
    // licence: one run across all six columns speaks for a pivot none of the
    // nine edges shares, so each star takes a rail row of its own and the gap
    // reserves a row per lane.
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, // S1 S2 S3
        .{ .real = 3 }, .{ .real = 4 }, .{ .real = 5 }, // M1 M2 M3
    };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 1 },
        .{ .from = 0, .to = 4, .reversed = false, .edge = 2 },
        .{ .from = 0, .to = 5, .reversed = false, .edge = 3 },
        .{ .from = 1, .to = 3, .reversed = false, .edge = 4 },
        .{ .from = 1, .to = 4, .reversed = false, .edge = 5 },
        .{ .from = 1, .to = 5, .reversed = false, .edge = 6 },
        .{ .from = 2, .to = 3, .reversed = false, .edge = 7 },
        .{ .from = 2, .to = 4, .reversed = false, .edge = 8 },
        .{ .from = 2, .to = 5, .reversed = false, .edge = 9 },
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
    // The three fan-OUT stars span the same columns, so no two may share a row.
    const lanes3 = [_]u32{ laneOfPivot(fans, .out, 0), laneOfPivot(fans, .out, 1), laneOfPivot(fans, .out, 2) };
    try testing.expect(lanes3[0] != lanes3[1]);
    try testing.expect(lanes3[0] != lanes3[2]);
    try testing.expect(lanes3[1] != lanes3[2]);
    var max_lane: u32 = 0;
    for (fans) |f| max_lane = @max(max_lane, f.lane);
    const extras = try fan.extraRowsPerGap(aa, lg, fans);
    try testing.expectEqual(max_lane + 1, extras[0]);
}

/// Like `mkGraph` but every edge is fully arrow-free (`A --- B`) — the shape
/// the shared-rail closure law judges. `extra` appends declarations that are
/// NOT layer edges (the leaf-pair backers).
fn mkBareGraph(a: std.mem.Allocator, ledges: []const sugiyama.LayerEdge, extra: []const sg.Edge) !sg.SemGraph {
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
    // A---Z, B---Z, C---Z inside a subgraph: no realized plan exists (the
    // clustered render carries the empty envelope), so the closure law runs
    // here or the crossbar silently asserts A—B, A—C and B—C. With the leaf
    // pairs DECLARED the same fan keeps its single shared rail.
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, // A B C (layer 0)
        .{ .real = 3 }, // Z (layer 1)
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

    // Undeclared: every member takes a lane of its own.
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

    // Declared clique A---B, A---C, B---C: the crossbar states only what the
    // graph already does, so the fan keeps ONE shared rail row.
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

test "a clustered DIRECTED fan is untouched by the closure law" {
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
    // mkGraph's edges all carry `arrow_to = .filled` — a directed fan.
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
    var lanes = [_]u32{ 9, 9, 9 };
    peerLanes(fans, .in, 3, &lanes);
    for (lanes) |l| try testing.expectEqual(@as(u32, 0), l);
}

test "a fan of placement proxies for directed crossings is untouched by the closure law" {
    // The outer level of a CLUSTERED render fans through placement edges, which
    // carry no arrowheads of their own (they drive layout and are never
    // painted) but stand for directed crossings. Reading their bare arrow
    // fields made every directed clustered fan unfuse; `stands_for_directed`
    // is what keeps the law inert on them.
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

    // No declared leaf pairs at all — the exact shape that unfuses when the
    // members really are arrow-free (the test above).
    const graph = try mkBareGraph(aa, &edges, &.{});
    for (@constCast(graph.edges)) |*e| e.stands_for_directed = true;

    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
    var lanes = [_]u32{ 9, 9, 9 };
    peerLanes(fans, .in, 3, &lanes);
    for (lanes) |l| try testing.expectEqual(@as(u32, 0), l);
}

test "a salvaged fan's excluded members never land on the kept trunk's lane" {
    // The closure law's salvage shape: a strict subset of the fan keeps the
    // trunk (edges 10 and 11 selected) and the rest unfuses. The excluded
    // member must start ABOVE the trunk's own lane — starting at the fan's
    // lane would put it straight back on the crossbar it was excluded from.
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

    var trunk = [_]u32{ 10, 11 };
    const selected = [_]sg.EdgeId{ 10, 11 };
    _ = selected;
    const joins: @import("../base/ledger.zig").RealizedJoins = .{
        .selected_joins = &.{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &trunk }},
        .memberships = &.{
            .{ .edge = 10, .source = null, .target = .{ .selected = 0 } },
            .{ .edge = 11, .source = null, .target = .{ .selected = 0 } },
            .{ .edge = 12, .source = null, .target = .{ .independent = .{ .permission_group = 0, .reason = .not_selected } } },
        },
    };
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, joins, null);
    var lanes = [_]u32{ 9, 9, 9 };
    peerLanes(fans, .in, 3, &lanes);
    try testing.expectEqual(@as(u32, 0), lanes[0]);
    try testing.expectEqual(@as(u32, 0), lanes[1]);
    try testing.expect(lanes[2] != 0);
}

test "an all-to-all gap lane-separates the arrival trunks that draw its rails" {
    // K2,2: A,B → X,Y. The plan selects the two ARRIVAL trunks (at X and at Y);
    // neither departure is selected, so neither draws a run and both defer
    // their peers. Model those arrivals as the gap's trunks — as the ones
    // actually drawing rails — and the two-sided union puts them on separate
    // rows, which is the star decomposition. Model them as owned by the
    // departures instead and the gap has no trunk at all, so nothing keeps the
    // two crossbars off one shared row.
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 } };
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 2, .reversed = false, .edge = 0 }, // A->X
        .{ .from = 0, .to = 3, .reversed = false, .edge = 1 }, // A->Y
        .{ .from = 1, .to = 2, .reversed = false, .edge = 2 }, // B->X
        .{ .from = 1, .to = 3, .reversed = false, .edge = 3 }, // B->Y
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 } };

    var x_members = [_]pb.EdgeId{ 0, 2 };
    var y_members = [_]pb.EdgeId{ 1, 3 };
    var selected = [_]pb.SelectedJoin{
        .{ .id = 0, .proposal = 0, .permission_group = 0, .members = &x_members },
        .{ .id = 1, .proposal = 1, .permission_group = 1, .members = &y_members },
    };
    var memberships: [4]pb.RealizedEdgeMembership = undefined;
    for (&memberships, 0..) |*m, i| m.* = .{
        .edge = @intCast(i),
        .source = .{ .independent = .{ .permission_group = 2, .reason = .overlap_conflict } },
        .target = .{ .selected = if (i % 2 == 0) 0 else 1 },
    };
    const joins: pb.RealizedJoins = .{ .selected_joins = &selected, .memberships = &memberships };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, joins, null);
    try testing.expect(laneOfPivot(fans, .in, 2) != laneOfPivot(fans, .in, 3));
}

test "two clustered rails implying one declared leaf pair both refuse" {
    // A---Z, B---Z, A---W, B---W with A---B declared, inside a subgraph (no
    // realized plan). Each crossbar asserts only A—B, which the graph does
    // declare — truthfully, one rail at a time. Together they stack over the
    // SAME two leaf columns, so a reader walks Z up A's column, along one
    // crossbar, down to W: a Z—W relation nothing declares. A pair is
    // spendable once, so the second claimant makes it nobody's and BOTH
    // unfuse. One rail alone over the same declaration keeps its trunk.
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, // A B (layer 0)
        .{ .real = 2 }, .{ .real = 3 }, // Z W (layer 1)
    };
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    // Columns: A/Z @ centre 1, B/W @ centre 10.
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 } };
    const declared_pair = [_]sg.Edge{
        .{ .id = 20, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null },
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // Two rails over the one declaration: both refuse.
    {
        var edges = [_]sugiyama.LayerEdge{
            .{ .from = 0, .to = 2, .reversed = false, .edge = 10 }, // A---Z
            .{ .from = 1, .to = 2, .reversed = false, .edge = 11 }, // B---Z
            .{ .from = 0, .to = 3, .reversed = false, .edge = 12 }, // A---W
            .{ .from = 1, .to = 3, .reversed = false, .edge = 13 }, // B---W
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

    // ONE rail over the same declaration: nothing competes for the pair, so
    // the trunk stays fused (the over-refusal boundary).
    {
        var edges = [_]sugiyama.LayerEdge{
            .{ .from = 0, .to = 2, .reversed = false, .edge = 10 }, // A---Z
            .{ .from = 1, .to = 2, .reversed = false, .edge = 11 }, // B---Z
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

//! Tests for fan_lanes.zig (incomplete-bipartite lane separation). Discovered
//! via fan_lanes.zig's `test { _ = @import }`.

const std = @import("std");
const testing = std.testing;
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const fan = @import("fan.zig");
const fan_lanes = @import("fan_lanes.zig");

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

test "complete K3,3 mesh keeps every fan on lane 0" {
    // Three sources fully connected to three targets: N×M == D == 9, a truthful
    // all-to-all. Every fan must stay on the shared row (lane 0), byte-identical.
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
    for (fans) |f| try testing.expectEqual(@as(u32, 0), f.lane);
    const extras = try fan.extraRowsPerGap(aa, lg, fans);
    try testing.expectEqual(@as(u32, 1), extras[0]);
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

const std = @import("std");
const testing = std.testing;
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const gap_rows = @import("gap_rows.zig");
const flt = @import("fan_lanes_test.zig");

const Geom = flt.Geom;
const Claim = gap_rows.Claim;

fn claim(gap: u32, lo: i32, hi: i32, kind: gap_rows.Kind) Claim {
    return .{ .gap = gap, .lo = lo, .hi = hi, .kind = kind };
}

fn rowOf(ledger: gap_rows.Ledger, lo: i32) i32 {
    for (ledger.claims) |c| if (c.lo == lo) return c.row;
    @panic("claim not found");
}

const pack_mod = @import("gap_rows_pack.zig");
const grid = @import("gap_rows_grid.zig");

test "a route past a box stacked under its source claims its entry in the sub-gap above that box" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 } };
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{2};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{.{ .from = 0, .to = 2, .reversed = false, .edge = 0 }};
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 20, .w = 21, .y = 0, .h = 3 }, .{ .x = 25, .w = 11, .y = 6, .h = 3 }, .{ .x = 0, .w = 11, .y = 0, .h = 3 } };
    const graph = try flt.mkGraph(aa, &edges);
    const bases = [_]u32{2};
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &.{}, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), ledger.sub_gaps.len);
    try testing.expectEqual(@as(u32, 1), ledger.sub_gaps[0].gap);
    try testing.expectEqual(@as(u32, 3), ledger.sub_gaps[0].base);
    const entry = ledger.claimOfEdge(0, .entry).?;
    try testing.expectEqual(@as(u32, 1), entry.gap);
    try testing.expectEqual(@as(i32, -1), entry.row);
    try testing.expectEqual(@as(u32, 0), ledger.laneOfEdge(0, .entry));
    try testing.expectEqual(gap_rows.Kind.corridor_entry, entry.kind);
    try testing.expectEqual(@as(?i32, null), ledger.rowOfEdge(0, .exit));
    try testing.expectEqual(@as(u32, 0), ledger.extraRows(0));
    try testing.expectEqual(@as(u32, 0), ledger.extraRows(1));

    const departures = [_]sg.NodeId{0};
    const with = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &.{}, .{}, .{}, &bases, &.{}, &departures);
    try testing.expectEqual(@as(u32, 1), with.extraRows(0));
    var found = false;
    for (with.claims) |c| if (c.kind == .bridge_return and c.gap == 0) {
        found = true;
    };
    try testing.expect(found);
}

test "an RL piece claims its offset jogs in the gap beside the target" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 } };
    var row0 = [_]u32{1};
    var row1 = [_]u32{0};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{.{ .from = 0, .to = 1, .reversed = false, .edge = 0 }};
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 20, .w = 3 } };
    var graph = try flt.mkGraph(aa, &edges);
    graph.direction = .RL;
    const bases = [_]u32{4};
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &.{}, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(@as(?i32, 0), ledger.rowOfEdge(0, .exit));
    try testing.expectEqual(@as(u32, 1), ledger.gaps[0].rows_used);
    try testing.expectEqual(@as(u32, 0), ledger.extraRows(0));
}

test "a bridge into a drawn stand-in claims the arrival row, into a packing stand-in the base row, and the placement edges are proxies" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 } };
    var row0 = [_]u32{0};
    var row1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .reversed = false, .edge = 0 },
        .{ .from = 0, .to = 2, .reversed = false, .edge = 1 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 20, .w = 5 }, .{ .x = 0, .w = 11 }, .{ .x = 40, .w = 11 } };
    const graph = try flt.mkGraph(aa, &edges);
    const bases = [_]u32{2};
    const supers = [_]gap_rows.Super{ .{ .node = 1, .drawn = true }, .{ .node = 2, .drawn = false } };
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &.{}, .{}, .{}, &bases, &supers, &.{});
    try testing.expectEqual(@as(?i32, -2), ledger.rowOfEdge(0, .exit));
    try testing.expectEqual(@as(?i32, -1), ledger.rowOfEdge(1, .exit));
    try testing.expectEqual(@as(u32, 0), ledger.laneOfEdge(0, .exit));
    try testing.expectEqual(@as(u32, 0), ledger.extraRows(0));
    try testing.expect(ledger.isProxy(0) and ledger.isProxy(1));
    for (ledger.claims) |c| try testing.expect(c.kind == .bridge_jog);
}

test "a sub-gap grows by the rows its packed claims need beyond the grid's" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{ 2, 3 };
    var subs = [_]grid.SubGap{.{ .gap = 1, .layer = 0, .top = 6, .far = 3, .base = 3 }};
    const claims = [_]Claim{ claim(1, 0, 10, .run), claim(1, 5, 20, .corridor_entry) };
    const l = try pack_mod.packSub(a, &claims, &.{}, &bases, &subs);
    try testing.expectEqual(@as(u32, 2), l.gaps[1].rows_used);
    try testing.expectEqual(@as(u32, 1), l.extraRows(1));
    const walls = [_]gap_rows.GapWalls{ .{ .far = 3, .near = 5 }, .{ .far = 3, .near = 6 } };
    const reserved = [_]u32{2};
    const node_of = [_]u32{};
    const records = try l.records(a, &reserved, &walls, &node_of);
    try testing.expectEqual(@as(u32, 4), records[1].reserved);
}

test "a run arriving down a column another run departs from sits nearer the target" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{2};
    var x_stem = [_]i32{51};
    var x_tap = [_]i32{59};
    var y_stem = [_]i32{71};
    var y_tap = [_]i32{51};
    const claims = [_]Claim{
        .{ .gap = 0, .lo = 30, .hi = 59, .kind = .corridor_entry, .end = .entry, .stems = &x_stem, .taps = &x_tap },
        .{ .gap = 0, .lo = 51, .hi = 71, .kind = .fan_out, .stems = &y_stem, .taps = &y_tap },
    };
    const l = try pack_mod.pack(a, &claims, &.{}, &bases);
    try testing.expectEqual(@as(i32, 0), rowOf(l, 51));
    try testing.expectEqual(@as(i32, 1), rowOf(l, 30));
}

test "a skip edge into a plain node joins the bridge band that ends on its port" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .virtual = .{ .edge = 4, .index = 0 } }, .{ .real = 4 },
    };
    var row0 = [_]u32{0};
    var row1 = [_]u32{ 1, 2, 3 };
    var row2 = [_]u32{4};
    var layers = [_][]u32{ &row0, &row1, &row2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .reversed = false, .edge = 0 },
        .{ .from = 0, .to = 2, .reversed = false, .edge = 1 },
        .{ .from = 1, .to = 4, .reversed = false, .edge = 2 },
        .{ .from = 2, .to = 4, .reversed = false, .edge = 3 },
        .{ .from = 0, .to = 3, .reversed = false, .edge = 4 },
        .{ .from = 3, .to = 4, .reversed = false, .edge = 4 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 20, .w = 5 }, .{ .x = 0, .w = 11 }, .{ .x = 30, .w = 11 }, .{ .x = 50, .w = 1 }, .{ .x = 20, .w = 5 } };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var graph_edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 1, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 3, .from = 2, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 4, .from = 0, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = &graph_edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const bases = [_]u32{ 2, 2 };
    const supers = [_]gap_rows.Super{ .{ .node = 1, .drawn = true }, .{ .node = 2, .drawn = true } };
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &.{}, .{}, .{}, &bases, &supers, &.{});
    try testing.expectEqual(@as(?i32, -1), ledger.rowOfEdge(4, .exit));
    try testing.expectEqual(@as(u32, 0), ledger.extraRows(1));
    const exit = ledger.claimOfEdge(4, .exit).?;
    try testing.expect(exit.kind == .corridor_exit and exit.pin == -1);
    const band = ledger.claimOfEdge(2, .exit).?;
    try testing.expect(band.kind == .bridge_jog and band.row == -1);
    try testing.expectEqual(@as(usize, 2), band.edges.len);
    for (ledger.claims) |c| if (c.gap == 1) try testing.expectEqual(@as(i32, -1), c.row);
    try testing.expectEqual(@as(?i32, 0), ledger.rowOfEdge(4, .entry));
}

test "a placement edge that stands for two crossings into a plain node claims the base row across its frame" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 } };
    var row0 = [_]u32{0};
    var row1 = [_]u32{1};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{.{ .from = 0, .to = 1, .reversed = false, .edge = 0 }};
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 16 }, .{ .x = 4, .w = 8 } };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const bases = [_]u32{2};
    const supers = [_]gap_rows.Super{.{ .node = 0, .drawn = true }};
    for ([_]u32{ 1, 2 }) |crossings| {
        var graph_edges = [_]sg.Edge{
            .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null, .stands_for = .forward_one_way, .crossings = crossings },
        };
        const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = &graph_edges, .clusters = &.{}, .classes = &.{}, .arena = null };
        const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &.{}, .{}, .{}, &bases, &supers, &.{});
        try testing.expectEqual(@as(u32, 0), ledger.extraRows(0));
        if (crossings == 1) {
            try testing.expectEqual(@as(?Claim, null), ledger.claimOfEdge(0, .exit));
            try testing.expect(!ledger.gaps[0].base_used);
            continue;
        }
        const band = ledger.claimOfEdge(0, .exit).?;
        try testing.expect(band.kind == .bridge_jog and band.row == -1 and band.height == 1);
        try testing.expectEqual(@as(i32, 0), band.lo);
        try testing.expectEqual(@as(i32, 15), band.hi);
        try testing.expect(ledger.gaps[0].base_used);
    }
}

test "a fan-OUT run whose span holds another fan-OUT's taps sits nearer the source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{2};
    var left_stem = [_]i32{46};
    var left_tap = [_]i32{8};
    var right_stem = [_]i32{52};
    var right_tap = [_]i32{92};
    var dotted_stems = [_]i32{ 50, 50 };
    var dotted_taps = [_]i32{ 28, 70 };
    const claims = [_]Claim{
        .{ .gap = 0, .lo = 8, .hi = 46, .kind = .fan_out, .stems = &left_stem, .taps = &left_tap },
        .{ .gap = 0, .lo = 28, .hi = 70, .kind = .fan_out, .stems = &dotted_stems, .taps = &dotted_taps },
        .{ .gap = 0, .lo = 52, .hi = 92, .kind = .fan_out, .stems = &right_stem, .taps = &right_tap },
    };
    const ledger = try pack_mod.pack(a, &claims, &.{}, &bases);
    try testing.expectEqual(@as(i32, 0), rowOf(ledger, 28));
    try testing.expectEqual(@as(i32, 1), rowOf(ledger, 8));
    try testing.expectEqual(@as(i32, 1), rowOf(ledger, 52));
    try testing.expectEqual(@as(u32, 2), ledger.extraRows(0));
    var outer_stem = [_]i32{50};
    var outer_taps = [_]i32{ 8, 92 };
    var inner_stem = [_]i32{40};
    var inner_taps = [_]i32{ 28, 70 };
    const arrivals = [_]Claim{
        .{ .gap = 0, .lo = 8, .hi = 92, .kind = .fan_in, .stems = &outer_stem, .taps = &outer_taps },
        .{ .gap = 0, .lo = 28, .hi = 70, .kind = .fan_in, .stems = &inner_stem, .taps = &inner_taps },
    };
    const li = try pack_mod.pack(a, &arrivals, &.{}, &bases);
    try testing.expectEqual(@as(i32, 0), rowOf(li, 8));
    try testing.expectEqual(@as(i32, 1), rowOf(li, 28));
}

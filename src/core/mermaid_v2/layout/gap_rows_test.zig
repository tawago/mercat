const std = @import("std");
const testing = std.testing;
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const sugiyama = @import("sugiyama.zig");
const fan = @import("fan.zig");
const gap_rows = @import("gap_rows.zig");
const pack_mod = @import("gap_rows_pack.zig");
const port_plan = @import("port_plan.zig");
const ports = @import("ports.zig");
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

test "spans separated by one blank cell share a row; abutting spans do not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{2};

    const apart = [_]Claim{ claim(0, 7, 13, .fan_in), claim(0, 15, 36, .fan_in) };
    const l1 = try pack_mod.pack(a, &apart, &.{}, &bases);
    try testing.expectEqual(@as(u32, 1), l1.gaps[0].rows_used);
    try testing.expectEqual(rowOf(l1, 7), rowOf(l1, 15));

    const abutting = [_]Claim{ claim(0, 7, 14, .fan_in), claim(0, 15, 36, .fan_in) };
    const l2 = try pack_mod.pack(a, &abutting, &.{}, &bases);
    try testing.expectEqual(@as(u32, 2), l2.gaps[0].rows_used);
    try testing.expect(rowOf(l2, 7) != rowOf(l2, 15));
}

test "an arrival rail stacks nearer the target than the departure rail it conflicts with" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{2};
    const claims = [_]Claim{ claim(0, 0, 20, .fan_out), claim(0, 5, 25, .fan_in) };
    const l = try pack_mod.pack(a, &claims, &.{}, &bases);
    try testing.expectEqual(@as(i32, 0), rowOf(l, 5));
    try testing.expectEqual(@as(i32, 1), rowOf(l, 0));
    try testing.expectEqual(@as(u32, 2), l.extraRows(0));
}

test "a rail whose stem column is a foreign tap's column sits where that tap ends before the junction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{2};
    var x_stem = [_]i32{10};
    var x_taps = [_]i32{ 0, 10 };
    var y_stem = [_]i32{30};
    var y_taps = [_]i32{ 10, 30 };
    const arrivals = [_]Claim{
        .{ .gap = 0, .lo = 0, .hi = 10, .kind = .fan_in, .stems = &x_stem, .taps = &x_taps },
        .{ .gap = 0, .lo = 10, .hi = 30, .kind = .fan_in, .stems = &y_stem, .taps = &y_taps },
    };
    const li = try pack_mod.pack(a, &arrivals, &.{}, &bases);
    try testing.expectEqual(@as(i32, 0), rowOf(li, 0));
    try testing.expectEqual(@as(i32, 1), rowOf(li, 10));
    const departures = [_]Claim{
        .{ .gap = 0, .lo = 0, .hi = 10, .kind = .fan_out, .stems = &x_stem, .taps = &x_taps },
        .{ .gap = 0, .lo = 10, .hi = 30, .kind = .fan_out, .stems = &y_stem, .taps = &y_taps },
    };
    const lo = try pack_mod.pack(a, &departures, &.{}, &bases);
    try testing.expectEqual(@as(i32, 1), rowOf(lo, 0));
    try testing.expectEqual(@as(i32, 0), rowOf(lo, 10));
}

test "a precedence cycle falls back to left-endpoint order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{2};
    var x_stem = [_]i32{0};
    var x_taps = [_]i32{ 0, 20 };
    var y_stem = [_]i32{20};
    var y_taps = [_]i32{ 0, 20 };
    const claims = [_]Claim{
        .{ .gap = 0, .lo = 0, .hi = 20, .kind = .fan_in, .stems = &x_stem, .taps = &x_taps },
        .{ .gap = 0, .lo = 0, .hi = 20, .kind = .fan_in, .stems = &y_stem, .taps = &y_taps },
    };
    const l = try pack_mod.pack(a, &claims, &.{}, &bases);
    try testing.expectEqual(@as(u32, 2), l.gaps[0].rows_used);
}

test "a run with no decorated end keeps the base row only when no claim or post shares a column with it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{2};
    var alone = [_]Claim{claim(0, 0, 10, .run)};
    alone[0].base_ok = true;
    const l1 = try pack_mod.pack(a, &alone, &.{}, &bases);
    try testing.expectEqual(@as(i32, -1), rowOf(l1, 0));
    try testing.expectEqual(@as(u32, 0), l1.extraRows(0));

    const posts = [_]gap_rows.Post{.{ .gap = 0, .x = 5 }};
    const l2 = try pack_mod.pack(a, &alone, &posts, &bases);
    try testing.expectEqual(@as(i32, 0), rowOf(l2, 0));
    try testing.expectEqual(@as(u32, 1), l2.extraRows(0));

    var crowded = [_]Claim{ claim(0, 0, 10, .run), claim(0, 8, 30, .fan_in) };
    crowded[0].base_ok = true;
    const l3 = try pack_mod.pack(a, &crowded, &.{}, &bases);
    try testing.expect(rowOf(l3, 0) >= 0);
}

test "rows the base spacing already holds cost nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{4};
    const claims = [_]Claim{ claim(0, 0, 10, .run), claim(0, 5, 15, .run), claim(0, 8, 20, .run) };
    const l = try pack_mod.pack(a, &claims, &.{}, &bases);
    try testing.expectEqual(@as(u32, 3), l.gaps[0].rows_used);
    try testing.expectEqual(@as(u32, 1), l.extraRows(0));
}

test "fans of one class sharing a column fuse into one claim; other classes stay apart" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bases = [_]u32{2};
    var fused = [_]Claim{ claim(0, 0, 20, .fan_in), claim(0, 0, 20, .fan_in) };
    fused[0].fuse = 0;
    fused[1].fuse = 0;
    const l1 = try pack_mod.pack(a, &fused, &.{}, &bases);
    try testing.expectEqual(@as(usize, 1), l1.claims.len);
    try testing.expectEqual(@as(u32, 1), l1.gaps[0].rows_used);

    var apart = [_]Claim{ claim(0, 0, 20, .fan_in), claim(0, 0, 20, .fan_in) };
    apart[0].fuse = 0;
    apart[1].fuse = 1;
    const l2 = try pack_mod.pack(a, &apart, &.{}, &bases);
    try testing.expectEqual(@as(usize, 2), l2.claims.len);
    try testing.expectEqual(@as(u32, 2), l2.gaps[0].rows_used);
}

fn port(node: sg.NodeId, side: @import("../sketch.zig").Dir4, offset: u32) @import("../sketch.zig").Port {
    return .{ .node = node, .side = side, .offset = offset };
}

test "four disjoint realized rails share one row and the gap is rail, run, head" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 },
        .{ .real = 3 }, .{ .real = 4 }, .{ .real = 5 },
        .{ .real = 6 },
    };
    var row0 = [_]u32{ 0, 1, 2 };
    var row1 = [_]u32{ 3, 4, 5, 6 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .reversed = false, .edge = 0 },
        .{ .from = 0, .to = 4, .reversed = false, .edge = 1 },
        .{ .from = 1, .to = 4, .reversed = false, .edge = 2 },
        .{ .from = 1, .to = 5, .reversed = false, .edge = 3 },
        .{ .from = 2, .to = 5, .reversed = false, .edge = 4 },
        .{ .from = 2, .to = 6, .reversed = false, .edge = 5 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{
        .{ .x = 10, .w = 3 }, .{ .x = 28, .w = 3 }, .{ .x = 46, .w = 3 },
        .{ .x = 1, .w = 3 },  .{ .x = 19, .w = 3 }, .{ .x = 37, .w = 3 },
        .{ .x = 55, .w = 3 },
    };
    var ad_members = [_]pb.EdgeId{ 1, 2 };
    var rs_members = [_]pb.EdgeId{ 3, 4 };
    var selected = [_]pb.SelectedBundle{
        .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &ad_members },
        .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &rs_members },
    };
    const ind: pb.MembershipDisposition = .{ .independent = .{ .candidate_bundle = 9, .reason = .not_selected } };
    var memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = ind, .target = null },
        .{ .edge = 1, .source = ind, .target = .{ .selected = 0 } },
        .{ .edge = 2, .source = ind, .target = .{ .selected = 0 } },
        .{ .edge = 3, .source = ind, .target = .{ .selected = 1 } },
        .{ .edge = 4, .source = ind, .target = .{ .selected = 1 } },
        .{ .edge = 5, .source = ind, .target = null },
    };
    const bundles: pb.RealizedBundles = .{ .selected_bundles = &selected, .memberships = &memberships };
    const plan_edges = [_]port_plan.EdgePorts{
        .{ .edge = 0, .source = port(0, .south, 0), .target = port(3, .north, 1), .source_ordinal = 0, .target_ordinal = 0 },
        .{ .edge = 1, .source = port(0, .south, 2), .target = port(4, .north, 1), .source_ordinal = 1, .target_ordinal = 0 },
        .{ .edge = 2, .source = port(1, .south, 0), .target = port(4, .north, 1), .source_ordinal = 0, .target_ordinal = 0 },
        .{ .edge = 3, .source = port(1, .south, 2), .target = port(5, .north, 1), .source_ordinal = 1, .target_ordinal = 0 },
        .{ .edge = 4, .source = port(2, .south, 0), .target = port(5, .north, 1), .source_ordinal = 0, .target_ordinal = 0 },
        .{ .edge = 5, .source = port(2, .south, 2), .target = port(6, .north, 1), .source_ordinal = 1, .target_ordinal = 0 },
    };
    const plan: port_plan.Plan = .{ .edges = &plan_edges };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try flt.mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    const bases = [_]u32{2};
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, fans, bundles, plan, &bases, &.{}, &.{});

    try testing.expectEqual(@as(usize, 4), ledger.claims.len);
    for (ledger.claims) |c| try testing.expectEqual(@as(i32, 0), c.row);
    try testing.expectEqual(@as(u32, 1), ledger.gaps[0].rows_used);
    try testing.expectEqual(@as(u32, 1), ledger.extraRows(0));
    try testing.expectEqual(@as(?i32, 0), ledger.rowOfFan(4, .in));
    try testing.expectEqual(@as(?i32, 0), ledger.rowOfFan(5, .in));
    try testing.expectEqual(@as(?i32, null), ledger.rowOfFan(0, .out));
    try testing.expectEqual(@as(u32, 1), ledger.laneOfEdge(0, .exit));
    try testing.expectEqual(@as(u32, 1), ledger.laneOfEdge(5, .exit));
}

test "a skip edge claims one row in the gap above its target layer, a plain chain claims none" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 }, .{ .virtual = .{ .edge = 2, .index = 0 } },
    };
    var row0 = [_]u32{ 0, 3 };
    var row1 = [_]u32{ 1, 4 };
    var row2 = [_]u32{2};
    var layers = [_][]u32{ &row0, &row1, &row2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .reversed = false, .edge = 0 },
        .{ .from = 1, .to = 2, .reversed = false, .edge = 1 },
        .{ .from = 3, .to = 4, .reversed = false, .edge = 2 },
        .{ .from = 4, .to = 2, .reversed = false, .edge = 2 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 20, .w = 3 }, .{ .x = 21, .w = 1 } };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var graph_edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 3, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = &graph_edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const bases = [_]u32{ 2, 2 };
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &.{}, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(@as(u32, 0), ledger.extraRows(0));
    try testing.expectEqual(@as(u32, 1), ledger.extraRows(1));
    try testing.expectEqual(@as(?i32, 0), ledger.rowOfEdge(2, .exit));
    try testing.expectEqual(@as(?i32, null), ledger.rowOfEdge(2, .entry));

    var plain_edges = [_]sugiyama.LayerEdge{ edges[0], edges[1] };
    var plain_row0 = [_]u32{0};
    var plain_row1 = [_]u32{1};
    var plain_layers = [_][]u32{ &plain_row0, &plain_row1, &row2 };
    const plain_lg = flt.mkLg(nodes[0..3], &plain_layers, &plain_edges, &reversed);
    const plain_graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = graph_edges[0..2], .clusters = &.{}, .classes = &.{}, .arena = null };
    const plain = try gap_rows.buildPiece(Geom, aa, plain_graph, plain_lg, geom[0..3], &.{}, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(@as(u32, 0), plain.extraRows(0));
    try testing.expectEqual(@as(u32, 0), plain.extraRows(1));
}

test "an offset decorated terminal claims one row; a column-aligned or undecorated one claims none" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 } };
    var row0 = [_]u32{0};
    var row1 = [_]u32{1};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{.{ .from = 0, .to = 1, .reversed = false, .edge = 0 }};
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const bases = [_]u32{2};

    const offset_geom = [_]Geom{ .{ .x = 0, .w = 10 }, .{ .x = 20, .w = 10 } };
    const decorated = try flt.mkGraph(aa, &edges);
    const l1 = try gap_rows.buildPiece(Geom, aa, decorated, lg, &offset_geom, &.{}, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(@as(u32, 1), l1.extraRows(0));
    try testing.expectEqual(@as(u32, 1), l1.laneOfEdge(0, .exit));

    const aligned_geom = [_]Geom{ .{ .x = 0, .w = 10 }, .{ .x = 0, .w = 10 } };
    const l2 = try gap_rows.buildPiece(Geom, aa, decorated, lg, &aligned_geom, &.{}, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(@as(u32, 0), l2.extraRows(0));
    try testing.expectEqual(@as(u32, 0), l2.laneOfEdge(0, .exit));

    var bare = try flt.mkGraph(aa, &edges);
    @constCast(bare.edges)[0].arrow_to = .none;
    const l3 = try gap_rows.buildPiece(Geom, aa, bare, lg, &offset_geom, &.{}, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(@as(u32, 0), l3.extraRows(0));
    try testing.expectEqual(@as(?i32, -1), l3.rowOfEdge(0, .exit));
    _ = &bare;
}

test "a labeled fan claims its rail row and one label band; an unlabeled fan claims one row" {
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
    const geom = [_]Geom{ .{ .x = 10, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 20, .w = 3 } };
    const graph = try flt.mkGraph(aa, &edges);
    const bases = [_]u32{2};
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 0, .peer_idx = 1, .role = .leftmost },
        .{ .edge_id = 1, .peer_idx = 2, .role = .rightmost },
    };
    const unlabeled = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    const lu = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &unlabeled, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(@as(u32, 1), lu.gaps[0].rows_used);

    peers[0].label_width = 3;
    const labeled = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true }};
    const ll = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &labeled, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(fan.LABEL_RUN_EXTRA_ROWS, ll.gaps[0].rows_used);
}

test "a fan-OUT with three labeled members claims the same rows as one with a single labeled member" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 } };
    var row0 = [_]u32{0};
    var row1 = [_]u32{ 1, 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .reversed = false, .edge = 0 },
        .{ .from = 0, .to = 2, .reversed = false, .edge = 1 },
        .{ .from = 0, .to = 3, .reversed = false, .edge = 2 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 10, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 10, .w = 3 }, .{ .x = 20, .w = 3 } };
    const graph = try flt.mkGraph(aa, &edges);
    const bases = [_]u32{2};
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 0, .peer_idx = 1, .role = .leftmost, .label_width = 3 },
        .{ .edge_id = 1, .peer_idx = 2, .role = .center },
        .{ .edge_id = 2, .peer_idx = 3, .role = .rightmost },
    };
    const one = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true }};
    const l_one = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &one, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(fan.LABEL_RUN_EXTRA_ROWS, l_one.gaps[0].rows_used);

    peers[1].label_width = 3;
    peers[2].label_width = 3;
    const three = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true }};
    const l_three = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &three, .{}, .{}, &bases, &.{}, &.{});
    try testing.expectEqual(l_one.gaps[0].rows_used, l_three.gaps[0].rows_used);
}

test "predicted ports give a side face its real length: three back edges on a TD node's east face allocate" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const Tall = struct { x: i32, w: u32, h: u32 };
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 } };
    var row0 = [_]u32{0};
    var row1 = [_]u32{1};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{};
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Tall{ .{ .x = 0, .w = 5, .h = 7 }, .{ .x = 0, .w = 5, .h = 3 } };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    const opposites = [_][]const u8{ "b", "c", "d" };
    var derived: [3]ports.DerivedAttachment = undefined;
    for (&derived, opposites) |*d, opp| d.* = .{
        .node = 0,
        .side = .east,
        .attachment = .{ .key = .{ .opposite = opp, .endpoint_side = .target_entry, .kind = 0, .arrow_from = 0, .arrow_to = 1, .label = null } },
    };
    const plan = try gap_rows.predictPorts(Tall, aa, graph, lg, &geom, &derived, .{}, true, 0);
    try testing.expectEqual(@as(usize, 0), plan.edges.len);
}

test "two unlabeled duplicate arrows claim the detour bands and the gap reaches twice the deeper detour's depth" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 } };
    var row0 = [_]u32{0};
    var row1 = [_]u32{1};
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .reversed = false, .edge = 0 },
        .{ .from = 0, .to = 1, .reversed = false, .edge = 1 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = flt.mkLg(&nodes, &layers, &edges, &reversed);
    const geom = [_]Geom{ .{ .x = 3, .w = 5 }, .{ .x = 3, .w = 5 } };
    const graph = try flt.mkGraph(aa, &edges);
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 0, .peer_idx = 1, .role = .leftmost, .shared = false },
        .{ .edge_id = 1, .peer_idx = 1, .role = .rightmost, .shared = false },
    };
    const fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    const plan_edges = [_]port_plan.EdgePorts{
        .{ .edge = 0, .source = port(0, .south, 1), .target = port(1, .north, 1), .source_ordinal = 0, .target_ordinal = 0, .source_duplicate = true, .target_duplicate = true },
        .{ .edge = 1, .source = port(0, .south, 3), .target = port(1, .north, 3), .source_ordinal = 1, .target_ordinal = 1, .source_duplicate = true, .target_duplicate = true },
    };
    const plan: port_plan.Plan = .{ .edges = &plan_edges };
    const bases = [_]u32{2};
    const ledger = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &fans, .{}, plan, &bases, &.{}, &.{});

    try testing.expectEqual(@as(usize, 2), ledger.claims.len);
    try testing.expectEqual(@as(u32, 4), ledger.gaps[0].rows_used);
    try testing.expectEqual(@as(u32, 4), ledger.extraRows(0));
    for (ledger.claims) |c| {
        try testing.expectEqual(@as(i32, 0), c.lo);
        try testing.expectEqual(@as(i32, 6), c.hi);
        switch (c.kind) {
            .detour_target => {
                try testing.expectEqual(@as(i32, -1), c.row);
                try testing.expectEqual(@as(u32, 2), c.height);
            },
            .detour_source => {
                try testing.expectEqual(@as(i32, 1), c.row);
                try testing.expectEqual(@as(u32, 3), c.height);
            },
            else => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(@as(?i32, null), ledger.rowOfFan(0, .out));
}

test "a discharged edge claims no gap row" {
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
    const geom = [_]Geom{ .{ .x = 10, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 20, .w = 3 } };
    const graph = try flt.mkGraph(aa, &edges);
    const ind: pb.MembershipDisposition = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } };
    const memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = ind, .target = null },
        .{ .edge = 1, .source = ind, .target = null },
    };
    const discharged: pb.RealizedBundles = .{ .memberships = &memberships, .discharged = &.{1} };
    const rows = try gap_rows.buildPiece(Geom, aa, graph, lg, &geom, &.{}, discharged, .{}, &.{2}, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), rows.claims.len);
    for (rows.claims) |c| try testing.expect(std.mem.indexOfScalar(pb.EdgeId, c.edges, 1) == null);
}

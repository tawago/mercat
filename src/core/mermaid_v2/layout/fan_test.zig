//! Tests for fan.zig. Discovered by fan.zig via `test { _ = @import }`.
//! fan_grid.zig-specific tests live in the sibling fan_grid_test.zig, and
//! fan_polyline.zig-specific tests live in fan_polyline_test.zig (both kept
//! under the 500-line mermaid_v2/ cap); imported below so `zig build test`
//! still discovers them.

const std = @import("std");
const prim = @import("prim");
const fan = @import("fan.zig");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const sugiyama = @import("sugiyama.zig");

const testing = std.testing;
const coords = @import("../layout.zig");

fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}
fn mkEdge2(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

fn findById2(nodes: []const sketch.NodePlacement, id: sketch.NodeId) sketch.NodePlacement {
    for (nodes) |n| if (n.id == id) return n;
    @panic("missing node");
}

fn deinitSketch2(s: *sketch.Sketch, allocator: std.mem.Allocator) void {
    _ = s;
    _ = allocator;
}

test "detect distinguishes fan-OUT and fan-IN in the same graph" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
    };
    var row0 = [_]u32{0};
    var row1 = [_]u32{ 1, 2, 3 };
    var row2 = [_]u32{4};
    var layers = [_][]u32{ &row0, &row1, &row2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .reversed = false, .edge = 100 },
        .{ .from = 0, .to = 2, .reversed = false, .edge = 101 },
        .{ .from = 0, .to = 3, .reversed = false, .edge = 102 },
        .{ .from = 1, .to = 4, .reversed = false, .edge = 200 },
        .{ .from = 2, .to = 4, .reversed = false, .edge = 201 },
        .{ .from = 3, .to = 4, .reversed = false, .edge = 202 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &reversed,
        .real_index = .empty,
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const dummy_graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    const fans = try fan.detect(arena.allocator(), dummy_graph, lg);

    try testing.expectEqual(@as(usize, 2), fans.len);
    var saw_out = false;
    var saw_in = false;
    for (fans) |f| {
        if (f.direction == .out and f.pivot_idx == 0) {
            saw_out = true;
            try testing.expectEqual(@as(sg.NodeId, 0), f.pivot);
            try testing.expectEqual(@as(usize, 3), f.peers.len);
        }
        if (f.direction == .in and f.pivot_idx == 4) {
            saw_in = true;
            try testing.expectEqual(@as(sg.NodeId, 4), f.pivot);
            try testing.expectEqual(@as(usize, 3), f.peers.len);
        }
    }
    try testing.expect(saw_out);
    try testing.expect(saw_in);

    try testing.expectEqual(fan.Direction.out, fans[0].direction);
    try testing.expectEqual(fan.Direction.in, fans[1].direction);
}

test "detect excludes a pivot whose next-layer candidates mix real and virtual peers" {
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .virtual = .{ .edge = 300, .index = 0 } },
        .{ .real = 3 },
    };
    var row0 = [_]u32{0};
    var row1 = [_]u32{ 1, 2, 3 };
    var row2 = [_]u32{4};
    var layers = [_][]u32{ &row0, &row1, &row2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .reversed = false, .edge = 100 },
        .{ .from = 0, .to = 2, .reversed = false, .edge = 101 },
        .{ .from = 0, .to = 3, .reversed = false, .edge = 300 },
        .{ .from = 3, .to = 4, .reversed = false, .edge = 300 },
    };
    var reversed = [_]sg.EdgeId{};
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &reversed,
        .real_index = .empty,
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const dummy_graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    const fans = try fan.detect(arena.allocator(), dummy_graph, lg);

    for (fans) |f| {
        try testing.expect(!(f.direction == .out and f.pivot_idx == 0));
    }
}

test "assignRoles handles even-count fan with no center (fan-OUT)" {
    const a = testing.allocator;
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{
        .direction = .out,
        .pivot_idx = 0,
        .source_layer = 0,
        .peers = &peers,
    }};
    const center_x = [_]i32{ 10, 0, 5, 15, 20 };
    fan.assignRoles(&fans, &center_x);
    _ = a;
    try testing.expectEqual(fan.ChildRole.leftmost, fans[0].peers[0].role);
    try testing.expectEqual(fan.ChildRole.middle, fans[0].peers[1].role);
    try testing.expectEqual(fan.ChildRole.middle, fans[0].peers[2].role);
    try testing.expectEqual(fan.ChildRole.rightmost, fans[0].peers[3].role);
}

test "assignRoles handles even-count fan with no center (fan-IN)" {
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{
        .direction = .in,
        .pivot_idx = 0,
        .source_layer = 0,
        .peers = &peers,
    }};
    const center_x = [_]i32{ 10, 0, 5, 15, 20 };
    fan.assignRoles(&fans, &center_x);
    try testing.expectEqual(fan.ChildRole.leftmost, fans[0].peers[0].role);
    try testing.expectEqual(fan.ChildRole.rightmost, fans[0].peers[3].role);
}

test "5-source fan-IN sink recenters onto the exact mean of its sources" {
    const nodes = [_]sg.Node{
        mkNode(0, "S0"), mkNode(1, "S1"), mkNode(2, "S2"), mkNode(3, "S3"), mkNode(4, "S4"), mkNode(5, "F"),
    };
    const edges = [_]sg.Edge{
        mkEdge2(0, 0, 5), mkEdge2(1, 1, 5), mkEdge2(2, 2, 5), mkEdge2(3, 3, 5), mkEdge2(4, 4, 5),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try coords.layout(arena.allocator(), g, .{});
    defer deinitSketch2(&s, arena.allocator());

    var sum_cx: i64 = 0;
    for (0..5) |i| {
        const n = findById2(s.nodes, @intCast(i));
        sum_cx += n.rect.x + @as(i32, @intCast(n.rect.w / 2));
    }
    const mean_cx: i32 = @intCast(@divTrunc(sum_cx, 5));

    const f = findById2(s.nodes, 5);
    const f_cx = f.rect.x + @as(i32, @intCast(f.rect.w / 2));

    try testing.expectEqual(mean_cx, f_cx);
}

test "bundles group a fan's peers by rail lane" {
    const a = testing.allocator;

    var peers_a = [_]fan.FanEdge{
        .{ .edge_id = 10, .peer_idx = 1, .role = .leftmost, .lane = 0 },
        .{ .edge_id = 11, .peer_idx = 2, .role = .middle, .lane = 1 },
        .{ .edge_id = 12, .peer_idx = 3, .role = .middle, .lane = 0 },
        .{ .edge_id = 13, .peer_idx = 4, .role = .rightmost, .lane = 0 },
    };
    var peers_b = [_]fan.FanEdge{
        .{ .edge_id = 20, .peer_idx = 6, .role = .leftmost },
        .{ .edge_id = 21, .peer_idx = 7, .role = .rightmost },
    };
    const fans = [_]fan.Fan{
        .{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers_a },
        .{ .direction = .in, .pivot_idx = 5, .source_layer = 1, .peers = &peers_b },
    };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sets = try fan.coSets(arena.allocator(), &fans);

    try testing.expectEqual(@as(usize, 2), sets.len);
    try testing.expectEqualSlices(u32, &.{ 10, 12, 13 }, sets[0].members);
    try testing.expectEqual(ledger.BundleOrigin.fan_rail, sets[0].origin);
    try testing.expectEqualSlices(u32, &.{ 20, 21 }, sets[1].members);

    try testing.expectEqual(@as(usize, 0), (try fan.coSets(arena.allocator(), &.{})).len);
}

test "bundles partition by the effective lane the ink occupies, not peer.lane alone" {
    const a = testing.allocator;

    var peers = [_]fan.FanEdge{
        .{ .edge_id = 50, .peer_idx = 1, .role = .leftmost, .lane = 0 },
        .{ .edge_id = 51, .peer_idx = 2, .role = .middle, .lane = 1 },
        .{ .edge_id = 52, .peer_idx = 3, .role = .rightmost, .lane = 3 },
    };
    const fans = [_]fan.Fan{
        .{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .lane = 2, .peers = &peers },
    };

    try testing.expectEqual(@as(u32, 2), fan.effectiveLane(fans[0], peers[0].lane));
    try testing.expectEqual(@as(u32, 2), fan.effectiveLane(fans[0], peers[1].lane));
    try testing.expectEqual(@as(u32, 3), fan.effectiveLane(fans[0], peers[2].lane));

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const sets = try fan.coSets(arena.allocator(), &fans);
    try testing.expectEqual(@as(usize, 1), sets.len);
    try testing.expectEqualSlices(u32, &.{ 50, 51 }, sets[0].members);
}

test {
    _ = @import("fan_grid_test.zig");
    _ = @import("fan_polyline_test.zig");
}

test "a labeled fan reserves three extra gap rows; an unlabeled fan reserves one" {
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
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &reversed,
        .real_index = .empty,
        .arena = null,
    };
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 0, .peer_idx = 1, .role = .leftmost },
        .{ .edge_id = 1, .peer_idx = 2, .role = .rightmost },
    };

    const unlabeled = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    const rows_u = try fan.extraRowsPerGap(aa, lg, &unlabeled);
    try testing.expectEqual(@as(u32, 1), rows_u[0]);

    peers[0].label_width = 3;
    const labeled = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true }};
    const rows_l = try fan.extraRowsPerGap(aa, lg, &labeled);
    try testing.expectEqual(@as(u32, 1 + fan.LABEL_RUN_EXTRA_ROWS), rows_l[0]);
}

test "detect marks a fan labeled iff a member edge carries a label" {
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
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &reversed,
        .real_index = .empty,
        .arena = null,
    };

    var sem_edges = [_]sg.Edge{ mkEdge2(0, 0, 1), mkEdge2(1, 0, 2) };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = &sem_edges, .clusters = &.{}, .classes = &.{}, .arena = null };

    const fans_plain = try fan.detect(aa, graph, lg);
    try testing.expectEqual(@as(usize, 1), fans_plain.len);
    try testing.expect(!fans_plain[0].labeled);

    sem_edges[1].label = "yes";
    const fans_lbl = try fan.detect(aa, graph, lg);
    try testing.expectEqual(@as(usize, 1), fans_lbl.len);
    try testing.expect(fans_lbl[0].labeled);
}

test "label reservation gate clears doomed fans and keeps feasible ones" {
    const Geom = struct { x: i32, y: i32, w: u32, h: u32 };

    var peers = [_]fan.FanEdge{
        .{ .edge_id = 0, .peer_idx = 1, .role = .leftmost },
        .{ .edge_id = 1, .peer_idx = 2, .role = .rightmost },
    };
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };

    var short_edges = [_]sg.Edge{ mkEdge2(0, 0, 1), mkEdge2(1, 0, 2) };
    short_edges[0].label = "yes";
    const g_short = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &short_edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    const geom = [_]Geom{
        .{ .x = 4, .y = 0, .w = 5, .h = 3 },
        .{ .x = 0, .y = 6, .w = 5, .h = 3 },
        .{ .x = 9, .y = 6, .w = 5, .h = 3 },
    };

    var fans_ok = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true }};
    fan.gateLabelReservations(Geom, g_short, &fans_ok, &geom, 20, 4);
    try testing.expect(fans_ok[0].labeled);

    var fans_wrap = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true }};
    fan.gateLabelReservations(Geom, g_short, &fans_wrap, &geom, 13, 4);
    try testing.expect(fans_wrap[0].labeled);
    try testing.expectEqual(@as(u32, 3), fans_wrap[0].peers[0].label_width);

    var wide_edges = [_]sg.Edge{ mkEdge2(0, 0, 1), mkEdge2(1, 0, 2) };
    wide_edges[0].label = "averyveryverylonglabel";
    const g_wide = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &wide_edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var fans_wide = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true }};
    fan.gateLabelReservations(Geom, g_wide, &fans_wide, &geom, 20, 4);
    try testing.expect(fans_wide[0].labeled);
    try testing.expectEqual(prim.displayWidth("averyveryverylonglabel"), fans_wide[0].peers[0].label_width);
}

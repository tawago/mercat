const std = @import("std");
const prim = @import("prim");
const fan = @import("fan.zig");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const bundle = @import("../base/bundle.zig");
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

test "detect keeps a long member as a fan-out peer, labeled or not" {
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

    var out: ?fan.Fan = null;
    for (fans) |f| if (f.direction == .out and f.pivot_idx == 0) {
        out = f;
    };
    const f = out orelse return error.MissingFanOut;
    try testing.expectEqual(@as(usize, 3), f.peers.len);
    var long_peers: usize = 0;
    for (f.peers) |p| if (p.long) {
        long_peers += 1;
        try testing.expectEqual(@as(u32, 3), p.peer_idx);
        try testing.expectEqual(@as(sg.EdgeId, 300), p.edge_id);
    };
    try testing.expectEqual(@as(usize, 1), long_peers);

    const g_nodes = [_]sg.Node{ mkNode(0, "P"), mkNode(1, "A"), mkNode(2, "B"), mkNode(3, "D") };
    var g_edges = [_]sg.Edge{ mkEdge2(100, 0, 1), mkEdge2(101, 0, 2), mkEdge2(300, 0, 3) };
    g_edges[2].label = "far";
    const labeled_graph: sg.SemGraph = .{ .direction = .TD, .nodes = &g_nodes, .edges = &g_edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const labeled = try fan.detect(arena.allocator(), labeled_graph, lg);
    var kept: ?fan.Fan = null;
    for (labeled) |lf| if (lf.direction == .out and lf.pivot_idx == 0) {
        kept = lf;
    };
    const kf = kept orelse return error.MissingFanOut;
    try testing.expectEqual(@as(usize, 3), kf.peers.len);
    fan.refreshLabelWidths(labeled_graph, labeled);
    for (kf.peers) |p| if (p.long) try testing.expectEqual(@as(u32, 0), p.label_width);
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
    try testing.expectEqual(bundle.BundleOrigin.fan_rail, sets[0].origin);
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

test "refreshLabelWidths reads each member's label width and flags the fan labeled" {
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
    var fans_short = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true }};
    fan.refreshLabelWidths(g_short, &fans_short);
    try testing.expect(fans_short[0].labeled);
    try testing.expectEqual(@as(u32, 3), fans_short[0].peers[0].label_width);

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
    fan.refreshLabelWidths(g_wide, &fans_wide);
    try testing.expect(fans_wide[0].labeled);
    try testing.expectEqual(prim.displayWidth("averyveryverylonglabel"), fans_wide[0].peers[0].label_width);
}

test "a fan-in tap label crowded by a neighbouring fan's drop unshares" {
    var peers_p = [_]fan.FanEdge{
        .{ .edge_id = 0, .peer_idx = 0, .role = .leftmost, .label_width = 7 },
        .{ .edge_id = 1, .peer_idx = 1, .role = .rightmost },
    };
    var peers_q = [_]fan.FanEdge{
        .{ .edge_id = 2, .peer_idx = 2, .role = .leftmost },
        .{ .edge_id = 3, .peer_idx = 3, .role = .rightmost },
    };
    var fans = [_]fan.Fan{
        .{ .direction = .in, .pivot = 10, .pivot_idx = 4, .source_layer = 0, .peers = &peers_p },
        .{ .direction = .in, .pivot = 11, .pivot_idx = 5, .source_layer = 0, .peers = &peers_q },
    };
    const G = struct { x: i32, w: u32 };
    const geom = [_]G{
        .{ .x = 20, .w = 1 }, .{ .x = 4, .w = 1 },
        .{ .x = 22, .w = 1 }, .{ .x = 40, .w = 1 },
        .{ .x = 12, .w = 1 }, .{ .x = 31, .w = 1 },
    };
    fan.gateFanInSharedLabels(G, &fans, &geom);
    try testing.expect(!peers_p[0].shared);
    try testing.expect(peers_p[1].shared);
    try testing.expect(peers_q[0].shared);
}

//! Tests for fan.zig. Discovered by fan.zig via `test { _ = @import }`.
//! fan_grid.zig-specific tests live in the sibling fan_grid_test.zig, and
//! fan_polyline.zig-specific tests live in fan_polyline_test.zig (both kept
//! under the 500-line mermaid_v2/ cap); imported below so `zig build test`
//! still discovers them.

const std = @import("std");
const fan = @import("fan.zig");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
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

// coords.layout's Sketch is arena-owned with no public deinit reachable
// from here; testing.allocator would flag a leak if we tried to free it
// piecemeal, so (like layout_test.zig) we simply leak within the test's
// own arena, which the test's `defer arena.deinit()` reclaims.
fn deinitSketch2(s: *sketch.Sketch, allocator: std.mem.Allocator) void {
    _ = s;
    _ = allocator;
}

test "detect distinguishes fan-OUT and fan-IN in the same graph" {
    // Graph: A->B, A->C, A->D (fan-out at A) and B->E, C->E, D->E
    // (fan-in at E). All on three layers: [A], [B,C,D], [E].
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // 0: A
        .{ .real = 1 }, // 1: B
        .{ .real = 2 }, // 2: C
        .{ .real = 3 }, // 3: D
        .{ .real = 4 }, // 4: E
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
    const dummy_graph: sg.SemGraph = undefined;
    const fans = try fan.detect(arena.allocator(), dummy_graph, lg);

    try testing.expectEqual(@as(usize, 2), fans.len);
    var saw_out = false;
    var saw_in = false;
    for (fans) |f| {
        if (f.direction == .out and f.pivot_idx == 0) {
            saw_out = true;
            try testing.expectEqual(@as(usize, 3), f.peers.len);
        }
        if (f.direction == .in and f.pivot_idx == 4) {
            saw_in = true;
            try testing.expectEqual(@as(usize, 3), f.peers.len);
        }
    }
    try testing.expect(saw_out);
    try testing.expect(saw_in);

    // detect() runs a fan-OUT pass over every pivot before its fan-IN pass
    // (matches the pre-unification two-slice router behavior) — assert the
    // returned slice actually orders the fan-OUT motif ahead of the fan-IN
    // motif, not just that both are present.
    try testing.expectEqual(fan.Direction.out, fans[0].direction);
    try testing.expectEqual(fan.Direction.in, fans[1].direction);
}

test "detect excludes a pivot whose next-layer candidates mix real and virtual peers" {
    // Graph: A->B, A->C (both real, on layer 1) plus A->E where E lives two
    // layers down, forcing a virtual node V on layer 1 for that edge's span.
    // A now has 2 real + 1 virtual candidate on layer 1: the fan-OUT
    // criterion must abort detection for A entirely, not fan just B/C.
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // 0: A (pivot)
        .{ .real = 1 }, // 1: B
        .{ .real = 2 }, // 2: C
        .{ .virtual = .{ .edge = 300, .index = 0 } }, // 3: V (A->E chain)
        .{ .real = 3 }, // 4: E
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
    const dummy_graph: sg.SemGraph = undefined;
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
    // pivot at x=10; peers at x=0,5,15,20 — none equal pivot.
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

// -- fan-IN 3-pass barycenter convergence (layout.zig buildSketch) -----------

test "5-source fan-IN sink recenters onto the exact mean of its sources" {
    // 5 independent sources -> F. A 2-pass (.down, .up) barycenter sweep
    // does not converge for this shape (see the worked example in
    // buildSketch's comment): F ends up mis-centered relative to its
    // sources. The third .down sweep re-centers F once the sources have
    // settled onto their final, evenly-spaced positions.
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

    // Without the third sweep the worked example shows F landing at the
    // far-left source's position instead of the mean — assert the
    // converged (not mis-centered) result.
    try testing.expectEqual(mean_cx, f_cx);
}

test {
    _ = @import("fan_grid_test.zig");
    _ = @import("fan_polyline_test.zig");
}

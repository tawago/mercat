//! Tests for `layout.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const coords = @import("../layout.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");

const testing = std.testing;

pub fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{
        .id = id,
        .raw_id = raw,
        .label = raw,
        .shape = .rect,
        .classes = &.{},
        .cluster = null,
    };
}

pub fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
    };
}

fn mkGeom(x: i32, w: u32) routing.NodeGeom {
    return .{ .x = x, .y = 0, .w = w, .h = 3, .layer = 0 };
}

fn findById(nodes: []const sketch.NodePlacement, id: sketch.NodeId) sketch.NodePlacement {
    for (nodes) |n| if (n.id == id) return n;
    @panic("missing node");
}

pub fn deinitSketch(s: *sketch.Sketch, allocator: std.mem.Allocator) void {
    _ = s;
    _ = allocator;
}

test "inter-layer gap is 2 rows for TD but 4 columns for LR (same graph, default v_spacing)" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B") };
    const edges = [_]sg.Edge{mkEdge(0, 0, 1)};
    const td_g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    const lr_g = sg.SemGraph{
        .direction = .LR,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var s_td = try coords.layout(arena.allocator(), td_g, .{});
    defer deinitSketch(&s_td, arena.allocator());
    var s_lr = try coords.layout(arena.allocator(), lr_g, .{});
    defer deinitSketch(&s_lr, arena.allocator());

    const a_td = findById(s_td.nodes, 0);
    const b_td = findById(s_td.nodes, 1);
    try testing.expectEqual(@as(i32, 2), b_td.rect.y - a_td.rect.bottom());

    const a_lr = findById(s_lr.nodes, 0);
    const b_lr = findById(s_lr.nodes, 1);
    try testing.expectEqual(@as(i32, 4), b_lr.rect.x - a_lr.rect.right());
}

test "linear chain produces monotone y per layer" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2) };
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
    defer deinitSketch(&s, arena.allocator());

    const a = findById(s.nodes, 0);
    const b = findById(s.nodes, 1);
    const c = findById(s.nodes, 2);
    try testing.expect(a.rect.y < b.rect.y);
    try testing.expect(b.rect.y < c.rect.y);
}

test "diamond converges horizontally" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "B"),
        mkNode(2, "C"),
        mkNode(3, "D"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1),
        mkEdge(1, 0, 2),
        mkEdge(2, 1, 3),
        mkEdge(3, 2, 3),
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
    defer deinitSketch(&s, arena.allocator());

    const a = findById(s.nodes, 0);
    const b = findById(s.nodes, 1);
    const c = findById(s.nodes, 2);
    const d = findById(s.nodes, 3);

    try testing.expectEqual(b.rect.y, c.rect.y);
    try testing.expect(a.rect.y < b.rect.y);
    try testing.expect(d.rect.y > b.rect.y);

    const a_cx = a.rect.x + @as(i32, @intCast(a.rect.w / 2));
    const b_cx = b.rect.x + @as(i32, @intCast(b.rect.w / 2));
    const c_cx = c.rect.x + @as(i32, @intCast(c.rect.w / 2));
    try testing.expect((b_cx <= a_cx and c_cx >= a_cx) or (b_cx >= a_cx and c_cx <= a_cx));
}

test "LR rotates frame" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B") };
    const edges = [_]sg.Edge{mkEdge(0, 0, 1)};
    const g = sg.SemGraph{
        .direction = .LR,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try coords.layout(arena.allocator(), g, .{});
    defer deinitSketch(&s, arena.allocator());

    const a = findById(s.nodes, 0);
    const b = findById(s.nodes, 1);
    try testing.expect(a.rect.x < b.rect.x);
    try testing.expectEqual(a.rect.y, b.rect.y);
}

test "BT mirrors canonical TD layout" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B") };
    const edges = [_]sg.Edge{mkEdge(0, 0, 1)};
    const g = sg.SemGraph{
        .direction = .BT,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try coords.layout(arena.allocator(), g, .{});
    defer deinitSketch(&s, arena.allocator());

    const a = findById(s.nodes, 0);
    const b = findById(s.nodes, 1);
    try testing.expectEqual(sketch.Direction.BT, s.direction);
    try testing.expect(a.rect.y > b.rect.y);
}

test "edges have non-empty polylines" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B") };
    const edges = [_]sg.Edge{mkEdge(0, 0, 1)};
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
    defer deinitSketch(&s, arena.allocator());

    try testing.expectEqual(@as(usize, 1), s.edges.len);
    try testing.expect(s.edges[0].polyline.len >= 2);
}

test "reversed edge swaps arrow direction" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 0) };
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
    defer deinitSketch(&s, arena.allocator());

    try testing.expectEqual(@as(usize, 2), s.edges.len);
    for (s.edges) |e| {
        try testing.expect(e.from == 0 or e.from == 1);
        try testing.expect(e.to == 0 or e.to == 1);
        try testing.expectEqual(sketch.ArrowKind.filled, e.arrow_to);
    }
}

const self_loops = @import("routing_self_loops.zig");

fn slPlacement(id: sg.NodeId, x: i32, y: i32, w: u32, h: u32) sketch.NodePlacement {
    return .{
        .id = id,
        .rect = .{ .x = x, .y = y, .w = w, .h = h },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
}

test "TD self-loop on an unobstructed node keeps the classic over-the-top shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = slPlacement(0, 0, 0, 7, 3);
    const placements = [_]sketch.NodePlacement{node};

    const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
    try testing.expectEqual(sketch.Dir4.east, sl.port_from.side);
    try testing.expectEqual(sketch.Dir4.north, sl.port_to.side);
    const last = sl.polyline[sl.polyline.len - 1];
    try testing.expectEqual(node.rect.y, last.y);
}

test "TD self-loop with a box stacked above loops below and re-enters east" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const above = slPlacement(0, 0, 0, 20, 3);
    const node = slPlacement(1, 0, 4, 20, 3);
    const placements = [_]sketch.NodePlacement{ above, node };

    const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
    try testing.expectEqual(sketch.Dir4.south, sl.port_from.side);
    try testing.expectEqual(sketch.Dir4.east, sl.port_to.side);
    var i: usize = 1;
    while (i < sl.polyline.len) : (i += 1) {
        const p0 = sl.polyline[i - 1];
        const p1 = sl.polyline[i];
        if (p0.x == p1.x) {
            const y0 = @min(p0.y, p1.y);
            const y1 = @max(p0.y, p1.y);
            try testing.expect(!sketch.lineTouchesRect(false, p0.x, y0, y1, above.rect));
        } else {
            const x0 = @min(p0.x, p1.x);
            const x1 = @max(p0.x, p1.x);
            try testing.expect(!sketch.lineTouchesRect(true, p0.y, x0, x1, above.rect));
        }
    }
    const last = sl.polyline[sl.polyline.len - 1];
    const prev = sl.polyline[sl.polyline.len - 2];
    try testing.expectEqual(last.y, prev.y);
    try testing.expectEqual(node.rect.right() - 1, last.x);
}

test "drift compaction fires on natural TD but is suppressed by is_direction_rotated, and never fires for LR" {
    const td_nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "BBBBBBBBBBBBBBBBBBBB"),
        mkNode(2, "C"),
        mkNode(3, "D"),
    };
    const td_edges = [_]sg.Edge{
        mkEdge(0, 0, 1),
        mkEdge(1, 0, 2),
        mkEdge(2, 1, 3),
        mkEdge(3, 2, 3),
    };
    const td_g = sg.SemGraph{
        .direction = .TD,
        .nodes = &td_nodes,
        .edges = &td_edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    {
        var s = try coords.layout(arena.allocator(), td_g, .{});
        defer deinitSketch(&s, arena.allocator());
        const a = findById(s.nodes, 0);
        const b = findById(s.nodes, 1);
        const c = findById(s.nodes, 2);
        const a_cx = a.rect.x + @as(i32, @intCast(a.rect.w / 2));
        const b_cx = b.rect.x + @as(i32, @intCast(b.rect.w / 2));
        const c_cx = c.rect.x + @as(i32, @intCast(c.rect.w / 2));
        const mean_bc = @divTrunc(b_cx + c_cx, 2);
        try testing.expectEqual(mean_bc, a_cx);
    }

    {
        var s = try coords.layout(arena.allocator(), td_g, .{ .is_direction_rotated = true });
        defer deinitSketch(&s, arena.allocator());
        const a = findById(s.nodes, 0);
        const b = findById(s.nodes, 1);
        const c = findById(s.nodes, 2);
        const a_cx = a.rect.x + @as(i32, @intCast(a.rect.w / 2));
        const b_cx = b.rect.x + @as(i32, @intCast(b.rect.w / 2));
        const c_cx = c.rect.x + @as(i32, @intCast(c.rect.w / 2));
        const mean_bc = @divTrunc(b_cx + c_cx, 2);
        try testing.expect(mean_bc != a_cx);
    }

    const lr_nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "B1\nB2\nB3\nB4"),
        mkNode(2, "C"),
        mkNode(3, "D"),
    };
    const lr_edges = td_edges;
    const lr_g = sg.SemGraph{
        .direction = .LR,
        .nodes = &lr_nodes,
        .edges = &lr_edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var s_normal = try coords.layout(arena.allocator(), lr_g, .{});
    defer deinitSketch(&s_normal, arena.allocator());
    var s_flagged = try coords.layout(arena.allocator(), lr_g, .{ .is_direction_rotated = true });
    defer deinitSketch(&s_flagged, arena.allocator());

    for (0..4) |id| {
        const n_id: sketch.NodeId = @intCast(id);
        const normal = findById(s_normal.nodes, n_id);
        const flagged = findById(s_flagged.nodes, n_id);
        try testing.expectEqual(normal.rect, flagged.rect);
    }
    const a = findById(s_normal.nodes, 0);
    const b = findById(s_normal.nodes, 1);
    const c = findById(s_normal.nodes, 2);
    const a_cy = a.rect.y + @as(i32, @intCast(a.rect.h / 2));
    const b_cy = b.rect.y + @as(i32, @intCast(b.rect.h / 2));
    const c_cy = c.rect.y + @as(i32, @intCast(c.rect.h / 2));
    const mean_bc_cy = @divTrunc(b_cy + c_cy, 2);
    try testing.expect(mean_bc_cy != a_cy);
}

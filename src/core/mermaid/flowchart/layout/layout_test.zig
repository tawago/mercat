const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sketch_clearance = @import("../sketch_clearance.zig");
const coords = @import("../layout.zig");
const node_geom = @import("node_geom.zig");

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

fn mkGeom(x: i32, w: u32) node_geom.NodeGeom {
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
    try testing.expectEqual(a_lr.rect.y, b_lr.rect.y);
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

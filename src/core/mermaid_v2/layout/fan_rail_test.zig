//! Tests for `fan_rail.zig`. Discovered via fan_rail.zig's top-level
//! `test { _ = @import("fan_rail_test.zig"); }` block.
//!
//! "rail taps stay in sync..." moved from `fan_test.zig` (which built
//! this fixture but was really exercising fan_rail's `Built.taps`
//! aliasing contract through the full `coords.layout` pipeline); its
//! `mkNode`/`mkEdge2`/`findById2`/`deinitSketch2` helpers are duplicated
//! here (rather than moved) since fan_test.zig's OWN remaining
//! "5-source fan-IN sink recenters..." test still uses them.
//!
//! "fan_rail.blocked rejects..." moved from `routing_test.zig` (which
//! tested `fan_rail.blocked` directly, unlike the rest of that file's
//! `coords.layout`-driven fan-rail-lift tests).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const coords = @import("../layout.zig");
const fan_rail = @import("fan_rail.zig");

const testing = std.testing;

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

test "rail taps stay in sync with their target node's post-shift position" {
    const nodes = [_]sg.Node{ mkNode(0, "P"), mkNode(1, "C1"), mkNode(2, "C2") };
    const edges = [_]sg.Edge{
        mkEdge2(0, 0, 1),
        mkEdge2(1, 0, 2),
        mkEdge2(2, 0, 0),
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

    const p = findById2(s.nodes, 0);
    try testing.expect(p.rect.y > 0);

    try testing.expectEqual(@as(usize, 1), s.rails.len);
    const rail = s.rails[0];
    try testing.expectEqual(@as(usize, 2), rail.taps.len);

    for (rail.taps) |tap| {
        const child = findById2(s.nodes, tap.node);
        const want_x = child.rect.x + @as(i32, @intCast(child.rect.w / 2));
        try testing.expectEqual(want_x, tap.landing.x);
        try testing.expectEqual(child.rect.y, tap.landing.y);
    }
}

test "fan_rail.blocked rejects a built rail whose tap drop touches a foreign node's box" {
    const p = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const q = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 30, .y = 12, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const other = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 60, .y = 12, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const foreign = sketch.NodePlacement{ .id = 3, .rect = .{ .x = 33, .y = 11, .w = 4, .h = 1 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ p, q, other, foreign };

    const e_pq = sg.Edge{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    const e_po = sg.Edge{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };

    var peers = [_]fan_rail.Peer{
        .{ .edge = e_pq, .placement = q },
        .{ .edge = e_po, .placement = other },
    };
    const resolved = fan_rail.Resolved{ .pivot = p, .peers = &peers };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const built = try fan_rail.build(arena.allocator(), resolved, 0, 0);

    try testing.expect(fan_rail.blocked(built, p.id, &placements));

    const clean_placements = [_]sketch.NodePlacement{ p, q, other };
    try testing.expect(!fan_rail.blocked(built, p.id, &clean_placements));
}

fn mkPlace(id: sketch.NodeId, x: i32, y: i32, w: u16, h: u16) sketch.NodePlacement {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = w, .h = h }, .shape = .rect, .lines = &.{}, .cluster_id = null };
}

test "formal base approach: rail lifts one row when the gap admits it, holds at a gap of 2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const pivot = mkPlace(0, 20, 0, 10, 3);
        const q = mkPlace(1, 10, 6, 6, 3);
        const r = mkPlace(2, 30, 6, 6, 3);
        var peers = [_]fan_rail.Peer{
            .{ .edge = mkEdge2(0, 0, 1), .placement = q },
            .{ .edge = mkEdge2(1, 0, 2), .placement = r },
        };
        const resolved = fan_rail.Resolved{ .pivot = pivot, .direction = .out, .peers = &peers };
        const built = try fan_rail.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 3), built.rail.crossbar[0].y);
        for (built.taps) |tap| {
            try testing.expect(built.rail.crossbar[0].y <= tap.landing.y - 3);
        }
        try testing.expect(built.rail.crossbar[0].y > pivot.rect.bottom() - 1);
    }

    {
        const pivot = mkPlace(0, 20, 0, 10, 3);
        const q = mkPlace(1, 10, 5, 6, 3);
        const r = mkPlace(2, 30, 5, 6, 3);
        var peers = [_]fan_rail.Peer{
            .{ .edge = mkEdge2(0, 0, 1), .placement = q },
            .{ .edge = mkEdge2(1, 0, 2), .placement = r },
        };
        const resolved = fan_rail.Resolved{ .pivot = pivot, .direction = .out, .peers = &peers };
        const built = try fan_rail.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 3), built.rail.crossbar[0].y);
        try testing.expect(built.rail.crossbar[0].y > pivot.rect.bottom() - 1);
    }

    {
        const pivot = mkPlace(0, 20, 0, 10, 3);
        const q = mkPlace(1, 10, 4, 6, 3);
        const r = mkPlace(2, 30, 4, 6, 3);
        var peers = [_]fan_rail.Peer{
            .{ .edge = mkEdge2(0, 0, 1), .placement = q },
            .{ .edge = mkEdge2(1, 0, 2), .placement = r },
        };
        const resolved = fan_rail.Resolved{ .pivot = pivot, .direction = .out, .peers = &peers };
        const built = try fan_rail.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 2), built.rail.crossbar[0].y);
    }

    {
        const sink = mkPlace(0, 20, 10, 10, 3);
        const s1 = mkPlace(1, 10, 0, 6, 3);
        const s2 = mkPlace(2, 30, 0, 6, 3);
        var peers = [_]fan_rail.Peer{
            .{ .edge = mkEdge2(0, 1, 0), .placement = s1 },
            .{ .edge = mkEdge2(1, 2, 0), .placement = s2 },
        };
        const resolved = fan_rail.Resolved{ .pivot = sink, .direction = .in, .peers = &peers };
        const built = try fan_rail.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 7), built.rail.crossbar[0].y);
        try testing.expect(built.rail.crossbar[0].y <= sink.rect.y - 3);
        try testing.expect(built.rail.crossbar[0].y < sink.rect.y);
        for (peers) |pr| try testing.expect(built.rail.crossbar[0].y > pr.placement.rect.bottom() - 1);
    }

    {
        const sink = mkPlace(0, 20, 5, 10, 3);
        const s1 = mkPlace(1, 10, 0, 6, 3);
        const s2 = mkPlace(2, 30, 0, 6, 3);
        var peers = [_]fan_rail.Peer{
            .{ .edge = mkEdge2(0, 1, 0), .placement = s1 },
            .{ .edge = mkEdge2(1, 2, 0), .placement = s2 },
        };
        const resolved = fan_rail.Resolved{ .pivot = sink, .direction = .in, .peers = &peers };
        const built = try fan_rail.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 3), built.rail.crossbar[0].y);
        for (peers) |pr| try testing.expect(built.rail.crossbar[0].y > pr.placement.rect.bottom() - 1);
    }
}

test "labeled fan-OUT rail lifts the crossbar for a 4-cell dropper when the gap admits it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lbl_edge_a = mkEdge2(0, 0, 1);
    lbl_edge_a.label = "yes";
    var lbl_edge_b = mkEdge2(1, 0, 2);
    lbl_edge_b.label = "no";

    {
        const pivot = mkPlace(0, 20, 0, 10, 3);
        const q = mkPlace(1, 10, 8, 6, 3);
        const r = mkPlace(2, 30, 8, 6, 3);
        var peers = [_]fan_rail.Peer{
            .{ .edge = lbl_edge_a, .placement = q },
            .{ .edge = lbl_edge_b, .placement = r },
        };
        const resolved = fan_rail.Resolved{ .pivot = pivot, .direction = .out, .peers = &peers };
        const built = try fan_rail.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 3), built.rail.crossbar[0].y);
        for (built.taps) |tap| {
            try testing.expectEqual(@as(i32, 4), tap.landing.y - tap.at.y - 1);
        }
    }

    {
        const pivot = mkPlace(0, 20, 0, 10, 3);
        const q = mkPlace(1, 10, 6, 6, 3);
        const r = mkPlace(2, 30, 6, 6, 3);
        var peers = [_]fan_rail.Peer{
            .{ .edge = lbl_edge_a, .placement = q },
            .{ .edge = lbl_edge_b, .placement = r },
        };
        const resolved = fan_rail.Resolved{ .pivot = pivot, .direction = .out, .peers = &peers };
        const built = try fan_rail.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 3), built.rail.crossbar[0].y);
    }
}

test "a fan whose peers were lifted onto separate lanes builds no rail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ mkNode(0, "Z"), mkNode(1, "A"), mkNode(2, "B") };
    var edges = [_]sg.Edge{ mkEdge2(10, 0, 1), mkEdge2(11, 0, 2) };
    for (&edges) |*e| e.arrow_to = .none;
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 6, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 0, .y = 8, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 12, .y = 8, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const allocated = try @import("port_plan.zig").midpoint(a, graph, &placements);

    var peers = [_]@import("fan.zig").FanEdge{
        .{ .edge_id = 10, .peer_idx = 1, .role = .leftmost },
        .{ .edge_id = 11, .peer_idx = 2, .role = .rightmost },
    };
    const shared: @import("fan.zig").Fan = .{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };
    try testing.expect((try fan_rail.resolve(a, .TD, shared, graph, &placements, .{}, allocated)) != null);

    peers[1].lane = 1;
    try testing.expectEqual(@as(?fan_rail.Resolved, null), try fan_rail.resolve(a, .TD, shared, graph, &placements, .{}, allocated));
}

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const prim = @import("prim");
const fan_rail = @import("fan_rail.zig");
const clusters = @import("clusters.zig");
const coords = @import("../layout.zig");

const testing = std.testing;

fn mkNode(id: sg.NodeId, cluster: ?sg.ClusterId) sg.Node {
    return .{ .id = id, .raw_id = "n", .label = "n", .shape = .rect, .classes = &.{}, .cluster = cluster };
}

fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId, label: ?[]const u8, role: sketch.EdgeRole, poly: []const sketch.Point) sketch.EdgePath {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .polyline = poly,
        .port_from = .{ .node = from, .side = .south, .offset = 0 },
        .port_to = .{ .node = to, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = label,
        .kind = .solid,
        .role = role,
    };
}

test "buildClusters: outer cluster bbox unions the already-expanded inner rect, not the raw inner member bbox" {
    const a = testing.allocator;

    const clusters_arr = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "inner", .label = "", .parent = 1, .members = &[_]sg.NodeId{0}, .sub_clusters = &.{} },
        .{ .id = 1, .raw_id = "outer", .label = "", .parent = null, .members = &.{}, .sub_clusters = &[_]sg.ClusterId{0} },
    };
    const graph = sg.SemGraph{
        .direction = .TD,
        .nodes = &[_]sg.Node{mkNode(0, 0)},
        .edges = &.{},
        .clusters = &clusters_arr,
        .classes = &.{},
        .arena = null,
    };
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 4 }, .shape = .rect, .lines = &.{}, .cluster_id = 0 },
    };

    const out = try clusters.buildClusters(a, graph, &placements, 0);
    defer a.free(out);

    var inner: ?sketch.Rect = null;
    var outer: ?sketch.Rect = null;
    for (out) |cf| {
        if (cf.id == 0) inner = cf.rect;
        if (cf.id == 1) outer = cf.rect;
    }
    try testing.expect(inner != null);
    try testing.expect(outer != null);

    try testing.expectEqual(sketch.Rect{ .x = -4, .y = -2, .w = 18, .h = 8 }, inner.?);

    try testing.expectEqual(sketch.Rect{ .x = -8, .y = -4, .w = 26, .h = 12 }, outer.?);
    try testing.expect(outer.?.x < inner.?.x);
    try testing.expect(outer.?.y < inner.?.y);
    try testing.expect(outer.?.right() > inner.?.right());
    try testing.expect(outer.?.bottom() > inner.?.bottom());
}

test "buildClusters: emitted ClusterFrame order matches input graph.clusters order, not the depth-sorted processing order" {
    const a = testing.allocator;

    const clusters_arr = [_]sg.Cluster{
        .{ .id = 10, .raw_id = "outer", .label = "", .parent = null, .members = &.{}, .sub_clusters = &[_]sg.ClusterId{20} },
        .{ .id = 20, .raw_id = "middle", .label = "", .parent = 10, .members = &.{}, .sub_clusters = &[_]sg.ClusterId{30} },
        .{ .id = 30, .raw_id = "inner", .label = "", .parent = 20, .members = &[_]sg.NodeId{0}, .sub_clusters = &.{} },
    };
    const graph = sg.SemGraph{
        .direction = .TD,
        .nodes = &[_]sg.Node{mkNode(0, 30)},
        .edges = &.{},
        .clusters = &clusters_arr,
        .classes = &.{},
        .arena = null,
    };
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 4 }, .shape = .rect, .lines = &.{}, .cluster_id = 30 },
    };

    const out = try clusters.buildClusters(a, graph, &placements, 0);
    defer a.free(out);

    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(sg.ClusterId, 10), out[0].id);
    try testing.expectEqual(@as(sg.ClusterId, 20), out[1].id);
    try testing.expectEqual(@as(sg.ClusterId, 30), out[2].id);
}

test "computeBbox: a self-loop detour point at the diagram's extreme corner extends the exclusive bbox by exactly +1" {
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var poly = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 10 } };
    var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, null, .forward, &poly)};
    var polylines = [_][]sketch.Point{&poly};
    var clusters_arr = [_]sketch.ClusterFrame{};
    var rails = [_]fan_rail.Built{};

    const bbox = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &rails, false, 200);

    try testing.expectEqual(@as(u32, 21), bbox.w);
    try testing.expectEqual(@as(u32, 11), bbox.h);
}

test "computeBbox: back-edge rail label relocation depends on the diagram's full right extent, not just its own edge" {
    const poly = [_]sketch.Point{ .{ .x = 40, .y = 0 }, .{ .x = 40, .y = 20 } };
    const label = "twelvechars!";
    const lbl_w = prim.displayWidth(label);
    try testing.expectEqual(@as(u32, 12), lbl_w);
    const max_width: u32 = 50;
    try testing.expect(40 + 2 + lbl_w > max_width);
    try testing.expect(40 - 1 - @as(i32, @intCast(lbl_w)) >= 0);

    {
        var placements = [_]sketch.NodePlacement{
            .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        };
        var poly_a = poly;
        var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, label, .back_edge, &poly_a)};
        var polylines = [_][]sketch.Point{&poly_a};
        var clusters_arr = [_]sketch.ClusterFrame{};
        var rails = [_]fan_rail.Built{};

        _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &rails, true, max_width);
        try testing.expect(edges[0].label_left_of_run);
    }

    {
        var placements = [_]sketch.NodePlacement{
            .{ .id = 1, .rect = .{ .x = 0, .y = 5, .w = 80, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        };
        var poly_b = poly;
        var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, label, .back_edge, &poly_b)};
        var polylines = [_][]sketch.Point{&poly_b};
        var clusters_arr = [_]sketch.ClusterFrame{};
        var rails = [_]fan_rail.Built{};

        _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &rails, true, max_width);
        try testing.expect(!edges[0].label_left_of_run);
    }
}

test "computeBbox: back-edge rail lever leaves the label right when the right placement already fits the budget" {
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var poly = [_]sketch.Point{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 20 } };
    var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, "ok", .back_edge, &poly)};
    var polylines = [_][]sketch.Point{&poly};
    var clusters_arr = [_]sketch.ClusterFrame{};
    var rails = [_]fan_rail.Built{};

    _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &rails, true, 200);
    try testing.expect(!edges[0].label_left_of_run);
}

test "computeBbox: rail tap label reservation matches Rail.tapLabelSeg + prim.edgeLabelAnchor" {
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 5, .y = 8, .w = 4, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 10, .rect = .{ .x = 12, .y = 8, .w = 4, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var edges = [_]sketch.EdgePath{};
    var polylines = [_][]sketch.Point{};
    var clusters_arr = [_]sketch.ClusterFrame{};

    var stem = [_]sketch.Point{ .{ .x = 5, .y = 8 }, .{ .x = 5, .y = 3 } };
    var taps = [_]sketch.Tap{
        .{ .edge = 1, .node = 10, .at = .{ .x = 12, .y = 3 }, .landing = .{ .x = 12, .y = 8 }, .label = "tap label" },
    };
    var rails = [_]fan_rail.Built{.{
        .rail = .{
            .pivot = 0,
            .stem = &stem,
            .crossbar = .{ .{ .x = 5, .y = 3 }, .{ .x = 20, .y = 3 } },
            .taps = &taps,
            .kind = .solid,
        },
        .stem = &stem,
        .taps = &taps,
    }};

    const bbox = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &rails, false, 200);

    const rail = rails[0].rail;
    const seg = rail.tapLabelSeg(taps[0]);
    const lbl_w = prim.displayWidth(taps[0].label.?);
    const anchor = prim.edgeLabelAnchor(seg[0].x, seg[0].y, seg[1].x, seg[1].y, lbl_w, .{});

    try testing.expect(bbox.w >= @as(u32, @intCast(anchor.x + @as(i32, @intCast(lbl_w)))));
    try testing.expect(bbox.h >= @as(u32, @intCast(anchor.y + 1)));
}

test "computeBbox: the shift pass updates both the Built.taps view and the aliased Rail.taps slice" {
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = -5, .y = 0, .w = 4, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var edges = [_]sketch.EdgePath{};
    var polylines = [_][]sketch.Point{};
    var clusters_arr = [_]sketch.ClusterFrame{};

    var stem = [_]sketch.Point{ .{ .x = -5, .y = 0 }, .{ .x = -5, .y = -2 } };
    var taps = [_]sketch.Tap{
        .{ .edge = 1, .node = 1, .at = .{ .x = -5, .y = -2 }, .landing = .{ .x = -5, .y = 0 } },
    };
    var rails = [_]fan_rail.Built{.{
        .rail = .{
            .pivot = 0,
            .stem = &stem,
            .crossbar = .{ .{ .x = -5, .y = -2 }, .{ .x = -5, .y = -2 } },
            .taps = &taps,
            .kind = .solid,
        },
        .stem = &stem,
        .taps = &taps,
    }};

    const pre_shift_tap_x = rails[0].rail.taps[0].at.x;
    _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &rails, false, 200);

    try testing.expect(rails[0].rail.taps[0].at.x != pre_shift_tap_x);
    try testing.expectEqual(rails[0].taps[0].at.x, rails[0].rail.taps[0].at.x);
    try testing.expectEqual(rails[0].taps[0].at.y, rails[0].rail.taps[0].at.y);
}

test "computeBbox: label_left_of_run is false exactly at prim.edgeLabelAnchor's default mid_x+2 offset" {
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var poly = [_]sketch.Point{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 20 } };
    var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, "x", .back_edge, &poly)};
    var polylines = [_][]sketch.Point{&poly};
    var clusters_arr = [_]sketch.ClusterFrame{};
    var rails = [_]fan_rail.Built{};

    _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &rails, true, 200);

    const mid_x: i32 = @divTrunc(poly[0].x + poly[1].x, 2);
    const anchor = prim.edgeLabelAnchor(poly[0].x, poly[0].y, poly[1].x, poly[1].y, prim.displayWidth("x"), .{});
    try testing.expectEqual(mid_x + 2, anchor.x);
    try testing.expect(!edges[0].label_left_of_run);
}

fn mkLeverNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

test "the back-edge rail label lever fires for authored TD but not for a rotated TD" {
    const nodes = [_]sg.Node{ mkLeverNode(0, "A"), mkLeverNode(1, "B"), mkLeverNode(2, "C"), mkLeverNode(3, "D") };
    const back_edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 3, .from = 3, .to = 0, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = "loop" },
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &back_edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const s_authored = try coords.layout(arena.allocator(), g, .{ .spacing_scale = 1, .max_width = 12, .is_direction_rotated = false });
    const s_rotated = try coords.layout(arena.allocator(), g, .{ .spacing_scale = 1, .max_width = 12, .is_direction_rotated = true });

    var back_authored: ?sketch.EdgePath = null;
    for (s_authored.edges) |e| {
        if (e.role == .back_edge) back_authored = e;
    }
    var back_rotated: ?sketch.EdgePath = null;
    for (s_rotated.edges) |e| {
        if (e.role == .back_edge) back_rotated = e;
    }

    try testing.expect(back_authored.?.label_left_of_run);
    try testing.expect(!back_rotated.?.label_left_of_run);
    try testing.expect(s_authored.bbox.w < s_rotated.bbox.w);
}

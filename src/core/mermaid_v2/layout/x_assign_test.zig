const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const cx_mod = @import("x_assign.zig");

const testing = std.testing;

fn mkNode3(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

test "centerLayer's fan-IN override centers on the real-source centroid, excluding a reversed back-edge source" {
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 100 },
        .{ .real = 101 },
        .{ .real = 102 },
        .{ .real = 103 },
    };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{3};
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .edge = 5, .reversed = false },
        .{ .from = 1, .to = 3, .edge = 6, .reversed = false },
        .{ .from = 2, .to = 3, .edge = 7, .reversed = true },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    var geom = [_]cx_mod.NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 20, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 100, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
    };
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &geom, lg, 2, .down, true, 0);
    const f_cx = geom[3].x + @as(i32, @intCast(geom[3].w / 2));
    try testing.expectEqual(@as(i32, 15), f_cx);
    try testing.expect(f_cx != 45);
}

test "monotonic packing's min_cursor floor drifts a shared-barycenter run right of its target, and compact=true corrects it" {
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 100 },
        .{ .real = 101 },
        .{ .real = 102 },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 5, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 6, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    const initial = [_]cx_mod.NodeGeom{
        .{ .x = 50, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
    };

    var packed_only = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &packed_only, lg, 2, .down, false, 0);
    const a_cx = packed_only[0].x + @as(i32, @intCast(packed_only[0].w / 2));
    {
        const b_cx = packed_only[1].x + @as(i32, @intCast(packed_only[1].w / 2));
        const c_cx = packed_only[2].x + @as(i32, @intCast(packed_only[2].w / 2));
        const mean_bc = @divTrunc(b_cx + c_cx, 2);
        try testing.expect(mean_bc != a_cx);
    }

    var corrected = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &corrected, lg, 2, .down, true, 0);
    const b_cx2 = corrected[1].x + @as(i32, @intCast(corrected[1].w / 2));
    const c_cx2 = corrected[2].x + @as(i32, @intCast(corrected[2].w / 2));
    const mean_bc2 = @divTrunc(b_cx2 + c_cx2, 2);
    try testing.expectEqual(a_cx, mean_bc2);
}

test "centerLayer skips re-centering a row that is both clustered and a labeled fork" {
    const nodes = [_]sg.Node{
        mkNode3(0, "A"),
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 10 },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = 10 },
    };
    const clusters = [_]sg.Cluster{
        .{ .id = 10, .raw_id = "grp", .label = "grp", .parent = null, .members = &.{ 1, 2 }, .sub_clusters = &.{} },
    };
    const edges = [_]sg.Edge{
        .{ .id = 5, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = "lbl" },
        .{ .id = 6, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = "lbl" },
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };
    var lg_nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 } };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var lg_edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 5, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 6, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &lg_nodes,
        .layers = &layers,
        .edges = &lg_edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    const geom = [_]cx_mod.NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
    };
    var packed_only = geom;
    try cx_mod.centerByBarycenter(testing.allocator, g, &packed_only, lg, 2, .down, false, 0);
    var corrected = geom;
    try cx_mod.centerByBarycenter(testing.allocator, g, &corrected, lg, 2, .down, true, 0);

    try testing.expectEqual(packed_only[1].x, corrected[1].x);
    try testing.expectEqual(packed_only[2].x, corrected[2].x);

    const b_cx = packed_only[1].x + @as(i32, @intCast(packed_only[1].w / 2));
    const c_cx = packed_only[2].x + @as(i32, @intCast(packed_only[2].w / 2));
    const mean_bc = @divTrunc(b_cx + c_cx, 2);
    const a_cx = packed_only[0].x + @as(i32, @intCast(packed_only[0].w / 2));
    try testing.expect(mean_bc != a_cx);
}

test "flushLeftRows' connector-stretch floor stops short of the margin instead of stretching a connector" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
        .{ .real = 3 },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layer2 = [_]u32{3};
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 0, .reversed = false },
        .{ .from = 2, .to = 3, .edge = 1, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    var geom = [_]cx_mod.NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 30, .y = 5, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 50, .y = 5, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 10, .w = 10, .h = 3, .layer = 2 },
    };
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    cx_mod.flushLeftRows(empty_g, &geom, lg);

    try testing.expect(@min(geom[1].x, geom[2].x) > 0);

    try testing.expect(geom[1].x >= 5);
    try testing.expect(geom[2].x >= 25);

    try testing.expectEqual(@as(i32, 5), geom[1].x);
    try testing.expectEqual(@as(i32, 25), geom[2].x);
}

fn bboxOf(geom: []const cx_mod.NodeGeom) i64 {
    var min_x: i32 = std.math.maxInt(i32);
    var max_r: i32 = std.math.minInt(i32);
    for (geom) |g| {
        if (g.x < min_x) min_x = g.x;
        const r = g.x + @as(i32, @intCast(g.w));
        if (r > max_r) max_r = r;
    }
    return @as(i64, max_r) - @as(i64, min_x);
}

test "flushLeftRows never widens the bounding box" {
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };

    {
        var nodes = [_]sugiyama.LayerNode{ .{ .real = 10 }, .{ .real = 11 }, .{ .real = 12 } };
        var layer0 = [_]u32{0};
        var layer1 = [_]u32{ 1, 2 };
        var layers = [_][]u32{ &layer0, &layer1 };
        var edges = [_]sugiyama.LayerEdge{
            .{ .from = 0, .to = 1, .edge = 0, .reversed = false },
            .{ .from = 0, .to = 2, .edge = 1, .reversed = false },
        };
        const lg = sugiyama.LayeredGraph{
            .nodes = &nodes,
            .layers = &layers,
            .edges = &edges,
            .reversed_edges = &.{},
            .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
            .arena = null,
        };
        var geom = [_]cx_mod.NodeGeom{
            .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
            .{ .x = 30, .y = 5, .w = 10, .h = 3, .layer = 1 },
            .{ .x = 45, .y = 5, .w = 10, .h = 3, .layer = 1 },
        };
        const before = bboxOf(&geom);
        cx_mod.flushLeftRows(empty_g, &geom, lg);
        const after = bboxOf(&geom);
        try testing.expect(after <= before);
        try testing.expect(after < before);
    }

    {
        var nodes = [_]sugiyama.LayerNode{ .{ .real = 20 }, .{ .real = 21 } };
        var layer0 = [_]u32{0};
        var layer1 = [_]u32{1};
        var layers = [_][]u32{ &layer0, &layer1 };
        var edges = [_]sugiyama.LayerEdge{
            .{ .from = 0, .to = 1, .edge = 0, .reversed = false },
        };
        const lg = sugiyama.LayeredGraph{
            .nodes = &nodes,
            .layers = &layers,
            .edges = &edges,
            .reversed_edges = &.{},
            .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
            .arena = null,
        };
        var geom = [_]cx_mod.NodeGeom{
            .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
            .{ .x = 50, .y = 5, .w = 10, .h = 3, .layer = 1 },
        };
        const before = bboxOf(&geom);
        cx_mod.flushLeftRows(empty_g, &geom, lg);
        const after = bboxOf(&geom);
        try testing.expectEqual(before, after);
    }
}

test "centerRunOnDesired re-centers using only real nodes, keeping the real node's rail straight" {
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };

    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 100 },
        .{ .virtual = .{ .edge = 5, .index = 0 } },
        .{ .real = 101 },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 5, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 6, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    const initial = [_]cx_mod.NodeGeom{
        .{ .x = 50, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 5, .w = 0, .h = 0, .layer = 1 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
    };

    var packed_only = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &packed_only, lg, 2, .down, false, 0);

    var real = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &real, lg, 2, .down, true, 0);
    const a_cx = real[0].x + @as(i32, @intCast(real[0].w / 2));
    const r_cx = real[2].x + @as(i32, @intCast(real[2].w / 2));
    try testing.expectEqual(a_cx, r_cx);

    const v_actual = packed_only[1].x;
    const r_actual = packed_only[2].x + @as(i32, @intCast(packed_only[2].w / 2));
    const desired = a_cx;
    const mutated_delta = @divTrunc((desired - v_actual) + (desired - r_actual), 2);
    const mutated_r_cx = r_actual + mutated_delta;
    try testing.expect(mutated_r_cx != a_cx);
}

test "centerRunOnDesired's width clamp keeps a recentered row from crossing x=0" {
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };

    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 100 },
        .{ .virtual = .{ .edge = 5, .index = 0 } },
        .{ .real = 101 },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 5, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 6, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    const initial = [_]cx_mod.NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 5, .w = 0, .h = 0, .layer = 1 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
    };

    var packed_only = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &packed_only, lg, 2, .down, false, 0);
    const a_cx = packed_only[0].x + @as(i32, @intCast(packed_only[0].w / 2));
    const r_actual = packed_only[2].x + @as(i32, @intCast(packed_only[2].w / 2));
    const unclamped_delta = a_cx - r_actual;
    const row_min_before = @min(packed_only[1].x, packed_only[2].x);
    try testing.expect(row_min_before + unclamped_delta < 0);

    var real = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &real, lg, 2, .down, true, 0);
    try testing.expect(real[1].x >= 0);
    try testing.expect(real[2].x >= 0);
}

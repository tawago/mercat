const std = @import("std");
const sketch = @import("../sketch.zig");
const bridges = @import("bridges.zig");
const tracks = @import("tracks.zig");

const Crossing = bridges.Crossing;

test "vertical stacked bridge routes straight when x-aligned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 10, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &.{}, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    try std.testing.expectEqual(@as(usize, 2), edges[0].polyline.len);
    try std.testing.expectEqual(@as(i32, 13), edges[0].polyline[0].x);
    try std.testing.expectEqual(@as(i32, 13), edges[0].polyline[1].x);
    try std.testing.expectEqual(sketch.Dir4.south, edges[0].port_from.side);
    try std.testing.expectEqual(sketch.Dir4.north, edges[0].port_to.side);
}

test "vertical bridge jogs when x-misaligned, final segment vertical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 8, .y = 20, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &.{}, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    const poly = edges[0].polyline;
    try std.testing.expectEqual(@as(usize, 4), poly.len);
    try std.testing.expectEqual(@as(i32, 18), poly[1].y);
    try std.testing.expectEqual(@as(i32, 18), poly[2].y);
    try std.testing.expectEqual(poly[poly.len - 2].x, poly[poly.len - 1].x);
    try std.testing.expectEqual(sketch.Dir4.north, edges[0].port_to.side);
}

test "jog landing on a drawn frame border row is displaced outside it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 20, .y = 8, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = 9 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 9, .rect = .{ .x = 20, .y = 8, .w = 6, .h = 3 }, .parent_id = 7, .label = "", .depth = 1, .synthetic = true },
        .{ .id = 7, .rect = .{ .x = 18, .y = 6, .w = 12, .h = 7 }, .parent_id = null, .label = "Real", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    const poly = edges[0].polyline;
    try std.testing.expectEqual(@as(usize, 4), poly.len);
    try std.testing.expectEqual(@as(i32, 5), poly[1].y);
    try std.testing.expectEqual(@as(i32, 5), poly[2].y);
    try std.testing.expectEqual(poly[2].x, poly[3].x);
}

test "two same-side bridges with overlapping spans get distinct tracks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 30, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 8, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = 7 },
        .{ .id = 3, .rect = .{ .x = 22, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"Q"}, .cluster_id = 7 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 6, .y = 8, .w = 24, .h = 7 }, .parent_id = null, .label = "Real", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2, 3 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    const jog0 = edges[0].polyline[1].y;
    const jog1 = edges[1].polyline[1].y;
    try std.testing.expect(jog0 != jog1);
    try std.testing.expect(jog0 < 8 and jog1 < 8);
    try std.testing.expectEqual(@as(i32, 1), @max(jog0, jog1) - @min(jog0, jog1));
}

test "bridges sharing one source port share a single rail track" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 12, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 8, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = 7 },
        .{ .id = 2, .rect = .{ .x = 22, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"Q"}, .cluster_id = 7 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 6, .y = 8, .w = 24, .h = 7 }, .parent_id = null, .label = "Real", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqual(edges[0].polyline[1].y, edges[1].polyline[1].y);
}

test "bridges sharing one target port share a single rail track" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 2, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"L"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 12, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"M"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 22, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"R"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 12, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"T"}, .cluster_id = 7 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 6, .y = 8, .w = 24, .h = 7 }, .parent_id = null, .label = "Real", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2, 3 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    try std.testing.expectEqual(@as(usize, 3), edges.len);
    try std.testing.expectEqual(@as(usize, 4), edges[0].polyline.len);
    try std.testing.expectEqual(@as(usize, 2), edges[1].polyline.len);
    try std.testing.expectEqual(@as(usize, 4), edges[2].polyline.len);
    try std.testing.expectEqual(edges[0].polyline[1].y, edges[2].polyline[1].y);
    try std.testing.expectEqual(@as(i32, 7), edges[0].polyline[1].y);
    try std.testing.expectEqual(edges[0].polyline[3].x, edges[1].polyline[1].x);
}

test "a bridge sharing a start with one peer and an end with another keys its request at the start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 2, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"S1"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 20, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"S2"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 10, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"T1"}, .cluster_id = 7 },
        .{ .id = 3, .rect = .{ .x = 28, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"T2"}, .cluster_id = 7 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 6, .y = 8, .w = 32, .h = 7 }, .parent_id = null, .label = "Real", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2, 3 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 1, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    try std.testing.expectEqual(@as(usize, 3), edges.len);
    try std.testing.expectEqual(edges[1].polyline[1].y, edges[2].polyline[1].y);
    try std.testing.expect(edges[0].polyline[1].y != edges[1].polyline[1].y);
}

test "tracks.onFrameBorder ignores synthetic frames and disjoint spans" {
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 10, .y = 5, .w = 10, .h = 6 }, .parent_id = null, .label = "R", .depth = 0 },
        .{ .id = 2, .rect = .{ .x = 40, .y = 5, .w = 10, .h = 6 }, .parent_id = null, .label = "", .depth = 0, .synthetic = true },
    };
    try std.testing.expect(tracks.onFrameBorder(true, 5, 0, 15, &clusters));
    try std.testing.expect(!tracks.onFrameBorder(true, 5, 0, 9, &clusters));
    try std.testing.expect(!tracks.onFrameBorder(true, 5, 40, 49, &clusters));
    try std.testing.expect(tracks.onFrameBorder(true, 10, 12, 18, &clusters));
    try std.testing.expect(!tracks.onFrameBorder(true, 7, 12, 18, &clusters));
    try std.testing.expect(tracks.onFrameBorder(false, 10, 6, 9, &clusters));
    try std.testing.expect(!tracks.onFrameBorder(false, 11, 6, 9, &clusters));
}

test "assignJogs: shared-request merge across different cluster depths picks the closest-to-target preference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 12, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 8, .y = 25, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = 7 },
        .{ .id = 2, .rect = .{ .x = 22, .y = 25, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"Q"}, .cluster_id = 8 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 6, .y = 20, .w = 24, .h = 10 }, .parent_id = null, .label = "Real", .depth = 0 },
        .{ .id = 8, .rect = .{ .x = 20, .y = 22, .w = 8, .h = 6 }, .parent_id = 7, .label = "", .depth = 1, .synthetic = true },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqual(@as(i32, 21), edges[0].polyline[1].y);
    try std.testing.expectEqual(@as(i32, 21), edges[1].polyline[1].y);
}

test "verticalCorridor: the source-side jog row (one past the source) is collision-free above the pierced child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 12, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 10, .y = 5, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{"child"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 40, .y = 20, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &.{}, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    const poly = edges[0].polyline;

    try std.testing.expectEqual(@as(usize, 5), poly.len);
    try std.testing.expectEqual(@as(i32, 15), poly[1].x);
    try std.testing.expectEqual(@as(i32, 3), poly[1].y);

    try std.testing.expect(!sketch.columnTouchesAny(poly[1].x, poly[0].y, poly[1].y, &placements, 0, 1));
}

test "a vertical corridor's descent column never lands on a drawn frame border" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 2, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 2, .y = 7, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"child"}, .cluster_id = 7 },
        .{ .id = 1, .rect = .{ .x = 5, .y = 20, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 0, .y = 4, .w = 10, .h = 12 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &frames, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    const poly = edges[0].polyline;
    try std.testing.expectEqual(@as(usize, 6), poly.len);

    const naive = sketch.clearLine(false, poly[5].x, poly[1].y, poly[3].y, &placements, 0, 1, .{ .margin = true });
    try std.testing.expect(tracks.onFrameBorder(false, naive, poly[1].y, poly[3].y, &frames));

    const run_col = poly[2].x;
    try std.testing.expectEqual(poly[3].x, run_col);
    try std.testing.expect(!tracks.onFrameBorder(false, run_col, poly[2].y, poly[3].y, &frames));
    try std.testing.expect(!sketch.columnTouchesAny(run_col, poly[2].y, poly[3].y, &placements, 0, 1));
}

test "a re-routed corridor raises no crossing demand on the frame it leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 4, .y = 2, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"M1"}, .cluster_id = 1 },
        .{ .id = 1, .rect = .{ .x = 4, .y = 7, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"M2"}, .cluster_id = 1 },
        .{ .id = 2, .rect = .{ .x = 0, .y = 16, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"T1"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 10, .y = 16, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"T2"}, .cluster_id = null },
    };
    const frames = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 2, .y = 0, .w = 12, .h = 13 }, .parent_id = null, .label = "S", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2, 3 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &frames, &.{}, &.{}, .TD, &orig_to_merged, null, .plain);
    try std.testing.expectEqual(@as(usize, 2), edges.len);

    try std.testing.expect(edges[0].polyline.len > 4);

    const centred: u32 = 3;
    for (edges) |e| {
        try std.testing.expectEqual(centred, e.port_from.offset);
        const rect = placements[e.from].rect;
        try std.testing.expectEqual(rect.x + @as(i32, centred), e.polyline[0].x);
    }
}

test "sceneObstacles derives the pivot and tap head cells the raster stamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem = [_]sketch.Point{ .{ .x = 7, .y = 10 }, .{ .x = 7, .y = 8 } };
    const taps = [_]sketch.Tap{
        .{ .edge = 0, .node = 1, .at = .{ .x = 4, .y = 8 }, .landing = .{ .x = 4, .y = 12 }, .arrow = .filled },
        .{ .edge = 1, .node = 2, .at = .{ .x = 10, .y = 8 }, .landing = .{ .x = 10, .y = 12 }, .arrow = .none },
    };
    const rails = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ .{ .x = 4, .y = 8 }, .{ .x = 10, .y = 8 } },
        .taps = &taps,
        .kind = .solid,
        .role = .fan_in_dropper,
        .pivot_arrow = .filled,
    }};

    const obs = try bridges.sceneObstacles(a, &rails, &.{});
    try std.testing.expectEqual(@as(usize, 2), obs.heads.len);
    try std.testing.expectEqual(@as(i32, 7), obs.heads[0].x);
    try std.testing.expectEqual(@as(i32, 9), obs.heads[0].y);
    try std.testing.expectEqual(@as(i32, 4), obs.heads[1].x);
    try std.testing.expectEqual(@as(i32, 11), obs.heads[1].y);

    try std.testing.expect(obs.blocks(true, 8, 0, 20));
    try std.testing.expect(obs.blocks(false, 7, 8, 10));
    try std.testing.expect(obs.blocks(false, 10, 8, 12));
    try std.testing.expect(!obs.blocks(true, 7, 0, 20));
}

test "a licensed shared-source fan moves its whole rail off a static run the scene models as no obstacle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"O"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 2, .y = 20, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B1"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 22, .y = 20, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B2"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 16, .y = 8, .w = 4, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = null },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2, 3 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const static_poly = [_]sketch.Point{ .{ .x = 16, .y = 18 }, .{ .x = 30, .y = 18 } };
    const statics = [_]sketch.EdgePath{.{
        .id = 90,
        .from = 3,
        .to = 2,
        .polyline = &static_poly,
        .port_from = .{ .node = 3, .side = .east, .offset = 1 },
        .port_to = .{ .node = 2, .side = .east, .offset = 1 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .solid,
    }};

    const edges = try bridges.route(a, &crossings, &placements, &.{}, &.{}, &statics, .TD, &orig_to_merged, null, .railed);
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqual(edges[0].polyline[0].x, edges[1].polyline[0].x);
    try std.testing.expectEqual(@as(usize, 4), edges[0].polyline.len);
    try std.testing.expectEqual(edges[0].polyline[1].y, edges[1].polyline[1].y);
    try std.testing.expect(edges[0].polyline[1].y != 18);
}

test "a licensed shared-target fan moves its whole rail off a static run the scene models as no obstacle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 10, .y = 20, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"I"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 2, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B1"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 22, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B2"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 16, .y = 8, .w = 4, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = null },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2, 3 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 1, .to = 0, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 2, .to = 0, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const static_poly = [_]sketch.Point{ .{ .x = 16, .y = 18 }, .{ .x = 30, .y = 18 } };
    const statics = [_]sketch.EdgePath{.{
        .id = 90,
        .from = 3,
        .to = 2,
        .polyline = &static_poly,
        .port_from = .{ .node = 3, .side = .east, .offset = 1 },
        .port_to = .{ .node = 2, .side = .east, .offset = 1 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .solid,
    }};

    const plain = try bridges.route(a, &crossings, &placements, &.{}, &.{}, &statics, .TD, &orig_to_merged, null, .plain);
    try std.testing.expectEqual(@as(i32, 18), plain[0].polyline[1].y);
    try std.testing.expectEqual(@as(i32, 18), plain[1].polyline[1].y);

    const edges = try bridges.route(a, &crossings, &placements, &.{}, &.{}, &statics, .TD, &orig_to_merged, null, .railed);
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqual(@as(usize, 4), edges[0].polyline.len);
    try std.testing.expectEqual(edges[0].polyline[3].x, edges[1].polyline[3].x);
    try std.testing.expectEqual(edges[0].polyline[1].y, edges[1].polyline[1].y);
    try std.testing.expect(edges[0].polyline[1].y != 18);
}

test "clearOfBorders expiry surrenders the coordinate and counts it; a cleared search counts nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const runs = try a.alloc([2]sketch.Point, 4200);
    for (runs, 0..) |*r, i| {
        const y: i32 = 10 - @as(i32, @intCast(i));
        r.* = .{ .{ .x = 0, .y = y }, .{ .x = 20, .y = y } };
    }
    var expired: u32 = 0;
    const c = tracks.clearOfBorders(.north, 10, 0, 20, &.{}, .{ .runs = runs }, &expired);
    try std.testing.expectEqual(@as(u32, 1), expired);
    try std.testing.expectEqual(@as(i32, 10 - 4096), c);

    var cleared: u32 = 0;
    const c2 = tracks.clearOfBorders(.north, 10, 0, 20, &.{}, .{ .runs = runs[0..1] }, &cleared);
    try std.testing.expectEqual(@as(u32, 0), cleared);
    try std.testing.expectEqual(@as(i32, 9), c2);
}

test "resolve threads the expiry counter through the lane cascade" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const runs = try a.alloc([2]sketch.Point, 4200);
    for (runs, 0..) |*r, i| {
        const y: i32 = 10 - @as(i32, @intCast(i));
        r.* = .{ .{ .x = 0, .y = y }, .{ .x = 20, .y = y } };
    }
    const reqs = [_]tracks.Req{
        .{ .span_lo = 0, .span_hi = 20, .pref = 10 },
        .{ .span_lo = 5, .span_hi = 15, .pref = 9 },
    };
    var expired: u32 = 0;
    _ = try tracks.resolve(a, &reqs, .north, &.{}, .{ .runs = runs }, &expired);
    try std.testing.expect(expired > 0);
}

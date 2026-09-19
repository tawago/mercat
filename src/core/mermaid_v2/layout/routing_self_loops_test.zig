const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const self_loops = @import("routing_self_loops.zig");
const testing = std.testing;

fn mkPlacement(id: sg.NodeId, x: i32, y: i32, w: u32, h: u32) sketch.NodePlacement {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = w, .h = h }, .shape = .rect, .lines = &.{}, .cluster_id = null };
}

test "self-loop detour offsets match OFF_H=4 (east overshoot) / OFF_V=3 (vertical rise/drop) across TD/BT/LR/RL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = mkPlacement(0, 0, 0, 7, 3);
    const placements = [_]sketch.NodePlacement{node};

    for ([_]sg.Direction{ .TD, .BT }) |dir| {
        const sl = try self_loops.selfLoop(arena.allocator(), dir, node, &placements);
        const east_x = node.rect.right() - 1;
        try testing.expectEqual(@as(i32, 4), sl.polyline[1].x - east_x);
        try testing.expectEqual(@as(i32, 3), node.rect.y - sl.polyline[2].y);
    }

    for ([_]sg.Direction{ .LR, .RL }) |dir| {
        const sl = try self_loops.selfLoop(arena.allocator(), dir, node, &placements);
        const south_y = node.rect.bottom() - 1;
        try testing.expectEqual(@as(i32, 3), sl.polyline[1].y - south_y);
    }
}

test "belowEastLoop's south descent blocking is monotonic: an obstacle at the nearest candidate gap row sinks the whole fallback (no deeper gap_y recovers)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const above = mkPlacement(0, 0, 0, 20, 3);
    const node = mkPlacement(1, 0, 4, 20, 3);
    const w_i: i32 = 20;
    const k = self_loops.selfLoopHalfGap(20);
    const exit_x = node.rect.x + @divTrunc(w_i, 2) + k;
    const south_y = node.rect.bottom() - 1;
    const obstacle = mkPlacement(2, exit_x, south_y + 1, 1, 1);
    const placements = [_]sketch.NodePlacement{ above, node, obstacle };

    const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
    try testing.expectEqual(sketch.Dir4.east, sl.port_from.side);
    try testing.expectEqual(sketch.Dir4.north, sl.port_to.side);
}

fn segmentTouchesInterior(p0: sketch.Point, p1: sketch.Point, interior: sketch.Rect) bool {
    if (interior.w == 0 or interior.h == 0) return false;
    if (p0.x == p1.x) {
        const lo = @min(p0.y, p1.y);
        const hi = @max(p0.y, p1.y);
        return sketch.lineTouchesRect(false, p0.x, lo, hi, interior);
    } else {
        const lo = @min(p0.x, p1.x);
        const hi = @max(p0.x, p1.x);
        return sketch.lineTouchesRect(true, p0.y, lo, hi, interior);
    }
}

fn expectNoInteriorCrossing(poly: []const sketch.Point, r: sketch.Rect) !void {
    if (r.w < 3 or r.h < 3) return;
    const interior: sketch.Rect = .{ .x = r.x + 1, .y = r.y + 1, .w = r.w - 2, .h = r.h - 2 };
    var i: usize = 1;
    while (i < poly.len) : (i += 1) {
        try testing.expect(!segmentTouchesInterior(poly[i - 1], poly[i], interior));
    }
}

test "self-loop detour never crosses back into the source node's own interior, across sizes and directions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sizes = [_][2]u32{ .{ 3, 3 }, .{ 7, 3 }, .{ 20, 3 }, .{ 5, 5 }, .{ 40, 6 } };

    for (sizes) |wh| {
        const node = mkPlacement(0, 0, 0, wh[0], wh[1]);
        const placements = [_]sketch.NodePlacement{node};

        {
            const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
            try expectNoInteriorCrossing(sl.polyline, node.rect);
        }
        {
            const sl = try self_loops.selfLoop(arena.allocator(), .LR, node, &placements);
            try expectNoInteriorCrossing(sl.polyline, node.rect);
        }
    }

    {
        const above = mkPlacement(0, 0, 0, 20, 3);
        const node = mkPlacement(1, 0, 4, 20, 3);
        const placements = [_]sketch.NodePlacement{ above, node };
        const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
        try expectNoInteriorCrossing(sl.polyline, node.rect);
    }
}

test "southLoop's final segment rises north (dy<0), the geometry paint.zig's arrowGlyph maps to the up-arrow ▲" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = mkPlacement(0, 0, 0, 9, 3);
    const placements = [_]sketch.NodePlacement{node};

    const sl = try self_loops.selfLoop(arena.allocator(), .LR, node, &placements);
    const last = sl.polyline[sl.polyline.len - 1];
    const prev = sl.polyline[sl.polyline.len - 2];
    try testing.expectEqual(prev.x, last.x);
    try testing.expect(last.y < prev.y);
}

test "selfLoopHalfGap keeps both south ports strictly inside [1, w-2] for every non-degenerate width" {
    var w: u32 = 5;
    while (w <= 200) : (w += 1) {
        const k = self_loops.selfLoopHalfGap(w);
        const w_i: i32 = @intCast(w);
        const half = @divTrunc(w_i, 2);
        try testing.expect(k >= 1);
        try testing.expect(half - k >= 1);
        try testing.expect(half + k <= w_i - 2);
    }
}

test "selfLoopHalfGap boundary: w=4 is the last degenerate width, w=5 is the first strictly-contained one" {
    const k4 = self_loops.selfLoopHalfGap(4);
    try testing.expectEqual(@as(i32, 1), k4);
    try testing.expect(2 + k4 > 4 - 2);

    const k5 = self_loops.selfLoopHalfGap(5);
    try testing.expect(2 - k5 >= 1);
    try testing.expect(2 + k5 <= 5 - 2);
}

test "belowEastLoop lands the east re-entry with a straight base cell (◀─┐)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const above = mkPlacement(0, 0, 0, 20, 3);
    const node = mkPlacement(1, 0, 4, 20, 3);
    const placements = [_]sketch.NodePlacement{ above, node };
    const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
    try testing.expectEqual(sketch.Dir4.south, sl.port_from.side);
    try testing.expectEqual(sketch.Dir4.east, sl.port_to.side);
    const east_x = node.rect.right() - 1;
    try testing.expect(sl.polyline[3].x - east_x >= 3);
    try testing.expectEqual(sl.polyline[4].x, east_x);
}

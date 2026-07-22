//! Tests for routing_self_loops.zig. Discovered via `test { _ = @import }`.
//!
//! These promote comment claims about the self-loop "lollipop" detour into
//! machine checks against the real `selfLoop`/`selfLoopHalfGap` output —
//! not a re-implementation of the geometry.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const self_loops = @import("routing_self_loops.zig");
const testing = std.testing;

fn mkPlacement(id: sg.NodeId, x: i32, y: i32, w: u32, h: u32) sketch.NodePlacement {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = w, .h = h }, .shape = .rect, .lines = &.{}, .cluster_id = null };
}

// -- OFF_H/OFF_V: classic-loop detour magnitudes -----------------------------

test "self-loop detour offsets match OFF_H=4 (east overshoot) / OFF_V=3 (vertical rise/drop) across TD/BT/LR/RL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = mkPlacement(0, 0, 0, 7, 3);
    const placements = [_]sketch.NodePlacement{node};

    // TD/BT: classic top loop. poly[1].x is the east overshoot peak;
    // poly[2].y is the row above the top border.
    for ([_]sg.Direction{ .TD, .BT }) |dir| {
        const sl = try self_loops.selfLoop(arena.allocator(), dir, node, &placements);
        const east_x = node.rect.right() - 1;
        try testing.expectEqual(@as(i32, 4), sl.polyline[1].x - east_x);
        try testing.expectEqual(@as(i32, 3), node.rect.y - sl.polyline[2].y);
    }

    // LR/RL: south loop. poly[1].y is the row below the south border.
    for ([_]sg.Direction{ .LR, .RL }) |dir| {
        const sl = try self_loops.selfLoop(arena.allocator(), dir, node, &placements);
        const south_y = node.rect.bottom() - 1;
        try testing.expectEqual(@as(i32, 3), sl.polyline[1].y - south_y);
    }
}

// -- belowEastLoop obstacle blocking is monotonic in gap_y -------------------

test "belowEastLoop's south descent blocking is monotonic: an obstacle at the nearest candidate gap row sinks the whole fallback (no deeper gap_y recovers)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Predecessor directly above forces the classic top loop to be blocked,
    // so `selfLoop` must attempt `belowEastLoop`.
    const above = mkPlacement(0, 0, 0, 20, 3);
    const node = mkPlacement(1, 0, 4, 20, 3);
    const w_i: i32 = 20;
    const k = self_loops.selfLoopHalfGap(20);
    const exit_x = node.rect.x + @divTrunc(w_i, 2) + k;
    const south_y = node.rect.bottom() - 1;
    // A 1-cell obstacle sitting exactly on the nearest candidate gap row
    // (south_y+1) blocks the south descent on its very first iteration.
    // Since the checked column range only grows with gap_y, this same
    // obstacle blocks every deeper gap_y too — belowEastLoop must give up
    // entirely rather than finding a deeper detour.
    const obstacle = mkPlacement(2, exit_x, south_y + 1, 1, 1);
    const placements = [_]sketch.NodePlacement{ above, node, obstacle };

    const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
    // belowEastLoop returned null (blocked) so selfLoop fell back to the
    // classic east/north top-loop shape rather than a south/east detour.
    try testing.expectEqual(sketch.Dir4.east, sl.port_from.side);
    try testing.expectEqual(sketch.Dir4.north, sl.port_to.side);
}

// -- lollipop detour never crosses back into the source node's own body -----

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
    // Shrink by one cell on every side: the perimeter border is where ports
    // legitimately sit, so only the strict interior counts as "inside the
    // node's body".
    if (r.w < 3 or r.h < 3) return; // no interior to violate
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

        // Classic top loop (TD/BT, unobstructed).
        {
            const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
            try expectNoInteriorCrossing(sl.polyline, node.rect);
        }
        // South loop (LR/RL).
        {
            const sl = try self_loops.selfLoop(arena.allocator(), .LR, node, &placements);
            try expectNoInteriorCrossing(sl.polyline, node.rect);
        }
    }

    // belowEastLoop fallback (TD with a blocking predecessor above).
    {
        const above = mkPlacement(0, 0, 0, 20, 3);
        const node = mkPlacement(1, 0, 4, 20, 3);
        const placements = [_]sketch.NodePlacement{ above, node };
        const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
        try expectNoInteriorCrossing(sl.polyline, node.rect);
    }
}

// -- southLoop's terminal segment rises north (guards the ▲ arrowhead) ------

test "southLoop's final segment rises north (dy<0), the geometry paint.zig's arrowGlyph maps to the up-arrow ▲" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const node = mkPlacement(0, 0, 0, 9, 3);
    const placements = [_]sketch.NodePlacement{node};

    const sl = try self_loops.selfLoop(arena.allocator(), .LR, node, &placements);
    const last = sl.polyline[sl.polyline.len - 1];
    const prev = sl.polyline[sl.polyline.len - 2];
    // Same x (vertical run) rising to a smaller y — the direction paint.zig
    // (`.north => '▲'`) reads off the final segment.
    try testing.expectEqual(prev.x, last.x);
    try testing.expect(last.y < prev.y);
}

// -- selfLoopHalfGap keeps both south ports strictly inside [1, w-2] --------

test "selfLoopHalfGap keeps both south ports strictly inside [1, w-2] for every non-degenerate width" {
    var w: u32 = 5;
    while (w <= 200) : (w += 1) {
        const k = self_loops.selfLoopHalfGap(w);
        const w_i: i32 = @intCast(w);
        const half = @divTrunc(w_i, 2);
        try testing.expect(k >= 1); // the two ports never coincide
        try testing.expect(half - k >= 1);
        try testing.expect(half + k <= w_i - 2);
    }
}

test "selfLoopHalfGap boundary: w=4 is the last degenerate width, w=5 is the first strictly-contained one" {
    // w=4 is documented as falling back to k=1 even though that pushes the
    // far port past w-2 (the degenerate case the doc comment calls out).
    const k4 = self_loops.selfLoopHalfGap(4);
    try testing.expectEqual(@as(i32, 1), k4);
    try testing.expect(2 + k4 > 4 - 2); // degenerate: does NOT satisfy strict containment

    const k5 = self_loops.selfLoopHalfGap(5);
    try testing.expect(2 - k5 >= 1);
    try testing.expect(2 + k5 <= 5 - 2);
}

// -- Base-side law: self-loop re-entries carry a straight base cell ----------

test "selfLoopAt TD lifts the top run OFF_V so the north re-entry has a straight base cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Node with headroom (r.y >= OFF_V) so the lift applies.
    const node = mkPlacement(0, 4, 6, 7, 3);
    const placements = [_]sketch.NodePlacement{node};
    const pf: sketch.Port = .{ .node = 0, .side = .east, .offset = 1 };
    const pt: sketch.Port = .{ .node = 0, .side = .north, .offset = 3 };

    const sl = try self_loops.selfLoopAt(arena.allocator(), .TD, node, &placements, pf, pt);
    // poly[3] = (north_x, loop_y), poly[4] = (north_x, r.y): the final descent
    // into the north border. It must span OFF_V (=3) cells so a straight `│`
    // sits between the corner and the `▼` (base cell present), never a 1-cell
    // turn-at-tip.
    const descent = sl.polyline[4].y - sl.polyline[3].y;
    try testing.expectEqual(@as(i32, 3), descent);
    try testing.expectEqual(node.rect.y - 3, sl.polyline[3].y);

    // Degenerate headroom (r.y < OFF_V): clamp back to -1 so the run never
    // underflows the canvas (still safe, no formal base at the very top rank).
    const top_node = mkPlacement(0, 0, 1, 7, 3);
    const top_pl = [_]sketch.NodePlacement{top_node};
    const sl_top = try self_loops.selfLoopAt(arena.allocator(), .TD, top_node, &top_pl, pf, pt);
    try testing.expectEqual(top_node.rect.y - 1, sl_top.polyline[3].y);
}

test "belowEastLoop lands the east re-entry with a straight base cell (◀─┐)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Box directly above (gap 1 row) blocks the classic top loop, forcing the
    // south/east fallback; no obstacle below, so belowEastLoop succeeds.
    const above = mkPlacement(0, 0, 0, 20, 3);
    const node = mkPlacement(1, 0, 4, 20, 3);
    const placements = [_]sketch.NodePlacement{ above, node };
    const sl = try self_loops.selfLoop(arena.allocator(), .TD, node, &placements);
    // Confirm we took the south/east fallback (not the classic top loop).
    try testing.expectEqual(sketch.Dir4.south, sl.port_from.side);
    try testing.expectEqual(sketch.Dir4.east, sl.port_to.side);
    // Final segment poly[3]->poly[4] runs west into the east border; the arm
    // corner (poly[3].x) must sit >= 3 cells east of the border so a straight
    // `─` precedes the `◀` (◀─┐), not a corner at the tip (◀┐).
    const east_x = node.rect.right() - 1;
    try testing.expect(sl.polyline[3].x - east_x >= 3);
    try testing.expectEqual(sl.polyline[4].x, east_x);
}

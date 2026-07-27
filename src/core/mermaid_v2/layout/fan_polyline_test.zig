//! Tests for fan_polyline.zig. Split out from fan_test.zig to keep both
//! files under the 500-line mermaid_v2/ cap. Discovered via fan_test.zig's
//! `test { _ = @import }`.

const std = @import("std");
const fan = @import("fan.zig");
const fan_polyline = @import("fan_polyline.zig");
const sketch = @import("../sketch.zig");

const testing = std.testing;

/// Assert no segment of `poly` touches `rect` (border-inclusive touch
/// semantics, matching `sketch.lineTouchesRect`). Shared by the dodge
/// tests below, which construct an obstruction a naive straight run
/// would slice and check the real dodge geometry actually avoids it.
fn expectPolyAvoidsRect(poly: []const sketch.Point, rect: sketch.Rect) !void {
    var i: usize = 1;
    while (i < poly.len) : (i += 1) {
        const p0 = poly[i - 1];
        const p1 = poly[i];
        if (p0.x == p1.x) {
            const y0 = @min(p0.y, p1.y);
            const y1 = @max(p0.y, p1.y);
            try testing.expect(!sketch.lineTouchesRect(false, p0.x, y0, y1, rect));
        } else {
            const x0 = @min(p0.x, p1.x);
            const x1 = @max(p0.x, p1.x);
            try testing.expect(!sketch.lineTouchesRect(true, p0.y, x0, x1, rect));
        }
    }
}

test "grid fan-OUT trunk dodges a sibling box stacked in an earlier grid row" {
    // Pivot at column 26 (hub_and_spoke shape): a row-2 child sits directly
    // BELOW a row-1 sibling in the pivot column. The straight trunk descent
    // would pass through the sibling; the polyline must instead detour to a
    // column that touches no box at all (touch semantics, borders included).
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{
        .id = 4,
        .rect = .{ .x = 19, .y = 5, .w = 15, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    const sibling = sketch.NodePlacement{
        .id = 5,
        .rect = .{ .x = 17, .y = 10, .w = 17, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    const child = sketch.NodePlacement{
        .id = 7,
        .rect = .{ .x = 19, .y = 15, .w = 15, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    const placements = [_]sketch.NodePlacement{ pivot, sibling, child };

    var peers = [_]fan.FanEdge{
        .{ .edge_id = 6, .peer_idx = 1, .role = .center },
    };
    const f = fan.Fan{
        .direction = .out,
        .pivot_idx = 0,
        .source_layer = 0,
        .peers = &peers,
        .rows = 2,
    };

    const poly = try fan_polyline.buildPolyline(
        arena.allocator(),
        .TD,
        f,
        pivot,
        child,
        .center,
        0,
        &placements,
    );

    // No vertical or horizontal segment may touch the sibling's rect.
    try expectPolyAvoidsRect(poly, sibling.rect);
    // Endpoints unchanged: leaves the pivot bottom, enters the child top.
    try testing.expectEqual(@as(i32, 7), poly[0].y);
    try testing.expectEqual(@as(i32, 15), poly[poly.len - 1].y);
}

test "grid fan-OUT rail sits exactly 2 rows above the child top (clean descent, not a corner-collision)" {
    // A 1-row-only headroom would leave the corner point and the final
    // approach point ADJACENT (rail == child_top - 1): the raster's corner
    // rewrite then owns that cell and the arrowhead direction is read off
    // the horizontal incoming segment instead of the vertical one — a
    // sideways glyph. Assert the real code keeps the required 2-row gap.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 14, .y = 10, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .middle }};
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .rows = 2 };

    const poly = try fan_polyline.buildPolyline(arena.allocator(), .TD, f, pivot, child, .middle, 0, &placements);

    try testing.expect(poly.len >= 2);
    const last = poly[poly.len - 1];
    const prev = poly[poly.len - 2];
    try testing.expectEqual(child.rect.y, last.y);
    try testing.expectEqual(prev.x, last.x);
    try testing.expectEqual(@as(i32, 2), last.y - prev.y);
}

test "grid fan-IN trunk dodges a source stacked in a lower grid row at the shared target column" {
    // Mirror of the fan-OUT grid dodge test above: the shared trunk column
    // descending into the target may pass through a DIFFERENT source's box
    // stacked in a lower grid row. The reverse comb must detour around it
    // instead of piercing it.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const target = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 19, .y = 20, .w = 15, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const source = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 19, .y = 5, .w = 15, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const lower_row_sibling = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 19, .y = 12, .w = 15, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ target, source, lower_row_sibling };

    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .center }};
    const f = fan.Fan{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .rows = 2 };

    const poly = try fan_polyline.buildPolyline(arena.allocator(), .TD, f, target, source, .center, 0, &placements);

    try expectPolyAvoidsRect(poly, lower_row_sibling.rect);
    try testing.expectEqual(source.rect.bottom() - 1, poly[0].y);
    try testing.expectEqual(target.rect.y, poly[poly.len - 1].y);
}

test "rail_lift moves the single-row rail away from the cluster frame-border row instead of fusing with it" {
    // Without a lift, the rail lands exactly on `t_peri - 2` — which the
    // comment says is also where a cluster's leading frame-border row
    // sits when the fan descends into a cluster the source isn't part of.
    // A positive rail_lift must move the rail strictly further from the
    // target (smaller y for TD), landing away from that shared row.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 40, .y = 20, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };

    const frame_border_row = child.rect.y - 2;

    const no_lift = try fan_polyline.buildPolyline(arena.allocator(), .TD, f, pivot, child, .leftmost, 0, &placements);
    const lifted = try fan_polyline.buildPolyline(arena.allocator(), .TD, f, pivot, child, .leftmost, 2, &placements);

    // Both polylines' rail point is the 2nd point (index 1): (sx, rail_y).
    try testing.expectEqual(frame_border_row, no_lift[1].y);
    try testing.expect(lifted[1].y != frame_border_row);
    try testing.expectEqual(frame_border_row - 2, lifted[1].y);
}

test "single-row fan spanning 2+ layers dodges an intermediate box instead of slicing it" {
    // A peer 2+ layers below the pivot needs a long drop through the gap
    // rows an in-between layer occupies. A straight column would slice an
    // intermediate box there — the raster refuses those cells, amputating
    // the edge. The dodge must route around it instead.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const in_between = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 18, .y = 6, .w = 14, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 50, .y = 20, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, in_between, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };

    const poly = try fan_polyline.buildPolyline(arena.allocator(), .TD, f, pivot, child, .leftmost, 0, &placements);

    try expectPolyAvoidsRect(poly, in_between.rect);
    try testing.expectEqual(pivot.rect.bottom() - 1, poly[0].y);
    try testing.expectEqual(child.rect.y, poly[poly.len - 1].y);
}

test "a centre-classified member with offset ports is railed, not emitted as a diagonal" {
    // `.center` is decided from PLACEMENT columns, but the polyline is built
    // from the allocated PORT columns. When D-PORT hands the member a target
    // port one cell off the source column, the straight two-point descent is
    // a DIAGONAL segment: `raster/edges.zig` finds no orthogonal direction,
    // calls the polyline degenerate, and drops the edge with zero ink and
    // zero cells_lost — a silent deletion no audit can see. Every consecutive
    // pair must therefore be axis-aligned.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const peer = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 20, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 16, .y = 14, .w = 13, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, peer };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .center }};
    const f = fan.Fan{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers };

    // Source port at the peer's centre column (22); target port one cell to
    // its left (21) — the offset a per-edge port allocation produces.
    const source_port = sketch.Port{ .node = peer.id, .side = .south, .offset = 2 };
    const target_port = sketch.Port{ .node = pivot.id, .side = .north, .offset = 5 };

    const poly = try fan_polyline.buildPolylineAt(
        arena.allocator(),
        .TD,
        f,
        pivot,
        peer,
        source_port,
        target_port,
        .center,
        0,
        0,
        &placements,
    );

    try testing.expect(poly.len > 2);
    var i: usize = 1;
    while (i < poly.len) : (i += 1) {
        const p0 = poly[i - 1];
        const p1 = poly[i];
        try testing.expect(p0.x == p1.x or p0.y == p1.y);
    }
    try testing.expectEqual(@as(i32, 22), poly[0].x);
    try testing.expectEqual(@as(i32, 21), poly[poly.len - 1].x);
}

test "a blocked landing column bends the rail once instead of doubling it back" {
    // The target column is blocked between the rail row and its landing row,
    // so the descent must move to a clear corridor. Running the rail all the
    // way to the target column FIRST and only then stepping back to that
    // corridor retraces the row just drawn; the reversal vertex carries arms on
    // one side only and paints a dead-end stub pointing at nothing. The rail
    // must therefore reverse direction nowhere.
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const peer = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 40, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 16, .y = 20, .w = 13, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    // Spans the target column between the rail row (14) and the landing row
    // (18), and everything to its LEFT — so the only clear descent corridor
    // lies to the RIGHT of the target column, i.e. back toward the source.
    const blocker = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 0, .y = 15, .w = 27, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, peer, blocker };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .rightmost }};
    const f = fan.Fan{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers };

    const source_port = sketch.Port{ .node = peer.id, .side = .south, .offset = 2 };
    const target_port = sketch.Port{ .node = pivot.id, .side = .north, .offset = 6 };
    // lane 4 lifts the rail to row 14, leaving a real gap (rows 15..18) for the
    // landing descent — the configuration in which the corridor is discovered.
    const poly = try fan_polyline.buildPolylineAt(
        arena.allocator(),
        .TD,
        f,
        pivot,
        peer,
        source_port,
        target_port,
        .rightmost,
        4,
        0,
        &placements,
    );

    // The fixture must actually reach the corridor path: the rail row is 14 and
    // the descent lands at row 18 in a column right of the target column.
    var saw_corridor = false;
    for (poly) |pt| {
        if (pt.y == 18 and pt.x > 22) saw_corridor = true;
    }
    try testing.expect(saw_corridor);

    // No horizontal run may reverse the direction of the previous one.
    var prev: i32 = 0;
    var i: usize = 1;
    while (i < poly.len) : (i += 1) {
        const dx = poly[i].x - poly[i - 1].x;
        if (dx == 0) continue;
        const sign: i32 = if (dx > 0) 1 else -1;
        if (prev != 0) try testing.expect(sign == prev);
        prev = sign;
    }
    try expectPolyAvoidsRect(poly, blocker.rect);
}

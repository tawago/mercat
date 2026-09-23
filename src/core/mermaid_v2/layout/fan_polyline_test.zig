const std = @import("std");
const sg = @import("../sem_graph.zig");
const fan = @import("fan.zig");
const fan_polyline = @import("fan_polyline.zig");
const sketch = @import("../sketch.zig");

const testing = std.testing;

fn portFromSource(dir: sg.Direction, source_p: sketch.NodePlacement) sketch.Port {
    const side: sketch.Dir4 = switch (dir) {
        .TD => .south,
        .BT => .north,
        .LR => .east,
        .RL => .west,
    };
    const offset: u32 = switch (side) {
        .north, .south => @divTrunc(source_p.rect.w, 2),
        .east, .west => @divTrunc(source_p.rect.h, 2),
    };
    return .{ .node = source_p.id, .side = side, .offset = offset };
}

fn portToTarget(dir: sg.Direction, target_p: sketch.NodePlacement) sketch.Port {
    const side: sketch.Dir4 = switch (dir) {
        .TD => .north,
        .BT => .south,
        .LR => .west,
        .RL => .east,
    };
    const offset: u32 = switch (side) {
        .north, .south => @divTrunc(target_p.rect.w, 2),
        .east, .west => @divTrunc(target_p.rect.h, 2),
    };
    return .{ .node = target_p.id, .side = side, .offset = offset };
}

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

fn buildPolyline(
    a: std.mem.Allocator,
    dir: sg.Direction,
    f: fan.Fan,
    pivot_p: sketch.NodePlacement,
    peer_p: sketch.NodePlacement,
    role: fan.ChildRole,
    rail_lift: u32,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]sketch.Point {
    const source = if (f.direction == .out) pivot_p else peer_p;
    const target = if (f.direction == .out) peer_p else pivot_p;
    return fan_polyline.buildPolylineAt(a, dir, f, pivot_p, peer_p, portFromSource(dir, source), portToTarget(dir, target), role, 0, rail_lift, null, placements, .{});
}

test "grid fan-OUT rail dodges a sibling box stacked in an earlier grid row" {
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

    const poly = try buildPolyline(
        arena.allocator(),
        .TD,
        f,
        pivot,
        child,
        .center,
        0,
        &placements,
    );

    try expectPolyAvoidsRect(poly, sibling.rect);
    try testing.expectEqual(@as(i32, 7), poly[0].y);
    try testing.expectEqual(@as(i32, 15), poly[poly.len - 1].y);
}

test "a first-row grid peer's rail rises with its ledger lane and never past the pivot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pivot: sketch.NodePlacement = .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child: sketch.NodePlacement = .{ .id = 1, .rect = .{ .x = 0, .y = 10, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    const f: fan.Fan = .{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &.{}, .rows = 2 };
    const from = portFromSource(.TD, pivot);
    const to = portToTarget(.TD, child);
    const at0 = try fan_polyline.buildPolylineAt(a, .TD, f, pivot, child, from, to, .leftmost, 0, 0, null, &placements, .{});
    const at1 = try fan_polyline.buildPolylineAt(a, .TD, f, pivot, child, from, to, .leftmost, 1, 0, null, &placements, .{});
    const far = try fan_polyline.buildPolylineAt(a, .TD, f, pivot, child, from, to, .leftmost, 12, 0, null, &placements, .{});
    try testing.expectEqual(@as(i32, 8), at0[1].y);
    try testing.expectEqual(@as(i32, 7), at1[1].y);
    try testing.expectEqual(@as(i32, 3), far[1].y);
}

test "grid fan-OUT rail sits exactly 2 rows above the child top (clean descent, not a corner-collision)" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 14, .y = 10, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .middle }};
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .rows = 2 };

    const poly = try buildPolyline(arena.allocator(), .TD, f, pivot, child, .middle, 0, &placements);

    try testing.expect(poly.len >= 2);
    const last = poly[poly.len - 1];
    const prev = poly[poly.len - 2];
    try testing.expectEqual(child.rect.y, last.y);
    try testing.expectEqual(prev.x, last.x);
    try testing.expectEqual(@as(i32, 2), last.y - prev.y);
}

test "grid fan-IN rail dodges a source stacked in a lower grid row at the shared target column" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const target = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 19, .y = 20, .w = 15, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const source = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 19, .y = 5, .w = 15, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const lower_row_sibling = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 19, .y = 12, .w = 15, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ target, source, lower_row_sibling };

    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .center }};
    const f = fan.Fan{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .rows = 2 };

    const poly = try buildPolyline(arena.allocator(), .TD, f, target, source, .center, 0, &placements);

    try expectPolyAvoidsRect(poly, lower_row_sibling.rect);
    try testing.expectEqual(source.rect.bottom() - 1, poly[0].y);
    try testing.expectEqual(target.rect.y, poly[poly.len - 1].y);
}

test "rail_lift moves the single-row rail away from the cluster frame-border row instead of fusing with it" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 40, .y = 20, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };

    const frame_border_row = child.rect.y - 2;

    const no_lift = try buildPolyline(arena.allocator(), .TD, f, pivot, child, .leftmost, 0, &placements);
    const lifted = try buildPolyline(arena.allocator(), .TD, f, pivot, child, .leftmost, 2, &placements);

    try testing.expectEqual(frame_border_row, no_lift[1].y);
    try testing.expect(lifted[1].y != frame_border_row);
    try testing.expectEqual(frame_border_row - 2, lifted[1].y);
}

test "single-row fan spanning 2+ layers dodges an intermediate box instead of slicing it" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const in_between = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 18, .y = 6, .w = 14, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 50, .y = 20, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, in_between, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };

    const poly = try buildPolyline(arena.allocator(), .TD, f, pivot, child, .leftmost, 0, &placements);

    try expectPolyAvoidsRect(poly, in_between.rect);
    try testing.expectEqual(pivot.rect.bottom() - 1, poly[0].y);
    try testing.expectEqual(child.rect.y, poly[poly.len - 1].y);
}

test "labeled fan-OUT rail rises to the rail's labeled row for a 4-cell private descent; unlabeled stays put" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 40, .y = 8, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};

    const plain = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };
    const labeled = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true };

    const p_plain = try buildPolyline(arena.allocator(), .TD, plain, pivot, child, .leftmost, 0, &placements);
    const p_lbl = try buildPolyline(arena.allocator(), .TD, labeled, pivot, child, .leftmost, 0, &placements);

    const classic = child.rect.y - 2;
    try testing.expectEqual(classic, p_plain[1].y);
    try testing.expectEqual(classic - @as(i32, @intCast(fan.LABEL_RUN_EXTRA_ROWS - 1)), p_lbl[1].y);
}

test "labeled fan-OUT rail holds the classic row when the raised rail would touch the source" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 40, .y = 5, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};
    const labeled = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers, .labeled = true };

    const poly = try buildPolyline(arena.allocator(), .TD, labeled, pivot, child, .leftmost, 0, &placements);
    try testing.expectEqual(child.rect.y - 2, poly[1].y);
}

test "a lane past the gap's capacity clamps to the innermost in-gap row instead of climbing over the source" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 40, .y = 8, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};

    const s_peri = pivot.rect.bottom() - 1;
    const t_peri = child.rect.y;

    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };
    const from = portFromSource(.TD, pivot);
    const to = portToTarget(.TD, child);
    const p_fits = try fan_polyline.buildPolylineAt(arena.allocator(), .TD, f, pivot, child, from, to, .leftmost, 3, 0, null, &placements, .{});
    try testing.expectEqual(t_peri - 2 - 3, p_fits[1].y);
    try testing.expectEqual(s_peri + 1, p_fits[1].y);

    for ([_]u32{ 4, 9 }) |lane| {
        const poly = try fan_polyline.buildPolylineAt(arena.allocator(), .TD, f, pivot, child, from, to, .leftmost, lane, 0, null, &placements, .{});
        try testing.expectEqual(s_peri + 1, poly[1].y);
        try testing.expect(poly[1].y > s_peri);
    }
}

test "a decorated source's lane clamp and dodge jog stay out of the departure cell" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 40, .y = 8, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};
    const s_peri = pivot.rect.bottom() - 1;
    const from = portFromSource(.TD, pivot);
    const to = portToTarget(.TD, child);

    for ([_]u32{ 4, 9 }) |lane| {
        const over = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };
        const plain = try fan_polyline.buildPolylineAt(arena.allocator(), .TD, over, pivot, child, from, to, .leftmost, lane, 0, null, &placements, .{});
        try testing.expectEqual(s_peri + 1, plain[1].y);
        const decorated = try fan_polyline.buildPolylineAt(arena.allocator(), .TD, over, pivot, child, from, to, .leftmost, lane, 0, null, &placements, .{ .from = true });
        try testing.expectEqual(s_peri + 2, decorated[1].y);
    }

    const far = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 40, .y = 20, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const blocker = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 20, .y = 8, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const dodge_placements = [_]sketch.NodePlacement{ pivot, far, blocker };
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };
    const dodged = try fan_polyline.buildPolylineAt(arena.allocator(), .TD, f, pivot, far, from, portToTarget(.TD, far), .leftmost, 0, 0, null, &dodge_placements, .{ .from = true });
    try testing.expectEqual(s_peri + 2, dodged[1].y);
    try expectPolyAvoidsRect(dodged, blocker.rect);
}

fn expectVisitsEachCellOnce(a: std.mem.Allocator, poly: []const sketch.Point) !void {
    var seen: std.AutoHashMapUnmanaged(sketch.Point, void) = .empty;
    defer seen.deinit(a);
    try seen.put(a, poly[0], {});
    var i: usize = 1;
    while (i < poly.len) : (i += 1) {
        const p0 = poly[i - 1];
        const p1 = poly[i];
        try testing.expect(p0.x == p1.x or p0.y == p1.y);
        try testing.expect(!(p0.x == p1.x and p0.y == p1.y));
        const dx: i32 = std.math.sign(p1.x - p0.x);
        const dy: i32 = std.math.sign(p1.y - p0.y);
        var c = p0;
        while (c.x != p1.x or c.y != p1.y) {
            c = .{ .x = c.x + dx, .y = c.y + dy };
            try testing.expect(!seen.contains(c));
            try seen.put(a, c, {});
        }
    }
}

test "the target-side corridor ends the rail run at the corridor column; the route visits each cell once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 43, .y = 0, .w = 11, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 26, .y = 20, .w = 11, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const blocker = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 0, .y = 15, .w = 35, .h = 2 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child, blocker };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };

    const poly = try fan_polyline.buildPolylineAt(a, .TD, f, pivot, child, portFromSource(.TD, pivot), portToTarget(.TD, child), .leftmost, 5, 0, null, &placements, .{});

    const rail_y = child.rect.y - 2 - 5;
    const land_y = child.rect.y - 2;
    try expectPolyAvoidsRect(poly, blocker.rect);
    try expectVisitsEachCellOnce(a, poly);
    try testing.expectEqual(@as(usize, 6), poly.len);
    try testing.expectEqual(rail_y, poly[1].y);
    try testing.expectEqual(rail_y, poly[2].y);
    try testing.expect(poly[2].x > 31 and poly[2].x < 48);
    try testing.expectEqual(poly[2].x, poly[3].x);
    try testing.expectEqual(land_y, poly[3].y);
    try testing.expectEqual(sketch.Point{ .x = 31, .y = land_y }, poly[4]);
}

test "a target-side corridor under a same-column child adds a rail leg instead of a diagonal step" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pivot = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 26, .y = 0, .w = 11, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const child = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 26, .y = 20, .w = 11, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const blocker = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 28, .y = 15, .w = 7, .h = 2 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ pivot, child, blocker };
    var peers = [_]fan.FanEdge{.{ .edge_id = 1, .peer_idx = 1, .role = .leftmost }};
    const f = fan.Fan{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers };

    const poly = try fan_polyline.buildPolylineAt(a, .TD, f, pivot, child, portFromSource(.TD, pivot), portToTarget(.TD, child), .leftmost, 5, 0, null, &placements, .{});

    try expectPolyAvoidsRect(poly, blocker.rect);
    try expectVisitsEachCellOnce(a, poly);
    try testing.expectEqual(@as(usize, 6), poly.len);
    try testing.expectEqual(sketch.Point{ .x = 31, .y = child.rect.y - 7 }, poly[1]);
    try testing.expectEqual(child.rect.y - 7, poly[2].y);
    try testing.expect(poly[2].x != 31);
}

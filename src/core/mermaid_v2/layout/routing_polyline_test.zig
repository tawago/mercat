//! Tests for routing_polyline.zig. Discovered via `test { _ = @import }`.
//!
//! These promote comment claims about `routePolyline`'s terminal-segment
//! geometry into machine checks. The painter maps an arrowhead's glyph
//! purely from the direction of the polyline's FINAL segment (north→▲,
//! east→▶, south→▼, west→◀ — see `paint.zig`'s `arrowGlyph` and its own
//! "arrowhead glyphs for all four directions" test). So the invariant that
//! actually prevents a sideways/degenerate arrowhead is: the last two
//! points of the returned polyline differ on exactly one axis, in the
//! direction the comment promises, by a non-zero amount. These tests
//! assert that directly against the real `routePolyline` output — not a
//! re-implementation of it — using minimal hand-built geometry.

const std = @import("std");
const sketch = @import("../sketch.zig");
const rp = @import("routing_polyline.zig");
const testing = std.testing;

fn mkPlacement(id: sketch.NodeId, rect: sketch.Rect) sketch.NodePlacement {
    return .{ .id = id, .rect = rect, .shape = .rect, .lines = &.{}, .cluster_id = null };
}

const Geom = struct { x: i32, y: i32, w: u32, h: u32 };

/// Assert the final segment of `poly` is a non-degenerate vertical run
/// (same x, y differing) and that it moves in `expect_down`'s direction
/// (true = south/downward, false = north/upward) — the geometry the
/// painter reads as a clean ▼/▲ rather than a sideways glyph.
fn expectCleanVerticalFinalApproach(poly: []const sketch.Point, expect_down: bool) !void {
    try testing.expect(poly.len >= 2);
    const last = poly[poly.len - 1];
    const prev = poly[poly.len - 2];
    try testing.expectEqual(prev.x, last.x);
    try testing.expect(last.y != prev.y);
    if (expect_down) {
        try testing.expect(last.y > prev.y);
    } else {
        try testing.expect(last.y < prev.y);
    }
}

/// Horizontal analogue of `expectCleanVerticalFinalApproach` (clean ▶/◀).
fn expectCleanHorizontalFinalApproach(poly: []const sketch.Point, expect_right: bool) !void {
    try testing.expect(poly.len >= 2);
    const last = poly[poly.len - 1];
    const prev = poly[poly.len - 2];
    try testing.expectEqual(prev.y, last.y);
    try testing.expect(last.x != prev.x);
    if (expect_right) {
        try testing.expect(last.x > prev.x);
    } else {
        try testing.expect(last.x < prev.x);
    }
}

test "TD skip-corridor final descent is a clean vertical approach (guards ▼)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
    const to_p = mkPlacement(1, .{ .x = 0, .y = 20, .w = 8, .h = 3 });
    const placements = [_]sketch.NodePlacement{ from_p, to_p };
    const geom = [_]Geom{.{ .x = 2, .y = 10, .w = 0, .h = 0 }};
    const virtuals = [_]u32{0};

    const poly = try rp.routePolyline(
        a,
        .TD,
        from_p,
        to_p,
        .{ .node = 0, .side = .south, .offset = 4 },
        .{ .node = 1, .side = .north, .offset = 4 },
        &virtuals,
        &geom,
        &placements,
        0,
        0,
        0,
    );
    try expectCleanVerticalFinalApproach(poly, true);
}

test "LR skip-corridor final approach is a clean horizontal approach (guards ▶)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
    const to_p = mkPlacement(1, .{ .x = 20, .y = 0, .w = 8, .h = 3 });
    const placements = [_]sketch.NodePlacement{ from_p, to_p };
    const geom = [_]Geom{.{ .x = 10, .y = 2, .w = 0, .h = 0 }};
    const virtuals = [_]u32{0};

    const poly = try rp.routePolyline(
        a,
        .LR,
        from_p,
        to_p,
        .{ .node = 0, .side = .east, .offset = 1 },
        .{ .node = 1, .side = .west, .offset = 1 },
        &virtuals,
        &geom,
        &placements,
        0,
        0,
        0,
    );
    try expectCleanHorizontalFinalApproach(poly, true);
}

test "west/east port jog pad is never zero, near or far (guards clean </>)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const geom: []const Geom = &.{};
    const virtuals: []const u32 = &.{};

    {
        const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
        const to_p = mkPlacement(1, .{ .x = 20, .y = 10, .w = 8, .h = 3 });
        const placements = [_]sketch.NodePlacement{ from_p, to_p };
        const poly = try rp.routePolyline(
            a,
            .LR,
            from_p,
            to_p,
            .{ .node = 0, .side = .east, .offset = 1 },
            .{ .node = 1, .side = .west, .offset = 1 },
            virtuals,
            geom,
            &placements,
            0,
            0,
            0,
        );
        try expectCleanHorizontalFinalApproach(poly, true);
        const last = poly[poly.len - 1];
        const prev = poly[poly.len - 2];
        try testing.expectEqual(@as(i32, 2), last.x - prev.x);
    }

    {
        const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
        const to_p = mkPlacement(1, .{ .x = 8, .y = 10, .w = 8, .h = 3 });
        const placements = [_]sketch.NodePlacement{ from_p, to_p };
        const poly = try rp.routePolyline(
            a,
            .LR,
            from_p,
            to_p,
            .{ .node = 0, .side = .east, .offset = 1 },
            .{ .node = 1, .side = .west, .offset = 1 },
            virtuals,
            geom,
            &placements,
            0,
            0,
            0,
        );
        try expectCleanHorizontalFinalApproach(poly, true);
        const last = poly[poly.len - 1];
        const prev = poly[poly.len - 2];
        try testing.expectEqual(@as(i32, 1), last.x - prev.x);
    }
}

test "north/south port jog pad is never zero, near or far (guards clean ^/v)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const geom: []const Geom = &.{};
    const virtuals: []const u32 = &.{};

    {
        const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
        const to_p = mkPlacement(1, .{ .x = 10, .y = 20, .w = 8, .h = 3 });
        const placements = [_]sketch.NodePlacement{ from_p, to_p };
        const poly = try rp.routePolyline(
            a,
            .TD,
            from_p,
            to_p,
            .{ .node = 0, .side = .south, .offset = 4 },
            .{ .node = 1, .side = .north, .offset = 4 },
            virtuals,
            geom,
            &placements,
            0,
            0,
            0,
        );
        try expectCleanVerticalFinalApproach(poly, true);
        const last = poly[poly.len - 1];
        const prev = poly[poly.len - 2];
        try testing.expectEqual(@as(i32, 2), last.y - prev.y);
    }

    {
        const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
        const to_p = mkPlacement(1, .{ .x = 10, .y = 3, .w = 8, .h = 3 });
        const placements = [_]sketch.NodePlacement{ from_p, to_p };
        const poly = try rp.routePolyline(
            a,
            .TD,
            from_p,
            to_p,
            .{ .node = 0, .side = .south, .offset = 4 },
            .{ .node = 1, .side = .north, .offset = 4 },
            virtuals,
            geom,
            &placements,
            0,
            0,
            0,
        );
        try expectCleanVerticalFinalApproach(poly, true);
        const last = poly[poly.len - 1];
        const prev = poly[poly.len - 2];
        try testing.expectEqual(@as(i32, 1), last.y - prev.y);
    }
}

test "the jog never lands on the source wall (span-2 gap and lane escalation clamp)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const geom: []const Geom = &.{};
    const virtuals: []const u32 = &.{};

    {
        const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
        const to_p = mkPlacement(1, .{ .x = 3, .y = 4, .w = 8, .h = 3 });
        const placements = [_]sketch.NodePlacement{ from_p, to_p };
        const poly = try rp.routePolyline(
            a,
            .TD,
            from_p,
            to_p,
            .{ .node = 0, .side = .south, .offset = 4 },
            .{ .node = 1, .side = .north, .offset = 6 },
            virtuals,
            geom,
            &placements,
            0,
            0,
            0,
        );
        const wall_y: i32 = 2;
        for (poly[1..]) |pt| try testing.expect(pt.y > wall_y);
    }

    {
        const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
        const to_p = mkPlacement(1, .{ .x = 3, .y = 5, .w = 8, .h = 3 });
        const placements = [_]sketch.NodePlacement{ from_p, to_p };
        const poly = try rp.routePolyline(
            a,
            .TD,
            from_p,
            to_p,
            .{ .node = 0, .side = .south, .offset = 4 },
            .{ .node = 1, .side = .north, .offset = 6 },
            virtuals,
            geom,
            &placements,
            0,
            0,
            1,
        );
        const wall_y: i32 = 2;
        for (poly[1..]) |pt| try testing.expect(pt.y > wall_y);
    }

    {
        const from_p = mkPlacement(0, .{ .x = 0, .y = 0, .w = 8, .h = 3 });
        const to_p = mkPlacement(1, .{ .x = 9, .y = 4, .w = 8, .h = 3 });
        const placements = [_]sketch.NodePlacement{ from_p, to_p };
        const poly = try rp.routePolyline(
            a,
            .LR,
            from_p,
            to_p,
            .{ .node = 0, .side = .east, .offset = 1 },
            .{ .node = 1, .side = .west, .offset = 1 },
            virtuals,
            geom,
            &placements,
            0,
            0,
            0,
        );
        const wall_x: i32 = 7;
        for (poly[1..]) |pt| try testing.expect(pt.x > wall_x);
    }
}

/// True iff the vertical/horizontal segment prev->end passes through the
/// strict open interior of `r` (the validator-mirror intrusion predicates).
fn finalLegIntrudes(prev: sketch.Point, end: sketch.Point, r: sketch.Rect) bool {
    if (prev.x == end.x) return rp.columnIntrudesRect(prev.x, @min(prev.y, end.y), @max(prev.y, end.y), r);
    return rp.rowIntrudesRect(prev.y, @min(prev.x, end.x), @max(prev.x, end.x), r);
}

test "final approach reconciles a below-approach opposite-side port to the entry-side terminal" {
    const rc = sketch.Rect{ .x = 22, .y = 22, .w = 13, .h = 3 };
    const to_p = mkPlacement(1, rc);

    var below = [_]sketch.Point{
        .{ .x = 10, .y = 19 }, .{ .x = 10, .y = 26 }, .{ .x = 29, .y = 26 }, .{ .x = 29, .y = 22 },
    };
    const north_port = sketch.Port{ .node = 1, .side = .north, .offset = 7 };
    try testing.expect(finalLegIntrudes(below[below.len - 2], below[below.len - 1], rc));

    const fixed = rp.reconcileTerminalSide(&below, to_p, north_port);
    try testing.expectEqual(sketch.Dir4.south, fixed.side);
    try testing.expectEqual(@as(u32, 7), fixed.offset);
    try testing.expectEqual(sketch.Point{ .x = 29, .y = 24 }, below[below.len - 1]);
    try testing.expect(!finalLegIntrudes(below[below.len - 2], below[below.len - 1], rc));
    try expectCleanVerticalFinalApproach(&below, false);
}

test "terminal reconciliation is a no-op for an agreeing or perpendicular approach" {
    const rc = sketch.Rect{ .x = 22, .y = 22, .w = 13, .h = 3 };
    const to_p = mkPlacement(1, rc);
    const north_port = sketch.Port{ .node = 1, .side = .north, .offset = 7 };

    var above = [_]sketch.Point{ .{ .x = 29, .y = 20 }, .{ .x = 29, .y = 22 } };
    const a_fixed = rp.reconcileTerminalSide(&above, to_p, north_port);
    try testing.expectEqual(sketch.Dir4.north, a_fixed.side);
    try testing.expectEqual(sketch.Point{ .x = 29, .y = 22 }, above[above.len - 1]);

    var side = [_]sketch.Point{ .{ .x = 25, .y = 22 }, .{ .x = 29, .y = 22 } };
    const s_fixed = rp.reconcileTerminalSide(&side, to_p, north_port);
    try testing.expectEqual(sketch.Dir4.north, s_fixed.side);
}

test "ensureBaseStub shifts a turn-at-tip descent back one cell" {
    const boxes = [_]sketch.NodePlacement{
        mkPlacement(1, .{ .x = 3, .y = 8, .w = 20, .h = 3 }),
    };
    var poly = [_]sketch.Point{
        .{ .x = 70, .y = 6 }, .{ .x = 2, .y = 6 }, .{ .x = 2, .y = 9 }, .{ .x = 3, .y = 9 },
    };
    try testing.expect(rp.ensureBaseStub(&poly, &boxes, 0, 1));
    try testing.expectEqual(sketch.Point{ .x = 1, .y = 6 }, poly[1]);
    try testing.expectEqual(sketch.Point{ .x = 1, .y = 9 }, poly[2]);
    try testing.expectEqual(sketch.Point{ .x = 3, .y = 9 }, poly[3]);
}

test "ensureBaseStub is a no-op for a straight (already base-fed) final approach" {
    var poly = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 9 }, .{ .x = 5, .y = 10 } };
    try testing.expect(!rp.ensureBaseStub(&poly, &.{}, 0, 1));
    try testing.expectEqual(sketch.Point{ .x = 5, .y = 9 }, poly[1]);
}

test "ensureBaseStub accept-fallback: no room to shift leaves the polyline untouched" {
    const boxes = [_]sketch.NodePlacement{
        mkPlacement(1, .{ .x = 3, .y = 8, .w = 20, .h = 3 }),
        mkPlacement(2, .{ .x = 0, .y = 5, .w = 3, .h = 6 }),
    };
    var poly = [_]sketch.Point{
        .{ .x = 70, .y = 6 }, .{ .x = 2, .y = 6 }, .{ .x = 2, .y = 9 }, .{ .x = 3, .y = 9 },
    };
    try testing.expect(!rp.ensureBaseStub(&poly, &boxes, 0, 1));
    try testing.expectEqual(sketch.Point{ .x = 2, .y = 6 }, poly[1]);
}

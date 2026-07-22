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

// -- claim: skipCorridorExtraRows headroom → clean ▼ on TD skip-edges -------

test "TD skip-corridor final descent is a clean vertical approach (guards ▼)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Source (layer 0) → one virtual (layer 1, mid-corridor) → target
    // (layer 2), spanning 2 layers — the tell of a skip edge.
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
        false,
    );
    try expectCleanVerticalFinalApproach(poly, true);
}

// -- claim: LR skip-corridor keeps a straight final approach → clean ▶ ------

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
        false,
    );
    try expectCleanHorizontalFinalApproach(poly, true);
}

// -- claim: west/east ports get a >=1-cell jog pad → clean ◀/▶ --------------

test "west/east port jog pad is never zero, near or far (guards clean </>)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const geom: []const Geom = &.{};
    const virtuals: []const u32 = &.{};

    // Far apart on x: absDiff(end.x, prev.x) >= 2, so the jog pads out the
    // full 2 cells the comment promises.
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
            false,
        );
        try expectCleanHorizontalFinalApproach(poly, true);
        const last = poly[poly.len - 1];
        const prev = poly[poly.len - 2];
        try testing.expectEqual(@as(i32, 2), last.x - prev.x);
    }

    // Nearly aligned on x: absDiff(end.x, prev.x) < 2, so the jog falls
    // back to a 1-cell pad — still non-zero, still a clean approach.
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
            false,
        );
        try expectCleanHorizontalFinalApproach(poly, true);
        const last = poly[poly.len - 1];
        const prev = poly[poly.len - 2];
        try testing.expectEqual(@as(i32, 1), last.x - prev.x);
    }
}

// -- claim: north/south ports mirror the same jog-pad rule → clean ▲/▼ ------

test "north/south port jog pad is never zero, near or far (guards clean ^/v)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const geom: []const Geom = &.{};
    const virtuals: []const u32 = &.{};

    // Far apart on y: absDiff(end.y, prev.y) >= 2 → full 2-cell pad.
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
            false,
        );
        try expectCleanVerticalFinalApproach(poly, true);
        const last = poly[poly.len - 1];
        const prev = poly[poly.len - 2];
        try testing.expectEqual(@as(i32, 2), last.y - prev.y);
    }

    // Nearly aligned on y: absDiff(end.y, prev.y) < 2 → falls back to a
    // 1-cell pad, still non-zero.
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
            false,
        );
        try expectCleanVerticalFinalApproach(poly, true);
        const last = poly[poly.len - 1];
        const prev = poly[poly.len - 2];
        try testing.expectEqual(@as(i32, 1), last.y - prev.y);
    }
}

/// True iff the vertical/horizontal segment prev->end passes through the
/// strict open interior of `r` (the validator-mirror pierce predicates).
fn finalLegPierces(prev: sketch.Point, end: sketch.Point, r: sketch.Rect) bool {
    if (prev.x == end.x) return rp.columnPiercesRect(prev.x, @min(prev.y, end.y), @max(prev.y, end.y), r);
    return rp.rowPiercesRect(prev.y, @min(prev.x, end.x), @max(prev.x, end.x), r);
}

test "final approach reconciles a below-approach opposite-side port to the entry-side terminal" {
    // Reproduces the pr_review CR->ReviseCode geometry: a dodging interior
    // shift left the run BELOW the target while its allocated port is NORTH
    // (top). The final leg (29,26)->(29,22) climbs through the whole box to
    // reach the recorded top border — a pierce the rasterizer drops. The
    // reconciler must flip the port to SOUTH and land the endpoint on the
    // bottom border (29,24), turning the pierce into a clean upward ▲.
    const rc = sketch.Rect{ .x = 22, .y = 22, .w = 13, .h = 3 }; // north offset 7 -> x=29
    const to_p = mkPlacement(1, rc);

    var below = [_]sketch.Point{
        .{ .x = 10, .y = 19 }, .{ .x = 10, .y = 26 }, .{ .x = 29, .y = 26 }, .{ .x = 29, .y = 22 },
    };
    const north_port = sketch.Port{ .node = 1, .side = .north, .offset = 7 };
    // Precondition: the recorded (north) terminal makes the final leg pierce.
    try testing.expect(finalLegPierces(below[below.len - 2], below[below.len - 1], rc));

    const fixed = rp.reconcileTerminalSide(&below, to_p, north_port);
    try testing.expectEqual(sketch.Dir4.south, fixed.side);
    try testing.expectEqual(@as(u32, 7), fixed.offset);
    try testing.expectEqual(sketch.Point{ .x = 29, .y = 24 }, below[below.len - 1]);
    // The corrected final leg (29,26)->(29,24) enters the bottom border and
    // no longer pierces; it is a clean non-degenerate upward approach.
    try testing.expect(!finalLegPierces(below[below.len - 2], below[below.len - 1], rc));
    try expectCleanVerticalFinalApproach(&below, false);
}

test "terminal reconciliation is a no-op for an agreeing or perpendicular approach" {
    const rc = sketch.Rect{ .x = 22, .y = 22, .w = 13, .h = 3 };
    const to_p = mkPlacement(1, rc);
    const north_port = sketch.Port{ .node = 1, .side = .north, .offset = 7 };

    // Correct north approach from above: entry side == port side -> untouched.
    var above = [_]sketch.Point{ .{ .x = 29, .y = 20 }, .{ .x = 29, .y = 22 } };
    const a_fixed = rp.reconcileTerminalSide(&above, to_p, north_port);
    try testing.expectEqual(sketch.Dir4.north, a_fixed.side);
    try testing.expectEqual(sketch.Point{ .x = 29, .y = 22 }, above[above.len - 1]);

    // Perpendicular (west) entry into a north port is a different malformation,
    // out of scope for the opposite-side reconciler -> untouched.
    var side = [_]sketch.Point{ .{ .x = 25, .y = 22 }, .{ .x = 29, .y = 22 } };
    const s_fixed = rp.reconcileTerminalSide(&side, to_p, north_port);
    try testing.expectEqual(sketch.Dir4.north, s_fixed.side);
}

test "ensureBaseStub shifts a turn-at-tip descent back one cell" {
    // Foreign box far to the east; the descent shift moves AWAY from it, so
    // clearance holds. Turn-at-tip: vertical descent in the arrow's own
    // column (x=2), then a 1-cell east hop into the port at (3,9).
    const boxes = [_]sketch.NodePlacement{
        mkPlacement(1, .{ .x = 3, .y = 8, .w = 20, .h = 3 }), // target (to)
    };
    var poly = [_]sketch.Point{
        .{ .x = 70, .y = 6 }, .{ .x = 2, .y = 6 }, .{ .x = 2, .y = 9 }, .{ .x = 3, .y = 9 },
    };
    try testing.expect(rp.ensureBaseStub(&poly, &boxes, 0, 1));
    // Descent column moved 2 -> 1; final leg now (1,9)->(3,9) spans two cells
    // so the arrowhead at (2,9) is fed on its west base by the (1,9) corner.
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
    // A foreign box occupies the shifted descent column (x=1), so the shift is
    // refused and the (report-only) violation is left for the validator.
    const boxes = [_]sketch.NodePlacement{
        mkPlacement(1, .{ .x = 3, .y = 8, .w = 20, .h = 3 }),
        mkPlacement(2, .{ .x = 0, .y = 5, .w = 3, .h = 6 }), // blocks x=1 at y=6..9
    };
    var poly = [_]sketch.Point{
        .{ .x = 70, .y = 6 }, .{ .x = 2, .y = 6 }, .{ .x = 2, .y = 9 }, .{ .x = 3, .y = 9 },
    };
    try testing.expect(!rp.ensureBaseStub(&poly, &boxes, 0, 1));
    try testing.expectEqual(sketch.Point{ .x = 2, .y = 6 }, poly[1]);
}

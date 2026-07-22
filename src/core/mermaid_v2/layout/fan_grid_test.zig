//! Tests for fan_grid.zig. Discovered via fan_test.zig's `test { _ = @import }`
//! (kept in a sibling file to stay under the 500-line mermaid_v2/ cap).

const std = @import("std");
const fan = @import("fan.zig");

const testing = std.testing;
const TestGeom = struct { x: i32, y: i32, w: u32, h: u32, layer: u32 = 0 };

// -- fan_grid.zig: fan-direction-dependent gap sizing -----------------------

test "wrapWideFanIn wrap decision uses the minimal 1-cell fit gap, not h_spacing" {
    // 3 sources, width 10 each, h_spacing 4. At the fan-IN fit gap (1 cell)
    // the single-row span is 10*3 + 1*2 = 32, which fits budget 35 — so the
    // fan must NOT wrap. If the wrap decision used h_spacing (4) instead,
    // the span would be 10*3 + 4*2 = 38 > 35 and it would wrongly wrap.
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 20, .y = 10, .w = 10, .h = 3 },
        .{ .x = 0, .y = 0, .w = 10, .h = 3 },
        .{ .x = 14, .y = 0, .w = 10, .h = 3 },
        .{ .x = 28, .y = 0, .w = 10, .h = 3 },
    };
    fan.wrapWideFanIn(TestGeom, &fans, &geom, 35, 4, 2);
    try testing.expectEqual(@as(u32, 1), fans[0].rows);
}

test "wrapWideFanIn floors the placement gap at 3 when h_spacing halves to 2" {
    // 4 sources, width 10 each, h_spacing 2 (pressure-halved). fit_gap=1
    // forces a wrap (single-row span 10*4+1*3=43 > budget 30). The placed
    // grid must still separate its 2 columns by 3 cells (not h_spacing=2),
    // so the fan-IN trunk clears both box walls.
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 20, .y = 10, .w = 10, .h = 3 },
        .{ .x = 0, .y = 0, .w = 10, .h = 3 },
        .{ .x = 12, .y = 0, .w = 10, .h = 3 },
        .{ .x = 24, .y = 0, .w = 10, .h = 3 },
        .{ .x = 36, .y = 0, .w = 10, .h = 3 },
    };
    fan.wrapWideFanIn(TestGeom, &fans, &geom, 30, 2, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    // geom[1]/geom[3] land in column 0, geom[2]/geom[4] in column 1 (both
    // 10 wide, so the boxes are flush to their column edges): the gap
    // between column 0's right edge and column 1's left edge must be 3.
    const col0_right = geom[1].x + @as(i32, @intCast(geom[1].w));
    try testing.expectEqual(@as(i32, 3), geom[2].x - col0_right);
}

// -- fan_grid.zig: legacy uniform-slot grid (fan-OUT only) -------------------

test "wrapWideFanOut legacy grid centres EACH row independently under the pivot" {
    // 4 children widths 10,10,6,6, h_spacing 4, budget 30: legacy_cols =
    // (30+4)/(10+4) = 2, which is >=2 and <4, so the legacy uniform-slot
    // path fires (not the fixed-column variable-width pack). The legacy
    // grid centres every row as its own block: row 0 (widths 10,10, span
    // 24) and row 1 (widths 6,6, span 16) must NOT share the same left
    // edge — a fixed-column pack would instead reuse row 0's column x for
    // row 1 regardless of the narrower row.
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 60, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 10, .h = 3 },
        .{ .x = 14, .y = 6, .w = 10, .h = 3 },
        .{ .x = 28, .y = 6, .w = 6, .h = 3 },
        .{ .x = 38, .y = 6, .w = 6, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 30, 4, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    // Row 0 (pivot_cx=70, row span 24) is centred at x=58; row 1 (span 16)
    // is centred at x=62 — a narrower, independently-centred block.
    try testing.expectEqual(@as(i32, 58), geom[1].x);
    try testing.expectEqual(@as(i32, 72), geom[2].x);
    try testing.expectEqual(@as(i32, 62), geom[3].x);
    try testing.expectEqual(@as(i32, 72), geom[4].x);
}

// -- fan_grid.zig: P5 variable-width column pack -----------------------------

test "wrapWideFanOut P5 pack finds a 2-column layout the old widest-slot math missed (29/25/25 @ budget 58)" {
    // The historical bug: 3 super-node children 29/25/25 wide, budget 58,
    // h_spacing 4. The OLD uniform-slot formula used the widest child
    // (29) for every slot: slot_w=33, legacy_cols=(58+4)/33=1 — forcing a
    // single-column 3-row stack even though a real 2-column pack
    // (29 + gap + 25 == 58) fits. Assert the fix: exactly 2 rows, not 3.
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 100, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 29, .h = 3 },
        .{ .x = 33, .y = 6, .w = 25, .h = 3 },
        .{ .x = 62, .y = 6, .w = 25, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 58, 4, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    // Column 0 (peer1 w29, peer3 w25) and column 1 (peer2 w25), separated
    // by exactly h_spacing (4). Peer1 and peer3 share column 0's CENTRE
    // (not raw x — they differ in width, so each is centred individually).
    const p1_cx = geom[1].x + @divTrunc(@as(i32, @intCast(geom[1].w)), 2);
    const p3_cx = geom[3].x + @divTrunc(@as(i32, @intCast(geom[3].w)), 2);
    try testing.expectEqual(p1_cx, p3_cx);
    try testing.expectEqual(@as(i32, 4), geom[2].x - (geom[1].x + @as(i32, @intCast(geom[1].w))));
}

test "wrapWideFanOut variable per-column widths avoid re-overflow from 2 narrow columns" {
    // 4 children in column order 5,25,5,25 (row-major i%2): column 0 holds
    // the two width-5 children, column 1 the two width-25 children.
    // block_w = col_w[0] + gap + col_w[1] = 5+4+25 = 34, comfortably under
    // budget 40. A uniform-widest-slot formula (2*max_child_w+gap =
    // 2*25+4 = 54) would have wrongly judged this pack infeasible and
    // re-overflowed the budget — assert the ACTUAL placed span is 34, not 54.
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 100, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 5, .h = 3 },
        .{ .x = 9, .y = 6, .w = 25, .h = 3 },
        .{ .x = 38, .y = 6, .w = 5, .h = 3 },
        .{ .x = 47, .y = 6, .w = 25, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 40, 4, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    const leftmost = geom[1].x;
    const rightmost = geom[2].x + @as(i32, @intCast(geom[2].w));
    try testing.expectEqual(@as(i32, 34), rightmost - leftmost);
}

// -- fan_grid.zig: zero-feasible-column fallback -----------------------------

test "wrapWideFanOut falls back to a single column matching the legacy per-box centering" {
    // 3 children so wide (40/35/30) that even a 2-column pack overflows
    // budget 50: no cols>=2 is feasible, so the pack falls back to
    // cols=1 — every child stacked on its own row (rows==n), each
    // individually centred under the pivot exactly like the historical
    // single-column stack: x = pivot_cx - w/2 (not a shared column width).
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 100, .y = 0, .w = 20, .h = 3 },
        .{ .x = 0, .y = 6, .w = 40, .h = 3 },
        .{ .x = 44, .y = 6, .w = 35, .h = 3 },
        .{ .x = 83, .y = 6, .w = 30, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 50, 4, 2);
    try testing.expectEqual(@as(u32, 3), fans[0].rows); // one row per child == n
    const pivot_cx = geom[0].x + @divTrunc(@as(i32, @intCast(geom[0].w)), 2);
    for (1..4) |i| {
        const want_x = pivot_cx - @divTrunc(@as(i32, @intCast(geom[i].w)), 2);
        try testing.expectEqual(want_x, geom[i].x);
    }
}

// -- fan_grid.zig: single-row fit + budget-overflow grid decision (moved from
//    fan_test.zig, which built these fixtures but was testing
//    `fan.wrapWideFanOut` — a re-export of `fan_grid.wrapWideFanOut`) -------

test "wrapWideFanOut leaves a fitting fan as a single row" {
    // 3 children, each width 10, h_spacing 4 -> single-row span 38 < 80.
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 20, .y = 0, .w = 10, .h = 3 }, // pivot
        .{ .x = 0, .y = 6, .w = 10, .h = 3 },
        .{ .x = 14, .y = 6, .w = 10, .h = 3 },
        .{ .x = 28, .y = 6, .w = 10, .h = 3 },
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 80, 4, 2);
    try testing.expectEqual(@as(u32, 1), fans[0].rows);
    try testing.expectEqual(@as(i32, 6), geom[1].y);
    try testing.expectEqual(@as(i32, 6), geom[3].y);
}

test "wrapWideFanOut grids a fan that overflows the budget" {
    // 6 children, each width 20, h_spacing 4 -> single-row span
    // 6*20 + 5*4 = 140 > 60, so the fan must wrap. A downstream node
    // far below must be pushed further down to make room.
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
        .{ .edge_id = 5, .peer_idx = 5, .role = .middle },
        .{ .edge_id = 6, .peer_idx = 6, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .out, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 60, .y = 0, .w = 20, .h = 3 }, // 0: pivot
        .{ .x = 0, .y = 6, .w = 20, .h = 3 }, // 1..6: children, one row
        .{ .x = 24, .y = 6, .w = 20, .h = 3 },
        .{ .x = 48, .y = 6, .w = 20, .h = 3 },
        .{ .x = 72, .y = 6, .w = 20, .h = 3 },
        .{ .x = 96, .y = 6, .w = 20, .h = 3 },
        .{ .x = 120, .y = 6, .w = 20, .h = 3 },
        .{ .x = 60, .y = 200, .w = 20, .h = 3 }, // 7: downstream
    };
    fan.wrapWideFanOut(TestGeom, &fans, &geom, 60, 4, 2);
    try testing.expect(fans[0].rows >= 2);
    var distinct_y = std.AutoHashMapUnmanaged(i32, void).empty;
    defer distinct_y.deinit(testing.allocator);
    for (1..7) |i| try distinct_y.put(testing.allocator, geom[i].y, {});
    try testing.expect(distinct_y.count() >= 2);
    try testing.expect(geom[7].y > 200);
}

test "wrapWideFanIn centres a narrow box on its column's centre, not flush to a wide neighbour" {
    // Column 1 holds a width-25 and a width-15 member (col_w[1]=25). The
    // narrower width-15 box must be centred within column 1 (offset +5
    // from the column's left edge), not left-jammed flush against the
    // trunk side (offset 0) nor right-jammed (offset +10).
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 1, .peer_idx = 1, .role = .middle },
        .{ .edge_id = 2, .peer_idx = 2, .role = .middle },
        .{ .edge_id = 3, .peer_idx = 3, .role = .middle },
        .{ .edge_id = 4, .peer_idx = 4, .role = .middle },
    };
    var fans = [_]fan.Fan{.{ .direction = .in, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var geom = [_]TestGeom{
        .{ .x = 100, .y = 10, .w = 20, .h = 3 },
        .{ .x = 0, .y = 0, .w = 20, .h = 3 },
        .{ .x = 24, .y = 0, .w = 25, .h = 3 },
        .{ .x = 53, .y = 0, .w = 20, .h = 3 },
        .{ .x = 77, .y = 0, .w = 15, .h = 3 },
    };
    fan.wrapWideFanIn(TestGeom, &fans, &geom, 50, 4, 2);
    try testing.expectEqual(@as(u32, 2), fans[0].rows);
    // geom[2] (w25) and geom[4] (w15) share column 1.
    try testing.expectEqual(@as(i32, 5), geom[4].x - geom[2].x);
}

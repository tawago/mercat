//! score_calibration_test.zig — isolated boundary-crossing tests for the
//! fitted composite constants in score.zig (RUNG_SCALE, SWITCH_TO_*_SCALE,
//! W_INTEGRITY, W_LABEL_DROP, W_LABEL_DISPLACED). Split out of
//! score_test.zig to keep both files under the mermaid_v2 500-line cap.
//!
//! Each test reconstructs, via hand-built synthetic Sketches (dead-space-only
//! t2, so a target legibility number is exact and cheap to hit), the raw
//! t1/t2/raster numbers that budget_test.zig's "score calibration" test
//! prints for the specific seed/width pair named in the score.zig comment
//! that pins each constant's fitted window — live-verified against
//! `zig build test` output on 2026-07-07, not guessed. This lets a single
//! focused test fail the moment a constant drifts outside its documented
//! window, without needing the full 39-pair aggregate gate (which only
//! reports an overall agreement percentage, not which boundary broke).

const std = @import("std");
const sketch = @import("sketch.zig");
const score = @import("score.zig");

const eval = score.eval;

const t = std.testing;

fn testNode(id: u32, rect: sketch.Rect, cluster_id: ?u32) sketch.NodePlacement {
    return .{ .id = id, .rect = rect, .shape = .rect, .lines = &.{}, .cluster_id = cluster_id };
}

fn testSketch(bbox: sketch.Rect, nodes: []const sketch.NodePlacement, edges: []const sketch.EdgePath, clusters: []const sketch.ClusterFrame) sketch.Sketch {
    return .{
        .bbox = bbox,
        .direction = .TD,
        .nodes = nodes,
        .clusters = clusters,
        .edges = edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 100_000, .rung = 0 },
    };
}

test "RUNG_SCALE tight window: flips exactly where the fitted (28.1, 31.1) bound says (live seed numbers)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    var natural_keep = testSketch(.{ .x = 0, .y = 0, .w = 319, .h = 1 }, &one_node, &.{}, &.{});
    natural_keep.budget.rung = 0;
    var tight_lose = testSketch(.{ .x = 0, .y = 0, .w = 182, .h = 1 }, &one_node, &.{}, &.{});
    tight_lose.budget.rung = 1;
    const sc_natural_keep = try eval(a, natural_keep, .TD, 0, .{});
    const sc_tight_lose = try eval(a, tight_lose, .TD, 1, .{});
    try t.expectEqual(@as(u64, 318), sc_natural_keep.t2_legibility);
    try t.expectEqual(@as(u64, 181), sc_tight_lose.t2_legibility);
    try t.expect(sc_natural_keep.lessThan(sc_tight_lose));

    var natural_lose = testSketch(.{ .x = 0, .y = 0, .w = 363, .h = 1 }, &one_node, &.{}, &.{});
    natural_lose.budget.rung = 0;
    var tight_win = testSketch(.{ .x = 0, .y = 0, .w = 187, .h = 1 }, &one_node, &.{}, &.{});
    tight_win.budget.rung = 1;
    const sc_natural_lose = try eval(a, natural_lose, .TD, 0, .{});
    const sc_tight_win = try eval(a, tight_win, .TD, 1, .{});
    try t.expectEqual(@as(u64, 362), sc_natural_lose.t2_legibility);
    try t.expectEqual(@as(u64, 186), sc_tight_win.t2_legibility);
    try t.expect(sc_tight_win.lessThan(sc_natural_lose));
}

test "SWITCH_TO_VERTICAL_SCALE window: flips exactly where the fitted (35.4, 42.2) bound says (live seed numbers)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    var natural_lr = testSketch(.{ .x = 0, .y = 0, .w = 220, .h = 1 }, &one_node, &.{}, &.{});
    natural_lr.direction = .LR;
    natural_lr.budget.rung = 0;
    var rotated_td = testSketch(.{ .x = 0, .y = 0, .w = 100, .h = 1 }, &one_node, &.{}, &.{});
    rotated_td.direction = .TD;
    rotated_td.budget.rung = 3;
    const sc_natural_lr = try eval(a, natural_lr, .LR, 0, .{});
    const sc_rotated_td = try eval(a, rotated_td, .LR, 4, .{});
    try t.expectEqual(@as(u64, 219), sc_natural_lr.t2_legibility);
    try t.expectEqual(@as(u64, 99), sc_rotated_td.t2_legibility);
    try t.expect(sc_natural_lr.lessThan(sc_rotated_td));

    var natural_rl = testSketch(.{ .x = 0, .y = 0, .w = 876, .h = 1 }, &one_node, &.{}, &.{});
    natural_rl.direction = .RL;
    natural_rl.budget.rung = 0;
    var rotated_td2 = testSketch(.{ .x = 0, .y = 0, .w = 333, .h = 1 }, &one_node, &.{}, &.{});
    rotated_td2.direction = .TD;
    rotated_td2.budget.rung = 3;
    const sc_natural_rl = try eval(a, natural_rl, .RL, 0, .{});
    const sc_rotated_td2 = try eval(a, rotated_td2, .RL, 4, .{});
    try t.expectEqual(@as(u64, 875), sc_natural_rl.t2_legibility);
    try t.expectEqual(@as(u64, 332), sc_rotated_td2.t2_legibility);
    try t.expect(sc_rotated_td2.lessThan(sc_natural_rl));
}

test "SWITCH_TO_HORIZONTAL_SCALE lower bound: natural stays ahead at the fitted 44 (live seed numbers)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    var natural_td = testSketch(.{ .x = 0, .y = 0, .w = 131, .h = 1 }, &one_node, &.{}, &.{});
    natural_td.budget.rung = 0;
    var rotated_lr = testSketch(.{ .x = 0, .y = 0, .w = 53, .h = 1 }, &one_node, &.{}, &.{});
    rotated_lr.direction = .LR;
    rotated_lr.budget.rung = 3;
    const sc_natural_td = try eval(a, natural_td, .TD, 0, .{});
    const sc_rotated_lr = try eval(a, rotated_lr, .TD, 4, .{});
    try t.expectEqual(@as(u64, 130), sc_natural_td.t2_legibility);
    try t.expectEqual(@as(u64, 52), sc_rotated_lr.t2_legibility);
    try t.expect(sc_natural_td.lessThan(sc_rotated_lr));
}

test "W_INTEGRITY window: crosses exactly where the fitted (17098, 36200) bound says" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var overlap_nodes: [6]sketch.NodePlacement = undefined;
    for (0..3) |k| {
        const x: i32 = @intCast(10 * k);
        overlap_nodes[k * 2] = testNode(@intCast(k * 2), .{ .x = x, .y = 0, .w = 1, .h = 1 }, null);
        overlap_nodes[k * 2 + 1] = testNode(@intCast(k * 2 + 1), .{ .x = x, .y = 0, .w = 1, .h = 1 }, null);
    }
    var dirty = testSketch(.{ .x = 0, .y = 0, .w = 1598, .h = 1 }, &overlap_nodes, &.{}, &.{});
    dirty.budget.rung = 0;
    const sc_dirty = try eval(a, dirty, .TD, 0, .{ .edge_cells_lost = 9 });
    try t.expectEqual(@as(u32, 3), sc_dirty.t1_integrity);
    try t.expectEqual(@as(u64, 1595), sc_dirty.t2_legibility);

    var clean = testSketch(.{ .x = 0, .y = 0, .w = 1548, .h = 1 }, &.{}, &.{}, &.{});
    clean.budget.rung = 4;
    const sc_clean = try eval(a, clean, .TD, 1, .{});
    try t.expectEqual(@as(u32, 0), sc_clean.t1_integrity);
    try t.expectEqual(@as(u64, 1548), sc_clean.t2_legibility);

    try t.expect(sc_clean.lessThan(sc_dirty));

    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};
    const pair_node = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null),
        testNode(1, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null),
    };
    var mild_dirty = testSketch(.{ .x = 0, .y = 0, .w = 1352, .h = 1 }, &pair_node, &.{}, &.{});
    mild_dirty.budget.rung = 0;
    const sc_mild_dirty = try eval(a, mild_dirty, .TD, 0, .{});
    try t.expectEqual(@as(u32, 1), sc_mild_dirty.t1_integrity);
    try t.expectEqual(@as(u64, 1351), sc_mild_dirty.t2_legibility);

    var switched = testSketch(.{ .x = 0, .y = 0, .w = 1315, .h = 1 }, &one_node, &.{}, &.{});
    switched.direction = .LR;
    switched.budget.rung = 3;
    const sc_switched = try eval(a, switched, .TD, 4, .{});
    try t.expectEqual(@as(u64, 1314), sc_switched.t2_legibility);

    try t.expect(sc_mild_dirty.lessThan(sc_switched));
}

test "W_LABEL_DROP prices a dropped label + lost cells above the shape_zoo_td_8 legibility margin" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    var raw = testSketch(.{ .x = 0, .y = 0, .w = 617, .h = 1 }, &one_node, &.{}, &.{});
    raw.budget.rung = 0;
    var motif_packed = testSketch(.{ .x = 0, .y = 0, .w = 471, .h = 1 }, &one_node, &.{}, &.{});
    motif_packed.budget.rung = 0;

    const sc_raw = try eval(a, raw, .TD, 0, .{});
    const sc_packed_clean = try eval(a, motif_packed, .TD, 1, .{});
    try t.expectEqual(@as(u64, 616), sc_raw.t2_legibility);
    try t.expectEqual(@as(u64, 470), sc_packed_clean.t2_legibility);
    try t.expect(sc_packed_clean.lessThan(sc_raw));

    const sc_packed_dirty = try eval(a, motif_packed, .TD, 1, .{ .labels_dropped = 1, .edge_cells_lost = 3 });
    try t.expect(sc_raw.lessThan(sc_packed_dirty));
}

test "W_LABEL_DISPLACED upper bound: a displaced label still clears the natural-preference margin (shape_zoo numbers)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    var natural = testSketch(.{ .x = 0, .y = 0, .w = 617, .h = 1 }, &one_node, &.{}, &.{});
    natural.budget.rung = 0;
    var motif_packed = testSketch(.{ .x = 0, .y = 0, .w = 471, .h = 1 }, &one_node, &.{}, &.{});
    motif_packed.budget.rung = 0;
    const sc_natural = try eval(a, natural, .TD, 0, .{});
    const sc_packed = try eval(a, motif_packed, .TD, 1, .{ .labels_displaced = 1, .edge_cells_lost = 3 });
    try t.expect(score.displacesNatural(sc_packed, sc_natural));
}

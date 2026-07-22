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

// NOTE: max_width is set far above every bbox width used in this file so
// T0 fit-severity stays 0 and every comparison below is decided at T12 (the
// composite tier these tests target) — these bboxes deliberately exceed the
// 120 default other score_test.zig helpers use.
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
    // Live-verified via budget_test.zig's score-calibration debug line
    // (`zig build test`, 2026-07-07):
    //   self_loop_in_subgraph_td_6 w60 natural-vs-tight t2 = 318 vs 181
    //     (labeled preference keeps natural -> needs RUNG_SCALE[tight] > 318*16/181 = 28.11)
    //   td_with_lr_subgraph_7 w60 natural-vs-tight t2 = 362 vs 186
    //     (labeled preference flips to tight -> needs RUNG_SCALE[tight] < 362*16/186 = 31.14)
    // The shipped RUNG_SCALE[1] = 30 sits inside (28.11, 31.14); this test
    // fails the moment a future edit pushes it outside that fitted window.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    // -- self_loop_in_subgraph_td_6 w60: natural must stay ahead --------
    var natural_keep = testSketch(.{ .x = 0, .y = 0, .w = 319, .h = 1 }, &one_node, &.{}, &.{});
    natural_keep.budget.rung = 0;
    var tight_lose = testSketch(.{ .x = 0, .y = 0, .w = 182, .h = 1 }, &one_node, &.{}, &.{});
    tight_lose.budget.rung = 1;
    const sc_natural_keep = try eval(a, natural_keep, .TD, 0, .{});
    const sc_tight_lose = try eval(a, tight_lose, .TD, 1, .{});
    try t.expectEqual(@as(u64, 318), sc_natural_keep.t2_legibility);
    try t.expectEqual(@as(u64, 181), sc_tight_lose.t2_legibility);
    try t.expect(sc_natural_keep.lessThan(sc_tight_lose)); // natural wins

    // -- td_with_lr_subgraph_7 w60: tight must flip ahead ---------------
    var natural_lose = testSketch(.{ .x = 0, .y = 0, .w = 363, .h = 1 }, &one_node, &.{}, &.{});
    natural_lose.budget.rung = 0;
    var tight_win = testSketch(.{ .x = 0, .y = 0, .w = 187, .h = 1 }, &one_node, &.{}, &.{});
    tight_win.budget.rung = 1;
    const sc_natural_lose = try eval(a, natural_lose, .TD, 0, .{});
    const sc_tight_win = try eval(a, tight_win, .TD, 1, .{});
    try t.expectEqual(@as(u64, 362), sc_natural_lose.t2_legibility);
    try t.expectEqual(@as(u64, 186), sc_tight_win.t2_legibility);
    try t.expect(sc_tight_win.lessThan(sc_natural_lose)); // tight wins (flip)
}

test "SWITCH_TO_VERTICAL_SCALE window: flips exactly where the fitted (35.4, 42.2) bound says (live seed numbers)" {
    // Live-verified (cycle_lr_4 w60: natural t2=219 keeps natural over a
    // rotated t2=99 candidate; fanin_rl_6 w120: a rotated t2=332 candidate
    // FLIPS ahead of natural t2=875). Both pairs are clean (no integrity
    // violations, no raster defects), so composite == scale * t2 exactly.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    // -- cycle_lr_4 w60: source LR, natural(LR) must stay ahead of a
    //    rotated-to-TD candidate (lower bound: scale must exceed 3504/99). --
    var natural_lr = testSketch(.{ .x = 0, .y = 0, .w = 220, .h = 1 }, &one_node, &.{}, &.{});
    natural_lr.direction = .LR;
    natural_lr.budget.rung = 0;
    var rotated_td = testSketch(.{ .x = 0, .y = 0, .w = 100, .h = 1 }, &one_node, &.{}, &.{});
    rotated_td.direction = .TD;
    rotated_td.budget.rung = 4;
    const sc_natural_lr = try eval(a, natural_lr, .LR, 0, .{});
    const sc_rotated_td = try eval(a, rotated_td, .LR, 4, .{});
    try t.expectEqual(@as(u64, 219), sc_natural_lr.t2_legibility);
    try t.expectEqual(@as(u64, 99), sc_rotated_td.t2_legibility);
    try t.expect(sc_natural_lr.lessThan(sc_rotated_td)); // natural (LR) wins

    // -- fanin_rl_6 w120: source RL, rotated-to-TD candidate FLIPS ahead
    //    of natural (upper bound: scale must stay below 14000/332 = 42.2). --
    var natural_rl = testSketch(.{ .x = 0, .y = 0, .w = 876, .h = 1 }, &one_node, &.{}, &.{});
    natural_rl.direction = .RL;
    natural_rl.budget.rung = 0;
    var rotated_td2 = testSketch(.{ .x = 0, .y = 0, .w = 333, .h = 1 }, &one_node, &.{}, &.{});
    rotated_td2.direction = .TD;
    rotated_td2.budget.rung = 4;
    const sc_natural_rl = try eval(a, natural_rl, .RL, 0, .{});
    const sc_rotated_td2 = try eval(a, rotated_td2, .RL, 4, .{});
    try t.expectEqual(@as(u64, 875), sc_natural_rl.t2_legibility);
    try t.expectEqual(@as(u64, 332), sc_rotated_td2.t2_legibility);
    try t.expect(sc_rotated_td2.lessThan(sc_natural_rl)); // rotated wins (flip)
}

test "SWITCH_TO_HORIZONTAL_SCALE lower bound: natural stays ahead at the fitted 44 (live seed numbers)" {
    // Live-verified: subgraph_to_subgraph_td_6 w60 natural(TD) t2=130 keeps
    // natural over a rotated-to-LR candidate t2=52 (lower bound: scale must
    // exceed 2080/52 = 40.0; shipped 44 clears it with room).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    var natural_td = testSketch(.{ .x = 0, .y = 0, .w = 131, .h = 1 }, &one_node, &.{}, &.{});
    natural_td.budget.rung = 0;
    var rotated_lr = testSketch(.{ .x = 0, .y = 0, .w = 53, .h = 1 }, &one_node, &.{}, &.{});
    rotated_lr.direction = .LR;
    rotated_lr.budget.rung = 4;
    const sc_natural_td = try eval(a, natural_td, .TD, 0, .{});
    const sc_rotated_lr = try eval(a, rotated_lr, .TD, 4, .{});
    try t.expectEqual(@as(u64, 130), sc_natural_td.t2_legibility);
    try t.expectEqual(@as(u64, 52), sc_rotated_lr.t2_legibility);
    try t.expect(sc_natural_td.lessThan(sc_rotated_lr)); // natural wins
}

test "W_INTEGRITY window: crosses exactly where the fitted (17098, 36200) bound says" {
    // Lower bound: live-verified via budget_test.zig's score-calibration
    // debug line (microservices_layers_td_16 w90, natural-vs-truncate):
    // natural t1=3 t2=1595 (+9 raster edge-cells-lost) vs truncate t1=0
    // t2=1548 clean. The labeled preference flips to truncate -- reproduced
    // (same raw t1/t2/raster inputs, fed through the SAME eval()) to lock
    // that W_INTEGRITY's shipped value still crosses this real boundary.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Three fully-overlapping node pairs (6 nodes at 3 distinct locations,
    // each pair identical rects) -> exactly 3 node_overlap violations, with
    // covered area = 3 cells (union per pair), so dead space is exact.
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
    clean.budget.rung = 5;
    const sc_clean = try eval(a, clean, .TD, 1, .{});
    try t.expectEqual(@as(u32, 0), sc_clean.t1_integrity);
    try t.expectEqual(@as(u64, 1548), sc_clean.t2_legibility);

    try t.expect(sc_clean.lessThan(sc_dirty)); // truncate flips ahead of natural

    // Upper bound: the comment's own symbolic pairing (T1=1, t2=1351 vs a
    // horizontal-switch rival at t2=1314) -- natural must STAY ahead, i.e.
    // W_INTEGRITY must stay below 44*1314 - 16*1351 = 36200.
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
    switched.budget.rung = 4;
    const sc_switched = try eval(a, switched, .TD, 4, .{});
    try t.expectEqual(@as(u64, 1314), sc_switched.t2_legibility);

    try t.expect(sc_mild_dirty.lessThan(sc_switched)); // natural stays ahead
}

test "W_LABEL_DROP prices a dropped label + lost cells above the shape_zoo_td_8 legibility margin" {
    // Live-verified (shape_zoo_td_8, natural-vs-motif-packed, all widths):
    // raw natural t2=616 vs packed t2=470, both rung=natural (scale 16).
    // Pre-penalty the packed candidate wins by 16*(616-470) = 2336. If the
    // packed candidate ships with 1 dropped label + 3 lost edge cells (the
    // documented shape of this seed's raster defect), W_LABEL_DROP +
    // 3*W_CELL_LOST must exceed 2336 for raw to stay preferred.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    var raw = testSketch(.{ .x = 0, .y = 0, .w = 617, .h = 1 }, &one_node, &.{}, &.{});
    raw.budget.rung = 0;
    var motif_packed = testSketch(.{ .x = 0, .y = 0, .w = 471, .h = 1 }, &one_node, &.{}, &.{});
    motif_packed.budget.rung = 0;

    // Without raster defects, packed wins on pure legibility.
    const sc_raw = try eval(a, raw, .TD, 0, .{});
    const sc_packed_clean = try eval(a, motif_packed, .TD, 1, .{});
    try t.expectEqual(@as(u64, 616), sc_raw.t2_legibility);
    try t.expectEqual(@as(u64, 470), sc_packed_clean.t2_legibility);
    try t.expect(sc_packed_clean.lessThan(sc_raw));

    // With the documented 1-drop + 3-lost-cells defect, raw must win instead.
    const sc_packed_dirty = try eval(a, motif_packed, .TD, 1, .{ .labels_dropped = 1, .edge_cells_lost = 3 });
    try t.expect(sc_raw.lessThan(sc_packed_dirty));
}

test "W_LABEL_DISPLACED window: crosses exactly where the fitted [577, 608]-ish bound says (self_loop_lr_4 + shape_zoo numbers)" {
    // Lower bound (self_loop_lr_4 w60 numbers, live-verified for the plain
    // chain_wrap rung): a NEGOTIATED fold priced at CHAIN_WRAP_NEGOTIATED_SCALE
    // (44) with t2=153 undercuts a switch_direction candidate (scale 36,
    // t2=203) by 44*153 vs 36*203 = 576 on raw legibility alone. Without the
    // displaced-label penalty the fold would WRONGLY win; W_LABEL_DISPLACED
    // must exceed 576 to make the reference-endorsed switch_direction win.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one_node = [_]sketch.NodePlacement{testNode(0, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, null)};

    var fold = testSketch(.{ .x = 0, .y = 0, .w = 154, .h = 1 }, &one_node, &.{}, &.{});
    fold.budget.rung = 3; // chain_wrap; negotiated_fold overrides the scale below
    var switched = testSketch(.{ .x = 0, .y = 0, .w = 204, .h = 1 }, &one_node, &.{}, &.{});
    switched.direction = .TD;
    switched.budget.rung = 4;

    const sc_fold_clean = try score.evalScaled(a, fold, .LR, 0, .{}, true);
    const sc_switch = try eval(a, switched, .LR, 1, .{});
    try t.expectEqual(@as(u64, 153), sc_fold_clean.t2_legibility);
    try t.expectEqual(@as(u64, 203), sc_switch.t2_legibility);
    // Without the displacement penalty the (undesirable) fold wins.
    try t.expect(sc_fold_clean.lessThan(sc_switch));

    // With 1 displaced label at the shipped weight, switch_direction wins.
    const sc_fold_displaced = try score.evalScaled(a, fold, .LR, 0, .{ .labels_displaced = 1 }, true);
    try t.expect(sc_switch.lessThan(sc_fold_displaced));

    // Upper bound (shape_zoo_td_8 w120 numbers, live-verified): the
    // motif-packed candidate (t2=470) challenges natural (t2=616) at the
    // SAME rung (scale 16); with 3 lost cells + 1 displaced label it must
    // still clear NATURAL_PREFERENCE_MARGIN (128) to legally displace
    // natural, per score.displacesNatural.
    var natural = testSketch(.{ .x = 0, .y = 0, .w = 617, .h = 1 }, &one_node, &.{}, &.{});
    natural.budget.rung = 0;
    var motif_packed = testSketch(.{ .x = 0, .y = 0, .w = 471, .h = 1 }, &one_node, &.{}, &.{});
    motif_packed.budget.rung = 0;
    const sc_natural = try eval(a, natural, .TD, 0, .{});
    const sc_packed = try eval(a, motif_packed, .TD, 1, .{ .labels_displaced = 1, .edge_cells_lost = 3 });
    try t.expect(score.displacesNatural(sc_packed, sc_natural));
}

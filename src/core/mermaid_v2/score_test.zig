//! score_test.zig — unit tests for score.zig, split out to keep score.zig
//! under the mermaid_v2 500-line cap. Covers tier ordering, the fitted
//! composite semantics (integrity priced not vetoed; monotone rung
//! degradation prior; direction-infidelity floor; T0 overflow magnitude)
//! and the raw T2 metric functions.
//!
//! The 36-pair labeled-reference CALIBRATION test (which needs parse+budget)
//! lives in budget_test.zig, not here — score_test may not import parse.

const std = @import("std");
const sketch = @import("sketch.zig");
const score = @import("score.zig");

const Score = score.Score;
const eval = score.eval;
const RUNG_SCALE = score.RUNG_SCALE;
const SWITCH_SCALE_INDEX = score.SWITCH_SCALE_INDEX;
const deadSpace = score.deadSpace;
const edgeStretch = score.edgeStretch;
const bends = score.bends;
const countCrossings = score.countCrossings;

const t = std.testing;

fn testNode(id: u32, rect: sketch.Rect, cluster_id: ?u32) sketch.NodePlacement {
    return .{ .id = id, .rect = rect, .shape = .rect, .lines = &.{}, .cluster_id = cluster_id };
}

fn testEdge(id: u32, polyline: []const sketch.Point) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 1,
        .polyline = polyline,
        .port_from = .{ .node = 0, .side = .south, .offset = 0 },
        .port_to = .{ .node = 1, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    };
}

fn testSketch(bbox: sketch.Rect, nodes: []const sketch.NodePlacement, edges: []const sketch.EdgePath, clusters: []const sketch.ClusterFrame) sketch.Sketch {
    return .{
        .bbox = bbox,
        .direction = .TD,
        .nodes = nodes,
        .clusters = clusters,
        .edges = edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 120, .rung = 0 },
    };
}

test "tier ordering: t0 severity, then composite, then height, then index" {
    const base: Score = .{ .t0_fit = 0, .t1_integrity = 0, .t2_legibility = 0, .t3_height = 0, .t4_index = 0, .t12_composite = 0 };
    var mild_clip = base;
    mild_clip.t0_fit = 3;
    var bad_clip = base;
    bad_clip.t0_fit = 100;
    try t.expect(mild_clip.lessThan(bad_clip));
    try t.expectEqualStrings("t0", Score.decidingTier(mild_clip, bad_clip));
    var fitting_but_ugly = base;
    fitting_but_ugly.t12_composite = 999_999_999;
    try t.expect(fitting_but_ugly.lessThan(mild_clip));
    var worse = base;
    worse.t12_composite = 10;
    worse.t1_integrity = 7;
    try t.expect(base.lessThan(worse));
    try t.expectEqualStrings("t12", Score.decidingTier(base, worse));
    var taller = base;
    taller.t3_height = 2;
    try t.expect(base.lessThan(taller));
    try t.expectEqualStrings("t3", Score.decidingTier(base, taller));
    var later = base;
    later.t4_index = 3;
    try t.expect(base.lessThan(later));
    try t.expectEqualStrings("t4", Score.decidingTier(base, later));
    try t.expectEqualStrings("tie", Score.decidingTier(base, base));
}

test "natural-preference margin: sliver composite wins do not displace natural" {
    const natural: Score = .{ .t0_fit = 0, .t1_integrity = 0, .t2_legibility = 16, .t3_height = 13, .t4_index = 0, .t12_composite = 256 };
    var sliver = natural;
    sliver.t4_index = 1;
    sliver.t12_composite = natural.t12_composite - (score.NATURAL_PREFERENCE_MARGIN - 1);
    try t.expect(sliver.lessThan(natural));
    try t.expect(!score.displacesNatural(sliver, natural));
    var big = sliver;
    big.t12_composite = natural.t12_composite - score.NATURAL_PREFERENCE_MARGIN;
    try t.expect(score.displacesNatural(big, natural));
    var overflowing_natural = natural;
    overflowing_natural.t0_fit = 5;
    var fitting = natural;
    fitting.t4_index = 4;
    try t.expect(score.displacesNatural(fitting, overflowing_natural));
}

test "eval: integrity is a large priced cost, not a veto" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dirty_nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 5, .h = 3 }, null),
        testNode(1, .{ .x = 2, .y = 1, .w = 5, .h = 3 }, null),
    };
    const dirty = testSketch(.{ .x = 0, .y = 0, .w = 7, .h = 4 }, &dirty_nodes, &.{}, &.{});
    const s_dirty = try eval(a, dirty, .TD, 0, .{});
    try t.expect(s_dirty.t1_integrity >= 1);

    const clean_nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 5, .h = 3 }, null),
    };
    const modest = testSketch(.{ .x = 0, .y = 0, .w = 10, .h = 5 }, &clean_nodes, &.{}, &.{});
    const s_modest = try eval(a, modest, .TD, 5, .{});
    try t.expectEqual(@as(u32, 0), s_modest.t1_integrity);
    try t.expect(s_modest.lessThan(s_dirty));

    const huge = testSketch(.{ .x = 0, .y = 0, .w = 60, .h = 40 }, &clean_nodes, &.{}, &.{});
    const s_huge = try eval(a, huge, .TD, 5, .{});
    try t.expect(s_dirty.lessThan(s_huge));
}

test "eval: a lost terminal head is priced above the plain lost cell it also is" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 5, .h = 3 }, null),
    };
    const sk = testSketch(.{ .x = 0, .y = 0, .w = 7, .h = 4 }, &nodes, &.{}, &.{});
    const base = try eval(a, sk, .TD, 0, .{ .edge_cells_lost = 1 });
    const headless = try eval(a, sk, .TD, 0, .{ .edge_cells_lost = 1, .heads_lost = 1 });
    try t.expectEqual(base.t12_composite + score.W_HEAD_LOST, headless.t12_composite);
    try t.expect(base.lessThan(headless));
}

test "eval: a tip off its port is an omission, a shipped lateral arm a fabrication, and both enter the composite" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 5, .h = 3 }, null),
    };
    const sk = testSketch(.{ .x = 0, .y = 0, .w = 7, .h = 4 }, &nodes, &.{}, &.{});
    const base = try eval(a, sk, .TD, 0, .{});
    const sideways = try eval(a, sk, .TD, 0, .{ .tip_not_port = 1 });
    const armed = try eval(a, sk, .TD, 0, .{ .arm_into_head = 1 });
    try t.expectEqual(base.t12_composite + score.W_TIP_NOT_PORT, sideways.t12_composite);
    try t.expectEqual(base.t12_composite + score.W_ARM_INTO_HEAD, armed.t12_composite);
    try t.expect(base.lessThan(sideways));
    try t.expect(sideways.lessThan(armed));
    try t.expectEqual(score.W_HEAD_LOST, score.W_TIP_NOT_PORT);
    try t.expectEqual(score.W_FOREIGN_JUNCTION, score.W_ARM_INTO_HEAD);
}

test "eval: rung multiplier is a fitted degradation prior" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 4, .h = 3 }, null),
    };
    var s = testSketch(.{ .x = 0, .y = 0, .w = 8, .h = 3 }, &nodes, &.{}, &.{});
    var rung: u8 = 0;
    while (rung < RUNG_SCALE.len) : (rung += 1) {
        s.budget.rung = rung;
        const sc = try eval(a, s, .TD, rung, .{});
        try t.expectEqual(RUNG_SCALE[rung] * sc.t2_legibility, sc.t12_composite);
        if (rung > 0) try t.expect(sc.t12_composite > 16 * sc.t2_legibility);
    }
    s.budget.rung = 4;
    const late = try eval(a, s, .TD, 4, .{});
    s.budget.rung = 0;
    const early = try eval(a, s, .TD, 0, .{});
    try t.expect(early.lessThan(late));
    try t.expect(score.SWITCH_TO_HORIZONTAL_SCALE > score.SWITCH_TO_VERTICAL_SCALE);
    try t.expect(RUNG_SCALE[4] > score.SWITCH_TO_HORIZONTAL_SCALE);
}

test "eval: direction infidelity pays the direction-matched switch scale" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 4, .h = 3 }, null),
    };
    var s = testSketch(.{ .x = 0, .y = 0, .w = 8, .h = 3 }, &nodes, &.{}, &.{});
    const faithful = try eval(a, s, .TD, 0, .{});
    s.direction = .LR;
    const to_horiz = try eval(a, s, .TD, 0, .{});
    try t.expectEqual(
        score.SWITCH_TO_HORIZONTAL_SCALE * to_horiz.t2_legibility,
        to_horiz.t12_composite,
    );
    try t.expect(faithful.lessThan(to_horiz));
    s.direction = .TD;
    const to_vert = try eval(a, s, .LR, 0, .{});
    try t.expectEqual(
        score.SWITCH_TO_VERTICAL_SCALE * to_vert.t2_legibility,
        to_vert.t12_composite,
    );
    try t.expect(to_vert.t12_composite < to_horiz.t12_composite);
    try t.expectEqual(score.SWITCH_TO_VERTICAL_SCALE, RUNG_SCALE[SWITCH_SCALE_INDEX]);
}

test "fit severity is overflow magnitude, not presence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 4, .h = 3 }, null),
    };
    var mild = testSketch(.{ .x = 0, .y = 0, .w = 8, .h = 3 }, &nodes, &.{}, &.{});
    mild.budget.max_width = 6;
    var bad = mild;
    bad.bbox.w = 60;
    const s_mild = try eval(a, mild, .TD, 0, .{});
    const s_bad = try eval(a, bad, .TD, 0, .{});
    try t.expectEqual(@as(u32, 2), s_mild.t0_fit);
    try t.expectEqual(@as(u32, 54), s_bad.t0_fit);
    try t.expect(s_mild.lessThan(s_bad));
}

test "crossings counter on a known crossing pair" {
    const cross_h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const cross_v = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 } };
    const edges = [_]sketch.EdgePath{ testEdge(0, &cross_h), testEdge(1, &cross_v) };
    const s = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 11 }, &.{}, &edges, &.{});
    try t.expectEqual(@as(u64, 1), countCrossings(s));

    const touch_v = [_]sketch.Point{ .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 10 } };
    const edges2 = [_]sketch.EdgePath{ testEdge(0, &cross_h), testEdge(1, &touch_v) };
    const s2 = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 11 }, &.{}, &edges2, &.{});
    try t.expectEqual(@as(u64, 0), countCrossings(s2));

    const edges3 = [_]sketch.EdgePath{testEdge(0, &cross_h)};
    const s3 = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 11 }, &.{}, &edges3, &.{});
    try t.expectEqual(@as(u64, 0), countCrossings(s3));
}

test "dead_space does not double-count cluster frames vs member nodes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 5 }, .parent_id = null, .label = "c", .depth = 0 },
    };
    const nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 2, .y = 1, .w = 4, .h = 3 }, 0),
    };
    const covered = testSketch(.{ .x = 0, .y = 0, .w = 10, .h = 5 }, &nodes, &.{}, &clusters);
    try t.expectEqual(@as(u64, 0), try deadSpace(a, covered));

    const bare = testSketch(.{ .x = 0, .y = 0, .w = 10, .h = 5 }, &nodes, &.{}, &.{});
    try t.expectEqual(@as(u64, 50 - 12), try deadSpace(a, bare));
}

test "rail bends: rail junction counted once, one turn per off-column tap" {
    const stem = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 5 } };
    const taps = [_]sketch.Tap{
        .{ .edge = 0, .node = 10, .at = .{ .x = 0, .y = 5 }, .landing = .{ .x = 0, .y = 8 } },
        .{ .edge = 1, .node = 11, .at = .{ .x = 5, .y = 5 }, .landing = .{ .x = 5, .y = 8 } },
        .{ .edge = 2, .node = 12, .at = .{ .x = 10, .y = 5 }, .landing = .{ .x = 10, .y = 8 } },
    };
    const rails = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } },
        .taps = &taps,
        .kind = .solid,
    }};
    var s = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 9 }, &.{}, &.{}, &.{});
    s.rails = &rails;
    try t.expectEqual(@as(u64, 3), bends(s));
}

test "rail crossings: shared rail registers once, never crosses itself" {
    const stem = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 5 } };
    const taps = [_]sketch.Tap{
        .{ .edge = 0, .node = 10, .at = .{ .x = 0, .y = 5 }, .landing = .{ .x = 0, .y = 8 } },
        .{ .edge = 1, .node = 11, .at = .{ .x = 5, .y = 5 }, .landing = .{ .x = 5, .y = 8 } },
        .{ .edge = 2, .node = 12, .at = .{ .x = 10, .y = 5 }, .landing = .{ .x = 10, .y = 8 } },
    };
    const rails = [_]sketch.Rail{.{
        .pivot = 0,
        .stem = &stem,
        .crossbar = .{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } },
        .taps = &taps,
        .kind = .solid,
    }};
    const crossing_edge = [_]sketch.Point{ .{ .x = 3, .y = 0 }, .{ .x = 3, .y = 10 } };
    const edges = [_]sketch.EdgePath{testEdge(0, &crossing_edge)};
    var s = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 10 }, &.{}, &edges, &.{});
    s.rails = &rails;
    try t.expectEqual(@as(u64, 1), countCrossings(s));

    var solo = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 10 }, &.{}, &.{}, &.{});
    solo.rails = &rails;
    try t.expectEqual(@as(u64, 0), countCrossings(solo));
}

test "edge stretch and bends" {
    const straight = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 5 } };
    const detour = [_]sketch.Point{
        .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 }, .{ .x = 4, .y = 2 },
        .{ .x = 4, .y = 5 }, .{ .x = 0, .y = 5 }, .{ .x = 0, .y = 7 },
    };
    const e1 = [_]sketch.EdgePath{testEdge(0, &straight)};
    const s1 = testSketch(.{ .x = 0, .y = 0, .w = 1, .h = 6 }, &.{}, &e1, &.{});
    try t.expectEqual(@as(u64, 0), edgeStretch(s1));
    try t.expectEqual(@as(u64, 0), bends(s1));

    const e2 = [_]sketch.EdgePath{testEdge(0, &detour)};
    const s2 = testSketch(.{ .x = 0, .y = 0, .w = 5, .h = 8 }, &.{}, &e2, &.{});
    try t.expectEqual(@as(u64, 8), edgeStretch(s2));
    try t.expectEqual(@as(u64, 4), bends(s2));
}

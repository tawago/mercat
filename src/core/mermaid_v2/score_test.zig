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
    // T0 magnitude dominates everything (and is a magnitude, not a flag).
    var mild_clip = base;
    mild_clip.t0_fit = 3;
    var bad_clip = base;
    bad_clip.t0_fit = 100;
    try t.expect(mild_clip.lessThan(bad_clip));
    try t.expectEqualStrings("t0", Score.decidingTier(mild_clip, bad_clip));
    var fitting_but_ugly = base;
    fitting_but_ugly.t12_composite = 999_999_999;
    try t.expect(fitting_but_ugly.lessThan(mild_clip));
    // Composite decides below T0; raw t1/t2 fields are informational only.
    var worse = base;
    worse.t12_composite = 10;
    worse.t1_integrity = 7; // not consulted by lessThan
    try t.expect(base.lessThan(worse));
    try t.expectEqualStrings("t12", Score.decidingTier(base, worse));
    // Equal T0+composite → height; then index.
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
    // Locks the selection hysteresis (score.displacesNatural, applied by
    // entry.scoreCandidates): a challenger beating natural's composite by
    // less than NATURAL_PREFERENCE_MARGIN must NOT displace it (the tiny
    // bare-label fixture region flips on 8-48-unit slivers), while a
    // reference-endorsed-scale win (smallest live flip: 212) must.
    const natural: Score = .{ .t0_fit = 0, .t1_integrity = 0, .t2_legibility = 16, .t3_height = 13, .t4_index = 0, .t12_composite = 256 };
    var sliver = natural;
    sliver.t4_index = 1;
    sliver.t12_composite = natural.t12_composite - (score.NATURAL_PREFERENCE_MARGIN - 1);
    try t.expect(sliver.lessThan(natural)); // wins the plain argmin...
    try t.expect(!score.displacesNatural(sliver, natural)); // ...but not natural
    var big = sliver;
    big.t12_composite = natural.t12_composite - score.NATURAL_PREFERENCE_MARGIN;
    try t.expect(score.displacesNatural(big, natural));
    // T0-decided displacement (natural overflows, challenger fits) is
    // exempt from the margin even at equal composites.
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

    // Two overlapping node rects → node_overlap violation, tiny bbox.
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
    // Clean candidate whose extra dead space is WITHIN one violation's
    // price (W_INTEGRITY/SCALE_ONE = 1280 cells): clean must win.
    const modest = testSketch(.{ .x = 0, .y = 0, .w = 10, .h = 5 }, &clean_nodes, &.{}, &.{});
    const s_modest = try eval(a, modest, .TD, 5, .{});
    try t.expectEqual(@as(u32, 0), s_modest.t1_integrity);
    try t.expect(s_modest.lessThan(s_dirty));

    // Clean candidate whose dead space EXCEEDS the violation's price
    // (60x40 bbox → ~2385 dead cells > 1280): the dirty one wins — the
    // dense_multi_cycle_td_8 w120 lesson (T1=1 must not veto).
    const huge = testSketch(.{ .x = 0, .y = 0, .w = 60, .h = 40 }, &clean_nodes, &.{}, &.{});
    const s_huge = try eval(a, huge, .TD, 5, .{});
    try t.expect(s_dirty.lessThan(s_huge));
}

test "eval: rung multiplier is a fitted degradation prior" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 0, .y = 0, .w = 4, .h = 3 }, null),
    };
    var s = testSketch(.{ .x = 0, .y = 0, .w = 8, .h = 3 }, &nodes, &.{}, &.{});
    // Every rung applies exactly its RUNG_SCALE multiplier (direction kept,
    // so no infidelity floor kicks in — rung 4's slot holds the vertical
    // switch scale). NOT monotone across rungs since round 2: chain_wrap
    // (48) deliberately prices above the switch scales (36/44).
    var rung: u8 = 0;
    while (rung < RUNG_SCALE.len) : (rung += 1) {
        s.budget.rung = rung;
        const sc = try eval(a, s, .TD, rung, .{});
        try t.expectEqual(RUNG_SCALE[rung] * sc.t2_legibility, sc.t12_composite);
        if (rung > 0) try t.expect(sc.t12_composite > 16 * sc.t2_legibility);
    }
    // Natural dominates every later rung on identical geometry...
    s.budget.rung = 5;
    const late = try eval(a, s, .TD, 5, .{});
    s.budget.rung = 0;
    const early = try eval(a, s, .TD, 0, .{});
    try t.expect(early.lessThan(late));
    // ...and the two fitted inversions hold: chain_wrap > both switch
    // scales, truncate above everything.
    try t.expect(RUNG_SCALE[3] > score.SWITCH_TO_HORIZONTAL_SCALE);
    try t.expect(score.SWITCH_TO_HORIZONTAL_SCALE > score.SWITCH_TO_VERTICAL_SCALE);
    try t.expect(RUNG_SCALE[5] > RUNG_SCALE[3]);
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
    // TD source rotated to horizontal: pays the (dearer) horizontal scale.
    s.direction = .LR; // rung still 0 — the floor applies regardless of rung
    const to_horiz = try eval(a, s, .TD, 0, .{});
    try t.expectEqual(
        score.SWITCH_TO_HORIZONTAL_SCALE * to_horiz.t2_legibility,
        to_horiz.t12_composite,
    );
    try t.expect(faithful.lessThan(to_horiz));
    // LR source rotated to vertical: the cheaper vertical scale (the
    // round-2 asymmetry: fanin_rl/subgraph_rl w120 flips).
    s.direction = .TD;
    const to_vert = try eval(a, s, .LR, 0, .{});
    try t.expectEqual(
        score.SWITCH_TO_VERTICAL_SCALE * to_vert.t2_legibility,
        to_vert.t12_composite,
    );
    try t.expect(to_vert.t12_composite < to_horiz.t12_composite);
    // The rung-4 slot IS the vertical scale (eval reaches the horizontal
    // value only via the infidelity floor).
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
    mild.budget.max_width = 6; // 2 columns over
    var bad = mild;
    bad.bbox.w = 60; // 54 columns over
    const s_mild = try eval(a, mild, .TD, 0, .{});
    const s_bad = try eval(a, bad, .TD, 0, .{});
    try t.expectEqual(@as(u32, 2), s_mild.t0_fit);
    try t.expectEqual(@as(u32, 54), s_bad.t0_fit);
    // A mild clip beats a catastrophic one even when the catastrophic
    // side is otherwise "cleaner" (frenzy w60 lesson).
    try t.expect(s_mild.lessThan(s_bad));
}

test "crossings counter on a known crossing pair" {
    const cross_h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const cross_v = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 } };
    const edges = [_]sketch.EdgePath{ testEdge(0, &cross_h), testEdge(1, &cross_v) };
    const s = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 11 }, &.{}, &edges, &.{});
    try t.expectEqual(@as(u64, 1), countCrossings(s));

    // Endpoint touch (T-junction) is NOT a crossing.
    const touch_v = [_]sketch.Point{ .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 10 } };
    const edges2 = [_]sketch.EdgePath{ testEdge(0, &cross_h), testEdge(1, &touch_v) };
    const s2 = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 11 }, &.{}, &edges2, &.{});
    try t.expectEqual(@as(u64, 0), countCrossings(s2));

    // Same edge never crosses itself (pairs are between DIFFERENT edges).
    const edges3 = [_]sketch.EdgePath{testEdge(0, &cross_h)};
    const s3 = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 11 }, &.{}, &edges3, &.{});
    try t.expectEqual(@as(u64, 0), countCrossings(s3));
}

test "dead_space does not double-count cluster frames vs member nodes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Cluster frame covering the WHOLE bbox with a member node inside:
    // coverage is the bitmap union, so dead space is exactly 0.
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 5 }, .parent_id = null, .label = "c", .depth = 0 },
    };
    const nodes = [_]sketch.NodePlacement{
        testNode(0, .{ .x = 2, .y = 1, .w = 4, .h = 3 }, 0),
    };
    const covered = testSketch(.{ .x = 0, .y = 0, .w = 10, .h = 5 }, &nodes, &.{}, &clusters);
    try t.expectEqual(@as(u64, 0), try deadSpace(a, covered));

    // Same node WITHOUT the cluster: dead space = bbox area − node area.
    const bare = testSketch(.{ .x = 0, .y = 0, .w = 10, .h = 5 }, &nodes, &.{}, &.{});
    try t.expectEqual(@as(u64, 50 - 12), try deadSpace(a, bare));
}

test "bus-bar bends: trunk junction counted once, one turn per off-column tap" {
    // Stem straight (no interior flips) from pivot (0,0) down to the
    // junction (0,5); rail runs horizontally from the junction out to
    // (10,5) — a real stem→rail turn (vertical→horizontal). Three taps:
    // one ON the stem column (straight pass-through, no turn) and two
    // OFF-column (one turn each). If the trunk's junction turn were ever
    // charged per-peer (the old per-peer-polyline distortion this slice
    // removes) the total would scale with taps.len instead of staying
    // fixed at "stem bends + 1 rail turn + off-column tap count".
    const stem = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 5 } };
    const taps = [_]sketch.Tap{
        .{ .edge = 0, .node = 10, .at = .{ .x = 0, .y = 5 }, .landing = .{ .x = 0, .y = 8 } }, // on-column
        .{ .edge = 1, .node = 11, .at = .{ .x = 5, .y = 5 }, .landing = .{ .x = 5, .y = 8 } }, // off-column
        .{ .edge = 2, .node = 12, .at = .{ .x = 10, .y = 5 }, .landing = .{ .x = 10, .y = 8 } }, // off-column
    };
    const busbars = [_]sketch.BusBar{.{
        .pivot = 0,
        .stem = &stem,
        .rail = .{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } },
        .taps = &taps,
        .kind = .solid,
    }};
    var s = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 9 }, &.{}, &.{}, &.{});
    s.busbars = &busbars;
    // 0 (straight stem) + 1 (stem→rail junction turn) + 0 (on-column tap)
    // + 1 + 1 (two off-column taps) = 3. A per-peer-multiplied count would
    // instead land at 2 turns × 3 taps = 6 (or similar taps.len-scaled
    // value) — this exact assertion catches that regression.
    try t.expectEqual(@as(u64, 3), bends(s));
}

test "bus-bar crossings: shared trunk registers once, never crosses itself" {
    // A bus-bar with a rail spanning x=0..10 at y=5, plus a plain edge
    // that runs vertically through x=3 across y=0..10. The edge's
    // vertical segment strictly crosses the rail exactly once. Two of the
    // three taps' drops also run vertically near that span (x=5, x=10)
    // but verticals never cross verticals, so they must not add crossings.
    // Under the old per-peer-polyline accounting, the shared rail
    // computed as N private per-tap spans could register the same
    // foreign crossing once per overlapping sibling tap (3, one per tap)
    // instead of once for the trunk.
    const stem = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 5 } };
    const taps = [_]sketch.Tap{
        .{ .edge = 0, .node = 10, .at = .{ .x = 0, .y = 5 }, .landing = .{ .x = 0, .y = 8 } },
        .{ .edge = 1, .node = 11, .at = .{ .x = 5, .y = 5 }, .landing = .{ .x = 5, .y = 8 } },
        .{ .edge = 2, .node = 12, .at = .{ .x = 10, .y = 5 }, .landing = .{ .x = 10, .y = 8 } },
    };
    const busbars = [_]sketch.BusBar{.{
        .pivot = 0,
        .stem = &stem,
        .rail = .{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } },
        .taps = &taps,
        .kind = .solid,
    }};
    const crossing_edge = [_]sketch.Point{ .{ .x = 3, .y = 0 }, .{ .x = 3, .y = 10 } };
    const edges = [_]sketch.EdgePath{testEdge(0, &crossing_edge)};
    var s = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 10 }, &.{}, &edges, &.{});
    s.busbars = &busbars;
    try t.expectEqual(@as(u64, 1), countCrossings(s));

    // A bus-bar alone (no other edges/busbars) never crosses itself, even
    // though its taps and rail share endpoints (excluded by strictCross).
    var solo = testSketch(.{ .x = 0, .y = 0, .w = 11, .h = 10 }, &.{}, &.{}, &.{});
    solo.busbars = &busbars;
    try t.expectEqual(@as(u64, 0), countCrossings(solo));
}

test "edge stretch and bends" {
    // Straight vertical edge: stretch 0, bends 0.
    const straight = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 5 } };
    // Detour: endpoints span 7, walked 15 → stretch 8; (V,H,V,H,V) = 4 bends.
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

//! Integration tests for `recurse.zig` that need both `cluster/`- and
//! `layout/`-zone privileges (split out to keep `recurse.zig` under the
//! mermaid_v2 500-line cap). Discovered by `recurse.zig`'s own top-level
//! `test { ... }` block, the established `x.zig` -> `x_test.zig` pattern.

const std = @import("std");
const prim = @import("prim");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const coords = @import("layout.zig");
const cluster_split = @import("cluster/split.zig");
const cluster_stitch = @import("cluster/stitch.zig");
const validate = @import("layout/validate.zig");
const recurse = @import("recurse.zig");

// Two-level nested-cluster fixture shared by the frame-lockstep and
// sub-budget-shrink tests below: Top -> [S: [T: a->b->c->d (LR chain)]] ->
// (T nested inside S; S has no direct members, only the sub-cluster T).
// Laying this out recurses TWICE (S's own recursion cuts T out again), so
// it exercises the SAME `pieceFrameOverheadX(scale)` shrink applied once
// per nesting level, and the SAME `superSize` pad applied once per stitch.
fn nestedTwoLevelGraph(nodes_buf: []sem_graph.Node, edges_buf: []sem_graph.Edge, members_buf: []sem_graph.NodeId, sub_buf: []sem_graph.ClusterId, clusters_buf: []sem_graph.Cluster) sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    nodes_buf[0] = .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null };
    nodes_buf[1] = .{ .id = 1, .raw_id = "a", .label = "alphaalpha", .shape = NS.rect, .classes = &.{}, .cluster = 200 };
    nodes_buf[2] = .{ .id = 2, .raw_id = "b", .label = "bravobravo", .shape = NS.rect, .classes = &.{}, .cluster = 200 };
    nodes_buf[3] = .{ .id = 3, .raw_id = "c", .label = "charliecharlie", .shape = NS.rect, .classes = &.{}, .cluster = 200 };
    nodes_buf[4] = .{ .id = 4, .raw_id = "d", .label = "deltadelta", .shape = NS.rect, .classes = &.{}, .cluster = 200 };
    edges_buf[0] = .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[1] = .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[2] = .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[3] = .{ .id = 3, .from = 3, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    members_buf[0] = 1;
    members_buf[1] = 2;
    members_buf[2] = 3;
    members_buf[3] = 4;
    sub_buf[0] = 200;
    clusters_buf[0] = .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &.{}, .sub_clusters = sub_buf, .direction = null };
    clusters_buf[1] = .{ .id = 200, .raw_id = "T", .label = "T", .parent = 100, .members = members_buf, .sub_clusters = &.{}, .direction = .LR };
    return .{
        .direction = .TD,
        .nodes = nodes_buf,
        .edges = edges_buf,
        .clusters = clusters_buf,
        .classes = &.{},
        .arena = null,
    };
}

// Single-cluster chain fixture shared by the never-widen-baseline and
// rejected-rotation tests: Top -> [S: a->b->c->d (LR chain)], S a
// direct-membership cluster with no sub-clusters. Caller owns the buffers
// so the returned SemGraph's borrowed slices outlive the call.
fn singleClusterChainGraph(nodes_buf: []sem_graph.Node, edges_buf: []sem_graph.Edge, members_buf: []sem_graph.NodeId, clusters_buf: []sem_graph.Cluster) sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    nodes_buf[0] = .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null };
    nodes_buf[1] = .{ .id = 1, .raw_id = "a", .label = "alphaalpha", .shape = NS.rect, .classes = &.{}, .cluster = 100 };
    nodes_buf[2] = .{ .id = 2, .raw_id = "b", .label = "bravobravo", .shape = NS.rect, .classes = &.{}, .cluster = 100 };
    nodes_buf[3] = .{ .id = 3, .raw_id = "c", .label = "charliecharlie", .shape = NS.rect, .classes = &.{}, .cluster = 100 };
    nodes_buf[4] = .{ .id = 4, .raw_id = "d", .label = "deltadelta", .shape = NS.rect, .classes = &.{}, .cluster = 100 };
    edges_buf[0] = .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[1] = .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[2] = .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[3] = .{ .id = 3, .from = 3, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    members_buf[0] = 1;
    members_buf[1] = 2;
    members_buf[2] = 3;
    members_buf[3] = 4;
    clusters_buf[0] = .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = members_buf, .sub_clusters = &.{}, .direction = .LR };
    return .{
        .direction = .TD,
        .nodes = nodes_buf,
        .edges = edges_buf,
        .clusters = clusters_buf,
        .classes = &.{},
        .arena = null,
    };
}

// Frame-chrome scale lockstep across TWO recursion levels (base/types.zig's
// "cluster frame chrome scale" invariant): S's super-node wraps T's frame by
// EXACTLY `2 * prim.framePadX(scale)`, at both the natural scale (0) and a
// pressure scale (1), even though this width was threaded through two
// nested `layoutClustered` calls (outer stitches S, S's own recursion
// stitches T). If any site along the way used a different/stale scale, the
// S-T rect gap would drift from the `framePadX` formula.
test "nested cluster: outer super-node pad tracks framePadX(scale) across two recursion levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var sub_buf: [1]sem_graph.ClusterId = undefined;
    var clusters_buf: [2]sem_graph.Cluster = undefined;
    const graph = nestedTwoLevelGraph(&nodes_buf, &edges_buf, &members_buf, &sub_buf, &clusters_buf);

    for ([_]u8{ 0, 1 }) |scale| {
        // Wide budget: both S and T stay in their declared (LR) form, so the
        // rects reflect pure frame-pad arithmetic, not a flip decision.
        const s = try recurse.layoutPieces(a, graph, .{ .max_width = 400, .spacing_scale = scale });
        var t_rect: ?sketch.Rect = null;
        var s_rect: ?sketch.Rect = null;
        for (s.clusters) |cf| {
            if (cf.id == 200) t_rect = cf.rect;
            if (cf.id == 100) s_rect = cf.rect;
        }
        const expected_pad = 2 * prim.framePadX(scale);
        try std.testing.expectEqual(t_rect.?.w + expected_pad, s_rect.?.w);
        try std.testing.expectEqual(sem_graph.Direction.LR, innerLeafDirection(s, 200).?);
    }
}

/// Find a specific cluster's recorded direction (by id) in a stitched
/// Sketch, regardless of nesting depth.
fn innerLeafDirection(s: sketch.Sketch, cluster_id: sem_graph.ClusterId) ?sem_graph.Direction {
    for (s.clusters) |cf| {
        if (cf.id == cluster_id) return cf.direction;
    }
    return null;
}

// Nested sub-budget shrink is applied ONCE PER NESTING LEVEL (recurse.zig's
// "each child gets a shrunk width sub-budget per nesting level" invariant).
// T's chain is 72 columns wide declared (LR) and 22 columns wide rotated
// (TD); the flip only fires when T's EFFECTIVE budget (after subtracting
// `frameOverheadX(scale)` TWICE — once for S's frame, once for T's own,
// since T sits two cluster levels deep) is below 72:
//   scale=0: frameOverheadX(0) = 8, so the flip boundary is exactly
//            72 + 2*8 = 88 (measured against the real pipeline).
//   scale=1: frameOverheadX(1) = 4, so the flip boundary is exactly
//            72 + 2*4 = 80.
// A regression that shrinks the budget only ONCE (ignoring the second
// nesting level) would move both boundaries down by one `frameOverheadX`
// (to 80 and 76 respectively) — this test's near-boundary values (87/88,
// 79/80) fail under that regression.
test "nested cluster: width sub-budget shrinks once per nesting level (saturating)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var sub_buf: [1]sem_graph.ClusterId = undefined;
    var clusters_buf: [2]sem_graph.Cluster = undefined;
    const graph = nestedTwoLevelGraph(&nodes_buf, &edges_buf, &members_buf, &sub_buf, &clusters_buf);

    const Case = struct { mw: u32, scale: u8, want: sem_graph.Direction };
    const cases = [_]Case{
        // scale=0: boundary at mw=88.
        .{ .mw = 84, .scale = 0, .want = .TD },
        .{ .mw = 87, .scale = 0, .want = .TD },
        .{ .mw = 88, .scale = 0, .want = .LR },
        // scale=1: boundary at mw=80.
        .{ .mw = 78, .scale = 1, .want = .TD },
        .{ .mw = 79, .scale = 1, .want = .TD },
        .{ .mw = 80, .scale = 1, .want = .LR },
    };
    for (cases) |c| {
        const s = try recurse.layoutPieces(a, graph, .{ .max_width = c.mw, .spacing_scale = c.scale });
        try std.testing.expectEqual(c.want, innerLeafDirection(s, 200).?);
    }

    // Saturating subtract: an absurdly tiny top-level budget must never
    // underflow (`-|`) when shrunk twice, just log-only-overflow, not crash.
    _ = try recurse.layoutPieces(a, graph, .{ .max_width = 1, .spacing_scale = 1 });
}

// `layoutClustered`'s never-widen guard (recurse.zig's "declared child
// sizes are always computed, never widened past the baseline, even when
// any_flip is true"): force a flip (any_flip=true) via the existing B5-style
// single-subgraph fixture at a narrow width, independently recompute the
// all-declared baseline via the same `stitchOuter` the driver uses, and
// assert the public result never exceeds it.
test "declared baseline is always computed and never exceeded when a child flips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var clusters_buf: [1]sem_graph.Cluster = undefined;
    const graph = singleClusterChainGraph(&nodes_buf, &edges_buf, &members_buf, &clusters_buf);

    const opts: coords.LayoutOptions = .{ .max_width = 40 }; // B5's narrow case: the child flips.
    const sr = try cluster_split.split(a, graph);
    try std.testing.expect(!sr.isFlat());

    var child_opts = opts;
    child_opts.max_width = opts.max_width -| recurse.pieceFrameOverheadX(sr, 1, opts.spacing_scale);
    const cc = try recurse.layoutChild(a, sr.pieces[1].graph, child_opts);
    try std.testing.expect(cc.flipped != null); // any_flip is true for this fixture.

    // Independently recompute the all-declared baseline the same way the
    // driver does, using ONLY `cc.declared` (never `cc.flipped`).
    const declared_children = try a.alloc(cluster_stitch.Clustered, sr.pieces.len);
    declared_children[1] = cc.declared;
    const declared_out = try recurse.stitchOuter(a, sr, opts, declared_children);

    const result = try recurse.layoutPieces(a, graph, opts);
    try std.testing.expect(result.bbox.w <= declared_out.sketch.bbox.w);
}

// Rejected-rotation invariant (recurse.zig's "a rotation that reduces
// overflow without fully fitting is rejected"): a child whose declared form
// overflows massively (72 cols) and whose rotated form reduces the overflow
// a lot (18 cols) but still doesn't fit a very tight sub-budget (14 cols)
// must be REJECTED (kept declared), not accepted as a "less bad" candidate.
// Cross-checked against `layout/validate.Counts`: the rejected rotated
// Sketch is independently confirmed still over its own budget by the same
// validator the entry point runs (bbox_overflow), i.e. rejecting it is not
// just an internal accounting quirk — the candidate really would still
// trip the Sketch validators recurse.zig's own comment refers to.
test "rotation that reduces but does not eliminate overflow is rejected (validator cross-check)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var clusters_buf: [1]sem_graph.Cluster = undefined;
    const graph = singleClusterChainGraph(&nodes_buf, &edges_buf, &members_buf, &clusters_buf);

    const sr = try cluster_split.split(a, graph);
    // child_opts.max_width = 14: declared LR (72 cols) massively overflows;
    // rotated TD (22 cols raw, ~18 cols once packed) reduces the overflow a
    // lot but 18 > 14 still doesn't fit.
    const child_opts: coords.LayoutOptions = .{ .max_width = 14 };
    const cc = try recurse.layoutChild(a, sr.pieces[1].graph, child_opts);

    try std.testing.expect(cc.declared.sketch.bbox.w > child_opts.max_width); // declared overflows
    try std.testing.expect(cc.flipped == null); // rejected, not "less bad"

    // Recompute the rotated candidate directly (bypassing recurse's guard)
    // to confirm it is still over ITS OWN budget per the shared validator.
    var rotated_graph = sr.pieces[1].graph;
    rotated_graph.direction = prim.rotatedDirection(sr.pieces[1].graph.direction);
    const rotated = try recurse.layoutClustered(a, rotated_graph, child_opts);
    try std.testing.expect(rotated.sketch.bbox.w < cc.declared.sketch.bbox.w); // did reduce overflow...
    try std.testing.expect(rotated.sketch.bbox.w > child_opts.max_width); // ...but still overflows

    var budgeted = rotated.sketch;
    budgeted.budget = .{ .max_width = child_opts.max_width, .rung = 0 };
    const vr = try validate.validate(a, budgeted);
    const c = validate.counts(vr, budgeted);
    try std.testing.expect(c.bbox_overflow >= 1); // validator agrees: still over budget
}

// Bus-bar rail re-clamp on a dropped (super-node) tap
// (`cluster/stitch.zig`'s "Re-clamp the rail to the surviving taps +
// junction" invariant): a fan-OUT pivot P -> {A, B, D} where D lives inside
// subgraph S. On the OUTER piece (pre-stitch) the fan-busbar trunk taps A,
// B, AND the super-node standing in for S (S's real edge is a cross-border
// crossing, routed separately by `bridges.route`). `stitch` must drop the
// super-node's tap and re-clamp the rail to just the two surviving taps +
// the stem junction — if it instead kept the ORIGINAL (pre-drop) rail span,
// the rail would keep painting a dead arm out to where the super-node's tap
// used to be, past the real taps that remain.
test "stitch re-clamps a surviving bus-bar's rail past a dropped super-node tap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NS = sem_graph.NodeShape;
    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "P", .label = "P", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "A", .label = "A", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 2, .raw_id = "B", .label = "B", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 3, .raw_id = "D", .label = "D", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 0, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{3};
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{} },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const opts: coords.LayoutOptions = .{ .max_width = 400 };
    const sr = try cluster_split.split(a, graph);
    try std.testing.expect(!sr.isFlat());
    try std.testing.expectEqual(@as(usize, 1), sr.supers.len);

    const child = try recurse.layoutChild(a, sr.pieces[1].graph, opts);
    const children = try a.alloc(cluster_stitch.Clustered, sr.pieces.len);
    children[1] = child.declared;

    const fixed = try a.alloc(coords.FixedSize, sr.supers.len);
    for (sr.supers, 0..) |super, i| {
        const sz = cluster_stitch.superSize(children[super.child_piece].sketch.bbox, opts.spacing_scale, super.synthetic);
        fixed[i] = .{ .node = super.outer_node, .w = sz.w, .h = sz.h };
    }
    var outer_opts = opts;
    outer_opts.fixed_sizes = fixed;
    const outer = try coords.layout(a, sr.pieces[0].graph, outer_opts);
    children[0] = .{ .sketch = outer, .input_of = &.{} };

    // Pre-stitch: the outer fan-busbar taps all THREE peers, including the
    // super-node standing in for S — record its x so we can prove it is
    // later excluded.
    try std.testing.expectEqual(@as(usize, 1), outer.busbars.len);
    try std.testing.expectEqual(@as(usize, 3), outer.busbars[0].taps.len);
    var dropped_x: ?i32 = null;
    for (outer.busbars[0].taps) |tap| {
        if (tap.node == sr.supers[0].outer_node) dropped_x = tap.at.x;
    }
    try std.testing.expect(dropped_x != null);

    const merged = try cluster_stitch.stitch(a, sr, outer, children, opts.spacing_scale);

    // Post-stitch: the same bus-bar survives with only the two real taps —
    // and its rail must NOT reach out to the dropped tap's x, which would
    // paint a dead trunk arm ending in mid-air past the surviving taps.
    try std.testing.expectEqual(@as(usize, 1), merged.sketch.busbars.len);
    try std.testing.expectEqual(@as(usize, 2), merged.sketch.busbars[0].taps.len);
    const rail = merged.sketch.busbars[0].rail;
    try std.testing.expect(rail[0].x <= rail[1].x);
    try std.testing.expect(dropped_x.? > rail[1].x or dropped_x.? < rail[0].x);
}

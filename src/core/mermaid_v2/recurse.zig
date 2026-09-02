//! Cluster cut-layout-stitch recursion: cuts top-level subgraphs
//! (`cluster/split.zig`), recursively lays out each child, sizes each
//! super-node to its child's bbox, lays out the outer via `layout/`, then
//! stitches pieces back (`cluster/stitch.zig`). Lives at the mermaid_v2 root
//! (not under `cluster/`) since it needs both `cluster/`- and `layout/`-zone
//! import privileges to run layout; only `budget.zig` shares that pairing.
//!
//! Allowed imports (`is_recurse` zone in `tools/lint_imports.zig`): `std`,
//! `prim`, `sem_graph.zig`, `sketch.zig`, `layout.zig` + `layout/*`, `cluster/*`.

const std = @import("std");
const prim = @import("prim");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const coords = @import("layout.zig");
const cluster_split = @import("cluster/split.zig");
const cluster_stitch = @import("cluster/stitch.zig");

/// Explicit error set for the cluster recursion. Required because
/// `layoutClustered`/`layoutChild` are mutually recursive: Zig cannot resolve
/// an inferred error set through a recursion cycle. Union of the errors raised
/// by `coords.layout` (`CoordsError`), `cluster_split.split` (`OutOfMemory`),
/// and `cluster_stitch.stitch` (`StitchError`).
pub const RecurseError = coords.CoordsError || cluster_stitch.StitchError;

/// Cut the graph into pieces, lay out each piece with the flat `layout/`
/// path, then glue the finished Sketches into one. This is the only place
/// (besides `budget.zig`, which calls in here) allowed to import BOTH
/// `cluster/` (the cut/glue) and `layout/` (the running) — `cluster/` is pure
/// data work and never runs layout itself.
///
/// For a flat flowchart this is exactly the former single `coords.layout`
/// call: one piece in, one Sketch out, returned unchanged by `stitch`.
/// `opts` carries the original graph's BundlePermits (with its own scope)
/// unchanged through every recursive piece; recursion never re-derives it.
/// A cluster-free piece builds and realizes its OWN piece plan inside
/// `bundle_commit.buildReported` — the root plan's scope only tells it to.
/// @guarded-by: entry.zig "V-D-IR-07: a clustered graph's bundles ride piece plans; the root plan stays skipped"
pub fn layoutPieces(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    opts: coords.LayoutOptions,
) RecurseError!sketch.Sketch {
    return (try layoutClustered(arena, graph, opts)).sketch;
}

/// Recursively lay out a (possibly clustered, possibly nested) flowchart:
/// cut the top-level subgraphs, lay each child out the same way (so a child
/// containing sub-subgraphs recurses), size each super-node to its child's
/// finished bbox, lay out the outer flowchart, then stitch. Returns the merged
/// Sketch plus the merged→input id map the parent level needs.
pub fn layoutClustered(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    opts: coords.LayoutOptions,
) RecurseError!cluster_stitch.Clustered {
    const sr = try cluster_split.split(arena, graph);

    if (sr.isFlat()) {
        const s = try coords.layout(arena, sr.pieces[0].graph, opts);
        return .{ .sketch = s, .input_of = try identityMap(arena, s.nodes) };
    }

    // Bottom-up: lay out each child first (recursing for nested ones). Each child gets a shrunk width sub-budget per nesting level; deeper nests shrink again via a saturating subtract. @guarded-by: recurse_test.zig "nested cluster: width sub-budget shrinks once per nesting level (saturating)"
    const choices = try arena.alloc(ChildChoice, sr.pieces.len);
    var any_flip = false;
    for (sr.pieces[1..], 1..) |piece, i| {
        var child_opts = opts;
        child_opts.max_width = opts.max_width -| pieceFrameOverheadX(sr, i, opts.spacing_scale);
        choices[i] = try layoutChild(arena, piece.graph, child_opts);
        if (choices[i].flipped != null) any_flip = true;
    }

    // Outer stitch with the DECLARED child sizes — always computed, never widened past, even when any_flip is true. @guarded-by: recurse_test.zig "declared baseline is always computed and never exceeded when a child flips"
    const declared_children = try arena.alloc(cluster_stitch.Clustered, sr.pieces.len);
    for (choices[1..], 1..) |c, i| declared_children[i] = c.declared;
    const declared_out = try stitchOuter(arena, sr, opts, declared_children);

    if (!any_flip) return declared_out;

    const greedy_children = try arena.alloc(cluster_stitch.Clustered, sr.pieces.len);
    for (choices[1..], 1..) |c, i| greedy_children[i] = c.flipped orelse c.declared;
    const greedy_out = try stitchOuter(arena, sr, opts, greedy_children);

    if (greedy_out.sketch.bbox.w < declared_out.sketch.bbox.w) return greedy_out;
    return declared_out;
}

/// Size every super-node to its (chosen) child's bbox + frame padding, lay out
/// the outer flowchart with those fixed sizes so the boxes get real room, then
/// stitch the children into it. Factored out so `layoutClustered` can run it
/// twice — once with all-declared children, once with greedy-flipped — to pick
/// the globally narrower result (the overall-width non-regression guard).
pub fn stitchOuter(
    arena: std.mem.Allocator,
    sr: cluster_split.SplitResult,
    opts: coords.LayoutOptions,
    children: []cluster_stitch.Clustered,
) RecurseError!cluster_stitch.Clustered {
    const fixed = try arena.alloc(coords.FixedSize, sr.supers.len);
    for (sr.supers, 0..) |super, i| {
        const sz = cluster_stitch.superSize(children[super.child_piece].sketch.bbox, opts.spacing_scale, super.synthetic);
        const ei = cluster_stitch.entryInsetFor(sr, children, super);
        fixed[i] = .{ .node = super.outer_node, .w = sz.w + ei.wExtra(), .h = sz.h + ei.hExtra() };
    }
    var outer_opts = opts;
    outer_opts.fixed_sizes = fixed;
    const outer = try coords.layout(arena, sr.pieces[0].graph, outer_opts);
    children[0] = .{ .sketch = outer, .input_of = &.{} };
    const authored_cluster_run = if (opts.bundle_permits) |p| !p.isFlat() else false;
    return cluster_stitch.stitch(arena, sr, outer, children, opts.spacing_scale, authored_cluster_run, opts.bridge_build);
}

/// Horizontal frame chrome the child piece at `piece_idx` sits inside: zero
/// for a synthetic packing cluster (its frame is invisible), the full
/// `prim.frameOverheadX` for a real one. Same lockstep-scale rule as every
/// other frame-pad site.
pub fn pieceFrameOverheadX(sr: cluster_split.SplitResult, piece_idx: usize, scale: u32) u32 {
    for (sr.supers) |s| {
        if (s.child_piece == piece_idx) {
            return if (s.synthetic) 0 else prim.frameOverheadX(scale);
        }
    }
    return prim.frameOverheadX(scale);
}

/// A child laid out in (at most) two ways: its `declared` orientation, always;
/// and a `flipped` 90°-rotated candidate, present only when the declared form
/// overflowed its width sub-budget AND the rotation was strictly narrower and
/// fit. `layoutClustered` decides which to commit by OVERALL stitched width.
const ChildChoice = struct {
    declared: cluster_stitch.Clustered,
    flipped: ?cluster_stitch.Clustered,
};

/// Lay out one child subgraph under its own width sub-budget, producing a
/// `ChildChoice`: the DECLARED orientation always, plus a `flipped` candidate
/// when the declared form overflows AND a 90°-rotation is strictly narrower and
/// fits:
///
///   1. Lay out the child in its DECLARED direction (recursing as normal).
///   2. If it already fits its sub-budget (`bbox.w <= child_opts.max_width`),
///      there is NO flip candidate — authored intent is kept wherever it fits.
///   3. Otherwise lay out a rotated copy (TD↔LR, BT↔RL via
///      `prim.rotatedDirection`) on a struct COPY of the child `SemGraph`
///      (never mutating the split's shared arena data). Offer it as the
///      `flipped` candidate only if it is STRICTLY NARROWER than declared AND
///      actually fits the sub-budget declared overflowed. A rotation that does
///      not reduce width is never offered (per-child never-widen invariant).
///
/// IMPORTANT — the flip is only a CANDIDATE here, not a commitment. The caller
/// (`layoutClustered`) decides whether to take it by OVERALL stitched width, so
/// a child that fits its sub-budget compactly when declared yet would balloon
/// the outer flow if flipped is never chosen. This file therefore never widens
/// the child; the caller never widens the whole diagram.
///
/// RECURSION BOUND: at most 2 layout passes per child (declared + at most one
/// rotated). No feedback to the outer rung ladder; locally bounded and
/// deterministic (same input + same `max_width` ⇒ same output). Per-child flip
/// composes with the top-level `switch_direction` rung but is independent of
/// it — an inner flip can fire on the `natural` rung.
pub fn layoutChild(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    child_opts: coords.LayoutOptions,
) RecurseError!ChildChoice {
    const declared = try layoutClustered(arena, graph, child_opts);
    if (declared.sketch.bbox.w <= child_opts.max_width) {
        return .{ .declared = declared, .flipped = null };
    }

    var rotated_graph = graph;
    rotated_graph.direction = prim.rotatedDirection(graph.direction);
    const rotated = try layoutClustered(arena, rotated_graph, child_opts);

    // Offer the rotation as a candidate only when it earns its keep — strictly narrower than declared (never-widen) AND fits the sub-budget declared overflowed; a rotation that reduces overflow without fully fitting is rejected. @guarded-by: recurse_test.zig "rotation that reduces but does not eliminate overflow is rejected (validator cross-check)"
    if (rotated.sketch.bbox.w < declared.sketch.bbox.w and
        rotated.sketch.bbox.w <= child_opts.max_width)
    {
        return .{ .declared = declared, .flipped = rotated };
    }
    return .{ .declared = declared, .flipped = null };
}

/// `input_of[id] = id` over the laid-out node ids — a flat `layout()` keeps the
/// graph's node ids as its Sketch node ids.
fn identityMap(arena: std.mem.Allocator, nodes: []const sketch.NodePlacement) RecurseError![]sketch.NodeId {
    var max: sketch.NodeId = 0;
    for (nodes) |n| {
        if (n.id > max) max = n.id;
    }
    const len: usize = if (nodes.len == 0) 0 else @as(usize, max) + 1;
    const m = try arena.alloc(sketch.NodeId, len);
    for (m, 0..) |*slot, i| slot.* = @intCast(i);
    return m;
}

/// Find the inner subgraph's recorded direction in a stitched Sketch by its
/// (single) ClusterFrame. The frame carries `child.sketch.direction`, i.e. the
/// orientation the child was actually laid out in after the per-child flip.
fn innerClusterDirection(s: sketch.Sketch) ?sem_graph.Direction {
    for (s.clusters) |cf| {
        if (cf.parent_id == null) return cf.direction;
    }
    return null;
}

test "inner-flip scenario: inner LR-in-TD subgraph flips to TD at narrow width, stays LR at wide; outer stays TD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NS = sem_graph.NodeShape;
    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "a", .label = "alphaalpha", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 2, .raw_id = "b", .label = "bravobravo", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 3, .raw_id = "c", .label = "charliecharlie", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 4, .raw_id = "d", .label = "deltadelta", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 3, .from = 3, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{ 1, 2, 3, 4 };
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{}, .direction = .LR },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const narrow = try layoutPieces(a, graph, .{ .max_width = 40 });
    try std.testing.expectEqual(sem_graph.Direction.TD, narrow.direction);
    try std.testing.expectEqual(sem_graph.Direction.TD, innerClusterDirection(narrow).?);

    const wide = try layoutPieces(a, graph, .{ .max_width = 400 });
    try std.testing.expectEqual(sem_graph.Direction.TD, wide.direction);
    try std.testing.expectEqual(sem_graph.Direction.LR, innerClusterDirection(wide).?);
}

test "layoutChild never widens: rotation rejected when it does not reduce width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NS = sem_graph.NodeShape;
    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "x", .label = "wwwwwwwwwwwwwwww", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{1};
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{}, .direction = .LR },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const s = try layoutPieces(a, graph, .{ .max_width = 8 });
    try std.testing.expectEqual(sem_graph.Direction.LR, innerClusterDirection(s).?);
}

test "fitting child keeps declared direction (overall never widened by a needless flip)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NS = sem_graph.NodeShape;
    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "a", .label = "A", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 2, .raw_id = "b", .label = "B", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 3, .raw_id = "Bot", .label = "Bot", .shape = NS.rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{ 1, 2 };
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{}, .direction = .LR },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const budget: u32 = 200;
    const s = try layoutPieces(a, graph, .{ .max_width = budget });
    try std.testing.expectEqual(sem_graph.Direction.LR, innerClusterDirection(s).?);
    try std.testing.expect(s.bbox.w <= budget);
}

test {
    _ = @import("recurse_test.zig");
    _ = @import("recurse_test2.zig");
}

//! select_test3.zig — the LABEL-PLACEMENT POLICY candidate axis
//! (select_labels.zig): both variants exist, the audit re-raster honors each
//! candidate's flag, the tie order keeps the on-run placement, and the debug
//! (forced-rung) path stays pinned to `.on_run`.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger,
//! sem_graph, sketch, budget, parse, score, select, select_labels, audit,
//! raster. Aggregated from select_test2.zig.

const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const permits_mod = @import("ledger/permits.zig");
const ladder = @import("budget.zig");
const select = @import("select.zig");
const select_labels = @import("select_labels.zig");
const audit = @import("audit.zig");
const raster = @import("raster.zig");
const parse = @import("parse.zig").parse;

const LABELED_FAN =
    \\flowchart TD
    \\  Root -->|accept| Alpha
    \\  Root -->|reject| Beta
    \\  Root -->|defer| Gamma
    \\  Alpha --> Sink
    \\  Beta --> Sink
    \\  Gamma --> Sink
    \\
;

// These tests exercise label policy, not join realization; scope is forced
// to skipped_clustered so join application stays inert (the pre-absorption
// literal `false` these tests were written against).
fn permitsFor(a: std.mem.Allocator, g: @TypeOf(@as(sem_graph.SemGraph, undefined))) !ledger.JoinPermits {
    var plan = (try permits_mod.build(a, g, .joined)).plan;
    plan.scope = .skipped_clustered;
    return plan;
}

fn countPolicies(merged: []const ladder.Candidate) struct { on_run: usize, beside: usize } {
    var on_run: usize = 0;
    var beside: usize = 0;
    for (merged) |c| switch (c.sketch.label_policy) {
        .on_run => on_run += 1,
        .beside => beside += 1,
    };
    return .{ .on_run = on_run, .beside = beside };
}

test "a labeled graph yields both policies; the winner is deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, LABELED_FAN);
    const permits = try permitsFor(a, g);
    const set = try select.enumerateAll(a, g, &permits, 120);

    const counts = countPolicies(set.merged);
    try std.testing.expect(counts.on_run > 0);
    try std.testing.expect(counts.beside > 0);
    // Bounded: never more than MAX_BESIDE twins, and never more twins than
    // on-run candidates to twin.
    try std.testing.expect(counts.beside <= select_labels.MAX_BESIDE);
    try std.testing.expect(counts.beside <= counts.on_run);

    // TIE ORDER: every `.beside` twin sits BEHIND every `.on_run` candidate,
    // so the argmin's index tie-break keeps today's on-run winner.
    var seen_beside = false;
    for (set.merged) |c| {
        if (c.sketch.label_policy == .beside) seen_beside = true else try std.testing.expect(!seen_beside);
    }

    // Deterministic: the same input selects byte-identically twice.
    const w1 = try select.choose(a, g, &permits, 120, false, false, .bridge);
    const w2 = try select.choose(a, g, &permits, 120, false, false, .bridge);
    try std.testing.expectEqual(w1.final_rung, w2.final_rung);
    try std.testing.expectEqual(w1.sketch.label_policy, w2.sketch.label_policy);
    try std.testing.expectEqual(w1.sketch.bbox.w, w2.sketch.bbox.w);
    try std.testing.expectEqual(w1.sketch.bbox.h, w2.sketch.bbox.h);
}

test "an unlabeled graph generates no label-policy twins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  Root --> Alpha\n  Root --> Beta\n  Root --> Gamma\n");
    const permits = try permitsFor(a, g);
    const set = try select.enumerateAll(a, g, &permits, 120);

    try std.testing.expect(!select_labels.hasLabeledEdge(g));
    try std.testing.expectEqual(@as(usize, 0), countPolicies(set.merged).beside);
}

test "the audit re-raster honors each candidate's policy flag" {
    // The score only sees the policy through the audit's re-rasterization,
    // so a `.beside` twin must record label counts of the beside ladder —
    // no on-run placement — while its `.on_run` source may record on-run
    // placements for the very same geometry.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, LABELED_FAN);
    const permits = try permitsFor(a, g);
    const set = try select.enumerateAll(a, g, &permits, 120);

    var on_run_sketch: ?@TypeOf(set.merged[0].sketch) = null;
    var beside_sketch: ?@TypeOf(set.merged[0].sketch) = null;
    for (set.merged) |c| {
        if (c.rung != .natural) continue;
        switch (c.sketch.label_policy) {
            .on_run => if (on_run_sketch == null) {
                on_run_sketch = c.sketch;
            },
            .beside => if (beside_sketch == null) {
                beside_sketch = c.sketch;
            },
        }
    }
    try std.testing.expect(on_run_sketch != null);
    try std.testing.expect(beside_sketch != null);

    // The flag reaches the raster pass: the beside twin places NOTHING on a run.
    const rep_beside = try raster.rasterize(a, beside_sketch.?, .bridge);
    try std.testing.expectEqual(@as(u32, 0), rep_beside.labels_on_run);
    const rep_on_run = try raster.rasterize(a, on_run_sketch.?, .bridge);
    try std.testing.expect(rep_on_run.labels_on_run > 0);

    // And the audit — the scorer's only view — collects each variant's own
    // counts rather than one shared number.
    const c_beside = audit.collect(a, beside_sketch.?, .bridge);
    const c_on_run = audit.collect(a, on_run_sketch.?, .bridge);
    const moved_beside = c_beside.labels_dropped + c_beside.labels_displaced;
    const moved_on_run = c_on_run.labels_dropped + c_on_run.labels_displaced;
    try std.testing.expect(moved_on_run <= moved_beside);
}

test "the beside twin keeps the labeled fan's reserved rows" {
    // The policy axis is a RASTER-form axis, NOT a layout-budget one. The
    // fan's reserved gap rows are where a `.beside` label SITS (one per
    // dropper, x-aligned with the dropper it names), so the twin must pay the
    // same reservation. When it did not, the twin came out ~3 rows shorter and
    // the score's height tier bought that discount with labels stranded on the
    // rail row beside a dropper they do not belong to.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, LABELED_FAN);
    const permits = try permitsFor(a, g);
    const on_run = try ladder.runVariant(a, g, &permits, 120, .natural, .on_run);
    const beside = try ladder.runVariant(a, g, &permits, 120, .natural, .beside);

    try std.testing.expectEqual(prim.LabelPolicy.on_run, on_run.sketch.label_policy);
    try std.testing.expectEqual(prim.LabelPolicy.beside, beside.sketch.label_policy);
    // Same layout, same height: the twins differ only in the raster forms.
    try std.testing.expectEqual(on_run.sketch.bbox.h, beside.sketch.bbox.h);
}

test "stitching preserves the outer sketch's label policy" {
    // cluster/stitch.zig builds a FRESH merged Sketch literal; the policy is a
    // candidate property, not a piece property, so it must be carried across
    // the cut/glue. When it was dropped, every clustered / motif-packed
    // candidate rastered under the struct DEFAULT, and the whole policy axis
    // was a no-op on exactly the population where labeled fans live.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\flowchart TD
        \\  subgraph S1
        \\    A -->|alpha| B
        \\    B -->|beta| C
        \\  end
        \\  C -->|gamma| D
        \\
    ;
    const g = try parse(a, src);
    const permits = try permitsFor(a, g);
    for ([2]prim.LabelPolicy{ .on_run, .beside }) |policy| {
        const r = try ladder.runVariant(a, g, &permits, 120, .natural, policy);
        try std.testing.expect(r.sketch.clusters.len > 0); // the stitch path really ran
        try std.testing.expectEqual(policy, r.sketch.label_policy);
    }
}

test "debug paths keep the on-run policy" {
    // MERCAT_FORCE_RUNG (runForced) and the terminal all-independent
    // candidate are DEBUG/fallback renders: they stay on today's behavior so
    // an inspected render matches production's usual winner class.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, LABELED_FAN);
    const permits = try permitsFor(a, g);

    const forced = try ladder.runForced(a, g, &permits, 120, .tight);
    try std.testing.expectEqual(ladder.Rung.tight, forced.final_rung);
    try std.testing.expect(forced.sketch.label_policy == .on_run);

    const plain = try ladder.run(a, g, &permits, 120);
    try std.testing.expect(plain.sketch.label_policy == .on_run);

    const independent = try ladder.runForcedIndependent(a, g, &permits, 120);
    try std.testing.expect(independent.sketch.label_policy == .on_run);

    // score-off (the A/B escape hatch) returns the ladder incumbent, which is
    // built by that same on-run driver.
    const off = try select.choose(a, g, &permits, 120, true, false, .bridge);
    try std.testing.expect(off.sketch.label_policy == .on_run);
}

test "width pressure is free to flip the policy; both variants stay in the set" {
    // Under a squeezed budget the twins are still enumerated (the policy axis
    // is not a wide-diagram luxury), and whichever wins, the selection ships a
    // real Sketch.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, LABELED_FAN);
    const permits = try permitsFor(a, g);

    const wide = try select.enumerateAll(a, g, &permits, 120);
    const narrow = try select.enumerateAll(a, g, &permits, 40);
    try std.testing.expect(countPolicies(wide.merged).beside > 0);
    try std.testing.expect(countPolicies(narrow.merged).beside > 0);

    const w = try select.choose(a, g, &permits, 40, false, false, .bridge);
    try std.testing.expect(w.sketch.nodes.len > 0);
}

test "the audit prices the raster that ships: mode reaches collect and changes the counts" {
    // A clustered crossing scene where the two subgraph-border notations do
    // not raster identically: `.cross` welds junctions into cluster-border
    // cells that `.bridge` refuses, and the arrow-base tally differs with
    // them. Scoring must therefore see the SELECTED mode's counts, never a
    // fixed `.bridge` counterfactual.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  subgraph S1
        \\    A --> B
        \\  end
        \\  subgraph S2
        \\    C --> D
        \\  end
        \\  A --> D
        \\  C --> B
        \\
    );
    const permits = try permitsFor(a, g);
    const winner = try select.choose(a, g, &permits, 90, false, false, .cross);

    // Pricing matches shipping: the audit's counts under the selected mode
    // are exactly the shipped raster's counts under that mode.
    const shipped = try raster.rasterize(a, winner.sketch, .cross);
    const priced = audit.collect(a, winner.sketch, .cross);
    try std.testing.expectEqual(shipped.arrow_base.violations, priced.arrow_base);
    try std.testing.expectEqual(shipped.crossings.foreign_junction_violation, priced.foreign_junction);
    try std.testing.expectEqual(shipped.crossings.arrowhead_transit_violation, priced.arrowhead_transit);
    try std.testing.expectEqual(shipped.edge_cells_lost, priced.edge_cells_lost);

    // And the counterfactual is real: on this scene the `.bridge` audit
    // prices an arrow-base violation the `.cross` grid does not have.
    const counterfactual = audit.collect(a, winner.sketch, .bridge);
    try std.testing.expect(counterfactual.arrow_base != priced.arrow_base);
}

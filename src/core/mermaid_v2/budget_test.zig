//! Graph-level tests for the budget.zig rung ladder (run / enumerate /
//! runForced over parsed SemGraphs). Split from budget.zig to keep it
//! under the 500-line cap; pure-helper tests (optionsFor, rotateForRung,
//! halveAtLeastOne) stay in budget.zig where the private functions live.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const budget = @import("budget.zig");
const sem_graph = @import("sem_graph.zig");
const parse_mod = @import("parse.zig");
const score = @import("score.zig");
const select = @import("select.zig");
const audit = @import("audit.zig");

const Rung = budget.Rung;
const run = budget.run;
const hasWidthOverflow = budget.hasWidthOverflow;

// File-scope const so the returned pointer has static lifetime — the
// drivers now take `*const JoinPermits` (F6: LayoutOptions.join_permits
// must alias a plan that outlives every layout pass, never a stack copy).
const test_join_permits: ledger.JoinPermits = .{ .policy = .joined };

fn testJoinPermits() *const ledger.JoinPermits {
    return &test_join_permits;
}

test "rung 0 wins on trivial graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(a, "graph TD\nA-->B\n");
    _ = &g;

    const result = try run(a, g, testJoinPermits(), true, 120);
    try std.testing.expectEqual(Rung.natural, result.final_rung);
    try std.testing.expectEqual(@as(u8, 1), result.attempts);
    try std.testing.expect(!hasWidthOverflow(result.sketch.diagnostics));
}

test "truncate rung always returns even under impossible budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(a, "graph TD\nA-->B\nB-->C\nA-->C\n");
    _ = &g;

    // max_width = 1 — every rung overflows. Must still return. The ladder now
    // has six rungs (natural, tight, wrap_labels, chain_wrap, switch_direction,
    // truncate), so an impossible TD graph issues 6 attempts before truncate
    // wins. (chain_wrap is a no-op for TD, so it behaves like wrap_labels and
    // still overflows.)
    const result = try run(a, g, testJoinPermits(), true, 1);
    try std.testing.expectEqual(Rung.truncate, result.final_rung);
    try std.testing.expectEqual(@as(u8, 6), result.attempts);
    // Sketch is the truncate-rung output; may still report overflow.
}

test "switch_direction is rejected when rotation also overflows; declared dir kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A wide LR chain that cannot fit in either orientation at a tiny
    // budget. The ladder must NOT settle on switch_direction (which would
    // flip LR->TD): rotating still overflows, so that would be a strictly
    // bad trade. It must fall through to `truncate`, which keeps the
    // DECLARED direction (LR).
    var g = try parse_mod.parse(
        a,
        "graph LR\nA[aaaaaa]-->B[bbbbbb]-->C[cccccc]-->D[dddddd]-->E[eeeeee]\n",
    );
    _ = &g;

    const result = try run(a, g, testJoinPermits(), true, 4);
    try std.testing.expectEqual(Rung.truncate, result.final_rung);
    // Declared direction (LR) is preserved — we did not rotate to TD.
    try std.testing.expectEqual(sem_graph.Direction.LR, result.sketch.direction);
}

test "chain_wrap acceptance guard defers to rotation when rotation fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A deep LR chain whose flow axis busts a narrow budget. The serpentine
    // fold (chain_wrap rung) CAN fit it, but so can the 90° rotation: a pure
    // chain rotated to TD is a narrow vertical column that fits any reasonable
    // width. The acceptance guard (`rotationStillOverflows`) deliberately
    // yields to rotation in that case so already-rotatable chains keep their
    // byte-identical rotated result — the fold only WINS for chains rotation
    // cannot save (the corpus cicd/pr_review/chained_bidir seeds, where
    // wide-label fans + back-edges occupy the cross-axis and make the rotation
    // overflow too). Here we assert the guard's deferral: switch_direction
    // wins, not chain_wrap, and the result fits.
    var g = try parse_mod.parse(
        a,
        "graph LR\nA[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]-->E[Echo]" ++
            "-->F[Foxtrot]-->G[Golf]-->H[Hotel]\n",
    );
    _ = &g;

    const result = try run(a, g, testJoinPermits(), true, 40);
    try std.testing.expectEqual(Rung.switch_direction, result.final_rung);
    try std.testing.expect(!hasWidthOverflow(result.sketch.diagnostics));
}

test "enumerate picks the same incumbent as run and keeps every rung" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(a, "graph TD\nA-->B\nB-->C\nA-->C\n");
    _ = &g;

    // Fitting graph: incumbent must equal run()'s choice (natural).
    const ladder = try run(a, g, testJoinPermits(), true, 120);
    const enumd = try budget.enumerate(a, g, testJoinPermits(), true, 120);
    try std.testing.expectEqual(ladder.final_rung, enumd.incumbent.final_rung);
    try std.testing.expectEqual(Rung.natural, enumd.incumbent.final_rung);
    // All six rungs laid out and retained, in rung order.
    try std.testing.expectEqual(@as(usize, 6), enumd.candidates.len);
    for (enumd.candidates, 0..) |cand, i| {
        try std.testing.expectEqual(@as(Rung, @enumFromInt(@as(u8, @intCast(i)))), cand.rung);
        // Only the incumbent rung is marked accepted.
        try std.testing.expectEqual(cand.rung == enumd.incumbent.final_rung, cand.accepted);
    }
    // The incumbent's Sketch is the accepted candidate's Sketch.
    try std.testing.expectEqual(
        enumd.candidates[0].sketch.bbox,
        enumd.incumbent.sketch.bbox,
    );
}

test "enumerate matches run on a truncate-terminal graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(a, "graph TD\nA-->B\nB-->C\nA-->C\n");
    _ = &g;

    const ladder = try run(a, g, testJoinPermits(), true, 1);
    const enumd = try budget.enumerate(a, g, testJoinPermits(), true, 1);
    try std.testing.expectEqual(Rung.truncate, ladder.final_rung);
    try std.testing.expectEqual(Rung.truncate, enumd.incumbent.final_rung);
    try std.testing.expectEqual(@as(usize, 6), enumd.candidates.len);
}

test "runForced returns exactly the requested rung, bypassing acceptance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The deep LR chain from the chain_wrap-guard test: the ladder resolves
    // it to switch_direction at w40. Forcing `natural` must return the
    // natural (overflowing, declared-direction) layout anyway.
    var g = try parse_mod.parse(
        a,
        "graph LR\nA[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]-->E[Echo]" ++
            "-->F[Foxtrot]-->G[Golf]-->H[Hotel]\n",
    );
    _ = &g;

    const forced = try budget.runForced(a, g, testJoinPermits(), true, 40, .natural);
    try std.testing.expectEqual(Rung.natural, forced.final_rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, forced.sketch.direction);
    try std.testing.expect(hasWidthOverflow(forced.sketch.diagnostics));

    // Forcing switch_direction rotates even when unnecessary.
    var g2 = try parse_mod.parse(a, "graph TD\nA-->B\n");
    _ = &g2;
    const rotated = try budget.runForced(a, g2, testJoinPermits(), true, 120, .switch_direction);
    try std.testing.expectEqual(Rung.switch_direction, rotated.final_rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, rotated.sketch.direction);
}

test "enumerate never probes acceptance for post-incumbent candidates" {
    // A TD fan-out/fan-in (load balancer -> 3 workers -> shared sink): this
    // shape fits comfortably in its declared TD orientation, so the
    // incumbent is decided at .natural -- long before .chain_wrap is even
    // reached. But rotating it to LR spreads the 3-wide fan-out/fan-in layer
    // across the row and overflows the same budget (empirically checked:
    // true at w in [8,30], false from w=40 up). That combination makes
    // ladderAccepts(.chain_wrap) -- fits AND rotation-still-overflows --
    // evaluate to `true`, i.e. the post-incumbent chain_wrap rung here is
    // exactly the "would-be accepted" case the acceptance guard's rotation
    // probe exists for. If enumerate() ever probed acceptance for
    // post-incumbent candidates (e.g. by calling tryRung/ladderAccepts
    // instead of layoutRung directly), this candidate's `.accepted` would
    // flip to `true`. It must stay `false`, and it must still be present in
    // the candidate list (not dropped by a probe failure).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(a, "graph TD\nLB-->W1\nLB-->W2\nLB-->W3\nW1-->DB\nW2-->DB\nW3-->DB\nDB-->R\n");
    _ = &g;

    const width: u32 = 20;
    const enumd = try budget.enumerate(a, g, testJoinPermits(), true, width);

    // Incumbent must be decided before .chain_wrap so the chain_wrap
    // candidate below is genuinely post-incumbent scoring-only work.
    try std.testing.expect(@intFromEnum(enumd.incumbent.final_rung) < @intFromEnum(Rung.chain_wrap));
    try std.testing.expectEqual(@as(usize, 6), enumd.candidates.len);

    const chain_wrap_cand = enumd.candidates[@intFromEnum(Rung.chain_wrap)];
    const switch_cand = enumd.candidates[@intFromEnum(Rung.switch_direction)];
    try std.testing.expectEqual(Rung.chain_wrap, chain_wrap_cand.rung);
    try std.testing.expectEqual(Rung.switch_direction, switch_cand.rung);

    // Sanity-check the scenario actually exercises the interesting case:
    // chain_wrap's own layout fits, but the rotated layout still overflows.
    try std.testing.expect(!hasWidthOverflow(chain_wrap_cand.sketch.diagnostics));
    try std.testing.expect(hasWidthOverflow(switch_cand.sketch.diagnostics));

    // The invariant under test: never probed, never dropped.
    try std.testing.expect(!chain_wrap_cand.accepted);
}

test "enumerate/run always resolve an incumbent across degenerate graphs and widths" {
    // The truncate-terminal guarantee (`.incumbent = incumbent.?` in
    // enumerate() must never panic) holds because ladderAccepts always
    // returns true once rung == .truncate. Stress that across a spread of
    // degenerate graph shapes -- a lone node, disconnected nodes, disjoint
    // edge components -- and a spread of widths, including widths far too
    // small for any rung to fit cleanly.
    const graphs = [_][]const u8{
        "graph TD\nA\n",
        "graph TD\nA\nB\n",
        "graph LR\nA-->B\n",
        "graph TD\nA-->B\nC-->D\n",
    };
    const widths = [_]u32{ 1, 4, 40, 120 };

    for (graphs) |src| {
        for (widths) |w| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var g = try parse_mod.parse(a, src);
            _ = &g;

            const ladder = try run(a, g, testJoinPermits(), true, w);
            try std.testing.expect(@intFromEnum(ladder.final_rung) <= @intFromEnum(Rung.truncate));

            const enumd = try budget.enumerate(a, g, testJoinPermits(), true, w);
            try std.testing.expect(@intFromEnum(enumd.incumbent.final_rung) <= @intFromEnum(Rung.truncate));
            try std.testing.expectEqual(@as(usize, 6), enumd.candidates.len);
        }
    }
}

// ---------------------------------------------------------------------------
// Phase-2 score calibration.
//
// GROUND TRUTH, round 1: 22 (seed x width) score-vs-ladder disagreements
// whose argmin side was rendered (MERCAT_FORCE_RUNG) and labeled in the
// maintainer's private evaluation suite.
// GROUND TRUTH, round 2: 14 more labels from the round-1 score's NEW
// disagreement surface, labeled the same way. fanin_rl_6 w90 was sampled
// but its evaluation repeatedly failed to complete — excluded, not
// fabricated.
// GROUND TRUTH, round 3 (Phase 4a): 3 raw-vs-PACKED shape_zoo labels,
// scored through the LIVE path
// (select.enumerateAll + per-candidate audit.collect) so raster-time
// defects are priced exactly as in production. w120 is a documented
// known-sacrifice (see the label block below).
// The score's fitted weights (score.zig RUNG_SCALE / switch split /
// W_INTEGRITY / W_LABEL_DROP / W_CELL_LOST / T0 severity) must reproduce
// the labeled preference on >= 80% of the full 39 (ties satisfied either
// way; gate 32/39). Reads harness/inputs/*.mmd from the repo root at test
// time; skips when run outside the repo.
// ---------------------------------------------------------------------------

const RefLabel = enum { incumbent, argmin, tie };

const LabeledPair = struct {
    seed: []const u8,
    width: u32, // the `mercat -w` value; the mermaid budget is width - 2
    incumbent: Rung,
    argmin: Rung, // argmin under the PRE-calibration score (the labeled pair)
    // Phase 4a: shape_zoo pairs pit a RAW rung against a motif-PACKED
    // candidate at the same rung; candidates are matched on (rung, transform).
    incumbent_transform: budget.Transform = .raw,
    argmin_transform: budget.Transform = .raw,
    label: RefLabel,
};

const labeled_pairs = [_]LabeledPair{
    .{ .seed = "flowchart_alternating_direction_nest_td_9", .width = 60, .incumbent = .natural, .argmin = .truncate, .label = .tie },
    .{ .seed = "flowchart_ampersand_fanout_td_6", .width = 60, .incumbent = .natural, .argmin = .truncate, .label = .incumbent },
    .{ .seed = "flowchart_arrow_ends_td_6", .width = 60, .incumbent = .tight, .argmin = .truncate, .label = .incumbent },
    .{ .seed = "flowchart_chained_bidir_lr_8", .width = 90, .incumbent = .switch_direction, .argmin = .truncate, .label = .incumbent },
    .{ .seed = "flowchart_classdef_styled_td_7", .width = 120, .incumbent = .natural, .argmin = .truncate, .label = .incumbent },
    .{ .seed = "flowchart_complete_bipartite_k33_td_9", .width = 90, .incumbent = .natural, .argmin = .truncate, .label = .incumbent },
    .{ .seed = "flowchart_cycle_bt_6", .width = 90, .incumbent = .natural, .argmin = .truncate, .label = .incumbent },
    .{ .seed = "flowchart_cycle_lr_4", .width = 60, .incumbent = .natural, .argmin = .switch_direction, .label = .incumbent },
    .{ .seed = "flowchart_cycle_with_side_exit_td_6", .width = 60, .incumbent = .natural, .argmin = .truncate, .label = .incumbent },
    .{ .seed = "flowchart_decision_yes_no_td_6", .width = 120, .incumbent = .natural, .argmin = .switch_direction, .label = .incumbent },
    .{ .seed = "flowchart_decision_yes_no_td_6", .width = 60, .incumbent = .natural, .argmin = .truncate, .label = .tie },
    .{ .seed = "flowchart_dense_multi_cycle_td_8", .width = 120, .incumbent = .natural, .argmin = .switch_direction, .label = .incumbent },
    .{ .seed = "flowchart_dense_multi_cycle_td_8", .width = 60, .incumbent = .natural, .argmin = .tight, .label = .incumbent },
    .{ .seed = "flowchart_fanin_td_5", .width = 90, .incumbent = .tight, .argmin = .truncate, .label = .tie },
    .{ .seed = "flowchart_fanout_td_6", .width = 90, .incumbent = .natural, .argmin = .tight, .label = .incumbent },
    .{ .seed = "flowchart_k8s_pod_lifecycle_td_8", .width = 60, .incumbent = .tight, .argmin = .truncate, .label = .incumbent },
    .{ .seed = "flowchart_mermaid_frenzy_td_31", .width = 60, .incumbent = .truncate, .argmin = .switch_direction, .label = .incumbent },
    .{ .seed = "flowchart_mermaid_frenzy_td_31", .width = 90, .incumbent = .truncate, .argmin = .switch_direction, .label = .incumbent },
    .{ .seed = "flowchart_microservices_layers_td_16", .width = 90, .incumbent = .natural, .argmin = .truncate, .label = .argmin },
    .{ .seed = "flowchart_order_state_machine_lr_9", .width = 120, .incumbent = .natural, .argmin = .switch_direction, .label = .incumbent },
    .{ .seed = "flowchart_self_loop_lr_4", .width = 60, .incumbent = .switch_direction, .argmin = .chain_wrap, .label = .incumbent },
    .{ .seed = "flowchart_td_with_lr_subgraph_7", .width = 60, .incumbent = .natural, .argmin = .tight, .label = .argmin },
    // -- Round-2 labels ------------------------------------------------------
    .{ .seed = "flowchart_ampersand_fanout_td_6", .width = 60, .incumbent = .natural, .argmin = .tight, .label = .tie },
    .{ .seed = "flowchart_complete_bipartite_k33_td_9", .width = 90, .incumbent = .natural, .argmin = .tight, .label = .incumbent },
    .{ .seed = "flowchart_fanout_into_subgraphs_td_9", .width = 90, .incumbent = .natural, .argmin = .tight, .label = .tie },
    .{ .seed = "flowchart_microservices_layers_td_16", .width = 90, .incumbent = .natural, .argmin = .tight, .label = .argmin },
    .{ .seed = "flowchart_nested_3deep_td_10", .width = 60, .incumbent = .natural, .argmin = .tight, .label = .tie },
    .{ .seed = "flowchart_self_loop_in_subgraph_td_6", .width = 60, .incumbent = .natural, .argmin = .tight, .label = .incumbent },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 60, .incumbent = .natural, .argmin = .tight, .label = .incumbent },
    .{ .seed = "flowchart_subgraph_with_cycle_td_7", .width = 60, .incumbent = .natural, .argmin = .tight, .label = .incumbent },
    .{ .seed = "flowchart_fanin_rl_6", .width = 120, .incumbent = .natural, .argmin = .switch_direction, .label = .argmin },
    .{ .seed = "flowchart_lr_with_td_subgraph_7", .width = 120, .incumbent = .natural, .argmin = .switch_direction, .label = .tie },
    .{ .seed = "flowchart_subgraph_rl_8", .width = 120, .incumbent = .natural, .argmin = .switch_direction, .label = .argmin },
    .{ .seed = "flowchart_subgraph_to_subgraph_td_6", .width = 60, .incumbent = .natural, .argmin = .switch_direction, .label = .incumbent },
    .{ .seed = "flowchart_cicd_pipeline_lr_10", .width = 90, .incumbent = .switch_direction, .argmin = .chain_wrap, .label = .incumbent },
    .{ .seed = "flowchart_pr_review_lr_10", .width = 90, .incumbent = .switch_direction, .argmin = .chain_wrap, .label = .incumbent },
    // -- Phase-4a labels: raw natural vs the
    //    motif-PACKED natural on shape_zoo. The packed candidate drops the
    //    "no" edge label + loses 3 edge cells IDENTICALLY at every width
    //    (same packed sketch, fits every budget), so no weight window can
    //    fix w60/w90 and keep w120: the labeled w120 packed preference (5-1)
    //    is a DOCUMENTED KNOWN-SACRIFICE — an expected MISS, priced into the
    //    >=80% gate, not silently skipped. See score.W_LABEL_DROP.
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 60, .incumbent = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .incumbent },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 90, .incumbent = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .incumbent },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 120, .incumbent = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .argmin },
};

test "score calibration: >=80% agreement with the labeled reference set" {
    var inputs_dir = std.fs.cwd().openDir("harness/inputs", .{}) catch {
        // Not running from the repo root (e.g. bare `zig test` from a cache
        // dir): the corpus is unavailable, so the check cannot run.
        return error.SkipZigTest;
    };
    defer inputs_dir.close();

    var agree: u32 = 0;
    std.debug.print(
        "\nscore-calibration ({d} labeled pairs; budget = width - 2):\n" ++
            "  pair | inc(t0,t1,t2,h,C,rl,rc) | arg(t0,t1,t2,h,C,rl,rc) | score/label\n",
        .{labeled_pairs.len},
    );
    for (labeled_pairs) |pair| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const path = try std.fmt.allocPrint(a, "{s}.mmd", .{pair.seed});
        const src = try inputs_dir.readFileAlloc(a, path, 1 << 20);
        const g = try parse_mod.parse(a, src);
        // The LIVE candidate set (raw rungs + motif-packed) and the live
        // scoring path: per-candidate raster audit (Phase 4a) into eval.
        const set = try select.enumerateAll(a, g, testJoinPermits(), true, pair.width - 2);
        if (set.incumbent.final_rung != pair.incumbent and pair.incumbent_transform == .raw) {
            std.debug.print(
                "  NOTE {s} w{d}: ladder incumbent drifted to {s} (labeled {s})\n",
                .{ pair.seed, pair.width, @tagName(set.incumbent.final_rung), @tagName(pair.incumbent) },
            );
        }

        var s_inc: ?score.Score = null;
        var s_arg: ?score.Score = null;
        for (set.merged, 0..) |cand, i| {
            const is_inc = cand.rung == pair.incumbent and cand.transform == pair.incumbent_transform;
            const is_arg = cand.rung == pair.argmin and cand.transform == pair.argmin_transform;
            if (!is_inc and !is_arg) continue;
            const counts = audit.collect(a, cand.sketch);
            const sc = try score.eval(a, cand.sketch, g.direction, @intCast(i), counts);
            if (is_inc) s_inc = sc;
            if (is_arg) s_arg = sc;
        }
        const si = s_inc.?;
        const sa = s_arg.?;
        const picks_incumbent = si.lessThan(sa);
        const ok = switch (pair.label) {
            .tie => true,
            .incumbent => picks_incumbent,
            .argmin => !picks_incumbent,
        };
        if (ok) agree += 1;
        std.debug.print(
            "  {s} w{d} {s}-vs-{s}: ({d},{d},{d},{d},{d},{d},{d}) | ({d},{d},{d},{d},{d},{d},{d}) | {s}/{s} {s}\n",
            .{
                pair.seed,                                      pair.width,
                @tagName(pair.incumbent),                       @tagName(pair.argmin),
                si.t0_fit,                                      si.t1_integrity,
                si.t2_legibility,                               si.t3_height,
                si.t12_composite,                               si.r_labels_dropped,
                si.r_edge_cells_lost,                           sa.t0_fit,
                sa.t1_integrity,                                sa.t2_legibility,
                sa.t3_height,                                   sa.t12_composite,
                sa.r_labels_dropped,                            sa.r_edge_cells_lost,
                if (picks_incumbent) "incumbent" else "argmin", @tagName(pair.label),
                if (ok) "OK" else "MISS",
            },
        );
    }
    std.debug.print(
        "score-calibration: agreement {d}/{d} (gate: >= {d})\n",
        .{ agree, labeled_pairs.len, (labeled_pairs.len * 4 + 4) / 5 },
    );
    // Gate: >= 80% (32/39), ties counting as agreement.
    try std.testing.expect(@as(usize, agree) * 5 >= labeled_pairs.len * 4);
}

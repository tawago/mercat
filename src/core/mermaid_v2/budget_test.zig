const std = @import("std");
const build_options = @import("build_options");
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

const test_bundle_permits: ledger.BundlePermits = .{ .policy = .joined };

fn testBundlePermits() *const ledger.BundlePermits {
    return &test_bundle_permits;
}

test "rung 0 wins on trivial graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(a, "graph TD\nA-->B\n");
    _ = &g;

    const result = try run(a, g, testBundlePermits(), 120);
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

    const result = try run(a, g, testBundlePermits(), 1);
    try std.testing.expectEqual(Rung.truncate, result.final_rung);
    try std.testing.expectEqual(@as(u8, 5), result.attempts);
}

test "switch_direction is rejected when rotation also overflows; declared dir kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(
        a,
        "graph LR\nA[aaaaaa]-->B[bbbbbb]-->C[cccccc]-->D[dddddd]-->E[eeeeee]\n",
    );
    _ = &g;

    const result = try run(a, g, testBundlePermits(), 4);
    try std.testing.expectEqual(Rung.truncate, result.final_rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, result.sketch.direction);
}

test "a deep LR chain resolves to switch_direction when rotation fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(
        a,
        "graph LR\nA[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]-->E[Echo]" ++
            "-->F[Foxtrot]-->G[Golf]-->H[Hotel]\n",
    );
    _ = &g;

    const result = try run(a, g, testBundlePermits(), 40);
    try std.testing.expectEqual(Rung.switch_direction, result.final_rung);
    try std.testing.expect(!hasWidthOverflow(result.sketch.diagnostics));
}

test "enumerate picks the same incumbent as run and keeps every rung" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(a, "graph TD\nA-->B\nB-->C\nA-->C\n");
    _ = &g;

    const ladder = try run(a, g, testBundlePermits(), 120);
    const enumd = try budget.enumerate(a, g, testBundlePermits(), 120);
    try std.testing.expectEqual(ladder.final_rung, enumd.incumbent.final_rung);
    try std.testing.expectEqual(Rung.natural, enumd.incumbent.final_rung);
    try std.testing.expectEqual(@as(usize, 5), enumd.candidates.len);
    for (enumd.candidates, 0..) |cand, i| {
        try std.testing.expectEqual(@as(Rung, @enumFromInt(@as(u8, @intCast(i)))), cand.rung);
        try std.testing.expectEqual(cand.rung == enumd.incumbent.final_rung, cand.accepted);
    }
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

    const ladder = try run(a, g, testBundlePermits(), 1);
    const enumd = try budget.enumerate(a, g, testBundlePermits(), 1);
    try std.testing.expectEqual(Rung.truncate, ladder.final_rung);
    try std.testing.expectEqual(Rung.truncate, enumd.incumbent.final_rung);
    try std.testing.expectEqual(@as(usize, 5), enumd.candidates.len);
}

test "runForced returns exactly the requested rung, bypassing acceptance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var g = try parse_mod.parse(
        a,
        "graph LR\nA[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]-->E[Echo]" ++
            "-->F[Foxtrot]-->G[Golf]-->H[Hotel]\n",
    );
    _ = &g;

    const forced = try budget.runForced(a, g, testBundlePermits(), 40, .natural);
    try std.testing.expectEqual(Rung.natural, forced.final_rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, forced.sketch.direction);
    try std.testing.expect(hasWidthOverflow(forced.sketch.diagnostics));

    var g2 = try parse_mod.parse(a, "graph TD\nA-->B\n");
    _ = &g2;
    const rotated = try budget.runForced(a, g2, testBundlePermits(), 120, .switch_direction);
    try std.testing.expectEqual(Rung.switch_direction, rotated.final_rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, rotated.sketch.direction);
}

test "enumerate/run always resolve an incumbent across degenerate graphs and widths" {
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

            const ladder = try run(a, g, testBundlePermits(), w);
            try std.testing.expect(@intFromEnum(ladder.final_rung) <= @intFromEnum(Rung.truncate));

            const enumd = try budget.enumerate(a, g, testBundlePermits(), w);
            try std.testing.expect(@intFromEnum(enumd.incumbent.final_rung) <= @intFromEnum(Rung.truncate));
            try std.testing.expectEqual(@as(usize, 5), enumd.candidates.len);
        }
    }
}

const RefLabel = enum { incumbent, argmin, tie };

const LabeledPair = struct {
    seed: []const u8,
    width: u32,
    incumbent: Rung,
    argmin: Rung,
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
    .{ .seed = "flowchart_td_with_lr_subgraph_7", .width = 60, .incumbent = .natural, .argmin = .tight, .label = .argmin },
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
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 60, .incumbent = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .incumbent },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 90, .incumbent = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .incumbent },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 120, .incumbent = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .argmin },
};

test "score calibration: >=80% agreement with the labeled reference set" {
    const inputs_path = build_options.calibration_inputs orelse return error.SkipZigTest;
    var inputs_dir = std.fs.cwd().openDir(inputs_path, .{}) catch return error.SkipZigTest;
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
        const set = try select.enumerateAll(a, g, testBundlePermits(), pair.width - 2);
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
            const counts = audit.collect(a, cand.sketch, .bridge);
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
    try std.testing.expect(@as(usize, agree) * 5 >= labeled_pairs.len * 4);
}

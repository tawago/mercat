const std = @import("std");
const build_options = @import("build_options");
const ledger = @import("base/ledger.zig");
const budget = @import("budget.zig");
const sem_graph = @import("sem_graph.zig");
const parse_mod = @import("parse.zig");
const score = @import("score.zig");
const select = @import("select.zig");

const Rung = budget.Rung;
const hasWidthOverflow = budget.hasWidthOverflow;

const test_bundle_permits: ledger.BundlePermits = .{ .policy = .joined };

fn testBundlePermits() *const ledger.BundlePermits {
    return &test_bundle_permits;
}

fn firstFit(a: std.mem.Allocator, src: []const u8, width: u32) !budget.Candidate {
    const g = try parse_mod.parse(a, src);
    return budget.firstFit(try budget.enumerate(a, g, testBundlePermits(), width));
}

test "natural fits a trivial graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try firstFit(arena.allocator(), "graph TD\nA-->B\n", 120);
    try std.testing.expectEqual(Rung.natural, result.rung);
    try std.testing.expect(!hasWidthOverflow(result.sketch.diagnostics));
}

test "truncate is the first fit under an impossible budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try firstFit(arena.allocator(), "graph TD\nA-->B\nB-->C\nA-->C\n", 1);
    try std.testing.expectEqual(Rung.truncate, result.rung);
}

test "switch_direction does not fit when rotation also overflows; declared direction kept" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try firstFit(arena.allocator(), "graph LR\nA[aaaaaa]-->B[bbbbbb]-->C[cccccc]-->D[dddddd]-->E[eeeeee]\n", 4);
    try std.testing.expectEqual(Rung.truncate, result.rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, result.sketch.direction);
}

test "a deep LR chain first fits at switch_direction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try firstFit(
        arena.allocator(),
        "graph LR\nA[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]-->E[Echo]" ++
            "-->F[Foxtrot]-->G[Golf]-->H[Hotel]\n",
        40,
    );
    try std.testing.expectEqual(Rung.switch_direction, result.rung);
    try std.testing.expect(!hasWidthOverflow(result.sketch.diagnostics));
}

test "enumerate lays out every rung in rung order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parse_mod.parse(a, "graph TD\nA-->B\nB-->C\nA-->C\n");
    for ([_]u32{ 1, 120 }) |w| {
        const candidates = try budget.enumerate(a, g, testBundlePermits(), w);
        try std.testing.expectEqual(@as(usize, 5), candidates.len);
        for (candidates, 0..) |cand, i| {
            try std.testing.expectEqual(@as(Rung, @enumFromInt(@as(u8, @intCast(i)))), cand.rung);
            try std.testing.expectEqual(budget.Transform.raw, cand.transform);
        }
    }
}

test "runForced returns exactly the requested rung, fitting or not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse_mod.parse(
        a,
        "graph LR\nA[Alpha]-->B[Bravo]-->C[Charlie]-->D[Delta]-->E[Echo]" ++
            "-->F[Foxtrot]-->G[Golf]-->H[Hotel]\n",
    );
    const forced = try budget.runForced(a, g, testBundlePermits(), 40, .natural);
    try std.testing.expectEqual(Rung.natural, forced.rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, forced.sketch.direction);
    try std.testing.expect(hasWidthOverflow(forced.sketch.diagnostics));

    const g2 = try parse_mod.parse(a, "graph TD\nA-->B\n");
    const rotated = try budget.runForced(a, g2, testBundlePermits(), 120, .switch_direction);
    try std.testing.expectEqual(Rung.switch_direction, rotated.rung);
    try std.testing.expectEqual(sem_graph.Direction.LR, rotated.sketch.direction);
}

test "every degenerate graph has a first fit at every width" {
    const graphs = [_][]const u8{
        "graph TD\nA\n",
        "graph TD\nA\nB\n",
        "graph LR\nA-->B\n",
        "graph TD\nA-->B\nC-->D\n",
    };
    for (graphs) |src| {
        for ([_]u32{ 1, 4, 40, 120 }) |w| {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = try firstFit(arena.allocator(), src, w);
        }
    }
}

const RefLabel = enum { first_fit, argmin, tie };

const LabeledPair = struct {
    seed: []const u8,
    width: u32,
    first_fit: Rung,
    argmin: Rung,
    argmin_transform: budget.Transform = .raw,
    label: RefLabel,
};

const labeled_pairs = [_]LabeledPair{
    .{ .seed = "flowchart_alternating_direction_nest_td_9", .width = 60, .first_fit = .natural, .argmin = .truncate, .label = .tie },
    .{ .seed = "flowchart_ampersand_fanout_td_6", .width = 60, .first_fit = .natural, .argmin = .truncate, .label = .first_fit },
    .{ .seed = "flowchart_arrow_ends_td_6", .width = 60, .first_fit = .tight, .argmin = .truncate, .label = .first_fit },
    .{ .seed = "flowchart_chained_bidir_lr_8", .width = 90, .first_fit = .switch_direction, .argmin = .truncate, .label = .first_fit },
    .{ .seed = "flowchart_classdef_styled_td_7", .width = 120, .first_fit = .natural, .argmin = .truncate, .label = .first_fit },
    .{ .seed = "flowchart_complete_bipartite_k33_td_9", .width = 90, .first_fit = .natural, .argmin = .truncate, .label = .first_fit },
    .{ .seed = "flowchart_cycle_bt_6", .width = 90, .first_fit = .natural, .argmin = .truncate, .label = .first_fit },
    .{ .seed = "flowchart_cycle_lr_4", .width = 60, .first_fit = .natural, .argmin = .switch_direction, .label = .first_fit },
    .{ .seed = "flowchart_cycle_with_side_exit_td_6", .width = 60, .first_fit = .natural, .argmin = .truncate, .label = .first_fit },
    .{ .seed = "flowchart_decision_yes_no_td_6", .width = 120, .first_fit = .natural, .argmin = .switch_direction, .label = .first_fit },
    .{ .seed = "flowchart_decision_yes_no_td_6", .width = 60, .first_fit = .natural, .argmin = .truncate, .label = .tie },
    .{ .seed = "flowchart_dense_multi_cycle_td_8", .width = 120, .first_fit = .natural, .argmin = .switch_direction, .label = .first_fit },
    .{ .seed = "flowchart_dense_multi_cycle_td_8", .width = 60, .first_fit = .natural, .argmin = .tight, .label = .first_fit },
    .{ .seed = "flowchart_fanin_td_5", .width = 90, .first_fit = .tight, .argmin = .truncate, .label = .tie },
    .{ .seed = "flowchart_fanout_td_6", .width = 90, .first_fit = .natural, .argmin = .tight, .label = .first_fit },
    .{ .seed = "flowchart_k8s_pod_lifecycle_td_8", .width = 60, .first_fit = .tight, .argmin = .truncate, .label = .first_fit },
    .{ .seed = "flowchart_mermaid_frenzy_td_31", .width = 60, .first_fit = .truncate, .argmin = .switch_direction, .label = .first_fit },
    .{ .seed = "flowchart_mermaid_frenzy_td_31", .width = 90, .first_fit = .truncate, .argmin = .switch_direction, .label = .first_fit },
    .{ .seed = "flowchart_microservices_layers_td_16", .width = 90, .first_fit = .natural, .argmin = .truncate, .label = .argmin },
    .{ .seed = "flowchart_order_state_machine_lr_9", .width = 120, .first_fit = .natural, .argmin = .switch_direction, .label = .first_fit },
    .{ .seed = "flowchart_td_with_lr_subgraph_7", .width = 60, .first_fit = .natural, .argmin = .tight, .label = .argmin },
    .{ .seed = "flowchart_ampersand_fanout_td_6", .width = 60, .first_fit = .natural, .argmin = .tight, .label = .tie },
    .{ .seed = "flowchart_complete_bipartite_k33_td_9", .width = 90, .first_fit = .natural, .argmin = .tight, .label = .first_fit },
    .{ .seed = "flowchart_fanout_into_subgraphs_td_9", .width = 90, .first_fit = .natural, .argmin = .tight, .label = .tie },
    .{ .seed = "flowchart_microservices_layers_td_16", .width = 90, .first_fit = .natural, .argmin = .tight, .label = .argmin },
    .{ .seed = "flowchart_nested_3deep_td_10", .width = 60, .first_fit = .natural, .argmin = .tight, .label = .tie },
    .{ .seed = "flowchart_self_loop_in_subgraph_td_6", .width = 60, .first_fit = .natural, .argmin = .tight, .label = .first_fit },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 60, .first_fit = .natural, .argmin = .tight, .label = .first_fit },
    .{ .seed = "flowchart_subgraph_with_cycle_td_7", .width = 60, .first_fit = .natural, .argmin = .tight, .label = .first_fit },
    .{ .seed = "flowchart_fanin_rl_6", .width = 120, .first_fit = .natural, .argmin = .switch_direction, .label = .argmin },
    .{ .seed = "flowchart_lr_with_td_subgraph_7", .width = 120, .first_fit = .natural, .argmin = .switch_direction, .label = .tie },
    .{ .seed = "flowchart_subgraph_rl_8", .width = 120, .first_fit = .natural, .argmin = .switch_direction, .label = .argmin },
    .{ .seed = "flowchart_subgraph_to_subgraph_td_6", .width = 60, .first_fit = .natural, .argmin = .switch_direction, .label = .first_fit },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 60, .first_fit = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .first_fit },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 90, .first_fit = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .first_fit },
    .{ .seed = "flowchart_shape_zoo_td_8", .width = 120, .first_fit = .natural, .argmin = .natural, .argmin_transform = .motif_pack, .label = .argmin },
};

test "score calibration: >=80% agreement with the labeled reference set" {
    const inputs_path = build_options.calibration_inputs orelse return error.SkipZigTest;
    var inputs_dir = std.fs.cwd().openDir(inputs_path, .{}) catch return error.SkipZigTest;
    defer inputs_dir.close();

    var agree: u32 = 0;
    std.debug.print(
        "\nscore-calibration ({d} labeled pairs; budget = width - 2):\n" ++
            "  pair | fit(t0,t1,t2,h,C) | arg(t0,t1,t2,h,C) | score/label\n",
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
        const fit = budget.firstFit(set).rung;
        if (fit != pair.first_fit) {
            std.debug.print(
                "  NOTE {s} w{d}: first fit drifted to {s} (labeled {s})\n",
                .{ pair.seed, pair.width, @tagName(fit), @tagName(pair.first_fit) },
            );
        }

        var s_fit: ?score.Score = null;
        var s_arg: ?score.Score = null;
        for (set, 0..) |cand, i| {
            const is_fit = cand.rung == pair.first_fit and cand.transform == .raw;
            const is_arg = cand.rung == pair.argmin and cand.transform == pair.argmin_transform;
            if (!is_fit and !is_arg) continue;
            const counts = try select.audit(a, cand.sketch, .bridge);
            const sc = try score.eval(a, cand.sketch, g.direction, @intCast(i), counts);
            if (is_fit) s_fit = sc;
            if (is_arg) s_arg = sc;
        }
        const si = s_fit.?;
        const sa = s_arg.?;
        const picks_first_fit = si.lessThan(sa);
        const ok = switch (pair.label) {
            .tie => true,
            .first_fit => picks_first_fit,
            .argmin => !picks_first_fit,
        };
        if (ok) agree += 1;
        std.debug.print(
            "  {s} w{d} {s}-vs-{s}: ({d},{d},{d},{d},{d}) | ({d},{d},{d},{d},{d}) | {s}/{s} {s}\n",
            .{
                pair.seed,                                      pair.width,
                @tagName(pair.first_fit),                       @tagName(pair.argmin),
                si.t0_fit,                                      si.t1_integrity,
                si.t2_legibility,                               si.t3_height,
                si.t12_composite,                               sa.t0_fit,
                sa.t1_integrity,                                sa.t2_legibility,
                sa.t3_height,                                   sa.t12_composite,
                if (picks_first_fit) "first_fit" else "argmin", @tagName(pair.label),
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

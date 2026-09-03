//! select_test.zig — tests for select.zig, split out of the module under
//! the Step 4 cap watch (plan N3: keep select.zig's call sites thin and
//! its line count clear of the 500-line cap). Aggregated into the test
//! build from entry.zig's `test {}` block.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! budget, parse, select, permits, reach_vector.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const ladder = @import("budget.zig");
const select = @import("select.zig");
const permits_mod = @import("ledger/permits.zig");
const reach_vector = @import("ledger/reach_vector.zig");
const parse = @import("parse.zig").parse;

const PACK_RUNGS = ladder.Transform.motif_pack.rungs();

const test_bundle_permits: ledger.BundlePermits = .{ .policy = .joined };

fn testBundlePermits() *const ledger.BundlePermits {
    return &test_bundle_permits;
}

test "truncate rung is ineligible when natural fits cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  A --> B\n  B --> C\n");
    const enumerated = try ladder.enumerate(a, g, testBundlePermits(), 80);
    const sel = select.scoreCandidates(a, enumerated.candidates, enumerated.incumbent.final_rung, g.direction, .bridge) orelse
        return error.ScoringFailed;

    var natural_idx: ?usize = null;
    var truncate_idx: ?usize = null;
    for (enumerated.candidates, 0..) |cand, i| {
        if (cand.rung == .natural) natural_idx = i;
        if (cand.rung == .truncate) truncate_idx = i;
    }
    const ns = sel.scores[natural_idx.?];
    const ts = sel.scores[truncate_idx.?];

    try std.testing.expectEqual(@as(u32, 0), ns.t0_fit);
    try std.testing.expectEqual(@as(u32, 0), ns.t1_integrity);
    try std.testing.expect(ts.lessThan(ns));

    try std.testing.expect(enumerated.candidates[sel.argmin_idx].rung != .truncate);
}

test "packed candidates: TD parallel graph yields motif_pack candidates at capped rungs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  A --> B1 --> C1
        \\  A --> B2 --> C2
        \\
    );
    const packed_cands = try select.packedCandidates(a, g, testBundlePermits(), 80);
    try std.testing.expectEqual(@as(usize, PACK_RUNGS.len), packed_cands.len);
    for (packed_cands, PACK_RUNGS) |cand, rung| {
        try std.testing.expectEqual(ladder.Transform.motif_pack, cand.transform);
        try std.testing.expectEqual(rung, cand.rung);
        try std.testing.expect(!cand.accepted);
    }

    const reports = select.reachReports(a, g, true, packed_cands);
    try std.testing.expectEqual(packed_cands.len, reports.len);
    for (reports, packed_cands) |r, cand| {
        try std.testing.expect(cand.sketch.clusters.len != 0);
        try std.testing.expect(r.skipped_packed);
        try std.testing.expect(!r.skipped_clustered);
        try std.testing.expectEqual(@as(u32, 1), r.counts.skipped_packed_candidate);
        try std.testing.expectEqual(@as(u32, 0), r.counts.skipped_clustered);
    }

    const g_lr = try parse(a, "flowchart LR\n  A --> B1 --> C1\n  A --> B2 --> C2\n");
    try std.testing.expectEqual(@as(usize, 0), (try select.packedCandidates(a, g_lr, testBundlePermits(), 80)).len);
}

test "choose: merged selection anchors to raw natural and never fails the render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  A --> B1 --> C1
        \\  A --> B2 --> C2
        \\
    );
    const result = try select.choose(a, g, testBundlePermits(), 120, false, false, .bridge);
    try std.testing.expect(result.sketch.bbox.w > 0);

    const incumbent = (try ladder.enumerate(a, g, testBundlePermits(), 120)).incumbent;
    const off = try select.choose(a, g, testBundlePermits(), 120, true, false, .bridge);
    try std.testing.expectEqual(incumbent.final_rung, off.final_rung);
}

test "report-only pin: reach oracle changes neither argmin nor winner" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  S1 --> T1
        \\  S1 --> T2
        \\  S2 --> T2
        \\
    );
    const plan = (try permits_mod.build(a, g, .joined)).plan;

    const set = try select.enumerateAll(a, g, &plan, 96);
    const before = select.scoreCandidates(a, set.merged, set.incumbent.final_rung, g.direction, .bridge) orelse
        return error.ScoringFailed;

    const reports = select.reachReports(a, g, true, set.merged);
    try std.testing.expectEqual(set.merged.len, reports.len);
    const after = select.scoreCandidates(a, set.merged, set.incumbent.final_rung, g.direction, .bridge) orelse
        return error.ScoringFailed;
    try std.testing.expectEqual(before.argmin_idx, after.argmin_idx);
    try std.testing.expectEqual(before.incumbent_idx, after.incumbent_idx);

    const result = try select.choose(a, g, &plan, 96, false, false, .bridge);
    try std.testing.expectEqual(set.merged[before.argmin_idx].rung, result.final_rung);

    for (reports, set.merged) |r, cand| {
        if (cand.sketch.clusters.len != 0) {
            try std.testing.expect(r.skipped_packed);
            try std.testing.expect(!r.skipped_clustered);
            try std.testing.expectEqual(@as(u32, 1), r.counts.skipped_packed_candidate);
            try std.testing.expectEqual(@as(u32, 0), r.counts.skipped_clustered);
        } else {
            try std.testing.expect(r.components.len > 0);
        }
    }
}

test "score-blindness: zeroing the surviving set's report counts leaves the argmin identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
    const plan = (try permits_mod.build(a, g, .joined)).plan;
    const set = try select.enumerateAll(a, g, &plan, 96);

    const with_counts = try a.dupe(reach_vector.Report, select.reachReports(a, g, true, set.merged));
    for (with_counts) |*r| r.counts.skipped_clustered += 7;
    const survivors = select.ciFilter(a, set.merged, with_counts).survivors;
    try std.testing.expectEqual(set.merged.len, survivors.len);
    const argmin_present = (select.scoreCandidates(a, survivors, set.incumbent.final_rung, g.direction, .bridge) orelse
        return error.ScoringFailed).argmin_idx;

    const zeroed = try a.dupe(reach_vector.Report, with_counts);
    for (zeroed) |*r| r.counts = .{};
    const survivors_zeroed = select.ciFilter(a, set.merged, zeroed).survivors;
    const argmin_zeroed = (select.scoreCandidates(a, survivors_zeroed, set.incumbent.final_rung, g.direction, .bridge) orelse
        return error.ScoringFailed).argmin_idx;
    try std.testing.expectEqual(argmin_present, argmin_zeroed);
}

test "regression: the raw natural anchor filtered out keeps truncate eligible and a deterministic argmin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
    const plan = (try permits_mod.build(a, g, .joined)).plan;
    const set = try select.enumerateAll(a, g, &plan, 96);
    const forged = try a.dupe(reach_vector.Report, select.reachReports(a, g, true, set.merged));

    var nat: ?usize = null;
    for (set.merged, 0..) |cand, i| if (cand.rung == .natural and cand.transform == .raw) {
        nat = i;
        break;
    };
    try std.testing.expect(nat != null);
    forged[nat.?].counts.undeclared_pair = 1;
    const filtered = select.ciFilter(a, set.merged, forged);
    for (filtered.survivors) |cand|
        try std.testing.expect(!(cand.rung == .natural and cand.transform == .raw));

    const s1 = select.scoreCandidates(a, filtered.survivors, set.incumbent.final_rung, g.direction, .bridge) orelse
        return error.ScoringFailed;
    const s2 = select.scoreCandidates(a, filtered.survivors, set.incumbent.final_rung, g.direction, .bridge) orelse
        return error.ScoringFailed;
    try std.testing.expectEqual(s1.argmin_idx, s2.argmin_idx);
    _ = filtered.survivors[s1.argmin_idx];
}

test "terminal candidate: raw-natural all-independent, zero realized rails, separate ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  S --> A\n  S --> B\n  S --> C\n");
    const plan = (try permits_mod.build(a, g, .joined)).plan;
    const term = try select.terminalCandidate(a, g, &plan, 120);

    try std.testing.expectEqual(ladder.Rung.natural, term.final_rung);
    try std.testing.expectEqual(@as(usize, 0), term.sketch.bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), term.sketch.rails.len);
    try std.testing.expect(term.sketch.bundles.memberships.len > 0);
    var all_independent = true;
    for (term.sketch.bundles.memberships) |rm| {
        if (rm.source) |d| if (d != .independent) {
            all_independent = false;
        };
        if (rm.target) |d| if (d != .independent) {
            all_independent = false;
        };
    }
    try std.testing.expect(all_independent);
}

test "CI-class event excludes the truncate rung too (no rung carve-out)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
    const plan = (try permits_mod.build(a, g, .joined)).plan;
    const set = try select.enumerateAll(a, g, &plan, 96);
    const forged = try a.dupe(reach_vector.Report, select.reachReports(a, g, true, set.merged));

    var t: ?usize = null;
    for (set.merged, 0..) |cand, i| if (cand.rung == .truncate and cand.transform == .raw) {
        t = i;
        break;
    };
    forged[t.?].counts.undeclared_pair = 1;
    const filtered = select.ciFilter(a, set.merged, forged);
    try std.testing.expect(filtered.excluded_any);
    try std.testing.expectEqual(set.merged.len - 1, filtered.survivors.len);
    for (filtered.survivors) |cand|
        try std.testing.expect(!(cand.rung == .truncate and cand.transform == .raw));
}

test "filter drops the ladder incumbent: argmin over survivors still ships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
    const plan = (try permits_mod.build(a, g, .joined)).plan;
    const set = try select.enumerateAll(a, g, &plan, 96);
    const forged = try a.dupe(reach_vector.Report, select.reachReports(a, g, true, set.merged));

    var inc: ?usize = null;
    for (set.merged, 0..) |cand, i| if (cand.transform == .raw and cand.rung == set.incumbent.final_rung) {
        inc = i;
        break;
    };
    try std.testing.expect(inc != null);
    forged[inc.?].counts.unknown_continuation = 1;
    const filtered = select.ciFilter(a, set.merged, forged);
    try std.testing.expect(filtered.excluded_any);
    try std.testing.expect(filtered.survivors.len > 0);
    for (filtered.survivors) |cand|
        try std.testing.expect(!(cand.rung == set.incumbent.final_rung and cand.transform == .raw));

    const sel = select.scoreCandidates(a, filtered.survivors, set.incumbent.final_rung, g.direction, .bridge) orelse
        return error.NoSurvivorWinner;
    _ = filtered.survivors[sel.argmin_idx];
    try std.testing.expectEqual(sel.argmin_idx, sel.incumbent_idx);
}

test "reachReports: node-key table maps raw_id bytes and tolerates sparse ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  Alpha --> Beta\n");
    const keys = try select.nodeKeyTable(a, g);
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("Alpha", keys[g.findNode("Alpha").?]);
    try std.testing.expectEqualStrings("Beta", keys[g.findNode("Beta").?]);
}

/// The plan's own answer to "may these two edges share ink": co-membership of
/// one selected bundle, or of one fused union (the two-sided fusion licence,
/// which makes its rails' rail one bundle). The predicate
/// `raster/crossings.zig` applies, restated here over ledger records so this
/// pin is about the DATA and not about the raster's copy of the question.
fn planCoMembers(plan: ledger.RealizedBundles, first: u32, second: u32) bool {
    for (plan.fused) |u| {
        var a_in = false;
        var b_in = false;
        for (u) |m| {
            if (m == first) a_in = true;
            if (m == second) b_in = true;
        }
        if (a_in and b_in) return true;
    }
    for (plan.selected_bundles) |j| {
        var a_in = false;
        var b_in = false;
        for (j.members) |m| {
            if (m == first) a_in = true;
            if (m == second) b_in = true;
        }
        if (a_in and b_in) return true;
    }
    return false;
}

test "bundles applied with the plan carry the plan's own membership" {
    const sources = [_][]const u8{
        "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n",
        "flowchart TD\n  A --> D\n  B --> D\n  C --> D\n",
        "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n",
        "flowchart TD\n  A --> X\n  A --> Y\n  B --> X\n  B --> Y\n",
        "flowchart TD\n  A --> B\n  B --> C\n  C --> A\n",
    };
    var saw_selected = false;
    for (sources) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const g = try parse(a, source);
        const permits = (try permits_mod.build(a, g, .joined)).plan;
        const winner = try select.choose(a, g, &permits, width, false, false, .bridge);
        for (winner.sketch.bundle_sets) |set| switch (set.origin) {
            .selected_bundle => saw_selected = true,
            .port_share => {},
            .fan_rail => return error.FlatCandidateKeptLayoutBundles,
        };
        const only_plan = try ledger.keepOrigin(a, winner.sketch.bundle_sets, .selected_bundle);

        var first: u32 = 0;
        while (first < g.edges.len) : (first += 1) {
            var second: u32 = 0;
            while (second < g.edges.len) : (second += 1) {
                if (first == second) continue;
                try std.testing.expectEqual(
                    planCoMembers(winner.sketch.bundles, first, second),
                    ledger.bundleMembers(only_plan, first, second),
                );
            }
        }
    };
    try std.testing.expect(saw_selected);
}

test "the forced-rung debug path carries plan bundles, not layout's fan rails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n");
    const permits = (try permits_mod.build(a, g, .joined)).plan;
    var forced = try ladder.runForced(a, g, &permits, 120, .natural);
    select.applyPlan(a, &permits, &forced.sketch);

    try std.testing.expect(forced.sketch.bundles.selected_bundles.len > 0);
    try std.testing.expect(forced.sketch.bundle_sets.len > 0);
    for (forced.sketch.bundle_sets) |set| {
        try std.testing.expect(set.origin != .fan_rail);
    }
}

test "a clustered render's rail bundles come from its piece plan and survive the stitch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  subgraph S
        \\    A --> B
        \\    A --> C
        \\    A --> D
        \\  end
        \\  B --> Z
        \\
    );
    const permits = (try permits_mod.build(a, g, .joined)).plan;
    const winner = try select.choose(a, g, &permits, 120, false, false, .bridge);

    try std.testing.expectEqual(@as(usize, 1), winner.sketch.bundles.selected_bundles.len);
    const rail = winner.sketch.bundles.selected_bundles[0];
    try std.testing.expectEqual(@as(usize, 3), rail.members.len);
    try std.testing.expect(winner.sketch.bundle_sets.len > 0);
    for (winner.sketch.bundle_sets) |set| {
        try std.testing.expect(set.origin == .selected_bundle or set.origin == .port_share);
        try std.testing.expect(set.members.len >= 2);
    }
    const plan_sets = try ledger.keepOrigin(a, winner.sketch.bundle_sets, .selected_bundle);
    try std.testing.expectEqual(@as(usize, 1), plan_sets.len);
    try std.testing.expectEqualSlices(ledger.EdgeId, rail.members, plan_sets[0].members);
}

test "an unrouted edge is a missing declared pair on a candidate the oracle skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // On a candidate it validates, the oracle finds the missing pair itself.
    const flat = try parse(a, "flowchart TD\n  A --> B\n  B --> C\n");
    const flat_set = try select.enumerateAll(a, flat, testBundlePermits(), 120);
    var flat_cand = flat_set.merged[0];
    try std.testing.expectEqual(@as(usize, 2), flat_cand.sketch.edges.len);
    try std.testing.expectEqual(@as(u32, 0), select.unroutedEdges(flat_cand.sketch));
    const flat_edges = try a.dupe(@TypeOf(flat_cand.sketch.edges[0]), flat_cand.sketch.edges);
    flat_edges[0].polyline = &.{};
    flat_cand.sketch.edges = flat_edges;
    try std.testing.expectEqual(@as(u32, 1), select.unroutedEdges(flat_cand.sketch));
    const flat_reports = select.reachReports(a, flat, true, &[_]ladder.Candidate{flat_cand});
    try std.testing.expect(!flat_reports[0].skipped_clustered);
    try std.testing.expectEqual(@as(u32, 1), flat_reports[0].counts.missing_declared);
    // On a clustered candidate the oracle skips, the pair is counted by
    // inspection so the filter still sees it.
    const clustered = try parse(a, "flowchart TD\n  subgraph S\n    A --> B\n  end\n  B --> C\n");
    const set = try select.enumerateAll(a, clustered, testBundlePermits(), 120);
    var cand = set.merged[0];
    try std.testing.expect(cand.sketch.clusters.len != 0);
    const edges = try a.dupe(@TypeOf(cand.sketch.edges[0]), cand.sketch.edges);
    edges[0].polyline = &.{};
    cand.sketch.edges = edges;
    const reports = select.reachReports(a, clustered, false, &[_]ladder.Candidate{cand});
    try std.testing.expect(reports[0].skipped_clustered);
    try std.testing.expectEqual(@as(u32, 1), reports[0].counts.missing_declared);
}

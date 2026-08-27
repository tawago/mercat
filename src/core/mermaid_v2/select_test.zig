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

// File-scope const so the returned pointer has static lifetime — the
// select/ladder drivers now take `*const JoinPermits` (F6).
const test_join_permits: ledger.JoinPermits = .{ .policy = .joined };

fn testJoinPermits() *const ledger.JoinPermits {
    return &test_join_permits;
}

test "truncate rung is ineligible when natural fits cleanly" {
    // Locks truncate-eligibility: a tiny, trivially-fitting, integrity-clean
    // graph must never ship the lossy truncate rung, even when truncate's
    // composite is numerically lower.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  A --> B\n  B --> C\n");
    const enumerated = try ladder.enumerate(a, g, testJoinPermits(), 80);
    const sel = select.scoreCandidates(a, enumerated.candidates, enumerated.incumbent.final_rung, g.direction) orelse
        return error.ScoringFailed;

    var natural_idx: ?usize = null;
    var truncate_idx: ?usize = null;
    for (enumerated.candidates, 0..) |cand, i| {
        if (cand.rung == .natural) natural_idx = i;
        if (cand.rung == .truncate) truncate_idx = i;
    }
    const ns = sel.scores[natural_idx.?];
    const ts = sel.scores[truncate_idx.?];

    // Preconditions: natural fits cleanly (so truncate is ineligible) and
    // truncate's raw score would otherwise win the plain argmin.
    try std.testing.expectEqual(@as(u32, 0), ns.t0_fit);
    try std.testing.expectEqual(@as(u32, 0), ns.t1_integrity);
    try std.testing.expect(ts.lessThan(ns));

    try std.testing.expect(enumerated.candidates[sel.argmin_idx].rung != .truncate);
}

test "packed candidates: TD parallel graph yields motif_pack candidates at capped rungs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two isomorphic 2-node branches under a fork — the absorbed parallel
    // form pack.transform packs.
    const g = try parse(a,
        \\flowchart TD
        \\  A --> B1 --> C1
        \\  A --> B2 --> C2
        \\
    );
    const packed_cands = try select.packedCandidates(a, g, testJoinPermits(), 80);
    try std.testing.expectEqual(@as(usize, PACK_RUNGS.len), packed_cands.len);
    for (packed_cands, PACK_RUNGS) |cand, rung| {
        try std.testing.expectEqual(ladder.Transform.motif_pack, cand.transform);
        try std.testing.expectEqual(rung, cand.rung);
        try std.testing.expect(!cand.accepted);
    }

    // F2: on this FLAT input the packed candidates carry synthetic cluster
    // frames, so the reach oracle skips them with the packed-candidate
    // marker — never the clustered-input one (non-vacuous: frames asserted).
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
    try std.testing.expectEqual(@as(usize, 0), (try select.packedCandidates(a, g_lr, testJoinPermits(), 80)).len);
}

test "choose: merged selection anchors to raw natural and never fails the render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A fitting parallel graph: packing produces candidates, but the raw
    // natural must survive the natural-preference margin unless a packed
    // candidate wins big. Whatever wins, choose() must return a result.
    const g = try parse(a,
        \\flowchart TD
        \\  A --> B1 --> C1
        \\  A --> B2 --> C2
        \\
    );
    const result = try select.choose(a, g, testJoinPermits(), 120, false, false);
    try std.testing.expect(result.sketch.bbox.w > 0);

    // score_off returns the ladder incumbent exactly.
    const incumbent = (try ladder.enumerate(a, g, testJoinPermits(), 120)).incumbent;
    const off = try select.choose(a, g, testJoinPermits(), 120, true, false);
    try std.testing.expectEqual(incumbent.final_rung, off.final_rung);
}

test "report-only pin: reach oracle changes neither argmin nor winner" {
    // P2v Step 6 inertness pin: computing the per-candidate D-REACH vector
    // reports records tags on candidates (a fused fan is expected red on
    // today's geometry) while the argmin and the shipped winner stay
    // byte-identical to a selection that never ran the oracle.
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

    // Selection WITHOUT the oracle: enumerate and score directly.
    const set = try select.enumerateAll(a, g, &plan, 96);
    const before = select.scoreCandidates(a, set.merged, set.incumbent.final_rung, g.direction) orelse
        return error.ScoringFailed;

    // Run the oracle (tags recorded per candidate), then score again.
    const reports = select.reachReports(a, g, true, set.merged);
    try std.testing.expectEqual(set.merged.len, reports.len);
    const after = select.scoreCandidates(a, set.merged, set.incumbent.final_rung, g.direction) orelse
        return error.ScoringFailed;
    try std.testing.expectEqual(before.argmin_idx, after.argmin_idx);
    try std.testing.expectEqual(before.incumbent_idx, after.incumbent_idx);

    // The production path (which DOES run the oracle inside choose) ships
    // exactly the oracle-free argmin's candidate.
    const result = try select.choose(a, g, &plan, 96, false, false);
    try std.testing.expectEqual(set.merged[before.argmin_idx].rung, result.final_rung);

    // The reports really are per-candidate recorded data (component
    // tables exist for flat candidates; a flat input's synthetic packed
    // frames record the PACKED skip — F2: never the clustered-input one).
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
    // The plan's literal score-blindness property (L811-813): take the
    // surviving set, ZERO all its reports' counts, re-run scoring, and assert
    // the argmin is identical. scoreCandidates consumes no reports, so the
    // ranking cannot depend on any count magnitude — the filter reads EVENTS,
    // the scorer reads geometry.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
    const plan = (try permits_mod.build(a, g, .joined)).plan;
    const set = try select.enumerateAll(a, g, &plan, 96);

    // Attach arbitrary NON-CI count magnitudes to every report — they survive
    // the filter (ciClean) yet must not perturb the scored argmin.
    const with_counts = try a.dupe(reach_vector.Report, select.reachReports(a, g, true, set.merged));
    for (with_counts) |*r| r.counts.skipped_clustered += 7;
    const survivors = select.ciFilter(a, set.merged, with_counts).survivors;
    try std.testing.expectEqual(set.merged.len, survivors.len); // all CI-clean
    const argmin_present = (select.scoreCandidates(a, survivors, set.incumbent.final_rung, g.direction) orelse
        return error.ScoringFailed).argmin_idx;

    // Zero every surviving report's counts; the argmin is byte-identical.
    const zeroed = try a.dupe(reach_vector.Report, with_counts);
    for (zeroed) |*r| r.counts = .{};
    const survivors_zeroed = select.ciFilter(a, set.merged, zeroed).survivors;
    const argmin_zeroed = (select.scoreCandidates(a, survivors_zeroed, set.incumbent.final_rung, g.direction) orelse
        return error.ScoringFailed).argmin_idx;
    try std.testing.expectEqual(argmin_present, argmin_zeroed);
}

test "regression: the raw natural anchor filtered out keeps truncate eligible and a deterministic argmin" {
    // Newly reachable once the filter can drop the incumbent: forge a CI event
    // on the RAW natural anchor. scoreCandidates finds no raw natural in the
    // survivors, so truncate stays eligible (the pre-existing default) and the
    // argmin over survivors is still returned deterministically.
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
    for (filtered.survivors) |cand| // the raw natural anchor is gone from the set
        try std.testing.expect(!(cand.rung == .natural and cand.transform == .raw));

    const s1 = select.scoreCandidates(a, filtered.survivors, set.incumbent.final_rung, g.direction) orelse
        return error.ScoringFailed;
    const s2 = select.scoreCandidates(a, filtered.survivors, set.incumbent.final_rung, g.direction) orelse
        return error.ScoringFailed;
    try std.testing.expectEqual(s1.argmin_idx, s2.argmin_idx); // deterministic
    _ = filtered.survivors[s1.argmin_idx]; // in-range survivor winner
}

test "terminal candidate: raw-natural all-independent, zero realized trunks, separate ports" {
    // D-DISPOSITION item 9(b): the terminal fallback is a raw-natural layout
    // with trunk realization disabled (LayoutOptions.disable_join_realization)
    // and an all-independent plan over the REAL permits — zero selected joins,
    // no shared trunk busbar, fully-populated memberships (NOT the bare envelope).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  S --> A\n  S --> B\n  S --> C\n"); // K1,3 fan-out
    const plan = (try permits_mod.build(a, g, .joined)).plan;
    const term = try select.terminalCandidate(a, g, &plan, 120);

    try std.testing.expectEqual(ladder.Rung.natural, term.final_rung);
    try std.testing.expectEqual(@as(usize, 0), term.sketch.joins.selected_joins.len); // zero realized trunks
    try std.testing.expectEqual(@as(usize, 0), term.sketch.busbars.len); // separate ports, no shared trunk ink
    try std.testing.expect(term.sketch.joins.memberships.len > 0); // NOT the bare envelope
    var all_independent = true;
    for (term.sketch.joins.memberships) |rm| {
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
    // The filter has NO rung exemption: a CI event on the always-returns
    // truncate rung excludes it exactly like any other candidate.
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
    forged[t.?].counts.undeclared_pair = 1; // fabricating truncate layout
    const filtered = select.ciFilter(a, set.merged, forged);
    try std.testing.expect(filtered.excluded_any);
    try std.testing.expectEqual(set.merged.len - 1, filtered.survivors.len);
    for (filtered.survivors) |cand| // the raw truncate is gone from the scored set
        try std.testing.expect(!(cand.rung == .truncate and cand.transform == .raw));
}

test "filter drops the ladder incumbent: argmin over survivors still ships" {
    // The frenzy-at-94 shape via forged reports: the CI-excluded candidate IS
    // the ladder incumbent (the sole accepted rung). scoreCandidates must fall
    // back to the argmin over survivors (NOT bail → terminal), so a surviving
    // winner still ships while survivors exist.
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
    forged[inc.?].counts.unknown_continuation = 1; // the incumbent fabricates
    const filtered = select.ciFilter(a, set.merged, forged);
    try std.testing.expect(filtered.excluded_any);
    try std.testing.expect(filtered.survivors.len > 0);
    for (filtered.survivors) |cand| // the incumbent rung is gone
        try std.testing.expect(!(cand.rung == set.incumbent.final_rung and cand.transform == .raw));

    // Even though the incumbent is absent, scoring returns a survivor winner
    // (the fix: scoreCandidates no longer bails when the incumbent is filtered).
    const sel = select.scoreCandidates(a, filtered.survivors, set.incumbent.final_rung, g.direction) orelse
        return error.NoSurvivorWinner;
    _ = filtered.survivors[sel.argmin_idx]; // a valid, in-range survivor index
    try std.testing.expectEqual(sel.argmin_idx, sel.incumbent_idx); // incumbent stands in for the argmin
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
/// one selected join. The predicate `raster/crossings.zig` applies, restated
/// here over ledger records so this pin is about the DATA and not about the
/// raster's copy of the question.
fn planCoMembers(plan: ledger.RealizedJoins, first: u32, second: u32) bool {
    for (plan.selected_joins) |j| {
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

test "co-sets applied with the plan carry the plan's own membership" {
    // The equality that makes co-channel plumbing inert on the flat path: for
    // every pair of edge ids in the winning candidate, the co-sets answer
    // exactly what the realized plan answers. Fixtures span a fan-out, a
    // shared-target fan-in, a dual-ended edge, and an all-to-all (whose star
    // decomposition still plans trunks) — the shapes with non-empty plans.
    const sources = [_][]const u8{
        "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n",
        "flowchart TD\n  A --> D\n  B --> D\n  C --> D\n",
        "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n",
        "flowchart TD\n  A --> X\n  A --> Y\n  B --> X\n  B --> Y\n",
        "flowchart TD\n  A --> B\n  B --> C\n  C --> A\n",
    };
    // SCOPE: the equality is over the PLAN-DERIVED sets only. `.port_share`
    // sets ride alongside them (geometry the plan never spoke for), so they
    // are filtered out by origin rather than the equality being weakened.
    //
    // Non-vacuity: an equality over two empty records proves nothing, so both
    // plan origins must actually appear somewhere in the sweep.
    var saw_selected = false;
    for (sources) |source| for ([_]u32{ 60, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const g = try parse(a, source);
        const permits = (try permits_mod.build(a, g, .joined)).plan;
        const winner = try select.choose(a, g, &permits, width, false, false);
        for (winner.sketch.co_sets) |set| switch (set.origin) {
            .selected_join => saw_selected = true,
            .port_share => {},
            .fan_rail => return error.FlatCandidateKeptLayoutCoSets,
        };
        const only_plan = try ledger.keepOrigin(a, winner.sketch.co_sets, .selected_join);

        var first: u32 = 0;
        while (first < g.edges.len) : (first += 1) {
            var second: u32 = 0;
            while (second < g.edges.len) : (second += 1) {
                if (first == second) continue; // identity, answered before either record
                try std.testing.expectEqual(
                    planCoMembers(winner.sketch.joins, first, second),
                    ledger.coMembers(only_plan, first, second),
                );
            }
        }
    };
    try std.testing.expect(saw_selected);
}

test "the forced-rung debug path carries plan co-sets, not layout's fan rails" {
    // entry.zig's forced-rung / score-off paths bypass select.choose, so they
    // apply the plan themselves. Without that, a flat graph's sketch would
    // keep layout's `.fan_rail` sets and the debug render's crossing
    // semantics would diverge from the production one.
    //
    // SCOPE — this pins the CONTRACT (runForced's sketch + applyPlan = plan
    // co-sets), not entry.zig's WIRING: it reproduces the two calls rather
    // than going through the real path, whose only trigger is the env read in
    // `EnvOptions.read`. Deleting entry.zig's applyPlan calls leaves this
    // test green; only a render through a set MERCAT_FORCE_RUNG /
    // MERCAT_SCORE_OFF would catch that.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n");
    const permits = (try permits_mod.build(a, g, .joined)).plan;
    var forced = try ladder.runForced(a, g, &permits, 120, .natural);
    select.applyPlan(a, &permits, &forced.sketch);

    try std.testing.expect(forced.sketch.joins.selected_joins.len > 0);
    try std.testing.expect(forced.sketch.co_sets.len > 0);
    for (forced.sketch.co_sets) |set| {
        try std.testing.expect(set.origin != .fan_rail);
    }
}

test "a clustered render's trunk co-sets come from its piece plan and survive the stitch" {
    // A subgraph-internal fan realizes against its PIECE plan (cluster
    // unification): the trunk's co-set carries the plan's own membership,
    // rewritten into merged edge ids, so the raster's licence sites read the
    // same sanction a flat candidate's trunk gets.
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
    const winner = try select.choose(a, g, &permits, 120, false, false);

    try std.testing.expectEqual(@as(usize, 1), winner.sketch.joins.selected_joins.len);
    const trunk = winner.sketch.joins.selected_joins[0];
    try std.testing.expectEqual(@as(usize, 3), trunk.members.len);
    try std.testing.expect(winner.sketch.co_sets.len > 0);
    for (winner.sketch.co_sets) |set| {
        try std.testing.expect(set.origin == .selected_join or set.origin == .port_share);
        try std.testing.expect(set.members.len >= 2);
    }
    // The trunk's sanction rides a plan-origin co-set with the SAME members.
    const plan_sets = try ledger.keepOrigin(a, winner.sketch.co_sets, .selected_join);
    try std.testing.expectEqual(@as(usize, 1), plan_sets.len);
    try std.testing.expectEqualSlices(ledger.EdgeId, trunk.members, plan_sets[0].members);
}

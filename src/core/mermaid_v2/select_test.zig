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
    const enumerated = try ladder.enumerate(a, g, testJoinPermits(), true, 80);
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
    const packed_cands = try select.packedCandidates(a, g, testJoinPermits(), true, 80);
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
    try std.testing.expectEqual(@as(usize, 0), (try select.packedCandidates(a, g_lr, testJoinPermits(), true, 80)).len);
}

test "negotiated fold candidate: generated once for LR, declined for TD, appended last" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g_lr = try parse(a, "flowchart LR\n  A --> B --> C --> D\n  D --> A\n");
    const cand = select.negotiatedFoldCandidate(a, g_lr, testJoinPermits(), true, 40) orelse return error.MissingCandidate;
    try std.testing.expectEqual(ladder.Transform.negotiated_fold, cand.transform);
    try std.testing.expectEqual(ladder.Rung.chain_wrap, cand.rung);
    try std.testing.expect(!cand.accepted);

    const g_td = try parse(a, "flowchart TD\n  A --> B\n");
    try std.testing.expect(select.negotiatedFoldCandidate(a, g_td, testJoinPermits(), true, 40) == null);

    // Merged list: raw candidates first (T4 tie preference), negotiated last.
    const set = try select.enumerateAll(a, g_lr, testJoinPermits(), true, 40);
    try std.testing.expectEqual(ladder.Transform.raw, set.merged[0].transform);
    try std.testing.expectEqual(
        ladder.Transform.negotiated_fold,
        set.merged[set.merged.len - 1].transform,
    );
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
    const result = try select.choose(a, g, testJoinPermits(), true, 120, false, false);
    try std.testing.expect(result.sketch.bbox.w > 0);

    // score_off returns the ladder incumbent exactly.
    const incumbent = (try ladder.enumerate(a, g, testJoinPermits(), true, 120)).incumbent;
    const off = try select.choose(a, g, testJoinPermits(), true, 120, true, false);
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
    const set = try select.enumerateAll(a, g, &plan, true, 96);
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
    const result = try select.choose(a, g, &plan, true, 96, false, false);
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
    const set = try select.enumerateAll(a, g, &plan, true, 96);

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
    const set = try select.enumerateAll(a, g, &plan, true, 96);
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
    const term = try select.terminalCandidate(a, g, &plan, true, 120);

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
    const set = try select.enumerateAll(a, g, &plan, true, 96);
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
    const set = try select.enumerateAll(a, g, &plan, true, 96);
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

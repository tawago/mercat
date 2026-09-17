//! select_filter.zig — P2v Step 8 pre-raster CI safety filter + terminal
//! candidate, split out of select.zig for the 500-line cap (cap-forced
//! deviation from the plan's "Lint: None" line; documented in the Step 8
//! report). Pure data/plan surface — no scoring, no geometry ranking.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, the base/ no-deps
//! tier, sem_graph, budget, sketch_bundles, ledger/dispose,
//! ledger/reach_vector.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const sketch_bundles = @import("sketch_bundles.zig");
const sem_graph = @import("sem_graph.zig");
const ladder = @import("budget.zig");
const dispose_mod = @import("ledger/dispose.zig");
const reach_vector = @import("ledger/reach_vector.zig");

/// True iff these bundles speak for a realized plan (rather than layout's
/// fans), so re-deriving them from a plan replaces like with like.
fn planDerived(sets: []const ledger.Bundle) bool {
    for (sets) |s| {
        switch (s.origin) {
            .selected_bundle => return true,
            .fan_rail, .port_share => {},
        }
    }
    return false;
}

/// Re-derive `sets` from `plan`, KEEPING the sketch's `.port_share` records.
/// INVARIANT: a port share is geometric, not planned — withdrawing a rail
/// says nothing about two edges the producers routed through one port, so the
/// plan's population is replaced and the port shares ride along unchanged.
fn replanSets(aa: std.mem.Allocator, sets: []const ledger.Bundle, plan: ledger.RealizedBundles) []const ledger.Bundle {
    const derived = ledger.bundlesFromPlan(aa, plan) catch return sets;
    const shares = ledger.keepOrigin(aa, sets, .port_share) catch &.{};
    return ledger.concatBundles(aa, derived, shares) catch derived;
}

/// The CI-filter partition. `survivors` (+ aligned `reports`) are the
/// CI-clean candidates the scorer sees; `excluded` holds the re-disposed
/// clause-(g)-pre copies of the CI candidates in candidate order — a LIVE
/// surface Step 10's telemetry consumes (D-JOIN-SELECT plan L775-776/L790),
/// empty on the identity path. `excluded_any` distinguishes the identity
/// (nothing filtered) from a filter that emptied a non-empty input.
pub const FilterResult = struct {
    survivors: []const ladder.Candidate,
    reports: []const reach_vector.Report,
    excluded: []const ladder.Candidate = &.{},
    excluded_any: bool = false,
};

/// P2v Step 8 pre-raster CI safety filter (D-JOIN-SELECT item 6;
/// D-DISPOSITION item 5 row 3). Partitions `candidates` by CI-class reach
/// EVENTS: any candidate whose parallel `reports[i]` is not `ciClean` is
/// EXCLUDED (no rung carve-out) and its emitted plan re-disposed clause-(g)-pre
/// (ledger/dispose.zig) into `excluded`; survivors keep their plan,
/// order, and aligned report. SCORE-BLIND: reads reach EVENTS only, never a
/// score, magnitude, or geometry. Clustered/packed SKIPS pass (`ciTotal`
/// excludes both skip counts — OPEN-8). On the census-clean corpus red
/// candidates are never winners (census 0/114), so excluding them never moves
/// the argmin (scoreCandidates falls back to the argmin when the incumbent is
/// filtered out); any allocation failure degrades to the identity.
pub fn ciFilter(
    aa: std.mem.Allocator,
    candidates: []const ladder.Candidate,
    reports: []const reach_vector.Report,
) FilterResult {
    const clean = FilterResult{ .survivors = candidates, .reports = reports };
    if (candidates.len != reports.len) return clean;
    var any = false;
    for (reports) |r| if (!r.counts.ciClean()) {
        any = true;
        break;
    };
    if (!any) return clean;

    const mut = aa.dupe(ladder.Candidate, candidates) catch return clean;
    var survivors: std.ArrayListUnmanaged(ladder.Candidate) = .empty;
    var kept: std.ArrayListUnmanaged(reach_vector.Report) = .empty;
    var excluded: std.ArrayListUnmanaged(ladder.Candidate) = .empty;
    for (mut, reports) |*cand, rep| {
        if (rep.counts.ciClean()) {
            survivors.append(aa, cand.*) catch return clean;
            kept.append(aa, rep) catch return clean;
        } else {
            cand.sketch.bundles = dispose_mod.disposeUnsafe(aa, cand.sketch.bundles) catch cand.sketch.bundles;
            if (planDerived(cand.sketch.bundle_sets))
                cand.sketch.bundle_sets = replanSets(aa, cand.sketch.bundle_sets, cand.sketch.bundles);
            sketch_bundles.stamp(aa, &cand.sketch);
            excluded.append(aa, cand.*) catch return clean;
        }
    }
    return .{
        .survivors = survivors.toOwnedSlice(aa) catch return clean,
        .reports = kept.toOwnedSlice(aa) catch return clean,
        .excluded = excluded.toOwnedSlice(aa) catch &.{},
        .excluded_any = true,
    };
}

/// D-DISPOSITION item 9(b) terminal candidate: the forced all-independent
/// fallback returned when the CI filter EMPTIES the scored set. Laid out by
/// `budget.runForcedIndependent` at the RAW `.natural` rung with rail
/// realization DISABLED (`LayoutOptions.disable_bundle_realization`): `bundle_commit`
/// emits an all-independent plan over the REAL permits, so `fan_rail` builds
/// no rail and `ports.derive` gives every edge its own D-PORT port — no shared
/// rail ink between a permit group's edges. Its plan is the all-independent
/// commitment `bundle_commit` emitted over the REAL `bundle_permits` (every
/// grouped endpoint `independent(not_selected)`). `terminal_fallback` is set
/// (9(e) observability; the RO `disp_terminal_fallback_engaged` count
/// aggregation is Step 10's job). A FALLBACK: never engages on the census-clean
/// corpus.
pub fn terminalCandidate(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) !ladder.LadderResult {
    var result = try ladder.runForcedIndependent(aa, graph, bundle_permits, max_width);
    result.terminal_fallback = true;
    std.log.debug("mermaid_v2/select: {s} engaged (terminal all-independent fallback)", .{ledger.tagName(.disp_terminal_fallback_engaged)});
    return result;
}

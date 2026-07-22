//! select_filter.zig — P2v Step 8 pre-raster CI safety filter + terminal
//! candidate, split out of select.zig for the 500-line cap (cap-forced
//! deviation from the plan's "Lint: None" line; documented in the Step 8
//! report). Pure data/plan surface — no scoring, no geometry ranking.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger,
//! sem_graph, budget, realized, reach_vector.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const ladder = @import("budget.zig");
const realized_mod = @import("ledger/realized.zig");
const reach_vector = @import("ledger/reach_vector.zig");

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

/// P2v Step 8 pre-raster CI safety filter (D-JOIN-SELECT item 6; TSD §13.2;
/// D-DISPOSITION item 5 row 3). Partitions `candidates` by CI-class reach
/// EVENTS: any candidate whose parallel `reports[i]` is not `ciClean` is
/// EXCLUDED (no rung carve-out) and its emitted plan re-disposed clause-(g)-pre
/// (`realized.disposeUnsafe`) into `excluded`; survivors keep their plan,
/// order, and aligned report. SCORE-BLIND: reads reach EVENTS only, never a
/// score, magnitude, or geometry. Clustered/packed SKIPS pass (`ciTotal`
/// excludes both skip counts — OPEN-8). On the census-clean corpus red
/// candidates are never winners (census 0/114), so excluding them never moves
/// the argmin (scoreCandidates falls back to the argmin when the incumbent is
/// filtered out); any allocation failure degrades to the identity.
/// guarded-by: disposition_test.zig "V-D-DISPOSITION-04: fusing incomplete-union candidate is CI-excluded, independent survivor routes; complete union fires nothing"
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
            // Clause-(g)-pre: withdraw the excluded candidate's realized trunks
            // so its emitted plan reads independent(unsafe_component); the
            // re-disposed copy rides `excluded` into Step 10's telemetry.
            cand.sketch.joins = realized_mod.disposeUnsafe(aa, cand.sketch.joins) catch cand.sketch.joins;
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
/// `budget.runForcedIndependent` at the RAW `.natural` rung with trunk
/// realization DISABLED (`LayoutOptions.disable_join_realization`): `join_commit`
/// emits an all-independent plan over the REAL permits, so `fan_busbar` builds
/// no trunk and `ports.derive` gives every edge its own D-PORT port — no shared
/// trunk ink between a permit group's edges. Its EMITTED plan is the
/// all-independent realization over the REAL `join_permits` (`realized.realize`
/// over the trunk-free sketch → every group falls to clause (f) →
/// `independent(not_selected)`, fully-populated memberships + per-edge terminal
/// ports, §6.7-valid — NOT the bare `.{}` envelope). `terminal_fallback` is set
/// (9(e) observability; the RO `disp_terminal_fallback_engaged` count
/// aggregation is Step 10's job). A FALLBACK: never engages on the census-clean
/// corpus.
/// guarded-by: disposition_test.zig "V-D-DISPOSITION-06: terminal fallback is built by the selection tail, marks terminal_fallback, validates, and renders"
pub fn terminalCandidate(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) !ladder.LadderResult {
    var result = try ladder.runForcedIndependent(aa, graph, join_permits, join_permits_flat, max_width);
    result.terminal_fallback = true;
    if (join_permits_flat) {
        if (realized_mod.realize(aa, join_permits.*, result.sketch, &.{})) |r| {
            result.sketch.joins = r.plan;
        } else |err| {
            std.log.warn("mermaid_v2/select: terminal fallback realize failed ({s}); emitting the empty envelope", .{@errorName(err)});
        }
    }
    std.log.debug("mermaid_v2/select: {s} engaged (terminal all-independent fallback)", .{ledger.tagName(.disp_terminal_fallback_engaged)});
    return result;
}

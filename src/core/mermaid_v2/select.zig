//! select.zig — candidate construction + live score selection.
//!
//! Merges RAW ladder rungs (raw first, so index ties prefer it) and PACKED
//! (motif-packed TD/BT parallel graphs at capped rungs). Raster-audits each multi-candidate
//! selection (audit.zig; skipped when only one) and picks the argmin of
//! score.eval, gated by truncate-eligibility and a natural-preference margin
//! anchored to the raw natural; the P2v Step 8 CI safety filter runs BEFORE
//! scoring (score-blind); failures degrade to the ladder incumbent.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, sem_graph, sketch,
//! sketch_ports (the Sketch-root extension deriving port-share co-sets),
//! budget, score, motif, audit, realized, invariants, reach_vector,
//! select_filter (the Step 8 CI filter + terminal candidate), parse (tests
//! only). In-file tests live in select_test.zig (plan N3 cap-watch).

const std = @import("std");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const sketch_mod = @import("sketch.zig");
const sketch_ports = @import("sketch_ports.zig");
const sketch_channels = @import("sketch_channels.zig");
const ladder = @import("budget.zig");
const score_mod = @import("score.zig");
const audit_mod = @import("audit.zig");
const realized_mod = @import("ledger/realized.zig");
const invariants = @import("ledger/invariants.zig");
const reach_vector = @import("ledger/reach_vector.zig");
const select_filter = @import("select_filter.zig");
const select_labels = @import("select_labels.zig");

/// Packed candidates' capped rung set (see budget.Transform.rungs).
const PACK_RUNGS = ladder.Transform.motif_pack.rungs();

/// Upper bound on the merged candidate list: 5 raw rungs + 3 packed.
const MAX_CANDIDATES = 16;

/// Enumerate raw + packed candidates, CI-filter, score them, and return the
/// winning `LadderResult`. `score_off` returns the ladder incumbent (A/B
/// escape hatch); `shadow` emits one `mercat-score-shadow:` line on disagreement.
/// Errors are exactly `budget.enumerate`'s (pre-incumbent layout failures).
pub fn choose(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    max_width: u32,
    score_off: bool,
    shadow: bool,
) !ladder.LadderResult {
    const set = try enumerateAll(aa, graph, join_permits, max_width);
    const merged = attachJoinPlans(aa, join_permits, set.merged);
    var incumbent = set.incumbent;
    if (join_permits.isFlat()) applyPlan(aa, join_permits, &incumbent.sketch);

    // D-REACH pre-raster vector reachability oracle per merged candidate,
    // AFTER realized and BEFORE scoring (D-REACH items 5/9/10/12-13). The
    // CI-filter + score + winner/terminal resolution is `selectWinner` — a
    // byte-identical decomposition, exposed so tests can drive the tail with
    // forged reports.
    // guarded-by: select_test.zig "report-only pin: reach oracle changes neither argmin nor winner"
    const reach = reachReports(aa, graph, join_permits.isFlat(), merged);
    return selectWinner(aa, graph, join_permits, max_width, merged, reach, incumbent, score_off, shadow);
}

// The Step 8 CI filter + terminal candidate live in select_filter.zig
// (cap-forced split; see that file). Re-exported so callers/tests keep
// reaching them as `select.ciFilter` / `select.terminalCandidate`.
pub const FilterResult = select_filter.FilterResult;
pub const ciFilter = select_filter.ciFilter;
pub const terminalCandidate = select_filter.terminalCandidate;

/// choose's post-oracle tail (D-JOIN-SELECT item 6; D-DISPOSITION item 9(b)):
/// CI-filter the merged candidates by their parallel `reach` reports, score the
/// survivors, and resolve the winner. The terminal all-independent candidate is
/// built ONLY when the filter EMPTIES the scored set (`survivors.len == 0`); a
/// scoring failure with survivors present degrades to the incumbent (spec:
/// terminal is not a scoring-failure fallback). `score_off` returns the
/// incumbent (A/B hatch); `shadow` emits the disagreement line. Byte-identical
/// composition of what `choose` used to inline.
/// guarded-by: disposition_test.zig "V-D-DISPOSITION-06: terminal fallback is built by the selection tail, marks terminal_fallback, validates, and renders"
pub fn selectWinner(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    max_width: u32,
    merged: []const ladder.Candidate,
    reach: []const reach_vector.Report,
    incumbent: ladder.LadderResult,
    score_off: bool,
    shadow: bool,
) !ladder.LadderResult {
    const filtered = ciFilter(aa, merged, reach);
    var selection = scoreCandidates(aa, filtered.survivors, incumbent.final_rung, graph.direction);
    if (selection) |*s| s.reach_reports = filtered.reports;
    if (shadow) {
        if (selection) |sel| emitScoreShadowLine(filtered.survivors, sel, max_width);
    }
    if (score_off) return incumbent;
    const sel = selection orelse {
        // Terminal candidate ONLY when the filter emptied the scored set
        // (D-DISPOSITION item 9(b)); a scoring failure with survivors present
        // degrades to the incumbent (never terminal while survivors exist).
        if (filtered.survivors.len == 0 and filtered.excluded_any)
            return terminalCandidate(aa, graph, join_permits, max_width) catch incumbent;
        return incumbent;
    };
    const winner = filtered.survivors[sel.argmin_idx];
    return .{ .sketch = winner.sketch, .final_rung = winner.rung, .attempts = @intCast(merged.len) };
}

/// P2v Step 4: populate every merged candidate's `Sketch.joins` BEFORE
/// scoring (D-IR items 5/8). FLAT-GATED (D-EDGE-ID item 4): on
/// clustered inputs `joins` stays `.{}`, preserving byte-identity. Any
/// planning failure degrades to the empty plan (the render never fails here).
/// guarded-by: realized_test.zig "V-D-IR-01: winner joins artifact survives selection to the entry boundary"
fn attachJoinPlans(
    aa: std.mem.Allocator,
    join_permits: *const ledger.JoinPermits,
    candidates: []const ladder.Candidate,
) []const ladder.Candidate {
    if (!join_permits.isFlat()) return candidates;
    const mut = aa.dupe(ladder.Candidate, candidates) catch return candidates;
    for (mut) |*cand| applyPlan(aa, join_permits, &cand.sketch);
    return mut;
}

/// Apply one candidate's realized plan to its Sketch: the plan itself AND the
/// co-channel sets derived from it.
///
/// Both land here, at the single point where the plan becomes the candidate's
/// own. Deriving co-sets at layout time instead would be writing them where
/// this call overwrites them — except where no plan realized, which is where
/// layout's fan-derived sets are the candidate's only record (see below). A
/// derivation failure degrades to no sets, matching how a planning failure
/// degrades to the empty plan.
///
/// Shared with entry.zig's forced-rung / score-off paths, which bypass
/// selection: a debug render must carry the same production join plan, or its
/// crossing semantics diverge from the render it is meant to explain.
pub fn applyPlan(
    aa: std.mem.Allocator,
    join_permits: *const ledger.JoinPermits,
    target: *sketch_mod.Sketch,
) void {
    const planned = planJoins(aa, join_permits, target.*);
    target.joins = planned.plan;
    // INVARIANT: plan-derived co-sets REPLACE layout's fan-derived sets only
    // when a plan actually realized. A candidate the planner never planned —
    // a motif-packed one, whose synthetic frames put it off the identity path
    // (realized.zig's `skipped_clustered`), or a planning failure — has said
    // nothing about who may share ink, so it keeps the sets layout gave it
    // rather than being emptied into "nobody may share".
    // guarded-by: select_test2.zig "a packed candidate keeps its layout co-sets when no plan realized"
    // INVARIANT: `.port_share` sets are NOT plan-derived and therefore are not
    // the plan's to withdraw — they record a share the producers made in
    // geometry, which no realization decision revokes. So the plan's sets
    // replace only the plan's own population, and the port shares are
    // re-derived from the sketch this call is finalizing.
    // guarded-by: select_test2.zig "applying a plan keeps the sketch's port-share co-sets"
    if (planned.realized) target.co_sets = sketch_ports.appendPortShares(
        aa,
        ledger.coSetsFromPlan(aa, planned.plan) catch &.{},
        target.edges,
    ) catch ledger.coSetsFromPlan(aa, planned.plan) catch &.{};
    // A rebuilt roster is a rebuilt set of names: the plan's sets arrive
    // unstamped, and layout's names spoke for the decision this call just
    // replaced. Re-stamping is unconditional so the two cases — plan applied,
    // plan declined — cannot leave the sketch in different states of filing.
    sketch_channels.stamp(aa, target);
}

/// P2v Step 6: one pre-raster vector reachability report per candidate
/// (parallel to `candidates`), each from the candidate's OWN Sketch + `joins`
/// (D-IR items 5/9). Node keys (D-REACH item 12) are raw_id bytes; failures
/// degrade to the empty report. `join_permits_flat` selects which skip a
/// cluster-framed sketch records — `reach_skipped_clustered` (clustered) vs.
/// `skipped_packed_candidate` (flat, synthetic packed frames — OPEN-8). Step
/// 8's filter consumes these; never score input.
pub fn reachReports(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits_flat: bool,
    candidates: []const ladder.Candidate,
) []const reach_vector.Report {
    const keys = nodeKeyTable(aa, graph) catch &.{};
    const out = aa.alloc(reach_vector.Report, candidates.len) catch return &.{};
    const input: reach_vector.InputKind = if (join_permits_flat) .flat else .clustered;
    for (candidates, out) |cand, *r| {
        r.* = reach_vector.validate(aa, cand.sketch, keys, input) catch .{};
    }
    return out;
}

/// Canonical node-key table: source raw_id bytes indexed by NodeId
/// (D-REACH item 12; the D-PORT canonical attachment key component).
pub fn nodeKeyTable(aa: std.mem.Allocator, graph: sem_graph.SemGraph) ![]const []const u8 {
    var max_id: usize = 0;
    for (graph.nodes) |n| max_id = @max(max_id, n.id);
    const keys = try aa.alloc([]const u8, if (graph.nodes.len == 0) 0 else max_id + 1);
    @memset(keys, "");
    for (graph.nodes) |n| keys[n.id] = n.raw_id;
    return keys;
}

/// One candidate's realized-join plan; invariant-validated on safety-checked builds (log-only).
fn planJoins(
    aa: std.mem.Allocator,
    join_permits: *const ledger.JoinPermits,
    candidate_sketch: sketch_mod.Sketch,
) PlanOutcome {
    const result = realized_mod.realize(aa, join_permits.*, candidate_sketch) catch return .{};
    const out: PlanOutcome = .{ .plan = result.plan, .realized = !result.report.skipped_clustered };
    if (std.debug.runtime_safety) {
        const report = invariants.validate(aa, join_permits.*, result.plan, result.report.proposals) catch
            return out;
        if (!report.valid()) {
            std.log.debug("mermaid_v2/select: realized-join plan failed invariant validation ({d} findings)", .{report.findings.len});
        }
    }
    return out;
}

/// A candidate's plan plus whether the planner actually planned it: false for
/// a candidate it declined (off the identity path) or a planning failure —
/// both of which leave the empty envelope, which is NOT the same statement as
/// a realized plan that selected no join.
const PlanOutcome = struct {
    plan: ledger.RealizedJoins = .{},
    realized: bool = false,
};

/// The full live candidate set: raw ladder rungs merged with the motif-packed
/// candidates, plus the ladder incumbent. Exposed so budget_test.zig scores
/// exactly the candidates the live path scores.
pub const CandidateSet = struct {
    merged: []const ladder.Candidate,
    incumbent: ladder.LadderResult,
};

/// Enumerate raw + packed candidates, RAW FIRST (T4 index ties prefer raw),
/// then — for a graph with labeled edges — the `.beside` LABEL-POLICY twins of
/// the promising candidates, appended LAST so an exact score tie keeps the
/// on-run placement (select_labels.zig). Packing is best-effort: any failure
/// leaves the raw set.
pub fn enumerateAll(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    max_width: u32,
) !CandidateSet {
    const enumerated = try ladder.enumerate(aa, graph, join_permits, max_width);

    var extras: [PACK_RUNGS.len + 1 + select_labels.MAX_BESIDE]ladder.Candidate = undefined;
    var n_extras: usize = 0;
    for (packedCandidates(aa, graph, join_permits, max_width) catch &.{}) |c| {
        extras[n_extras] = c;
        n_extras += 1;
    }
    // The label-policy twins are picked against the FULL on-run set, so they
    // are chosen after both extras blocks and appended behind them.
    var on_run: [MAX_CANDIDATES]ladder.Candidate = undefined;
    const on_run_n = enumerated.candidates.len + n_extras;
    if (on_run_n <= on_run.len) {
        @memcpy(on_run[0..enumerated.candidates.len], enumerated.candidates);
        @memcpy(on_run[enumerated.candidates.len..on_run_n], extras[0..n_extras]);
        n_extras += select_labels.besideVariants(aa, graph, join_permits, max_width, on_run[0..on_run_n], extras[n_extras..]);
    }

    const merged = blk: {
        if (n_extras == 0) break :blk enumerated.candidates;
        const m = aa.alloc(ladder.Candidate, enumerated.candidates.len + n_extras) catch
            break :blk enumerated.candidates;
        @memcpy(m[0..enumerated.candidates.len], enumerated.candidates);
        @memcpy(m[enumerated.candidates.len..], extras[0..n_extras]);
        break :blk m;
    };
    return .{ .merged = merged, .incumbent = enumerated.incumbent };
}

/// Lay out the motif-packed graph (when packing applies) at the capped rung
/// set. Empty slice when the transform declines; per-rung failures are
/// skipped (packed candidates are scoring-only extra work).
pub fn packedCandidates(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    max_width: u32,
) error{OutOfMemory}![]const ladder.Candidate {
    const packed_graph = select_labels.packedGraph(aa, graph) orelse return &.{};

    var list: std.ArrayListUnmanaged(ladder.Candidate) = .empty;
    for (PACK_RUNGS) |rung| {
        const result = ladder.runForced(aa, packed_graph, join_permits, max_width, rung) catch continue;
        try list.append(aa, .{
            .rung = rung,
            .sketch = result.sketch,
            .accepted = false,
            .transform = .motif_pack,
        });
    }
    return list.toOwnedSlice(aa);
}

/// Scores of every retained candidate plus the two indices the selection
/// cares about. `scores[0..n]` parallels the merged candidate list.
pub const ScoredSelection = struct {
    scores: [MAX_CANDIDATES]score_mod.Score,
    n: usize,
    incumbent_idx: usize,
    argmin_idx: usize,
    /// The per-SURVIVOR D-REACH vector reports, parallel to the scored
    /// candidate list (borrowed into choose's `aa`). Report-only — scoring
    /// never reads it; `scoreCandidates` leaves it empty, choose attaches it.
    reach_reports: []const reach_vector.Report = &.{},
};

/// Score every candidate (score.zig) and locate the argmin and the ladder
/// incumbent. Returns null on any scoring failure or an empty/oversized set —
/// callers degrade to the incumbent. A missing incumbent (CI-filtered out of
/// the list) is NOT null: the argmin stands in for it (shadow telemetry
/// no-ops), so a surviving winner still ships.
///
/// Truncate-eligibility: `truncate` participates in the argmin ONLY when the
/// RAW natural-rung candidate is broken (t0 > 0 or t1 > 0). Covers packed
/// truncate candidates too — same lossy rung, same anchor.
/// guarded-by: select_test.zig "truncate rung is ineligible when natural fits cleanly"
///
/// Natural-preference margin: a challenger displaces the RAW natural-rung
/// candidate only when it beats natural's composite by >=
/// score.NATURAL_PREFERENCE_MARGIN (T0 wins exempt — see displacesNatural).
/// guarded-by: score_test.zig "natural-preference margin: sliver composite wins do not displace natural"
pub fn scoreCandidates(
    aa: std.mem.Allocator,
    candidates: []const ladder.Candidate,
    incumbent_rung: ladder.Rung,
    source_direction: sem_graph.Direction,
) ?ScoredSelection {
    var sel: ScoredSelection = undefined;
    sel.reach_reports = &.{};
    const n = candidates.len;
    if (n == 0 or n > sel.scores.len) return null;

    // Locate the ladder incumbent up front: it always gets a FULL score.
    var incumbent_idx: ?usize = null;
    for (candidates, 0..) |cand, i| {
        if (cand.transform == .raw and cand.rung == incumbent_rung) {
            incumbent_idx = i;
            break;
        }
    }

    // Pass 1: T0 fit severity plus the raster audit for EVERY candidate —
    // the composite prices the audit's violation counters, so every scored
    // candidate needs its counts. Audit is skipped for n == 1.
    var t0s: [MAX_CANDIDATES]u32 = undefined;
    var rasters: [MAX_CANDIDATES]score_mod.RasterCounts = undefined;
    var min_t0: u32 = std.math.maxInt(u32);
    for (candidates, 0..) |cand, i| {
        t0s[i] = score_mod.fitSeverity(cand.sketch);
        rasters[i] = if (n > 1) audit_mod.collect(aa, cand.sketch) else .{};
        min_t0 = @min(min_t0, t0s[i]);
    }

    // Pass 2: full evaluation (validate + geometry) ONLY for candidates that
    // can still win (t0 == min) plus the incumbent. The rest get a sentinel
    // losing score carrying the TRUE t0 (decided at the T0 tier, so
    // argmin/anchor are unaffected).
    for (candidates, 0..) |cand, i| {
        if (t0s[i] > min_t0 and (incumbent_idx == null or i != incumbent_idx.?)) {
            sel.scores[i] = .{
                .t0_fit = t0s[i],
                .t1_integrity = 0,
                .t2_legibility = 0,
                .t3_height = std.math.maxInt(u32),
                .t4_index = @intCast(i),
                .t12_composite = std.math.maxInt(u64),
            };
            continue;
        }
        const raster = rasters[i];
        sel.scores[i] = score_mod.eval(
            aa,
            cand.sketch,
            source_direction,
            @intCast(i),
            raster,
        ) catch return null;
    }

    // Truncate is eligible only when the RAW natural is broken (doc above).
    // The first raw natural IS the anchor; if absent, keep truncate eligible
    // and let the plain argmin decide.
    var truncate_eligible = true;
    var natural_idx: ?usize = null;
    for (candidates, 0..) |cand, i| {
        if (cand.rung == .natural and cand.transform == .raw) {
            natural_idx = i;
            const s = sel.scores[i];
            truncate_eligible = s.t0_fit > 0 or s.t1_integrity > 0;
            break;
        }
    }

    var argmin_idx: ?usize = null;
    for (candidates, 0..) |cand, i| {
        if (cand.rung == .truncate and !truncate_eligible) continue;
        if (argmin_idx == null or sel.scores[i].lessThan(sel.scores[argmin_idx.?])) {
            argmin_idx = i;
        }
    }
    if (natural_idx) |ni| {
        if (argmin_idx) |ai| {
            if (ai != ni and !score_mod.displacesNatural(sel.scores[ai], sel.scores[ni])) {
                argmin_idx = ni;
            }
        }
    }
    sel.n = n;
    sel.argmin_idx = argmin_idx orelse return null;
    // When the ladder incumbent was CI-filtered out of the candidate list, the
    // argmin stands in for it (self-comparison → emitScoreShadowLine no-ops via
    // its argmin==incumbent early return). Byte-for-byte unchanged when the
    // incumbent IS present; only the filtered-out case reaches the fallback.
    sel.incumbent_idx = incumbent_idx orelse sel.argmin_idx;
    return sel;
}

/// When the argmin differs from the ladder incumbent, emit ONE machine-
/// readable disagreement line to STDERR (MERCAT_SCORE_SHADOW=1; external
/// diagnostics capture `^mercat-score-shadow:`). Purely observational.
fn emitScoreShadowLine(
    candidates: []const ladder.Candidate,
    sel: ScoredSelection,
    max_width: u32,
) void {
    const inc_idx = sel.incumbent_idx;
    const argmin_idx = sel.argmin_idx;
    if (argmin_idx == inc_idx) return;

    const inc = sel.scores[inc_idx];
    const arg = sel.scores[argmin_idx];
    std.debug.print(
        "mercat-score-shadow: incumbent={s} argmin={s} width={d} " ++
            "inc_score={d}/{d}/{d}/{d} arg_score={d}/{d}/{d}/{d} " ++
            "inc_raster={d}/{d} arg_raster={d}/{d} tier={s} transform={s}\n",
        .{
            @tagName(candidates[inc_idx].rung),
            @tagName(candidates[argmin_idx].rung),
            max_width,
            inc.t0_fit,
            inc.t1_integrity,
            inc.t2_legibility,
            inc.t3_height,
            arg.t0_fit,
            arg.t1_integrity,
            arg.t2_legibility,
            arg.t3_height,
            inc.r_labels_dropped,
            inc.r_edge_cells_lost,
            arg.r_labels_dropped,
            arg.r_edge_cells_lost,
            score_mod.Score.decidingTier(inc, arg),
            @tagName(candidates[argmin_idx].transform),
        },
    );
}

// Tests live in select_test.zig (cap-watch mitigation, plan N3),
// aggregated into the test build from entry.zig's `test {}` block.

//! select.zig — candidate construction + live score selection.
//!
//! Merges RAW ladder rungs (raw first, so index ties prefer it), PACKED
//! (motif-packed TD/BT parallel graphs at capped rungs), and NEGOTIATED FOLD
//! (one LR/RL chain_wrap candidate). Raster-audits each multi-candidate
//! selection (audit.zig; skipped when only one) and picks the argmin of
//! score.eval, gated by truncate-eligibility and a natural-preference margin
//! anchored to the raw natural; the P2v Step 8 CI safety filter runs BEFORE
//! scoring (score-blind); failures degrade to the ladder incumbent.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, sem_graph, sketch,
//! budget, score, motif, audit, realized, invariants, reach_vector,
//! select_filter (the Step 8 CI filter + terminal candidate), parse (tests
//! only). In-file tests live in select_test.zig (plan N3 cap-watch).

const std = @import("std");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const sketch_mod = @import("sketch.zig");
const ladder = @import("budget.zig");
const score_mod = @import("score.zig");
const motif_mod = @import("motif.zig");
const audit_mod = @import("audit.zig");
const realized_mod = @import("ledger/realized.zig");
const invariants = @import("ledger/invariants.zig");
const reach_vector = @import("ledger/reach_vector.zig");
const select_filter = @import("select_filter.zig");

/// Packed candidates' capped rung set (see budget.Transform.rungs).
const PACK_RUNGS = ladder.Transform.motif_pack.rungs();

/// Upper bound on the merged candidate list: 6 raw rungs + 3 packed.
const MAX_CANDIDATES = 16;

/// Enumerate raw + packed candidates, CI-filter, score them, and return the
/// winning `LadderResult`. `score_off` returns the ladder incumbent (A/B
/// escape hatch); `shadow` emits one `mercat-score-shadow:` line on disagreement.
/// Errors are exactly `budget.enumerate`'s (pre-incumbent layout failures).
pub fn choose(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
    score_off: bool,
    shadow: bool,
) !ladder.LadderResult {
    const set = try enumerateAll(aa, graph, join_permits, join_permits_flat, max_width);
    const merged = attachJoinPlans(aa, join_permits, join_permits_flat, set.merged);
    var incumbent = set.incumbent;
    if (join_permits_flat) incumbent.sketch.joins = planJoins(aa, join_permits, incumbent.sketch);

    // D-REACH pre-raster vector reachability oracle per merged candidate,
    // AFTER realized and BEFORE scoring (D-REACH items 5/9/10/12-13). The
    // CI-filter + score + winner/terminal resolution is `selectWinner` — a
    // byte-identical decomposition, exposed so tests can drive the tail with
    // forged reports.
    // guarded-by: select_test.zig "report-only pin: reach oracle changes neither argmin nor winner"
    const reach = reachReports(aa, graph, join_permits_flat, merged);
    return selectWinner(aa, graph, join_permits, join_permits_flat, max_width, merged, reach, incumbent, score_off, shadow);
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
    join_permits_flat: bool,
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
            return terminalCandidate(aa, graph, join_permits, join_permits_flat, max_width) catch incumbent;
        return incumbent;
    };
    const winner = filtered.survivors[sel.argmin_idx];
    return .{ .sketch = winner.sketch, .final_rung = winner.rung, .attempts = @intCast(merged.len) };
}

/// P2v Step 4: populate every merged candidate's `Sketch.joins` BEFORE
/// scoring (D-IR items 5/8; TSD §13.2 order). FLAT-GATED (D-EDGE-ID §4): on
/// clustered inputs `joins` stays `.{}`, preserving byte-identity. Any
/// planning failure degrades to the empty plan (the render never fails here).
/// guarded-by: realized_test.zig "V-D-IR-01: winner joins artifact survives selection to the entry boundary"
fn attachJoinPlans(
    aa: std.mem.Allocator,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    candidates: []const ladder.Candidate,
) []const ladder.Candidate {
    if (!join_permits_flat) return candidates;
    const mut = aa.dupe(ladder.Candidate, candidates) catch return candidates;
    for (mut) |*cand| cand.sketch.joins = planJoins(aa, join_permits, cand.sketch);
    return mut;
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

/// One candidate's realized-join plan; §6.7-validated on safety-checked builds (log-only).
fn planJoins(
    aa: std.mem.Allocator,
    join_permits: *const ledger.JoinPermits,
    candidate_sketch: sketch_mod.Sketch,
) ledger.RealizedJoins {
    const result = realized_mod.realize(aa, join_permits.*, candidate_sketch, &.{}) catch return .{};
    if (std.debug.runtime_safety) {
        const report = invariants.validate(aa, join_permits.*, result.plan, result.report.proposals) catch
            return result.plan;
        if (!report.valid()) {
            std.log.debug("mermaid_v2/select: realized-join plan failed §6.7 validation ({d} findings)", .{report.findings.len});
        }
    }
    return result.plan;
}

/// The full live candidate set: raw ladder rungs merged with the motif-packed
/// candidates, plus the ladder incumbent. Exposed so budget_test.zig scores
/// exactly the candidates the live path scores.
pub const CandidateSet = struct {
    merged: []const ladder.Candidate,
    incumbent: ladder.LadderResult,
};

/// Enumerate raw + packed candidates, RAW FIRST (T4 index ties prefer raw).
/// Packing is best-effort: any failure leaves the raw set.
pub fn enumerateAll(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) !CandidateSet {
    const enumerated = try ladder.enumerate(aa, graph, join_permits, join_permits_flat, max_width);

    var extras: [PACK_RUNGS.len + 1]ladder.Candidate = undefined;
    var n_extras: usize = 0;
    for (packedCandidates(aa, graph, join_permits, join_permits_flat, max_width) catch &.{}) |c| {
        extras[n_extras] = c;
        n_extras += 1;
    }
    if (negotiatedFoldCandidate(aa, graph, join_permits, join_permits_flat, max_width)) |c| {
        extras[n_extras] = c;
        n_extras += 1;
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

/// ONE extra candidate on LR/RL graphs (chain_wrap's domain): the chain_wrap
/// rung with NEGOTIATED band breaks. Best-effort. When the fold never fires
/// the sketch is byte-identical to the raw chain_wrap candidate and can never
/// win (raw wrap_labels scores lower, scale 32 < 44, same geometry).
pub fn negotiatedFoldCandidate(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) ?ladder.Candidate {
    if (!ladder.Transform.negotiated_fold.appliesTo(graph.direction)) return null;
    const result = ladder.runNegotiatedFold(aa, graph, join_permits, join_permits_flat, max_width) catch return null;
    return .{
        .rung = .chain_wrap,
        .sketch = result.sketch,
        .accepted = false,
        .transform = .negotiated_fold,
    };
}

/// Lay out the motif-packed graph (when packing applies) at the capped rung
/// set. Empty slice when the transform declines; per-rung failures are
/// skipped (packed candidates are scoring-only extra work).
pub fn packedCandidates(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    join_permits_flat: bool,
    max_width: u32,
) error{OutOfMemory}![]const ladder.Candidate {
    if (!ladder.Transform.motif_pack.appliesTo(graph.direction)) return &.{};
    const tree = try motif_mod.decompose(aa, graph);
    const packed_graph = (try motif_mod.pack.transform(aa, graph, tree)) orelse return &.{};

    var list: std.ArrayListUnmanaged(ladder.Candidate) = .empty;
    for (PACK_RUNGS) |rung| {
        const result = ladder.runForced(aa, packed_graph, join_permits, join_permits_flat, max_width, rung) catch continue;
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

    // Pass 1: T0 fit severity only (pure bbox arithmetic). T0 is the top tier,
    // so any candidate above the minimum severity can never be the argmin.
    var t0s: [MAX_CANDIDATES]u32 = undefined;
    var min_t0: u32 = std.math.maxInt(u32);
    for (candidates, 0..) |cand, i| {
        t0s[i] = score_mod.fitSeverity(cand.sketch);
        min_t0 = @min(min_t0, t0s[i]);
    }

    // Pass 2: full evaluation (raster audit + validate + geometry) ONLY for
    // candidates that can still win (t0 == min) plus the incumbent. The rest
    // get a sentinel losing score carrying the TRUE t0 (decided at the T0
    // tier, so argmin/anchor are unaffected). Audit is skipped for n == 1.
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
        const raster: score_mod.RasterCounts = if (n > 1) audit_mod.collect(aa, cand.sketch) else .{};
        // The negotiated fold pays its own provisional scale (44 vs chain_wrap
        // 48) — score.evalScaled owns that; we only tag the candidate.
        sel.scores[i] = score_mod.evalScaled(
            aa,
            cand.sketch,
            source_direction,
            @intCast(i),
            raster,
            cand.transform == .negotiated_fold,
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

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
//! budget, score, motif, audit, reach_vector, select_filter (the Step 8 CI
//! filter + terminal candidate), parse (tests only). In-file tests live in
//! select_test.zig (plan N3 cap-watch).
//!
//! Every candidate carries the bundle plan its layout committed
//! (layout/bundle_commit.zig) and the bundle sets layout derived from it;
//! selection reads them and never rewrites them.

const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const sketch_mod = @import("sketch.zig");
const ladder = @import("budget.zig");
const score_mod = @import("score.zig");
const audit_mod = @import("audit.zig");
const reach_vector = @import("ledger/reach_vector.zig");
const select_filter = @import("select_filter.zig");
const select_labels = @import("select_labels.zig");

/// Packed candidates' capped rung set (see budget.Transform.rungs).
const PACK_RUNGS = ladder.Transform.motif_pack.rungs();

/// Upper bound on the merged candidate list: 5 raw rungs + 3 packed +
/// 4 beside twins + up to 4 bridge-build twins (capped at append time).
const MAX_CANDIDATES = 16;

/// Bridge-build twins: {dodged, railed} x {raw natural, ladder incumbent}.
const MAX_BRIDGE = 4;

/// Enumerate raw + packed candidates, CI-filter, score them, and return the
/// winning `LadderResult`. `score_off` returns the ladder incumbent (A/B
/// escape hatch); `shadow` emits one `mercat-score-shadow:` line on disagreement.
/// Errors are exactly `budget.enumerate`'s (pre-incumbent layout failures).
pub fn choose(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    score_off: bool,
    shadow: bool,
    subgraph_edges: prim.SubgraphEdges,
) !ladder.LadderResult {
    const set = try enumerateAll(aa, graph, bundle_permits, max_width);
    const merged = set.merged;

    // D-REACH pre-raster vector reachability oracle per merged candidate,
    // BEFORE scoring (D-REACH items 5/9/10/12-13). The CI-filter + score +
    // winner/terminal resolution is `selectWinner` — a byte-identical
    // decomposition, exposed so tests can drive the tail with forged reports.
    // @guarded-by: select_test.zig "report-only pin: reach oracle changes neither argmin nor winner"
    const reach = reachReports(aa, graph, bundle_permits.isFlat(), merged);
    return selectWinner(aa, graph, bundle_permits, max_width, merged, reach, set.incumbent, score_off, shadow, subgraph_edges);
}

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
pub fn selectWinner(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    merged: []const ladder.Candidate,
    reach: []const reach_vector.Report,
    incumbent: ladder.LadderResult,
    score_off: bool,
    shadow: bool,
    subgraph_edges: prim.SubgraphEdges,
) !ladder.LadderResult {
    const filtered = ciFilter(aa, merged, reach);
    var selection = scoreCandidates(aa, filtered.survivors, incumbent.final_rung, graph.direction, subgraph_edges);
    if (selection) |*s| s.reach_reports = filtered.reports;
    if (shadow) {
        if (selection) |sel| emitScoreShadowLine(filtered.survivors, sel, max_width);
    }
    if (score_off) return incumbent;
    const sel = selection orelse {
        if (filtered.survivors.len == 0 and filtered.excluded_any)
            return terminalCandidate(aa, graph, bundle_permits, max_width) catch incumbent;
        return incumbent;
    };
    const winner = filtered.survivors[sel.argmin_idx];
    return .{ .sketch = winner.sketch, .final_rung = winner.rung, .attempts = @intCast(merged.len) };
}

/// P2v Step 6: one pre-raster vector reachability report per candidate
/// (parallel to `candidates`), each from the candidate's OWN Sketch + `bundles`
/// (D-IR items 5/9). Node keys (D-REACH item 12) are raw_id bytes; failures
/// degrade to the empty report. `bundle_permits_flat` selects which skip a
/// cluster-framed sketch records — `reach_skipped_clustered` (clustered) vs.
/// `skipped_packed_candidate` (flat, synthetic packed frames — OPEN-8). Step
/// 8's filter consumes these; never score input.
pub fn reachReports(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits_flat: bool,
    candidates: []const ladder.Candidate,
) []const reach_vector.Report {
    const keys = nodeKeyTable(aa, graph) catch &.{};
    const out = aa.alloc(reach_vector.Report, candidates.len) catch return &.{};
    const input: reach_vector.InputKind = if (bundle_permits_flat) .flat else .clustered;
    for (candidates, out) |cand, *r| {
        r.* = reach_vector.validate(aa, cand.sketch, keys, input) catch .{};
        // An edge the router laid no ink for (routing.zig `unrouted`) is a
        // declared pair with no trace — the oracle's own `missing_declared`
        // event. The oracle reads it on the candidates it validates; on the
        // ones it skips (clustered input, packed frames) the pair is still
        // verifiably missing by inspection, and the filter must see it there
        // too, or a candidate could win the fit tier by dropping edges.
        // @guarded-by: select_test.zig "an unrouted edge is a missing declared pair on a candidate the oracle skipped"
        if (r.counts.skipped_clustered != 0 or r.counts.skipped_packed_candidate != 0)
            r.counts.missing_declared += unroutedEdges(cand.sketch);
    }
    return out;
}

/// Visible edges of `s` with no polyline at all.
pub fn unroutedEdges(s: sketch_mod.Sketch) u32 {
    var n: u32 = 0;
    for (s.edges) |e| if (e.polyline.len < 2 and e.kind != .invisible) {
        n += 1;
    };
    return n;
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
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) !CandidateSet {
    const enumerated = try ladder.enumerate(aa, graph, bundle_permits, max_width);

    var extras: [PACK_RUNGS.len + 1 + select_labels.MAX_BESIDE + MAX_BRIDGE]ladder.Candidate = undefined;
    var n_extras: usize = 0;
    for (packedCandidates(aa, graph, bundle_permits, max_width) catch &.{}) |c| {
        extras[n_extras] = c;
        n_extras += 1;
    }
    var on_run: [MAX_CANDIDATES]ladder.Candidate = undefined;
    const on_run_n = enumerated.candidates.len + n_extras;
    if (on_run_n <= on_run.len) {
        @memcpy(on_run[0..enumerated.candidates.len], enumerated.candidates);
        @memcpy(on_run[enumerated.candidates.len..on_run_n], extras[0..n_extras]);
        n_extras += select_labels.besideVariants(aa, graph, bundle_permits, max_width, on_run[0..on_run_n], extras[n_extras..]);
    }

    n_extras += bridgeVariants(
        aa,
        graph,
        bundle_permits,
        max_width,
        enumerated.candidates,
        enumerated.incumbent.final_rung,
        @min(extras.len - n_extras, MAX_CANDIDATES -| (enumerated.candidates.len + n_extras)),
        extras[n_extras..],
    );

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

/// Lay out the dodged/railed BRIDGE-BUILD twins of a clustered graph's
/// promising candidates (the raw natural rung and the ladder incumbent),
/// appended behind every other candidate so ties keep the plain build. The
/// composite score against the real raster then decides which bridge
/// routing ships — the router itself never picks (confluence selection
/// note: dodge vs plain and fused vs separate are candidate axes, not
/// routing-time proxy decisions). A twin whose edges are byte-identical to
/// its plain base is dropped (it cannot score differently); failures are
/// skipped — twins are scoring-only extra work. Returns the number written.
/// @guarded-by: select_test3.zig "bridge variants: a clustered graph enumerates dodged/railed twins behind the raw set"
fn bridgeVariants(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    raw: []const ladder.Candidate,
    incumbent_rung: ladder.Rung,
    budget_slots: usize,
    out: []ladder.Candidate,
) usize {
    if (graph.clusters.len == 0) return 0;
    var rungs: [2]?ladder.Rung = .{ .natural, null };
    if (incumbent_rung != .natural) rungs[1] = incumbent_rung;
    var n: usize = 0;
    const cap = @min(budget_slots, out.len);
    for (rungs) |rung_opt| {
        const rung = rung_opt orelse continue;
        const base = baseCandidate(raw, rung) orelse continue;
        for ([2]prim.BridgeBuild{ .dodged, .railed }) |build| {
            if (n >= cap) return n;
            const result = ladder.runBridgeVariant(aa, graph, bundle_permits, max_width, rung, build) catch continue;
            if (sameEdgeGeometry(base.sketch, result.sketch)) continue;
            out[n] = .{
                .rung = rung,
                .sketch = result.sketch,
                .accepted = false,
                .transform = switch (build) {
                    .dodged => .bridge_dodged,
                    .railed => .bridge_railed,
                    .plain => unreachable,
                },
            };
            n += 1;
        }
    }
    return n;
}

/// The raw candidate laid out at `rung`, if the ladder produced one.
fn baseCandidate(raw: []const ladder.Candidate, rung: ladder.Rung) ?ladder.Candidate {
    for (raw) |c| {
        if (c.transform == .raw and c.rung == rung) return c;
    }
    return null;
}

/// True when two candidate Sketches carry identical edge geometry (ids and
/// polylines) — a variant that changed nothing cannot audit or score
/// differently, so it is not a distinct candidate.
fn sameEdgeGeometry(a: sketch_mod.Sketch, b: sketch_mod.Sketch) bool {
    if (a.edges.len != b.edges.len) return false;
    for (a.edges, b.edges) |ea, eb| {
        if (ea.id != eb.id or ea.polyline.len != eb.polyline.len) return false;
        for (ea.polyline, eb.polyline) |pa, pb| {
            if (pa.x != pb.x or pa.y != pb.y) return false;
        }
    }
    return true;
}

/// Lay out the motif-packed graph (when packing applies) at the capped rung
/// set. Empty slice when the transform declines; per-rung failures are
/// skipped (packed candidates are scoring-only extra work).
pub fn packedCandidates(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) error{OutOfMemory}![]const ladder.Candidate {
    const packed_graph = select_labels.packedGraph(aa, graph) orelse return &.{};

    var list: std.ArrayListUnmanaged(ladder.Candidate) = .empty;
    for (PACK_RUNGS) |rung| {
        const result = ladder.runForced(aa, packed_graph, bundle_permits, max_width, rung) catch continue;
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
/// @guarded-by: select_test.zig "truncate rung is ineligible when natural fits cleanly"
///
/// Natural-preference margin: a challenger displaces the RAW natural-rung
/// candidate only when it beats natural's composite by >=
/// score.NATURAL_PREFERENCE_MARGIN (T0 wins exempt — see displacesNatural).
/// @guarded-by: score_test.zig "natural-preference margin: sliver composite wins do not displace natural"
pub fn scoreCandidates(
    aa: std.mem.Allocator,
    candidates: []const ladder.Candidate,
    incumbent_rung: ladder.Rung,
    source_direction: sem_graph.Direction,
    subgraph_edges: prim.SubgraphEdges,
) ?ScoredSelection {
    var sel: ScoredSelection = undefined;
    sel.reach_reports = &.{};
    const n = candidates.len;
    if (n == 0 or n > sel.scores.len) return null;

    var incumbent_idx: ?usize = null;
    for (candidates, 0..) |cand, i| {
        if (cand.transform == .raw and cand.rung == incumbent_rung) {
            incumbent_idx = i;
            break;
        }
    }

    var t0s: [MAX_CANDIDATES]u32 = undefined;
    var rasters: [MAX_CANDIDATES]score_mod.RasterCounts = undefined;
    var min_t0: u32 = std.math.maxInt(u32);
    for (candidates, 0..) |cand, i| {
        t0s[i] = score_mod.fitSeverity(cand.sketch);
        rasters[i] = if (n > 1) audit_mod.collect(aa, cand.sketch, subgraph_edges) else .{};
        min_t0 = @min(min_t0, t0s[i]);
    }

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

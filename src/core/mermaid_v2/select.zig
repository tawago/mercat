//! select.zig — candidate construction + live score selection.
//!
//! Merges RAW ladder rungs (raw first, so index ties prefer it) and PACKED
//! (motif-packed TD/BT parallel graphs at capped rungs). Raster-audits each multi-candidate
//! selection (audit.zig; skipped when only one) and picks the argmin of
//! score.eval, gated by truncate-eligibility and a natural-preference margin
//! anchored to the raw natural; failures degrade to the ladder incumbent.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, sem_graph, sketch,
//! budget, score, motif, audit, parse (tests only). In-file tests live in
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
const motif_mod = @import("motif.zig");

/// Packed candidates' capped rung set (see budget.Transform.rungs).
const PACK_RUNGS = ladder.Transform.motif_pack.rungs();

/// Upper bound on the merged candidate list: 5 raw rungs + 3 packed +
/// up to 4 bridge-build twins (capped at append time), with headroom.
const MAX_CANDIDATES = 16;

/// Bridge-build twins: {dodged, railed} x {raw natural, ladder incumbent}.
const MAX_BRIDGE = 4;

/// Enumerate raw + packed candidates, score them, and return the winning
/// `LadderResult`. `score_off` returns the ladder incumbent (A/B escape
/// hatch); `shadow` emits one `mercat-score-shadow:` line on disagreement.
/// A scoring failure leaves the ladder incumbent. Errors are exactly
/// `budget.enumerate`'s (pre-incumbent layout failures).
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
    const incumbent = set.incumbent;
    const selection = scoreCandidates(aa, set.merged, incumbent.final_rung, graph.direction, subgraph_edges);
    if (shadow) {
        if (selection) |sel| emitScoreShadowLine(set.merged, sel, max_width);
    }
    if (score_off) return incumbent;
    const sel = selection orelse return incumbent;
    const winner = set.merged[sel.argmin_idx];
    return .{ .sketch = winner.sketch, .final_rung = winner.rung, .attempts = @intCast(set.merged.len) };
}

/// The full live candidate set: raw ladder rungs merged with the motif-packed
/// candidates, plus the ladder incumbent. Exposed so budget_test.zig scores
/// exactly the candidates the live path scores.
pub const CandidateSet = struct {
    merged: []const ladder.Candidate,
    incumbent: ladder.LadderResult,
};

/// Enumerate raw + packed candidates, RAW FIRST (T4 index ties prefer raw),
/// then the bridge-build twins of a clustered graph, appended LAST so an
/// exact score tie keeps the plain build. Packing is best-effort: any
/// failure leaves the raw set.
pub fn enumerateAll(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) !CandidateSet {
    const enumerated = try ladder.enumerate(aa, graph, bundle_permits, max_width);

    var extras: [PACK_RUNGS.len + 1 + MAX_BRIDGE]ladder.Candidate = undefined;
    var n_extras: usize = 0;
    for (packedCandidates(aa, graph, bundle_permits, max_width) catch &.{}) |c| {
        extras[n_extras] = c;
        n_extras += 1;
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
/// @guarded-by: select_test.zig "bridge variants: a clustered graph enumerates dodged/railed twins behind the raw set"
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

/// The motif-packed rewrite of `graph`, or null when packing declines (wrong
/// direction, or `pack.transform` found nothing to pack). Pure.
fn packedGraph(aa: std.mem.Allocator, graph: sem_graph.SemGraph) ?sem_graph.SemGraph {
    if (!ladder.Transform.motif_pack.appliesTo(graph.direction)) return null;
    const tree = motif_mod.decompose(aa, graph) catch return null;
    return (motif_mod.pack.transform(aa, graph, tree) catch return null) orelse null;
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
    const packed_graph = packedGraph(aa, graph) orelse return &.{};

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

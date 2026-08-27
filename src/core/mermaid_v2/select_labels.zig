//! select_labels.zig — the label-placement policy as a SCORED candidate axis.
//!
//! Label placement is not a preference the raster pass applies unconditionally:
//! for a graph that HAS labeled edges, each promising candidate is laid out a
//! second time under `prim.LabelPolicy.beside` (no on-run forms, no fan label
//! rows) and both variants go into the scored set. The score — which already
//! prices `labels_dropped` / `labels_displaced` / `edge_cells_lost` off the
//! audit re-raster, and the raster honors `Sketch.label_policy` — decides per
//! diagram. No new score term: an on-run placement counts as placed, as today.
//!
//! Cap-forced split of select.zig. Also owns `packedGraph`, the motif-pack
//! transform select.zig needs both for its packed candidates and for their
//! variants' recipe.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger, sem_graph,
//! sketch, budget, score, motif. In-file tests live in select_test3.zig.

const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const ladder = @import("budget.zig");
const score_mod = @import("score.zig");
const motif_mod = @import("motif.zig");

/// Upper bound on beside-variants added to one selection. The merged on-run
/// set peaks at 10 (6 raw + 3 packed + 1 fold), so 4 keeps the total under
/// select.MAX_CANDIDATES with room to spare — and the variants are the
/// expensive kind of candidate (one extra layout AND one extra audit raster
/// each), so duplicating the whole ladder would be pure waste: everything
/// above the minimum fit severity already loses at the score's top tier.
pub const MAX_BESIDE = 4;

/// True when any edge carries a non-empty label — the only case where the
/// policy axis can change a single cell of ink.
pub fn hasLabeledEdge(graph: sem_graph.SemGraph) bool {
    for (graph.edges) |e| {
        const l = e.label orelse continue;
        if (l.len > 0) return true;
    }
    return false;
}

/// The motif-packed rewrite of `graph`, or null when packing declines (wrong
/// direction, or `pack.transform` found nothing to pack). Pure; select.zig
/// uses it for the packed candidates and this file for their variant recipe.
pub fn packedGraph(aa: std.mem.Allocator, graph: sem_graph.SemGraph) ?sem_graph.SemGraph {
    if (!ladder.Transform.motif_pack.appliesTo(graph.direction)) return null;
    const tree = motif_mod.decompose(aa, graph) catch return null;
    return (motif_mod.pack.transform(aa, graph, tree) catch return null) orelse null;
}

/// Lay out the `.beside` twin of each PROMISING candidate in `merged` and
/// write them to `out` (append them AFTER the on-run set: the argmin breaks
/// exact ties on candidate index, so on-run first keeps today's winner).
/// Returns how many were written.
///
/// "Promising" = minimum `score.fitSeverity`, the same top-tier test
/// `select.scoreCandidates` uses to decide which candidates are worth a full
/// evaluation — anything above it already lost at T0 and its twin would too.
/// Capped at `MAX_BESIDE`, taken in list order (raw rungs first), so the
/// candidate count stays bounded and deterministic.
///
/// Best-effort throughout: a variant that fails to lay out is simply skipped,
/// leaving the on-run set exactly as it was.
/// guarded-by: select_test3.zig "a labeled graph yields both policies; the winner is deterministic"
pub fn besideVariants(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    join_permits: *const ledger.JoinPermits,
    max_width: u32,
    merged: []const ladder.Candidate,
    out: []ladder.Candidate,
) usize {
    if (merged.len == 0 or out.len == 0) return 0;
    if (!hasLabeledEdge(graph)) return 0;

    var min_t0: u32 = std.math.maxInt(u32);
    for (merged) |c| min_t0 = @min(min_t0, score_mod.fitSeverity(c.sketch));

    var packed_graph: ?sem_graph.SemGraph = null;
    var packed_tried = false;
    var n: usize = 0;
    for (merged) |c| {
        if (n >= out.len or n >= MAX_BESIDE) break;
        if (score_mod.fitSeverity(c.sketch) > min_t0) continue;
        const source: sem_graph.SemGraph = switch (c.transform) {
            .raw, .negotiated_fold => graph,
            .motif_pack => blk: {
                if (!packed_tried) {
                    packed_tried = true;
                    packed_graph = packedGraph(aa, graph);
                }
                break :blk packed_graph orelse continue;
            },
        };
        const result = ladder.runVariant(
            aa,
            source,
            join_permits,
            max_width,
            c.rung,
            c.transform == .negotiated_fold,
            .beside,
        ) catch continue;
        out[n] = .{
            .rung = c.rung,
            .sketch = result.sketch,
            .accepted = false,
            .transform = c.transform,
        };
        n += 1;
    }
    return n;
}

test {
    _ = @import("select_test3.zig");
}

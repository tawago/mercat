//! score.zig — pure integer candidate score. Evaluates a laid-out `Sketch`
//! into a deterministic `Score`, ordered lexicographically: T0 fit severity
//! (width-overflow magnitude, not a count) > T12 composite (RUNG_SCALE[rung]
//! * t2_legibility + W_INTEGRITY * t1_integrity + raster-defect weights;
//! integrity is a large cost, not a veto) > T3 height > T4 rung index (total
//! order, unique argmin). Raw t1/t2 stay on `Score` for the shadow line;
//! only `lessThan`/`decidingTier` consult the composite. Raster-time
//! defects arrive via `RasterCounts` — this file stays raster-blind.
//!
//! Pure: no floats, no RNG, no I/O. Allocations (validate scratch + the
//! dead-space coverage bitmap) come from the caller's arena.
//! Allowed imports (lint): std, prim, sem_graph, sketch, layout/validate.

const std = @import("std");
const sketch = @import("sketch.zig");
const validate = @import("layout/validate.zig");
const geom = @import("score_geom.zig");

// The pure geometric T2 measurements live in score_geom.zig (split for the
// 500-line cap); re-exported so callers/tests keep one score surface.
pub const deadSpace = geom.deadSpace;
pub const edgeStretch = geom.edgeStretch;
pub const bends = geom.bends;
pub const countCrossings = geom.countCrossings;

/// Overall flow direction (re-export so callers need not import prim).
pub const Direction = sketch.Direction;

// -- Fitted weights -------------------------------------------------------
//
// Units: the composite is expressed in SIXTEENTHS of one T2 legibility unit
// (one dead-space cell = 16), so the rung multipliers below can express
// fractional ratios in pure integers.

/// Per-rung legibility multipliers, indexed by `Sketch.budget.rung`
/// (0=natural, 1=tight, 2=wrap_labels, 3=chain_wrap, 4=switch_direction,
/// 5=truncate). 16 = 1.0x. A later rung wins only when it improves
/// legibility by MORE than its ratio vs the earlier rung's.
///
///  - natural 16: baseline, by definition.
///  - tight 30 (1.875x): fitted window (28.1, 31.1) from labeled w60/w90 reference pairs. // guarded-by: score_calibration_test.zig "RUNG_SCALE tight window: flips exactly where the fitted (28.1, 31.1) bound says (live seed numbers)"
///  - wrap_labels 32: no labeled pair pins it; kept monotone just above
///    tight so the ladder prior stays ordered.
///  - chain_wrap 48: ABOVE both switch scales, deliberately breaking the
///    ladder's direction-preserving prior. All three labeled fold pairs go
///    against the fold: self_loop_lr_4 w60 6-1, pr_review_lr_10 w90 9-1,
///    cicd_pipeline_lr_10 w90 6-5 (near-tie) — this encodes "folds strand
///    dead space until the motif/lanes work lands" (re-audit when folds
///    improve). Lower bound 47.8 from self_loop_lr w60 (36*203 <
///    scale*153); ceiling 50 (truncate) keeps a fold preferable to
///    clipping. The self_loop_lr margin is thin (7308-vs-7344).
///  - switch_direction (rung 4): SPLIT by the candidate's FINAL direction —
///    see SWITCH_TO_VERTICAL_SCALE / SWITCH_TO_HORIZONTAL_SCALE below. The
///    array slot holds the vertical (lower) value; `eval` overrides via
///    `switchScale`.
///  - truncate 50 (3.125x): lower bounds 40.9-adjacent from
///    chained_bidir_lr_8 w90 (switch beats truncate: 864*36 < 707*scale →
///    scale > 44.0) and 31.4 from ampersand_fanout w60 (natural over
///    truncate at 445-vs-227); upper bound 56.6 from microservices_layers
///    w90 (the labeled preference flips to truncate; see W_INTEGRITY).
pub const RUNG_SCALE = [6]u64{ 16, 30, 32, 48, SWITCH_TO_VERTICAL_SCALE, 50 };

/// Rotation asymmetry: rotations INTO vertical (LR/RL->TD) price cheaper (36, window 35.4-42.2) than rotations OUT of TD into horizontal (44). // guarded-by: score_calibration_test.zig "SWITCH_TO_VERTICAL_SCALE window: flips exactly where the fitted (35.4, 42.2) bound says (live seed numbers)"
pub const SWITCH_TO_VERTICAL_SCALE: u64 = 36;
/// Fitted lower bound 40.0. // guarded-by: score_calibration_test.zig "SWITCH_TO_HORIZONTAL_SCALE lower bound: natural stays ahead at the fitted 44 (live seed numbers)"
pub const SWITCH_TO_HORIZONTAL_SCALE: u64 = 44;

/// PROVISIONAL scale for the NEGOTIATED chain-wrap fold candidate; applied
/// by select.zig via `evalScaled`, keyed off `Transform.negotiated_fold`
/// — the candidate's recorded rung is still chain_wrap. Rationale:
/// chain_wrap's 48 encodes "folds strand dead space until the motif/lanes
/// work lands"; a negotiated fold whose band breaks reserve MEASURED
/// back-edge gutters (chain_wrap.bandMargin via lanes.gutter) no longer
/// earns the blind fold's stranded-dead-space reputation tax. Priced at
/// switch_to_horizontal's 44: below the blind fold (48) and truncate (50),
/// but still above switch_to_vertical (36) until new labeled reference
/// pairs re-fit this constant.
pub const CHAIN_WRAP_NEGOTIATED_SCALE: u64 = 44;

/// One legibility unit in composite space (the 16ths base).
const SCALE_ONE: u64 = 16;

/// `RUNG_SCALE` index of the switch_direction rung: any candidate whose
/// direction differs from the source pays AT LEAST the direction-matched
/// switch multiplier, even if its recorded rung is lower (belt-and-braces;
/// today only rung 4 rotates — and rung 4 always rotates, so this same
/// `@max` path is what applies the vertical/horizontal split to it).
pub const SWITCH_SCALE_INDEX: usize = 4;

/// Switch multiplier for a rotated candidate, keyed by its FINAL
/// (post-rotation) direction — `Sketch.direction` is post-rotation (see
/// budget.rotateForRung / runForced).
pub fn switchScale(final_direction: Direction) u64 {
    return switch (final_direction) {
        .TD, .BT => SWITCH_TO_VERTICAL_SCALE,
        .LR, .RL => SWITCH_TO_HORIZONTAL_SCALE,
    };
}

/// Composite cost per integrity violation, in 16ths (= 1280 dead-space cells at natural scale). Large, not a veto. Fitted window (17098, 36200). // guarded-by: score_calibration_test.zig "W_INTEGRITY window: crosses exactly where the fitted (17098, 36200) bound says"
pub const W_INTEGRITY: u64 = 20480;

/// Raster-time shipped-defect counts for one candidate, computed by
/// audit.zig (this file may not import raster); `.{}` = not audited.
pub const RasterCounts = struct {
    labels_dropped: u32 = 0,
    /// Labels the fallback ladder placed away from their primary anchor.
    labels_displaced: u32 = 0,
    edge_cells_lost: u32 = 0,
};

/// Composite cost per raster-DROPPED label, in 16ths; rung-scale-independent (added AFTER the RUNG_SCALE multiply, same tier as W_INTEGRITY). 4096 keeps W_INTEGRITY/label ≈ 5:1 — Sketch-level violations stay dearer. // guarded-by: score_calibration_test.zig "W_LABEL_DROP prices a dropped label + lost cells above the shape_zoo_td_8 legibility margin"
pub const W_LABEL_DROP: u64 = 4096;

/// Composite cost per edge cell lost to collision at raster time, in 16ths.
/// Fitted with W_LABEL_DROP (shape_zoo constraint above); individually
/// unpinned — drops and lost cells co-occur in every labeled pair to date.
/// 512 keeps a few lost cells below one integrity violation while still
/// separating candidates with identical drop counts.
pub const W_CELL_LOST: u64 = 512;

/// Composite cost per raster-DISPLACED label (placed by the fallback ladder, but not at its primary anchor — see raster/labels_edge.zig). Fitted window [577, 608], well under a drop (4096) — displacement is degraded legibility, not lost information. // guarded-by: score_calibration_test.zig "W_LABEL_DISPLACED window: crosses exactly where the fitted [577, 608]-ish bound says (self_loop_lr_4 + shape_zoo numbers)"
pub const W_LABEL_DISPLACED: u64 = 592;

/// Natural-preference (hysteresis) margin, in composite 16ths: a challenger
/// may displace the natural-rung candidate at the T12 composite tier only
/// when its composite beats natural's by at least this much. Fitted from
/// live-flip data: every reference-endorsed displacement of
/// natural won by a wide margin (smallest of the 13 live flips:
/// td_with_lr_subgraph_7 w60 tight, 16*362 - 30*186 = 212; next 660), while
/// the internal tiny bare-label fixtures flip on slivers (chain_td_2 8,
/// chain_td_3/bt_3 16, chain_td_5 32, deep_narrow 48 — one to three dead
/// cells of uncalibrated tiny-diagram noise, not signal). Window (48, 212);
/// 128 sits mid-window. Decisions at T0 (natural overflows, the challenger
/// does not) are exempt, as are exact-composite ties that fall through to
/// T3/T4 — the margin only filters sliver composite wins.
pub const NATURAL_PREFERENCE_MARGIN: u64 = 128;

/// Selection predicate for `entry.scoreCandidates`: may `challenger`
/// displace the natural-rung candidate? Requires strict score superiority
/// and — when the decision falls in the T12 composite tier — superiority
/// by at least `NATURAL_PREFERENCE_MARGIN`.
pub fn displacesNatural(challenger: Score, natural: Score) bool {
    if (!challenger.lessThan(natural)) return false;
    if (challenger.t0_fit != natural.t0_fit) return true; // T0-decided: exempt
    if (challenger.t12_composite == natural.t12_composite) return true; // T3/T4-decided
    return natural.t12_composite - challenger.t12_composite >= NATURAL_PREFERENCE_MARGIN;
}

// -- T2 legibility weights -------------------------------------------------

/// Weight per cell of bbox area not covered by any node/cluster/edge.
const W_DEAD_SPACE: u64 = 1;
/// Weight per cell of polyline detour beyond the endpoints' manhattan span.
const W_EDGE_STRETCH: u64 = 2;
/// Weight per interior axis flip in an edge polyline.
const W_BENDS: u64 = 2;
/// Weight per edge-pair polyline crossing. Deliberately LOW (the plan:
/// "crossings low-weight").
const W_CROSSINGS: u64 = 1;
/// Weight per node whose label was force-wrapped by the budget.
const W_LABEL_WRAPS: u64 = 2;

// -- Score ---------------------------------------------------------------------

/// Integer score; lower is better. Ordering compares t0_fit, then
/// t12_composite, then t3_height, then t4_index. `t1_integrity` and
/// `t2_legibility` are the raw pre-weight measurements, kept for the
/// shadow disagreement line and external diagnostics.
pub const Score = struct {
    t0_fit: u32,
    t1_integrity: u32,
    t2_legibility: u64,
    t3_height: u32,
    t4_index: u32,
    /// RUNG_SCALE[rung]*t2 + W_INTEGRITY*t1 + W_LABEL_DROP*drops +
    /// W_LABEL_DISPLACED*displaced + W_CELL_LOST*lost.
    t12_composite: u64,
    /// Raw raster audit counts, kept for shadow telemetry.
    r_labels_dropped: u32 = 0,
    r_edge_cells_lost: u32 = 0,

    /// Strict "a is better than b".
    pub fn lessThan(a: Score, b: Score) bool {
        if (a.t0_fit != b.t0_fit) return a.t0_fit < b.t0_fit;
        if (a.t12_composite != b.t12_composite) return a.t12_composite < b.t12_composite;
        if (a.t3_height != b.t3_height) return a.t3_height < b.t3_height;
        return a.t4_index < b.t4_index;
    }

    /// Name of the first tier at which `a` and `b` differ ("t0", "t12",
    /// "t3", "t4"), or "tie" when fully equal. Used by the shadow line.
    pub fn decidingTier(a: Score, b: Score) []const u8 {
        if (a.t0_fit != b.t0_fit) return "t0";
        if (a.t12_composite != b.t12_composite) return "t12";
        if (a.t3_height != b.t3_height) return "t3";
        if (a.t4_index != b.t4_index) return "t4";
        return "tie";
    }
};

/// Score one candidate Sketch. `source_direction` is the ORIGINAL graph
/// direction (pre-rotation): a direction-infidel candidate pays at least
/// the switch_direction multiplier regardless of its recorded rung.
/// `candidate_index` is the rung-ladder position (T4 tiebreak); `raster`
/// is this candidate's audit.zig count. Allocations: arena expected.
pub fn eval(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    source_direction: Direction,
    candidate_index: u32,
    raster: RasterCounts,
) !Score {
    return evalScaled(allocator, s, source_direction, candidate_index, raster, false);
}

/// `eval` for a possibly-NEGOTIATED candidate. When `negotiated_fold` is
/// true the rung-scale lookup is replaced by CHAIN_WRAP_NEGOTIATED_SCALE
/// (the direction-infidelity floor still applies on top): the candidate's
/// Sketch records the chain_wrap rung, whose 48 would overtax the
/// measured-gutter fold. select.zig passes
/// `cand.transform == .negotiated_fold`; the scale decision lives HERE so
/// score.zig is the single producer of composite scales.
pub fn evalScaled(
    allocator: std.mem.Allocator,
    s: sketch.Sketch,
    source_direction: Direction,
    candidate_index: u32,
    raster: RasterCounts,
    negotiated_fold: bool,
) !Score {
    const counts = blk: {
        const vr = try validate.validate(allocator, s);
        break :blk validate.counts(vr, s);
    };
    const t1: u32 = counts.node_overlap + counts.path_off_perimeter +
        counts.path_through_interior + counts.cluster_containment +
        counts.cluster_port;

    const dead = try geom.deadSpace(allocator, s);
    const t2: u64 = W_DEAD_SPACE * dead +
        W_EDGE_STRETCH * geom.edgeStretch(s) +
        W_BENDS * geom.bends(s) +
        W_CROSSINGS * geom.countCrossings(s) +
        W_LABEL_WRAPS * geom.labelWraps(s);

    const rung_idx: usize = @min(s.budget.rung, RUNG_SCALE.len - 1);
    var scale = if (negotiated_fold) CHAIN_WRAP_NEGOTIATED_SCALE else RUNG_SCALE[rung_idx];
    if (s.direction != source_direction) scale = @max(scale, switchScale(s.direction));

    return .{
        .t0_fit = fitSeverity(s),
        .t1_integrity = t1,
        .t2_legibility = t2,
        .t3_height = s.bbox.h,
        .t4_index = candidate_index,
        .t12_composite = scale * t2 + W_INTEGRITY * @as(u64, t1) +
            W_LABEL_DROP * @as(u64, raster.labels_dropped) +
            W_LABEL_DISPLACED * @as(u64, raster.labels_displaced) +
            W_CELL_LOST * @as(u64, raster.edge_cells_lost),
        .r_labels_dropped = raster.labels_dropped,
        .r_edge_cells_lost = raster.edge_cells_lost,
    };
}

// -- T0: fit severity ----------------------------------------------------------

/// Overflow MAGNITUDE: columns of bbox beyond the budget, plus one per
/// `width_overflow` diagnostic. 0 = fits. The bbox excess dominates so a
/// mild clip beats a catastrophic one (frenzy w60: truncate excess ~19 vs
/// rotated excess ~194 — the old presence-count tied them 2-2 and let 34
/// integrity violations decide AGAINST the labeled preference). The small per-diagnostic
/// add keeps the value nonzero for any layout-reported overflow even when
/// the bbox itself was already cut back to the budget.
///
/// Pub: select.zig's cheap T0 pre-pass uses this to skip the raster audit +
/// full eval for candidates that cannot win the T0 tier.
pub fn fitSeverity(s: sketch.Sketch) u32 {
    var n: u32 = s.bbox.w -| s.budget.max_width;
    for (s.diagnostics) |d| switch (d) {
        .width_overflow => n += 1,
        else => {},
    };
    return n;
}

// ====================================================================
// Tests
// ====================================================================
// All unit tests live in score_test.zig (split to keep this file under
// the mermaid_v2 500-line cap). The chain reference below pulls them in.

test {
    _ = @import("score_test.zig");
    _ = @import("score_calibration_test.zig");
}

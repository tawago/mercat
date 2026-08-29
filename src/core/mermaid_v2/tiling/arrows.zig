//! Arrowhead ink laws for the report-only structural audit.
//!
//! LATERAL EXCLUSIVITY: an arrowhead's run is its tip axis. The two
//! TIP-PERPENDICULAR bits are not part of that run, so every one of them
//! must be explained by something adjacent — otherwise the cell's mask
//! claims ink that does not exist.
//!
//! This counter is METADATA HYGIENE, not a painted defect: `paint.zig`
//! ignores an arrowhead's neighbour mask entirely and draws the glyph
//! from the tip alone. What an orphan lateral bit costs is truth in the
//! IR — every downstream reader (the audit itself, any future
//! consumer) is entitled to believe the mask.
//!
//! Why orphans genuinely accumulate rather than being repaired:
//! `reconcile.isJunctionBearing` admits only `edge_segment` and
//! `cluster_border`, so arrowhead masks are never reconciled.
//!
//! LEGAL populations that must never land in `d_`: the edge writer
//! OR-merges a foreign crossing's bits into an arrowhead cell, and the
//! refuse branch of the guarded write lays down a pristine along-axis
//! mask. Both leave laterals whose neighbours reciprocate, so they land
//! in `c_arrow_lat_explained`.
//! guarded-by: tiling_crosscheck_test.zig "clustered crossing render has zero orphan arrowhead laterals"
//!
//! BASE SUPPORT: the cell opposite an arrowhead's tip must carry an arm
//! pointing INTO the triangle. That law already exists in the renderer
//! (`raster/arrow_base.zig`), which reports one undifferentiated
//! violation count; `checkBase` is a bucketed DECOMPOSITION of it,
//! evaluated in exactly that validator's order, so the buckets partition
//! its violation set and the exemption it grants. The identity is pinned
//! from the crosscheck, which can see both instruments.
//! guarded-by: tiling_crosscheck_test.zig "base buckets decompose arrow_base.validate exactly"
//!
//! Imports: `std`, `prim`, `lattice.zig`, tiling siblings.

const std = @import("std");
const cell = @import("cell.zig");
const counts = @import("counts.zig");

/// Lateral-exclusivity check for ONE arrowhead cell. Called from
/// `scan.run`'s single ownership dispatch, which guarantees `t.kind ==
/// .arrow`; the two perpendicular bits are this family's property and no
/// other check may consume them.
///
/// First-match ladder per set perpendicular bit:
///   stroke/arrow reciprocating -> explained
///   ring (node or frame)       -> frame-solid convention
///   glyph / fill               -> opaque: nothing there can reciprocate
///   blank / ghost / OOB        -> gap reprieve, else orphan
///   stroke/arrow silent        -> orphan
pub fn checkLateral(v: cell.View, x: u32, y: u32, t: cell.Typed, c: *counts.Counts) void {
    const tip = t.tip orelse return;
    for (cell.perpendicular(tip)) |p| {
        if (t.ink & cell.bit(p) == 0) continue;
        const n = v.arm(x, y, p) orelse {
            // Off-grid: nothing can explain the bit and there is no cell
            // beyond it to resume from.
            c.d_arrow_lat_orphan += 1;
            continue;
        };
        switch (n.kind) {
            .stroke, .arrow => {
                if (v.reciprocates(x, y, p)) c.c_arrow_lat_explained += 1 else c.d_arrow_lat_orphan += 1;
            },
            .ring_node, .ring_frame => c.c_arrow_lat_frame += 1,
            .glyph, .fill => c.c_arrow_lat_opaque += 1,
            .blank, .ghost => {
                // A ghost occupies the cell but paints nothing, so it is
                // treated exactly like background: the run may still
                // resume one cell further along the same axis.
                if (v.gapReprieve(x, y, p)) c.c_arrow_lat_explained += 1 else c.d_arrow_lat_orphan += 1;
            },
        }
    }
}

/// Mirror of `raster/arrow_base.sideFed`: the arrowhead at `(x,y)` is fed
/// by edge ink arriving PERPENDICULAR to its tip axis — the run turned
/// the corner at the tip. Judged on the NEIGHBOUR's occupant and mask
/// (a coincident frame passing through is not a side feed), exactly as
/// the original does; an invisible stroke carrying the bit counts, since
/// the original is blind to stroke kind.
/// guarded-by: tiling_crosscheck_test.zig "sideFed mirrors raster/arrow_base.sideFed over an occupant x mask matrix"
pub fn sideFed(v: cell.View, x: u32, y: u32, tip: cell.Dir4) bool {
    for (cell.perpendicular(tip)) |p| {
        const n = v.arm(x, y, p) orelse continue;
        const edgey = switch (n.kind) {
            .stroke, .ghost, .arrow => true,
            else => false,
        };
        if (edgey and n.mask & cell.bit(cell.reverse(p)) != 0) return true;
    }
    return false;
}

/// True for the fan-strip roles. The fan-trunk stamp rewrites those masks
/// at the end of the edges stage, so such a base legally lacks the
/// into-arrow arm and the renderer's weld never repairs it.
fn isFanStrip(role: ?cell.EdgeRole) bool {
    const r = role orelse return false;
    return switch (r) {
        .fan_out_rail, .fan_out_dropper, .fan_in_rail, .fan_in_dropper => true,
        else => false,
    };
}

/// Base-support check for ONE arrowhead cell: the ladder below is the
/// renderer validator's own decision order, split into buckets.
///
///   1  base off-grid                     -> u_base_oob
///   2  base is a label glyph             -> c_base_label   (validate exempts)
///   3  base mask carries the into-arm    -> fed, no bucket
///   4  the run turned the corner here    -> c_base_side_fed
///   5  base is background                -> d_base_blank
///   6  base is edge ink: fan strip       -> c_base_fan_trunk
///                       foreign edge     -> c_base_foreign
///                       own edge         -> d_base_unfed
///   7  base is a cluster frame           -> c_base_frame
///   8  base is node/arrow ink            -> d_base_unfed
///
/// Steps 1 and 4-8 partition the validator's violations; step 2 is its
/// exemption. Judged on `mask`, not `ink`: the original is blind to
/// stroke kind, so an invisible base carrying the bit reads as fed in
/// both instruments.
pub fn checkBase(v: cell.View, x: u32, y: u32, t: cell.Typed, c: *counts.Counts) void {
    const tip = t.tip orelse return;
    const b = v.arm(x, y, cell.reverse(tip)) orelse {
        c.u_base_oob += 1;
        return;
    };
    if (b.kind == .glyph) {
        c.c_base_label += 1;
        return;
    }
    if (b.mask & cell.intoArrowBit(tip) != 0) return;
    if (sideFed(v, x, y, tip)) {
        c.c_base_side_fed += 1;
        return;
    }
    switch (b.kind) {
        .blank => c.d_base_blank += 1,
        .stroke, .ghost => {
            if (isFanStrip(b.edge_role)) {
                c.c_base_fan_trunk += 1;
            } else if (b.edge != null and t.edge != null and b.edge.? != t.edge.?) {
                c.c_base_foreign += 1;
            } else {
                c.d_base_unfed += 1;
            }
        },
        .ring_frame => c.c_base_frame += 1,
        .ring_node, .fill, .arrow => c.d_base_unfed += 1,
        // Handled by step 2 above; kept explicit so a new Kind cannot
        // slip through without a bucket.
        .glyph => unreachable,
    }
}

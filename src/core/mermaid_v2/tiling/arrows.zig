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
//! IR — every downstream reader (weld, the audit itself, any future
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

//! Orchestrator of the report-only structural audit (`tiling/`).
//!
//! WHAT THIS IS. A dark audit over the FINAL, SHIPPED lattice: it runs
//! once per render in the composition root, after the raster's own weld
//! and validate passes, and emits one `mercat-tiling:` stderr line under
//! `MERCAT_TILING_AUDIT=1`. It is structurally incapable of steering
//! anything — the per-candidate raster audit that feeds `score` lives in
//! the root-level `audit.zig`, runs earlier, and shares no code with this.
//!
//! NON-MUTATION — the honest version. `Lattice.at()` takes `self` BY
//! VALUE and returns `*Cell`, so a `*const Lattice` alone would NOT make
//! a write a compile error. The guarantee is threefold instead:
//!   (a) checks receive a `cell.View`, which hands out `Typed` COPIES and
//!       never a `*Cell`;
//!   (b) the lint zone forbids importing `raster/`, so no writer is even
//!       reachable from here;
//!   (c) a byte snapshot of `lat.cells` before/after `run()`, plus
//!       painted-string equality, is the pinned proof.
//! guarded-by: scan_test.zig "scan: run() leaves the lattice byte-identical"
//!
//! BIT OWNERSHIP. `run()` owns the single cell loop and routes every cell
//! to exactly ONE check family by `Typed.kind`; within a family every
//! (cell, direction-bit) lands in exactly one bucket via a first-match
//! ladder. Nothing may be counted twice, so `defectTotal()` stays a sum
//! of distinct events:
//!
//!   arrow      -> the two TIP-PERPENDICULAR bits: lateral exclusivity;
//!                 the opposite-tip cell: base support (both arrows.zig).
//!                 The tip-direction abutment is disjoint by direction and
//!                 lands in the terminal family (terminal.zig).
//!   stroke     -> arity/stub, per-arm dangling, collinear fusion
//!                 (strokes.zig); an arm landing on a RING goes to the
//!                 terminal family instead, which is the one target the
//!                 dangling ladder deliberately files under no bucket.
//!   ring_node  -> outline stencil + off-ring fusion (rings.zig).
//!   ring_frame -> frame stencil + off-ring fusion (rings.zig).
//!   ghost/glyph/fill/blank -> population counters only.
//!
//! One exception, and it is cell-level rather than bit-level: ink sitting
//! INSIDE a node's fill is a property of the cell, not of any arm, so
//! `strokes.inkInInterior` is consulted for stroke AND arrowhead cells.
//! It can fire at most once per cell, so the ownership property holds.
//! guarded-by: scan_test.zig "ownership: each seeded defect increments defectTotal by exactly one"
//!
//! After the lattice tier, the SKETCH-anchored expectation tier
//! (`expect.zig`) asks what the geometry declared that the ink does not
//! show. That tier is the only one that allocates, and it degrades to
//! partial counts rather than failing a render.
//!
//! Imports: `std`, `prim`, `lattice.zig`, `sem_graph.zig`, `sketch.zig`,
//! tiling siblings (see `tools/lint_imports.zig`).

const std = @import("std");
const prim = @import("prim");
const lattice = @import("../lattice.zig");
const sem_graph = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const arrows = @import("arrows.zig");
const strokes = @import("strokes.zig");
const rings = @import("rings.zig");
const terminal = @import("terminal.zig");
const expect = @import("expect.zig");

/// Everything the audit reads. Assembled by the composition root from
/// values that are already live there; the audit derives nothing itself
/// and re-runs no pipeline stage.
pub const Ctx = struct {
    graph: sem_graph.SemGraph,
    sketch: sketch.Sketch,
    /// The SHIPPED lattice — post-weld, post-validate, pre-paint.
    lat: *const lattice.Lattice,
    /// Frame notation actually used. Steers bucketing only.
    mode: prim.SubgraphEdges,
    /// Raster-report scalars, carried verbatim so the audit can compare
    /// its own census against the rasterizer's without re-deriving it.
    labels_placed: u32 = 0,
    labels_dropped: u32 = 0,
    labels_displaced: u32 = 0,
    edge_cells_lost: u32 = 0,
};

/// Scan `ctx.lat` and return the counts. Never fails: an audit that
/// cannot allocate degrades to partial counts (`u_audit_oom`) rather
/// than propagating an error into a render.
pub fn run(alloc: std.mem.Allocator, ctx: Ctx) counts.Counts {
    var c: counts.Counts = .{};
    c.n_clustered = @intCast(ctx.graph.clusters.len);
    const mode_cross = ctx.mode == .cross;
    c.n_mode_cross = if (mode_cross) 1 else 0;

    const w = ctx.lat.width;
    const h = ctx.lat.height;
    // A zero-sized lattice is an empty render: no ink to judge, and no
    // position for the expectation tier to look at either.
    if (w == 0 or h == 0) return c;
    c.n_cells = @intCast(@min(@as(u64, w) * @as(u64, h), std.math.maxInt(u32)));

    const v = cell.View.init(ctx.lat);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        // Painted columns of this row, against the w CELLS it occupies.
        var cols: u32 = 0;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const t = v.at(x, y) orelse continue;
            cols += v.columns(x, y);
            if (v.isWideGlyph(x, y)) c.m_wide_label_cells += 1;

            // The single ownership dispatch (see the module doc).
            switch (t.kind) {
                .arrow => {
                    c.n_arrow_cells += 1;
                    arrows.checkLateral(v, x, y, t, &c);
                    arrows.checkBase(v, x, y, t, &c);
                    terminal.check(v, x, y, t, &c);
                    if (strokes.inkInInterior(v, x, y)) c.d_ink_in_interior += 1;
                },
                .stroke => {
                    c.n_stroke_cells += 1;
                    strokes.check(v, x, y, t, &c);
                    terminal.check(v, x, y, t, &c);
                },
                .ghost => c.n_ghost_cells += 1,
                .ring_node => {
                    c.n_ring_node_cells += 1;
                    rings.check(v, x, y, t, mode_cross, &c);
                },
                .ring_frame => {
                    c.n_ring_frame_cells += 1;
                    rings.check(v, x, y, t, mode_cross, &c);
                },
                .fill, .glyph, .blank => {},
            }
        }
        if (cols > w) c.m_row_col_overflow += cols - w;
    }

    expect.check(alloc, .{
        .graph = ctx.graph,
        .sketch = ctx.sketch,
        .lat = ctx.lat,
        .labels_placed = ctx.labels_placed,
        .labels_dropped = ctx.labels_dropped,
        .labels_displaced = ctx.labels_displaced,
    }, &c);

    return c;
}

/// Run the audit and emit its one stderr line. The composition root
/// gates this on `MERCAT_TILING_AUDIT=1`.
pub fn emit(alloc: std.mem.Allocator, ctx: Ctx) void {
    run(alloc, ctx).emitLine();
}

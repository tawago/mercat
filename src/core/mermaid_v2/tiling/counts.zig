//! Counter record of the report-only structural audit (`tiling/`).
//!
//! PREFIX CONTRACT — every field name begins with exactly one of:
//!
//!   `n_`  population / denominator. Never a claim; the thing the rates
//!         below are measured against.
//!   `m_`  measurement. A number with no defect claim attached.
//!   `c_`  renderer CONVENTION: legal by construction, counted so the
//!         legal population can never contaminate the defect total.
//!   `d_`  genuine defect candidate. `defectTotal()` sums exactly these
//!         and nothing else — it is the one human number on the line.
//!   `u_`  audit-side limitation (fix the audit, not the renderer).
//!
//! A bucket is added, never suppressed: when a legal rendering lands in a
//! `d_` field the answer is a new `c_` bucket, not a filter.
//! guarded-by: counts_test.zig "counts: every field carries an n_/m_/c_/d_/u_ prefix"
//!
//! Flat, all `u32`, reflection-emitted: the struct and the printer cannot
//! drift because `writeLine` enumerates the fields.
//! Imports: `std` only.

const std = @import("std");

/// Field-name prefixes of the contract, in declaration order. Exposed so
/// the completeness test and any future consumer read the same list.
pub const prefixes = [_][]const u8{ "n_", "m_", "c_", "d_", "u_" };

/// Byte budget of one emitted line. Sized so that even the absolute worst
/// case — every counter printed at a u32's full ten digits — leaves the
/// buffer half empty, so the taxonomy can keep growing; `writeLine`
/// truncates rather than failing either way.
/// guarded-by: counts_test.zig "writeLine: the whole taxonomy fits the line buffer with room to grow"
pub const line_buf_len: usize = 8192;

/// Leading token of the emitted stderr line — the grep handle.
pub const line_prefix = "mercat-tiling:";

/// Every counter the audit maintains. Fields are grouped by the check
/// family that owns them (see `scan.zig`'s ownership table); a family's
/// fields appear only once the commit that implements it lands.
pub const Counts = struct {
    // -- meta ---------------------------------------------------------
    /// Lattice cells visited (`width * height`). The denominator.
    n_cells: u32 = 0,
    /// Clusters (subgraphs) declared in the SemGraph. Zero on a flat
    /// render; nonzero flags the population where fusion/shadowing
    /// conventions are expected and per-edge identity is lossy.
    n_clustered: u32 = 0,
    /// 1 when this render used the `cross` frame notation, else 0. Steers
    /// bucketing only (a frame arm is a convention under `cross` and a
    /// leak under `bridge`); never a defect by itself.
    n_mode_cross: u32 = 0,
    /// The audit's own scratch allocation failed and a tier was skipped.
    /// An audit limitation: the counts on this line are partial.
    u_audit_oom: u32 = 0,

    // -- arrowhead lateral exclusivity (arrows.zig) -------------------
    /// Arrowhead cells scanned.
    n_arrow_cells: u32 = 0,
    /// A lateral (tip-perpendicular) arm whose neighbour reciprocates, or
    /// resumes across a 1-cell reprieved gap: the ink genuinely turns or
    /// crosses here.
    c_arrow_lat_explained: u32 = 0,
    /// A lateral arm abutting a node/cluster ring — frame-solid: the ring
    /// never reciprocates, and the arrowhead inherited the bit legally.
    c_arrow_lat_frame: u32 = 0,
    /// A lateral arm abutting an opaque cell (label glyph or node fill):
    /// nothing there can reciprocate, so the bit explains itself.
    c_arrow_lat_opaque: u32 = 0,
    /// A lateral arm with nothing to explain it: metadata claiming ink
    /// that does not exist. Arrowhead masks are never reconciled, so
    /// these accumulate rather than being repaired.
    d_arrow_lat_orphan: u32 = 0,

    // -- arrowhead base support (arrows.zig) --------------------------
    /// The base cell is a label/title glyph. `arrow_base.baseFeedsArrow`
    /// exempts these by construction: the owner's convention leaves a run
    /// interrupted by a label in place, so it is never a violation.
    c_base_label: u32 = 0,
    /// The edge turned the corner AT the arrowhead: ink arrives
    /// perpendicular to the tip axis. A routing artifact, not a stub gap —
    /// `weld` refuses to touch these.
    c_base_side_fed: u32 = 0,
    /// The base is a fan trunk/rail cell. The fan-strip stamp rewrites
    /// those masks at the end of the edges stage, so a trunk base legally
    /// lacks the into-arrow arm.
    c_base_fan_trunk: u32 = 0,
    /// The base is a FOREIGN edge's stroke. Welding here would fabricate a
    /// junction between two unrelated runs, so `weld` refuses by design.
    c_base_foreign: u32 = 0,
    /// The base is a cluster frame. Frame-solid: `weld` leaves frames
    /// alone, so the arrowhead legally sits against an unmerged border.
    c_base_frame: u32 = 0,
    /// The base cell is background and nothing lies behind it — the
    /// arrowhead floats, receiving its tip on nothing.
    d_base_blank: u32 = 0,
    /// The base is this edge's own ink (or node/arrow ink) yet carries no
    /// arm into the triangle: a real break in the run at the tip.
    d_base_unfed: u32 = 0,
    /// The base cell would lie outside the lattice. An audit limitation as
    /// much as a defect: the geometry that produced it is off-grid.
    u_base_oob: u32 = 0,

    // -- stroke ink laws (strokes.zig) --------------------------------
    /// Visible edge-segment cells scanned.
    n_stroke_cells: u32 = 0,
    /// Invisible (`~~~`) edge-segment cells: they occupy a cell, paint a
    /// blank, and enter no ink law.
    n_ghost_cells: u32 = 0,
    /// A stroke cell with no arms at all: the painter has no junction to
    /// draw from, so the cell paints a lone fallback glyph.
    d_stroke_armless: u32 = 0,
    /// A one-armed stroke abutting an arrowhead, ring, or label — the
    /// legitimate way a run stops.
    c_stub_terminal: u32 = 0,
    /// A one-armed stroke with nothing terminal beside it: a run that
    /// simply stops in open space.
    d_stroke_stub: u32 = 0,
    /// Two-armed stroke cells that turn (path-simplicity proxy).
    m_corner_cells: u32 = 0,
    /// Two-armed stroke cells that run straight through.
    m_straight_cells: u32 = 0,
    /// Three-armed stroke cells (tees).
    m_tee_cells: u32 = 0,
    /// Four-armed stroke cells (crosses).
    m_cross_cells: u32 = 0,
    /// An arm pointing at background whose run genuinely resumes one cell
    /// further along the axis — the port-padding reprieve reconcile grants.
    c_arm_gap_reprieved: u32 = 0,
    /// An arm pointing at an invisible edge's cell: it occupies the cell
    /// but paints nothing, so the arm terminates on a blank by convention.
    c_arm_into_ghost: u32 = 0,
    /// An arm pointing at background with no resumption. Reconcile clears
    /// this class before labels run, so a nonzero value localises to a
    /// POST-reconcile regression (labels, weld).
    d_arm_dangling: u32 = 0,
    /// An arm pointing into a node's fill: ink asserting a connection to
    /// the inside of a box.
    d_arm_into_fill: u32 = 0,
    /// A stroke or arrowhead cell with the SAME node's fill on two
    /// opposite sides: ink crossing a box's interior. Suppresses that
    /// cell's per-arm into-fill increments so one event counts once.
    d_ink_in_interior: u32 = 0,
    /// Two adjacent straight-through stroke cells of DIFFERENT edges
    /// reciprocating along the shared axis: two runs fused into one line.
    /// UNDER-counts by construction (first-writer-wins hides fully
    /// overlapping pairs) — the safe direction.
    d_run_fused_collinear: u32 = 0,
    /// The same adjacency where one of the two cells is a JUNCTION (three
    /// or four arms): the runs genuinely meet there, so the differing id
    /// is the first-writer artifact and not a fusion.
    c_run_fused_crossing: u32 = 0,
    /// A stroke arm at a stroke neighbour that does not carry the
    /// reciprocal bit. Pure measurement: the repair pass has its own
    /// guards and this does not reproduce them.
    m_arm_asym: u32 = 0,

    // -- ring stencils and fusion (rings.zig) -------------------------
    /// Node-border cells scanned.
    n_ring_node_cells: u32 = 0,
    /// Cluster-frame cells scanned.
    n_ring_frame_cells: u32 = 0,
    /// A corner cell carrying fewer than two of its full-rect ring axes:
    /// the signature of a degenerate 1xN / Nx1 node. Stencil skipped.
    c_ring_node_thin: u32 = 0,
    /// A ring arm landing on a cluster frame or another node's ring:
    /// clusters rasterize first and border writes skip occupied cells, so
    /// this cell was legally never written.
    c_ring_node_shadowed: u32 = 0,
    /// A ring arm landing on a label glyph: a title band overwrote it.
    c_ring_node_label: u32 = 0,
    /// A ring arm landing on background: the outline is broken.
    d_ring_node_break: u32 = 0,
    /// A frame arm landing on a label glyph — the title band stamps EVERY
    /// cell of its span, spaces included.
    c_ring_frame_title: u32 = 0,
    /// A frame arm landing on edge ink: a terminal arrival into the
    /// cluster replaced the border cell.
    c_ring_frame_terminal: u32 = 0,
    /// A frame arm landing on another cluster's frame or on node geometry.
    c_ring_frame_shadowed: u32 = 0,
    /// A frame arm landing on background: the frame is broken. Reconcile
    /// clears frame phantoms, so residuals are post-label regressions.
    d_ring_frame_break: u32 = 0,
    /// A ring arm OFF the ring's own axes that feeds an arrowhead whose
    /// tip points along it — the arrowhead-base weld. Checked FIRST,
    /// because weld ORs an arm in for ANY tip including east/west.
    c_border_arm_weld: u32 = 0,
    /// A node ring's extra N/S arm: the source-border merge stamps the
    /// departure bit for vertical departures only.
    c_border_arm_source_ns: u32 = 0,
    /// A node ring's extra E/W arm. Nothing in the rasterizer writes one,
    /// so it is ink the border claims and no run provides.
    d_border_arm_ew: u32 = 0,
    /// A frame's extra arm under the `cross` notation, which welds edges
    /// into the border by design.
    c_frame_arm_cross_mode: u32 = 0,
    /// A frame's extra arm under `bridge`, which refuses frame fusion
    /// outright: a survivor is a leak.
    d_frame_arm_foreign: u32 = 0,

    // -- expectation tier (expect.zig) --------------------------------
    /// Non-invisible Sketch edges (each declares one terminal approach).
    n_edges_declared: u32 = 0,
    /// Bus-bar taps: fan edges whose sole geometry is the trunk.
    n_taps_declared: u32 = 0,
    /// A declared edge/tap whose final approach cell (and its one-cell
    /// reprieve) holds no ink at all: the arrival left no evidence.
    d_edge_no_terminal_evidence: u32 = 0,
    /// The approach cell holds foreign opaque ink (a ring, a label, a
    /// node fill, another edge's blank): the arrival was absorbed rather
    /// than lost. Positional evidence cannot tell whose ink it is.
    c_edge_absorbed: u32 = 0,
    /// Per placed node, declared in-arrivals minus the distinct ink cells
    /// abutting its perimeter, summed over nodes and floored at zero: the
    /// collision-shadowed arrivals per-edge positional evidence cannot see.
    m_term_ink_deficit: u32 = 0,
    /// Arrowheads the Sketch declares (edge ends, tap ends, pivot).
    n_arrows_declared: u32 = 0,
    /// A declared arrowhead with no arrowhead cell anywhere along its
    /// approach axis.
    d_arrow_missing: u32 = 0,
    /// The arrowhead's position is held by node geometry or a label — the
    /// documented refusal paths that increment the raster's lost-cell count.
    c_arrow_refused: u32 = 0,
    /// Placed nodes in the Sketch.
    n_nodes_declared: u32 = 0,
    /// A placed node with zero border cells carrying its id.
    d_node_ring_missing: u32 = 0,
    /// A placement not fully inside the lattice: the rasterizer skips it
    /// by design, so its missing ring is not a break.
    c_node_offgrid: u32 = 0,
    /// A node with label lines and room for them, yet no glyph inside.
    d_node_label_missing: u32 = 0,
    /// A node with label lines whose rect is too small to hold any: the
    /// label placer refuses below 3x3.
    c_node_label_no_room: u32 = 0,
    /// A vertical departure from a node border whose border cell does not
    /// carry the departure bit — the source-merge the rasterizer promises.
    d_source_merge_missing: u32 = 0,
    /// Labels the Sketch declares, counted exactly as the rasterizer
    /// counts its attempts.
    n_labels_declared: u32 = 0,
    /// Labels the rasterizer reported as dropped, carried verbatim.
    c_labels_dropped_reported: u32 = 0,
    /// Labels the rasterizer reported as displaced, carried verbatim.
    c_labels_displaced_reported: u32 = 0,
    /// Disagreement between this audit's declared-label census and the
    /// rasterizer's placed+dropped. A cross-instrument mismatch is an
    /// audit bug, never a renderer bug.
    u_label_census_mismatch: u32 = 0,
    /// SemGraph node count — the identity-free census half.
    m_graph_nodes: u32 = 0,
    /// SemGraph edge count.
    m_graph_edges: u32 = 0,
    /// Sketch placement count. A gap against `m_graph_nodes` is semantic
    /// loss between IR 1 and IR 2, visible without per-entity matching.
    m_sketch_nodes: u32 = 0,
    /// Sketch edge count (routed polylines plus bus-bar taps).
    m_sketch_edges: u32 = 0,

    // -- EAW label-geometry bridge ------------------------------------
    /// Label cells holding an East-Asian-Wide codepoint. Each such cell
    /// paints two columns while occupying one lattice cell.
    m_wide_label_cells: u32 = 0,
    /// Summed per-row excess of painted COLUMNS over lattice CELLS. The
    /// lattice is a cell grid, the terminal a column grid; a nonzero
    /// value means at least one row lies about its own width.
    m_row_col_overflow: u32 = 0,

    /// Sum of exactly the `d_` fields — the single number a reader looks
    /// at first. Reflection-driven, so a new defect bucket is included
    /// the moment it is declared.
    /// guarded-by: counts_test.zig "counts: defectTotal sums exactly the d_ fields"
    pub fn defectTotal(self: Counts) u32 {
        var total: u32 = 0;
        inline for (@typeInfo(Counts).@"struct".fields) |f| {
            if (comptime std.mem.startsWith(u8, f.name, "d_")) total += @field(self, f.name);
        }
        return total;
    }

    /// Render the one-line `mercat-tiling: k=v ...` form into `buf` and
    /// return the written slice. Truncates at the buffer end instead of
    /// failing — a diagnostic line must never break a render.
    /// The trailing `d_total` term is `defectTotal()`, not a field.
    /// guarded-by: counts_test.zig "writeLine: one token per field plus d_total, mercat-tiling prefix"
    pub fn writeLine(self: Counts, buf: []u8) []const u8 {
        var i: usize = 0;
        const head = std.fmt.bufPrint(buf, "{s}", .{line_prefix}) catch return buf[0..0];
        i = head.len;
        inline for (@typeInfo(Counts).@"struct".fields) |f| {
            const term = std.fmt.bufPrint(buf[i..], " {s}={d}", .{ f.name, @field(self, f.name) }) catch break;
            i += term.len;
        }
        const tail = std.fmt.bufPrint(buf[i..], " d_total={d}", .{self.defectTotal()}) catch return buf[0..i];
        return buf[0 .. i + tail.len];
    }

    /// Emit one line to STDERR. Stdout bytes are unaffected: this writes
    /// to stderr only and changes no pipeline decision.
    pub fn emitLine(self: Counts) void {
        var buf: [line_buf_len]u8 = undefined;
        std.debug.print("{s}\n", .{self.writeLine(&buf)});
    }
};

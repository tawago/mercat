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
//! drift because `writeLine` enumerates the fields. The printer itself lives
//! in `counts_line.zig` (cap split) and is re-exported here unchanged.
//! Imports: `std`, `counts_line.zig`.

const line = @import("counts_line.zig");

pub const prefixes = line.prefixes;
pub const line_buf_len = line.line_buf_len;
pub const line_prefix = line.line_prefix;

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
    n_aux_collection_complete: u32 = 0,
    n_aux_records_attempted: u32 = 0,
    n_aux_records_available: u32 = 0,
    u_aux_not_collected: u32 = 0,
    /// AUX collection failed atomically.
    u_aux_collection_oom: u32 = 0,
    /// Attempted records withheld by atomic collection failure.
    u_aux_records_lost: u32 = 0,

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
    /// `receiveBase` refuses to touch these.
    c_base_side_fed: u32 = 0,
    /// The base is a fan shared-run (rail) or dropper cell. The fan-strip
    /// stamp rewrites those masks at the end of the edges stage, so such a
    /// base legally lacks the into-arrow arm.
    c_base_fan_trunk: u32 = 0,
    /// The base is a FOREIGN edge's stroke. Welding here would fabricate a
    /// junction between two unrelated runs, so `receiveBase` refuses by design.
    c_base_foreign: u32 = 0,
    /// The base is a cluster frame. Frame-solid: `receiveBase` leaves frames
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
    /// or four arms). The PARENT population of the three buckets below,
    /// which partition it exactly:
    /// `c_run_fused_crossing == c_run_fused_licensed + d_run_fused_foreign
    /// + u_run_fused_unevidenced`.
    /// Kept whole rather than filtered: this tier adds buckets, it never
    /// removes one a reader already knows how to read.
    /// THE UNIT IS AN ADJACENT PAIR, NOT A CELL. `fusion` walks each cell's
    /// east and south arms, so one fabricated junction glyph is counted once
    /// per fused neighbour it has — a `┼` between two flanking runs scores
    /// TWO. Do not read any of these four numbers as "how many cells".
    /// guarded-by: strokes_test.zig "fusion: the three junction verdicts partition the crossing population"
    c_run_fused_crossing: u32 = 0,
    /// A junction of that adjacency where a `.carrier` record ON the
    /// junction cell names the OTHER cell's edge and states that the two
    /// legally shared a channel THERE. The glyph asserts an adjacency the
    /// crossing rule licensed, so the differing id really is a first-writer
    /// artifact.
    /// WEAKER THAN IT READS, for two reasons. The licence was evaluated for
    /// the ordered pair (the id the cell kept, the id it dropped), and on a
    /// rail's shared run the id the cell keeps is an arbitrary member of the
    /// fan: this clears the REPRESENTATIVE pair, not necessarily the two runs
    /// a reader traces. And a structural co-set (a realized join, a fan rail)
    /// licenses its members at EVERY cell (`base/co_channel.zig` sets
    /// `cells = null`), so a licence here can rest on a shared endpoint
    /// arbitrarily far away; only a `.port_share` licence is local.
    /// Both lean the same way — over-generous — which is what makes `d_` the
    /// floor rather than the estimate.
    c_run_fused_licensed: u32 = 0,
    /// The same junction where such a record instead states FOREIGN — the
    /// crossing rule refused this edge's ink here (`.suppressed`), or a
    /// producer merged it with the channel question answered no
    /// (`.merged_foreign`). The junction glyph asserts an adjacency no
    /// source declares: a fabrication, filed as a defect.
    /// ANY foreign record on EITHER junction cell decides, because a
    /// position-scoped licence can differ at the two ends and one
    /// unlicensed end is enough to make the drawn line a claim nothing
    /// declares. That is a conservative choice, not a derivation, and it is
    /// also what keeps the bucket independent of producer order.
    /// A FLOOR, for one reason beyond the representative-id one above: two
    /// merely ADJACENT runs never write on each other at all, so neither
    /// cell can carry a record naming the other. That lands in
    /// `u_run_fused_unevidenced`, never here.
    /// guarded-by: strokes_test.zig "fusion: a foreign record on the junction cell files the defect"
    d_run_fused_foreign: u32 = 0,
    /// The same junction where NO record on any junction cell of the pair
    /// names the other cell's edge, or the only ones that do state nothing
    /// (`.merged_untested`). The question could not be ASKED here: neither
    /// run ever attempted ink at the other's cell, or the side table was
    /// not collected at all (an empty record slice means "nothing recorded
    /// OR nothing collected", never "nothing happened" — `cell.zig`).
    /// An audit limitation, never a licence. SILENCE IS NOT ADMISSION: no
    /// path may fall through to `c_run_fused_licensed`.
    /// guarded-by: strokes_test.zig "fusion: a junction with no usable record is unevidenced, never licensed"
    u_run_fused_unevidenced: u32 = 0,
    /// A stroke arm at a stroke neighbour that does not carry the
    /// reciprocal bit. Pure measurement, deliberately unguarded: it reports
    /// every half-open pair the SHIPPED mask holds, on no theory of which
    /// side meant it. No pass closes such a pair, so this reads the picture
    /// as drawn, never a repair still owed.
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
    /// A node ring's off-axis arm landing on the SAME node's own border:
    /// internal structure the node rasterizer synthesized (the subroutine
    /// double wall), not an edge attachment.
    c_border_arm_wall: u32 = 0,
    /// A node ring's extra arm explained by a `.port` record at the cell:
    /// port erasure merges an attachment stroke into the border on any of
    /// the four faces and files a record for every stroke drawn. The one
    /// end that draws NO stroke is a decorated end whose head FACES the
    /// wall: it contributes no arm at all, so it is never counted here and
    /// never in the defect bucket below — there is nothing to explain. A
    /// head merely BESIDE the wall, pointing along the route past it, does
    /// draw its stroke and is recorded like any other.
    c_border_arm_port: u32 = 0,
    /// A node ring's extra arm with no `.port` record (and no weld): ink
    /// the border claims and no recorded writer provides. A terminal whose
    /// arrowhead FACES the wall is NOT this — its wall stays pristine by
    /// convention, so it carries no arm to explain.
    d_border_arm_unrecorded: u32 = 0,
    /// The same question abstained because AUX was unavailable.
    u_border_arm_aux_unavailable: u32 = 0,
    /// A frame's extra arm under the `cross` notation, which welds edges
    /// into the border by design.
    c_frame_arm_cross_mode: u32 = 0,
    /// A frame's extra arm under `bridge`, which refuses frame fusion
    /// outright: a survivor is a leak.
    d_frame_arm_foreign: u32 = 0,

    // -- terminal abutment (terminal.zig) -----------------------------
    /// (ink cell, direction, ring cell) pairs found: every place a run
    /// stops against a node outline or a subgraph frame. The denominator
    /// for the buckets below.
    n_term_abut: u32 = 0,
    /// The ring cell holds a `.port` record for this position: an edge
    /// attached a port stroke here (source departure OR target arrival), so
    /// no face verdict is drawn from the pair.
    /// Read from the side table, not inferred from the mask — a bit
    /// pointing back is evidence of SOME writer, not of this one. A
    /// TIP-FACING decorated terminal has no record and correctly falls
    /// through to the `c_term_node_*_arrow` conventions below.
    c_term_port_recorded: u32 = 0,
    /// The ring carries the arm back but no port record explains it. The
    /// arrowhead-base weld ORs an arm into a border cell for any tip, so
    /// such a bit exists without being a departure. Not a departure and
    /// not an arrival either: the arm's own writer already accounts for
    /// it (`c_border_arm_weld`), so this family draws no face verdict.
    c_term_ring_arm_unrecorded: u32 = 0,
    /// The ring sits one cell beyond a reprieved gap — port padding. The
    /// gap is the rasterizer's own convention, so no face verdict is
    /// drawn from such a pair.
    c_term_gap_reprieved: u32 = 0,
    /// A bare stroke abutting a node's north or south face: an arrival
    /// along the vertical axis. Nothing writes a reciprocal bit into a
    /// TARGET border, so this is the standard rendering.
    c_term_node_ns_bare: u32 = 0,
    /// A bare stroke abutting a node's east or west face.
    c_term_node_ew_bare: u32 = 0,
    /// An arrowhead's tip against a node's north or south face — a plain
    /// `A --> B` in a top-down render.
    c_term_node_ns_arrow: u32 = 0,
    /// An arrowhead's tip against a node's east or west face.
    c_term_node_ew_arrow: u32 = 0,
    /// Ink landing on a node's CORNER. Perimeter ports are issued as face
    /// offsets only, so a run that ends here missed the face it aimed at.
    d_term_node_corner: u32 = 0,
    /// An abutment whose port-record absence could not be established.
    u_term_aux_unavailable: u32 = 0,
    /// A bare stroke abutting a subgraph frame's face: frame-solid, and
    /// how a bridge legally crosses a border.
    c_term_frame_bare: u32 = 0,
    /// A bare stroke abutting a frame's corner. Still frame-solid: a
    /// frame corner is a real cell a run may pass.
    c_term_frame_corner: u32 = 0,
    /// An arrowhead's tip against an untouched frame cell. A genuine
    /// arrival into a cluster REPLACES the frame cell with the arrowhead,
    /// so this one stopped a cell short of what it was aiming at.
    d_term_frame_arrow: u32 = 0,

    // -- expectation tier (expect.zig) --------------------------------
    /// Non-invisible Sketch edges (each declares one terminal approach).
    n_edges_declared: u32 = 0,
    /// Rail taps: fan edges whose sole geometry is the trunk.
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
    m_graph_nodes: u32 = 0,
    m_graph_edges: u32 = 0,
    /// Sketch placement count. A gap against `m_graph_nodes` is semantic
    /// loss between IR 1 and IR 2, visible without per-entity matching.
    m_sketch_nodes: u32 = 0,
    /// Sketch edge count (routed polylines plus rail taps).
    m_sketch_edges: u32 = 0,

    // -- fused crossbar runs (rails.zig) ------------------------------
    /// guarded-by: rails_test.zig "rails: the entry denominator is published before the tier can decline"
    n_rails_first_class: u32 = 0,
    /// guarded-by: rails_test.zig "rails: an empty population is named, not silent"
    u_rail_population_absent: u32 = 0,
    /// Fan rails sharing ONE crossbar row with touching spans raster into
    /// one continuous line. This counts such runs that are TWO-SIDED (more
    /// than one distinct upper-stage node AND more than one distinct
    /// lower-stage node) — the only shape where one run can stand for a
    /// pivot nothing declares. Derived from the drawn geometry, so it is
    /// wider than any one upstream gate's admitted set and never claims
    /// that gate approved the run. It counts CROSSBARS, not continuous
    /// ink, so a zero here is NOT "no fused line" — read it together with
    /// `u_rail_run_continued`, which counts the runs whose drawn line
    /// outgrows the crossbars this tier could measure.
    n_rail_runs_two_sided: u32 = 0,
    /// A crossbar run — of ANY size, two-sided or not — whose drawn line
    /// continues past the crossbars into stroke ink this tier does not
    /// attribute: an ordinary edge's horizontal jog landing collinear with
    /// a crossbar, or a crossbar abutting the next one column-adjacent.
    /// The continued line reaches endpoints that never enter the sides
    /// counted above, so it can assert pairs `n_rail_pairs_asserted` does
    /// not contain and can be two-sided where the crossbars alone are not.
    /// An audit limitation and the explicit companion of a zero
    /// population: it is how often this tier's answer is known to be a
    /// floor. The fused-run family above sees these junctions as three- or
    /// four-armed, so a continued run leaves `d_run_fused_collinear` at
    /// zero too — but `d_run_fused_foreign` now speaks for the same
    /// fabrication from the other side, per adjacent CELL PAIR rather than
    /// per run and only where a record survives to prove it. Read the two
    /// together; neither is the whole count.
    u_rail_run_continued: u32 = 0,
    /// Summed over those runs, |upper| x |lower|: the CROSS-pair floor of
    /// what a reader tracing one continuous line can get between. Not the
    /// whole asserted set — a member that does not block the leaf-to-leaf
    /// trace also asserts within-side pairs, which the Sketch cannot state,
    /// so this UNDER-counts by construction (the safe direction).
    n_rail_pairs_asserted: u32 = 0,
    /// An asserted pair some rail of the run declares (a tap names it) AND
    /// whose branch cell carries that member's `.tap` record: the run
    /// asserts it and a reader can follow that member off the run.
    c_rail_pair_accounted: u32 = 0,
    /// An asserted pair NO rail of the run declares: the drawn line stands
    /// for a connection nothing branches for. The fabrication itself.
    /// A pure Sketch fact — it needs no side table, so no state of the
    /// record channel can suppress it.
    d_rail_pair_undeclared: u32 = 0,
    /// A declared asserted pair whose branch cell is on the grid, on a run
    /// whose row does carry records, and carries no `.tap` record of its
    /// own: the member rides the shared run with nothing marking where it
    /// leaves, so its own trace is lost even though the pair is honest.
    d_rail_branch_unrecorded: u32 = 0,
    /// A declared asserted pair whose branch question could not be ASKED:
    /// the run's whole crossbar row carries no `.tap` record (side table
    /// not collected), or that member's branch cell is off the grid. An
    /// audit limitation, never a defect — an empty record slice means
    /// "nothing recorded OR nothing collected" (`cell.zig`), and an
    /// unreadable position is no evidence of anything.
    /// The four pair buckets partition the denominator exactly:
    /// `n_rail_pairs_asserted == c_rail_pair_accounted +
    /// d_rail_pair_undeclared + d_rail_branch_unrecorded +
    /// u_rail_pair_unevidenced`.
    u_rail_pair_unevidenced: u32 = 0,
    /// A two-sided run whose whole crossbar row carries no `.tap` record at
    /// all — the side table was not collected, or the row is off-grid. The
    /// run-level companion of the bucket above; its pairs are still counted
    /// and still judged for what needs no record. An audit limitation.
    u_rail_run_records_absent: u32 = 0,

    n_rail_claims: u32 = 0,
    n_rail_claim_members: u32 = 0,
    c_rail_star_valid: u32 = 0,
    d_rail_star_violation: u32 = 0,
    d_rail_deco_mixed: u32 = 0,
    d_rail_member_style_mixed: u32 = 0,
    u_rail_claim_unresolved: u32 = 0,
    u_rail_claim_record_invalid: u32 = 0,
    u_rail_claim_population_absent: u32 = 0,
    // -- channel identity, derivation, and filed claim (channels.zig) --
    n_channel_carrier_records: u32 = 0,
    u_channel_record_aux_unavailable: u32 = 0,
    u_channel_record_owner_absent: u32 = 0,
    u_channel_record_restates_owner: u32 = 0,
    n_channel_carrier_pairs: u32 = 0,
    u_channel_population_absent: u32 = 0,
    n_channel_pairs_compared: u32 = 0,
    m_channel_identity_agreed: u32 = 0,
    u_channel_identity_disagreed: u32 = 0,
    u_channel_identity_unavailable: u32 = 0,
    n_channel_details_compared: u32 = 0,
    m_channel_detail_agreed: u32 = 0,
    u_channel_detail_disagreed: u32 = 0,
    u_channel_detail_untested: u32 = 0,
    u_channel_detail_invalid: u32 = 0,
    u_channel_detail_identity_unavailable: u32 = 0,
    n_channel_stamp_complete: u32 = 0,
    u_channel_stamp_unattempted: u32 = 0,
    u_channel_stamp_oom: u32 = 0,
    u_channel_stamp_rail_invariant: u32 = 0,
    u_channel_roster_inconsistent: u32 = 0,
    // -- EAW label-geometry bridge ------------------------------------
    /// Label cells holding an East-Asian-Wide codepoint. Each such cell
    /// paints two columns while occupying one lattice cell.
    m_wide_label_cells: u32 = 0,
    /// Summed per-row excess of painted COLUMNS over lattice CELLS. The
    /// lattice is a cell grid, the terminal a column grid; a nonzero
    /// value means at least one row lies about its own width.
    m_row_col_overflow: u32 = 0,
    /// Sum of exactly the `d_` fields; reflection includes new defect buckets.
    /// guarded-by: counts_test.zig "counts: defectTotal sums exactly the d_ fields"
    pub fn defectTotal(self: Counts) u32 {
        return line.defectTotal(Counts, self);
    }

    /// Render one line; trailing `d_total` is derived, not a field.
    /// guarded-by: counts_test.zig "writeLine: one token per field plus d_total, mercat-tiling prefix"
    pub fn writeLine(self: Counts, buf: []u8) []const u8 {
        return line.writeLine(Counts, self, buf);
    }
    /// Emit one line to stderr without changing stdout or pipeline decisions.
    pub fn emitLine(self: Counts) void {
        line.emitLine(Counts, self);
    }
};

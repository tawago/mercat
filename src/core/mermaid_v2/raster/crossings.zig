//! Crossing / transversal semantics for the mermaid_v2 raster (Amendment C,
//! rulings C1/C2 — design/ascii-ambiguity-p1a-records/D-CROSS.md).
//!
//! This module owns the crossing EVENT vocabulary recorded by
//! `raster/edges.zig` and the decision predicates that keep foreign ink from
//! fabricating a junction:
//!
//!   * C1 — a crossing of two UNRELATED edges must read as a TRANSVERSAL: the
//!     crossed run (first writer) keeps its straight stroke; the crossing edge
//!     contributes NO bits to that cell (no `┬ ├ ┤ ┴` / `┼` on a foreign run).
//!   * C2 — an edge must never bridge on/through an ARROWHEAD cell; foreign ink
//!     landing on a foreign edge's arrowhead is refused and the arrowhead stays
//!     pristine.
//!
//! No new glyph and no painter change: the transversal is produced by NOT
//! OR-merging foreign perpendicular overlap at the raster layer.
//!
//! EXEMPTIONS (structural, never seed-keyed): same owner, and co-members of one
//! realized selected join or one exempt mesh union — that ink sharing is legal
//! join ink (D-JOIN clause 4). Determined from `Sketch.joins` (RealizedJoins),
//! never from geometry or a fixture name.
//!
//! SCOPE: the rule is inert unless a realized-join plan exists (`active`). A
//! clustered/subgraph render carries an empty plan (V-D-IR-07), so this module
//! never alters clustered bytes.
//!
//! Report-only: counts flow raster → entry → diagnostics, never into
//! score.RasterCounts, audit.zig, or candidate selection. No new DiagnosticTag.
//!
//! Allowed imports: `std`, `lattice.zig`, `base/ledger.zig`, the `prim`
//! module (base/types.zig — universally importable; enforced by
//! `tools/lint_imports.zig`).

const std = @import("std");
const lattice = @import("../lattice.zig");
const ledger = @import("../base/ledger.zig");
const prim = @import("prim");

pub const EdgeId = ledger.EdgeId;

/// The three painted-crossing outcomes a foreign overlap can classify to.
pub const CrossingClass = enum {
    /// A strict orthogonal transversal between unrelated channels: the crossed
    /// run keeps its straight stroke, the crossing edge resumes on the opposite
    /// side. Legal (D-CROSS C1 reading requirement, D-REACH clause 7 vector half).
    legal_crossing,
    /// A junction glyph would have attached crossing traffic to a foreign edge's
    /// run (collinear overlap, cornering, or a T onto the foreign straight run).
    /// C1 prohibition; first-writer bits kept, no tee fabricated.
    foreign_junction_violation,
    /// Foreign ink met an arrowhead cell (a fabricated second arrival). C2
    /// prohibition; the arrowhead stays pristine.
    arrowhead_transit_violation,
};

/// Report-only crossing tallies surfaced through the raster report.
pub const CrossingCounts = struct {
    legal_crossing: u32 = 0,
    foreign_junction_violation: u32 = 0,
    arrowhead_transit_violation: u32 = 0,
    /// Frame-solid border bridging (D-CROSS, owner ruling 2026-07-19): a
    /// THROUGH-GOING edge segment that crossed a `.cluster_border` cell and
    /// contributed NO bits — the frame glyph stays continuous and the edge
    /// resumes on the far side. Fires only in `.bridge` mode (the default);
    /// `.cross` mode welds instead. Report-only; no DiagnosticTag.
    b_frame_bridge: u32 = 0,
    /// A corner arm that landed on a `.cluster_border` cell and was refused —
    /// welding a tee (`┼ ├ ┤`) into the frame is forbidden (frame-solid). The
    /// border stays pristine. Fires only in `.bridge` mode; report-only;
    /// same-ruling companion counter.
    b_border_fusion_refused: u32 = 0,
};

/// Per-raster crossing context threaded through the edge walk: the realized
/// plan (for the exemption), whether the rule is `active`, the tally sink, and
/// the subgraph-border notation mode.
/// Copied by value; `counts` is a pointer so increments persist.
pub const Ctx = struct {
    joins: ledger.RealizedJoins = .{},
    active: bool = false,
    counts: *CrossingCounts,
    /// Subgraph frame-border notation (owner ruling, tawago 2026-07-19).
    /// `.bridge` (default): frame-solid, edges bridge the border. `.cross`:
    /// the pre-Slice-1 junction-weld behavior — byte-identical to before.
    mode: prim.SubgraphEdges = .bridge,
};

/// The crossing rule is active only when a realized-join plan exists — which,
/// on the production path, happens exactly for flat top-level graphs. Clustered
/// and subgraph renders keep the plan empty, so the rule stays inert there and
/// the clustered pipeline is byte-identical.
pub fn active(joins: ledger.RealizedJoins) bool {
    return joins.selected_joins.len > 0 or
        joins.mesh_unions.len > 0 or
        joins.memberships.len > 0;
}

/// Two edges share LEGAL join ink iff they are the same owner or co-members of
/// one realized selected join or one exempt mesh union (D-JOIN clause 4). This
/// is the structural exemption from the transversal rule — determined from the
/// realized-join plan, never from geometry or a seed name.
pub fn sameChannel(a: EdgeId, b: EdgeId, joins: ledger.RealizedJoins) bool {
    if (a == b) return true;
    for (joins.selected_joins) |j| {
        if (contains(j.members, a) and contains(j.members, b)) return true;
    }
    for (joins.mesh_unions) |m| {
        if (contains(m.members, a) and contains(m.members, b)) return true;
    }
    return false;
}

fn contains(edges: []const EdgeId, edge: EdgeId) bool {
    for (edges) |e| if (e == edge) return true;
    return false;
}

/// A mask is a clean straight run iff exactly its two collinear arms are set.
pub fn isStraightPair(m: lattice.Neighbours) bool {
    const h = m.e and m.w and !m.n and !m.s;
    const v = m.n and m.s and !m.e and !m.w;
    return h or v;
}

/// Classify a FOREIGN, non-exempt edge-segment overlap onto an existing
/// edge-segment cell. `existing` is the first-writer's mask; `incoming` is the
/// arriving straight-or-corner mask.
pub fn classifySegment(existing: lattice.Neighbours, incoming: lattice.Neighbours) CrossingClass {
    if (isStraightPair(existing) and isStraightPair(incoming)) {
        const existing_h = existing.e and existing.w;
        const incoming_h = incoming.e and incoming.w;
        // Perpendicular straight-through → a legal transversal; same axis →
        // collinear overlap (never a legal junction with foreign ink).
        if (existing_h != incoming_h) return .legal_crossing;
        return .foreign_junction_violation;
    }
    // The existing run is a corner/tee, or the incoming arm corners onto it:
    // a junction glyph here would assert a branch off the foreign run.
    return .foreign_junction_violation;
}

/// Decide a foreign edge-segment overlap onto an existing edge-segment cell.
/// Returns true when the caller must KEEP the first writer's cell untouched (no
/// OR-merge, no role change) — the transversal / no-foreign-tee behavior — and
/// records the classified event. Returns false to proceed with the pre-C
/// merge (rule inert, same owner, or legal join ink).
pub fn segmentOverlap(
    counts: *CrossingCounts,
    joins: ledger.RealizedJoins,
    active_rule: bool,
    existing_edge: EdgeId,
    existing_mask: lattice.Neighbours,
    incoming_edge: EdgeId,
    incoming_mask: lattice.Neighbours,
) bool {
    if (!active_rule) return false;
    if (sameChannel(existing_edge, incoming_edge, joins)) return false;
    switch (classifySegment(existing_mask, incoming_mask)) {
        .legal_crossing => counts.legal_crossing += 1,
        .foreign_junction_violation => counts.foreign_junction_violation += 1,
        .arrowhead_transit_violation => unreachable,
    }
    return true;
}

/// Decide a foreign edge meeting an arrowhead cell (either a foreign segment
/// landing on an arrowhead, or an arrowhead being written over a foreign
/// segment). Returns true when the caller must keep the arrowhead cell pristine
/// (C2), recording the violation; false to proceed with the pre-C behavior (an
/// edge's own terminal arrowhead, rule inert, or legal join ink).
pub fn arrowheadTransit(
    counts: *CrossingCounts,
    joins: ledger.RealizedJoins,
    active_rule: bool,
    arrow_edge: EdgeId,
    incoming_edge: EdgeId,
) bool {
    if (!active_rule) return false;
    if (sameChannel(arrow_edge, incoming_edge, joins)) return false;
    counts.arrowhead_transit_violation += 1;
    return true;
}

// -- Tests -------------------------------------------------------------------

const H: lattice.Neighbours = .{ .e = true, .w = true };
const V: lattice.Neighbours = .{ .n = true, .s = true };

test "isStraightPair recognizes only clean H/V runs" {
    try std.testing.expect(isStraightPair(H));
    try std.testing.expect(isStraightPair(V));
    try std.testing.expect(!isStraightPair(.{ .n = true, .e = true })); // corner
    try std.testing.expect(!isStraightPair(.{ .n = true, .e = true, .s = true })); // tee
    try std.testing.expect(!isStraightPair(.{})); // empty
}

test "classifySegment: perpendicular is legal, collinear/corner are violations" {
    try std.testing.expectEqual(CrossingClass.legal_crossing, classifySegment(H, V));
    try std.testing.expectEqual(CrossingClass.legal_crossing, classifySegment(V, H));
    try std.testing.expectEqual(CrossingClass.foreign_junction_violation, classifySegment(H, H));
    try std.testing.expectEqual(CrossingClass.foreign_junction_violation, classifySegment(V, V));
    try std.testing.expectEqual(
        CrossingClass.foreign_junction_violation,
        classifySegment(.{ .n = true, .e = true }, V),
    );
}

test "sameChannel: same owner, selected-join co-members, mesh co-members" {
    var members = [_]EdgeId{ 10, 11, 12 };
    var sel = [_]ledger.SelectedJoin{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &members }};
    const joins: ledger.RealizedJoins = .{ .selected_joins = &sel };

    try std.testing.expect(sameChannel(5, 5, joins)); // same owner
    try std.testing.expect(sameChannel(10, 12, joins)); // co-members
    try std.testing.expect(!sameChannel(10, 99, joins)); // one foreign
    try std.testing.expect(!sameChannel(98, 99, .{})); // empty plan, distinct
}

test "active reflects a non-empty realized plan" {
    try std.testing.expect(!active(.{}));
    var mesh = [_]EdgeId{ 1, 2 };
    var mu = [_]ledger.MeshUnion{.{ .id = 0, .members = &mesh, .source_keys = &.{}, .target_keys = &.{} }};
    try std.testing.expect(active(.{ .mesh_unions = &mu }));
}

test "segmentOverlap: inert / exempt merge; foreign perpendicular keeps first writer" {
    var counts: CrossingCounts = .{};
    // Rule inert → merge (false), no event.
    try std.testing.expect(!segmentOverlap(&counts, .{}, false, 1, H, 2, V));
    try std.testing.expectEqual(@as(u32, 0), counts.legal_crossing);

    // Active, foreign, perpendicular → keep first writer (true), legal event.
    var members = [_]EdgeId{ 1, 3 };
    var sel = [_]ledger.SelectedJoin{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &members }};
    const joins: ledger.RealizedJoins = .{ .selected_joins = &sel };
    try std.testing.expect(segmentOverlap(&counts, joins, true, 1, H, 2, V));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);

    // Active but co-members (1 & 3 share the selected join) → merge (false).
    try std.testing.expect(!segmentOverlap(&counts, joins, true, 1, H, 3, V));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);

    // Active, foreign, collinear → keep first writer, junction violation.
    try std.testing.expect(segmentOverlap(&counts, joins, true, 1, H, 2, H));
    try std.testing.expectEqual(@as(u32, 1), counts.foreign_junction_violation);
}

test "arrowheadTransit: own terminal exempt, foreign refused" {
    var counts: CrossingCounts = .{};
    // Same owner (own terminal) → not a violation.
    try std.testing.expect(!arrowheadTransit(&counts, .{}, true, 7, 7));
    try std.testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);
    // Foreign edge over a foreign arrowhead → C2 violation, keep pristine.
    try std.testing.expect(arrowheadTransit(&counts, .{}, true, 7, 8));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
    // Rule inert → no refusal.
    try std.testing.expect(!arrowheadTransit(&counts, .{}, false, 7, 8));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}

test {
    _ = @import("crossings_test.zig");
}

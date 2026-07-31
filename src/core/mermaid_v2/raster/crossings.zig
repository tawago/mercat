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
//! join ink (D-JOIN clause 4). Determined from `Sketch.joins` (RealizedJoins)
//! and from `Sketch.co_sets`, the co-channel membership the same decisions
//! record; never from geometry or a fixture name. The two agree by
//! construction on the flat path (co-sets are derived from the plan where the
//! plan is applied), and `co_sets` alone speaks for a clustered render, whose
//! fans are its only channels.
//!
//! SCOPE: UNCONDITIONAL. A crossing between two edges that do not legally
//! share a channel never paints a junction glyph, on every render — flat,
//! clustered, and recursion children alike. There is no arming predicate: the
//! only question ever asked is `sameChannel`. On a clustered/subgraph render
//! the realized plan is empty (V-D-IR-07) and `co_sets` alone carries the
//! legality — its fans are its only channels — which is exactly why the plan
//! may not gate the rule.
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
pub const CoCell = ledger.CoCell;

/// The lattice cell a crossing decision is about, in the co-set's coordinate
/// space (`ledger.CoCell` is signed because a Sketch polyline is; a rasterized
/// cell is always non-negative, so the widening is total).
pub fn cellAt(x: u32, y: u32) ledger.CoCell {
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

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
/// plan (for the exemption), the tally sink, and the subgraph-border notation
/// mode.
/// Copied by value; `counts` is a pointer so increments persist.
pub const Ctx = struct {
    joins: ledger.RealizedJoins = .{},
    /// Co-channel membership from the Sketch (`Sketch.co_sets`). Carried as a
    /// plain slice of base-tier records because this zone may not import
    /// sketch.zig for it.
    co_sets: []const ledger.CoSet = &.{},
    counts: *CrossingCounts,
    /// Subgraph frame-border notation (owner ruling, tawago 2026-07-19).
    /// `.bridge` (default): frame-solid, edges bridge the border. `.cross`:
    /// the pre-Slice-1 junction-weld behavior — byte-identical to before.
    mode: prim.SubgraphEdges = .bridge,
};

/// Two edges share LEGAL join ink iff they are the same owner or co-members of
/// one channel: a declared co-set, a realized selected join, or an exempt mesh
/// union (D-JOIN clause 4). This is the structural exemption from the
/// transversal rule — determined from the recorded membership, never from
/// geometry or a seed name.
///
/// `co_sets` and `joins` are asked in turn and neither can veto the other, so
/// on the flat path — where the co-sets ARE the plan's membership — the answer
/// is the plan's answer.
/// guarded-by: crossings.zig "sameChannel: co-set membership answers what the plan answers"
/// `at` is the CELL the decision is about. A co-set may be cell-scoped (a
/// `.port_share` set licenses only the two edges' common approach), so the
/// membership question is always asked about a position; the structural
/// origins license every cell and ignore it.
/// guarded-by: crossings.zig "sameChannel: a cell-scoped co-set answers only on its own cells"
pub fn sameChannel(
    a: EdgeId,
    b: EdgeId,
    joins: ledger.RealizedJoins,
    co_sets: []const ledger.CoSet,
    at: ledger.CoCell,
) bool {
    if (a == b) return true;
    if (ledger.coMembersAt(co_sets, a, b, at)) return true;
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
/// merge (same owner or legal join ink).
pub fn segmentOverlap(
    counts: *CrossingCounts,
    joins: ledger.RealizedJoins,
    co_sets: []const ledger.CoSet,
    existing_edge: EdgeId,
    existing_mask: lattice.Neighbours,
    incoming_edge: EdgeId,
    incoming_mask: lattice.Neighbours,
    at: ledger.CoCell,
) bool {
    if (sameChannel(existing_edge, incoming_edge, joins, co_sets, at)) return false;
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
/// edge's own terminal arrowhead or legal join ink).
pub fn arrowheadTransit(
    counts: *CrossingCounts,
    joins: ledger.RealizedJoins,
    co_sets: []const ledger.CoSet,
    arrow_edge: EdgeId,
    incoming_edge: EdgeId,
    at: ledger.CoCell,
) bool {
    if (sameChannel(arrow_edge, incoming_edge, joins, co_sets, at)) return false;
    counts.arrowhead_transit_violation += 1;
    return true;
}

// -- Tests -------------------------------------------------------------------

/// Any cell: the structural origins license every position, so the tests that
/// speak for them pass an arbitrary one.
const ANY: ledger.CoCell = .{ .x = 0, .y = 0 };

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

    try std.testing.expect(sameChannel(5, 5, joins, &.{}, ANY)); // same owner
    try std.testing.expect(sameChannel(10, 12, joins, &.{}, ANY)); // co-members
    try std.testing.expect(!sameChannel(10, 99, joins, &.{}, ANY)); // one foreign
    try std.testing.expect(!sameChannel(98, 99, .{}, &.{}, ANY)); // empty plan, distinct
}

test "sameChannel: co-set membership answers what the plan answers" {
    // The flat path derives its co-sets FROM the plan, so the two arguments
    // are two spellings of one fact. Pin that: asked with only the plan, or
    // with only the plan's co-sets, the answers agree on every pair.
    var members = [_]EdgeId{ 10, 11, 12 };
    var sel = [_]ledger.SelectedJoin{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &members }};
    var mesh = [_]EdgeId{ 20, 21 };
    var mu = [_]ledger.MeshUnion{.{ .id = 0, .members = &mesh, .source_keys = &.{}, .target_keys = &.{} }};
    const joins: ledger.RealizedJoins = .{ .selected_joins = &sel, .mesh_unions = &mu };

    const derived = try ledger.coSetsFromPlan(std.testing.allocator, joins);
    defer std.testing.allocator.free(derived);

    for ([_]EdgeId{ 10, 11, 12, 20, 21, 99 }) |a| {
        for ([_]EdgeId{ 10, 11, 12, 20, 21, 99 }) |b| {
            try std.testing.expectEqual(
                sameChannel(a, b, joins, &.{}, ANY),
                sameChannel(a, b, .{}, derived, ANY),
            );
        }
    }
    // A co-set with no plan behind it still speaks — that is the clustered
    // render's only channel evidence.
    var fan = [_]EdgeId{ 4, 5 };
    const fan_sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(sameChannel(4, 5, .{}, &fan_sets, ANY));
    try std.testing.expect(!sameChannel(4, 6, .{}, &fan_sets, ANY));
}

test "segmentOverlap: exempt merges; foreign perpendicular keeps first writer" {
    var counts: CrossingCounts = .{};
    // With no plan and no co-sets at all, two distinct edges are still foreign:
    // the rule is unconditional, so this is a legal transversal, not a merge.
    try std.testing.expect(segmentOverlap(&counts, .{}, &.{}, 1, H, 2, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);
    counts = .{};

    // Foreign, perpendicular → keep first writer (true), legal event.
    var members = [_]EdgeId{ 1, 3 };
    var sel = [_]ledger.SelectedJoin{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &members }};
    const joins: ledger.RealizedJoins = .{ .selected_joins = &sel };
    try std.testing.expect(segmentOverlap(&counts, joins, &.{}, 1, H, 2, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);

    // Co-members (1 & 3 share the selected join) → merge (false).
    try std.testing.expect(!segmentOverlap(&counts, joins, &.{}, 1, H, 3, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);

    // Foreign, collinear → keep first writer, junction violation.
    try std.testing.expect(segmentOverlap(&counts, joins, &.{}, 1, H, 2, H, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.foreign_junction_violation);

    // A co-set exempts on its own, with no plan behind it.
    var fan = [_]EdgeId{ 1, 2 };
    const fan_sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(!segmentOverlap(&counts, .{}, &fan_sets, 1, H, 2, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);
}

test "arrowheadTransit: own terminal exempt, foreign refused" {
    var counts: CrossingCounts = .{};
    // Same owner (own terminal) → not a violation.
    try std.testing.expect(!arrowheadTransit(&counts, .{}, &.{}, 7, 7, ANY));
    try std.testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);
    // Foreign edge over a foreign arrowhead → C2 violation, keep pristine.
    try std.testing.expect(arrowheadTransit(&counts, .{}, &.{}, 7, 8, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
    // A co-set exempts on its own, with no plan behind it.
    var fan = [_]EdgeId{ 7, 8 };
    const fan_sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(!arrowheadTransit(&counts, .{}, &fan_sets, 7, 8, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}

test {
    _ = @import("crossings_test.zig");
}

test "sameChannel: a cell-scoped co-set answers only on its own cells" {
    // A `.port_share` set licenses the two edges' common approach and nothing
    // else: at a crossing far from the shared port the pair is still foreign,
    // so a true transversal there keeps its plain stroke.
    const licensed = [_]ledger.CoCell{ .{ .x = 30, .y = 12 }, .{ .x = 30, .y = 13 } };
    const sets = [_]ledger.CoSet{.{ .origin = .port_share, .members = &.{ 9, 11 }, .cells = &licensed }};
    try std.testing.expect(sameChannel(9, 11, .{}, &sets, .{ .x = 30, .y = 12 }));
    try std.testing.expect(sameChannel(9, 11, .{}, &sets, .{ .x = 30, .y = 13 }));
    try std.testing.expect(!sameChannel(9, 11, .{}, &sets, .{ .x = 21, .y = 15 }));
    // The unscoped origins are position-blind, on the same cell.
    const fan = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &.{ 9, 11 } }};
    try std.testing.expect(sameChannel(9, 11, .{}, &fan, .{ .x = 21, .y = 15 }));
}

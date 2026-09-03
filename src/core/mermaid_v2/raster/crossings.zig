//! Crossing / transversal semantics for the mermaid_v2 raster (Amendment C).
//! The amendment's normative text is held by the owner and is not in-tree;
//! its two rulings — the TRANSVERSAL ruling and the ARROWHEAD-SANCTITY
//! ruling — are restated in full below.
//!
//! This module owns the crossing EVENT vocabulary recorded by
//! `raster/edges.zig` and the decision predicates that keep foreign ink from
//! fabricating a junction:
//!
//!   * TRANSVERSAL ruling — a crossing of two UNRELATED edges must read as a TRANSVERSAL: the
//!     crossed run (first writer) keeps its straight stroke; the crossing edge
//!     contributes NO bits to that cell (no `┬ ├ ┤ ┴` / `┼` on a foreign run).
//!   * ARROWHEAD-SANCTITY ruling — an edge must never bridge on/through an ARROWHEAD cell; foreign ink
//!     landing on a foreign edge's arrowhead is refused and the arrowhead stays
//!     pristine.
//!
//! No new glyph and no painter change: the transversal is produced by NOT
//! OR-merging foreign perpendicular overlap at the raster layer.
//!
//! EXEMPTIONS (structural, never seed-keyed): same owner, and co-members of one
//! realized selected bundle — that ink sharing is legal bundle ink (D-JOIN clause
//! 4). Determined from `Sketch.bundles` (RealizedBundles)
//! and from `Sketch.bundle_sets`, the bundle membership the same decisions
//! record; never from geometry or a fixture name. The two agree by
//! construction wherever a plan realized — flat sketches directly, clustered
//! sketches through the piece plans the stitch merges — and `bundle_sets` alone
//! speaks for a sketch with no realized plan (motif-packed, plan failure).
//!
//! SCOPE: UNCONDITIONAL. A crossing between two edges that do not legally
//! share a bundle never paints a junction glyph, on every render — flat,
//! clustered, and recursion children alike. There is no arming predicate: the
//! only question ever asked of the INK is `sameBundle`, the membership
//! derivation. What a record SAYS about a cell is a different question, and it
//! is answered by looking up the bundle identity the producer stamped
//! (`bundleAt` / `licenceFor`); the two are counted against each other on
//! every render. A sketch may carry legality in
//! `bundle_sets` without a realized plan (motif-packed candidates, plan
//! failures), which is exactly why the plan may not gate the rule.
//!
//! Counts flow raster → entry → diagnostics, and via audit.zig into
//! score.RasterCounts' violation tier of candidate selection; the shipped
//! lattice is never modified by them. No new DiagnosticTag.
//!
//! Allowed imports: `std`, `sketch.zig`, `lattice.zig`, `base/ledger.zig`,
//! the `prim` module (base/types.zig — universally importable; enforced by
//! `tools/lint_imports.zig`).

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ledger = @import("../base/ledger.zig");
const prim = @import("prim");

pub const EdgeId = ledger.EdgeId;
pub const BundleCell = ledger.BundleCell;

/// The lattice cell a crossing decision is about, in the bundle's coordinate
/// space (`ledger.BundleCell` is signed because a Sketch polyline is; a rasterized
/// cell is always non-negative, so the widening is total).
pub fn cellAt(x: u32, y: u32) ledger.BundleCell {
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

/// The three painted-crossing outcomes a foreign overlap can classify to.
pub const CrossingClass = enum {
    /// A strict orthogonal transversal between unrelated bundles: the crossed
    /// run keeps its straight stroke, the crossing edge resumes on the opposite
    /// side. Legal (the transversal ruling's reading requirement; D-CROSS, D-REACH clause 7 vector half).
    legal_crossing,
    /// A junction glyph would have attached crossing traffic to a foreign edge's
    /// run (collinear overlap, cornering, or a T onto the foreign straight run).
    /// transversal-ruling prohibition; first-writer bits kept, no tee fabricated.
    foreign_junction_violation,
    /// Foreign ink met an arrowhead cell (a fabricated second arrival). The arrowhead-sanctity ruling
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
    /// A lateral arm REFUSED at a decoration cell: a write from another
    /// edge (a run, a corner, a rail claim, a perpendicular head) would
    /// have entered an arrowhead cell from one of its two guarded lateral
    /// sides, and the raster kept the head untouched instead. Counted per
    /// arm, against the edge that lost the cell — never against the head
    /// (constitution, ink attribution: a decoration cell has three guarded
    /// sides; confluence routing note: the refusal is the outcome that
    /// ships). The head's edge keeps its own counters. Lateral arms that
    /// SHIP (an edge turning inside its own terminal cell) are the painted
    /// half of the same tally, read post-raster by `arrow_base.validate`;
    /// `raster.RasterReport.armIntoHead` sums both.
    arm_into_head: u32 = 0,

    /// Fold `other` into `self`: the rail pass and the edge pass each keep
    /// their own tallies and the raster report ships one.
    pub fn add(self: *CrossingCounts, other: CrossingCounts) void {
        inline for (@typeInfo(CrossingCounts).@"struct".fields) |f| {
            @field(self, f.name) += @field(other, f.name);
        }
    }
};

/// Per-raster crossing context threaded through the edge walk: the realized
/// plan (for the exemption), the tally sink, and the subgraph-border notation
/// mode.
/// Copied by value; `counts` is a pointer so increments persist.
pub const Ctx = struct {
    bundles: ledger.RealizedBundles = .{},
    /// Bundle membership from the Sketch (`Sketch.bundle_sets`).
    bundle_sets: []const ledger.Bundle = &.{},
    /// Outcome of the producer's transactional bundle stamp. This gates only
    /// recorded identity lookups; the ink predicates below remain derived.
    stamp_state: sketch.BundleStampState = .unattempted,
    counts: *CrossingCounts,
    /// Subgraph frame-border notation (owner ruling, tawago 2026-07-19).
    /// `.bridge` (default): frame-solid, edges bridge the border. `.cross`:
    /// the pre-Slice-1 junction-weld behavior — byte-identical to before.
    mode: prim.SubgraphEdges = .bridge,
};

/// Two edges share LEGAL bundle ink iff they are the same owner or co-members of
/// one bundle: a declared bundle or a realized selected bundle (D-JOIN clause
/// 4). This is the structural exemption from the
/// transversal rule — determined from the recorded membership, never from
/// geometry or a seed name.
///
/// `bundle_sets` and `bundles` are asked in turn and neither can veto the other, so
/// on the flat path — where the bundles ARE the plan's membership — the answer
/// is the plan's answer.
/// @guarded-by: crossings.zig "sameBundle: bundle membership answers what the plan answers"
/// `at` is the CELL the decision is about. A bundle may be cell-scoped (a
/// `.port_share` set licenses only the two edges' common approach), so the
/// membership question is always asked about a position; the structural
/// origins license every cell and ignore it.
/// @guarded-by: crossings.zig "sameBundle: a cell-scoped bundle answers only on its own cells"
///
/// STANDING. This is the DERIVATION, and it is no longer what establishes a
/// licence anywhere it only fills in a record's `detail`: those sites read the
/// bundle identity the producer filed (`bundleAt` below). It still gates INK
/// at the two refusal predicates in this file, and it is kept whole as the
/// witness the recorded identity is measured against: both answers are run
/// over every carrier a render files and counted agreeing and disagreeing.
/// One copy, in `base/ledger.zig`, so no caller can drift into asking two
/// different questions.
pub fn sameBundle(
    a: EdgeId,
    b: EdgeId,
    bundles: ledger.RealizedBundles,
    bundle_sets: []const ledger.Bundle,
    at: ledger.BundleCell,
) bool {
    return ledger.derivedSameBundle(bundles, bundle_sets, a, b, at);
}

/// The bundle `edge` rides at `at`, read off the roster the producer stamped.
/// Every edge has one: a bundle names a SHARED bundle, and an edge no set
/// names rides its own, one edge wide. A reader compares two of these instead
/// of re-scanning membership — which is the whole point, because the id can
/// then be said out loud ("this run speaks for bundle k") where the relation
/// could only ever be asserted about a pair.
pub fn bundleAt(bundle_sets: []const ledger.Bundle, edge: EdgeId, at: ledger.BundleCell) ledger.BundleId {
    return ledger.bundleOf(bundle_sets, edge, at);
}

/// The merged-carrier flavour for an ordered pair at `at`, decided by RECORDED
/// IDENTITY: licensed iff the two carriers name one bundle. Label-only — no
/// caller of this moves a byte.
///
/// ABSTAINS unless the producer completed its transactional stamp AND every
/// roster entry is numbered. A failed or refused re-stamp can leave an old,
/// internally numbered payload in place; the explicit state says that payload
/// is not current and therefore cannot establish a licence. Conversely,
/// `.complete` with an unnumbered entry is inconsistent and also abstains.
/// The did-not-ask value (`.merged_untested`) is attributable in both cases.
/// @guarded-by: crossings_test.zig "licenceFor trusts identity only after a complete consistent stamp"
pub fn licenceFor(
    held: EdgeId,
    incoming: EdgeId,
    bundle_sets: []const ledger.Bundle,
    stamp_state: sketch.BundleStampState,
    at: ledger.BundleCell,
) lattice.CarrierKind {
    if (stamp_state != .complete or !ledger.rosterNumbered(bundle_sets)) return .merged_untested;
    if (held == incoming) return .merged_licensed;
    return if (bundleAt(bundle_sets, held, at) == bundleAt(bundle_sets, incoming, at))
        .merged_licensed
    else
        .merged_foreign;
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
        if (existing_h != incoming_h) return .legal_crossing;
        return .foreign_junction_violation;
    }
    return .foreign_junction_violation;
}

/// Decide a foreign edge-segment overlap onto an existing edge-segment cell.
/// Returns true when the caller must KEEP the first writer's cell untouched (no
/// OR-merge, no role change) — the transversal / no-foreign-tee behavior — and
/// records the classified event. Returns false to proceed with the pre-C
/// merge (same owner or legal bundle ink).
pub fn segmentOverlap(
    counts: *CrossingCounts,
    bundles: ledger.RealizedBundles,
    bundle_sets: []const ledger.Bundle,
    existing_edge: EdgeId,
    existing_mask: lattice.Neighbours,
    incoming_edge: EdgeId,
    incoming_mask: lattice.Neighbours,
    at: ledger.BundleCell,
) bool {
    if (sameBundle(existing_edge, incoming_edge, bundles, bundle_sets, at)) return false;
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
/// (arrowhead sanctity), recording the violation; false to proceed with the pre-C behavior (an
/// edge's own terminal arrowhead or legal bundle ink).
pub fn arrowheadTransit(
    counts: *CrossingCounts,
    bundles: ledger.RealizedBundles,
    bundle_sets: []const ledger.Bundle,
    arrow_edge: EdgeId,
    incoming_edge: EdgeId,
    at: ledger.BundleCell,
) bool {
    if (sameBundle(arrow_edge, incoming_edge, bundles, bundle_sets, at)) return false;
    counts.arrowhead_transit_violation += 1;
    return true;
}

/// The arms of `mask` that lie OFF the axis of a head pointing `tip`: for
/// a north/south head the east and west bits, for an east/west head the
/// north and south bits. These are the head's two guarded lateral sides.
pub fn lateralArms(tip: lattice.Dir4, mask: lattice.Neighbours) lattice.Neighbours {
    return switch (tip) {
        .north, .south => .{ .e = mask.e, .w = mask.w },
        .east, .west => .{ .n = mask.n, .s = mask.s },
    };
}

/// Decide a write of `incoming_mask` by `incoming_edge` onto the arrowhead
/// cell of `arrow_edge` (tip `tip`). Returns true when the caller must keep
/// the head untouched, recording every event the write is:
///   - foreign ink meeting a head is an arrowhead transit (as before —
///     nothing here weakens that tally);
///   - a lateral arm is refused whatever the licence, and counted as
///     `arm_into_head` per arm, against `incoming_edge`.
/// Returns false only for a bundle co-member riding the head's own axis:
/// a shared stem cell that carries the head, rail-interior state.
/// The head's own edge never reaches this: its writes are its own ink.
/// @guarded-by: crossings.zig "headEntry: a lateral arm is refused for co-members too; an on-axis co-member rides"
pub fn headEntry(
    counts: *CrossingCounts,
    bundles: ledger.RealizedBundles,
    bundle_sets: []const ledger.Bundle,
    arrow_edge: EdgeId,
    tip: lattice.Dir4,
    incoming_edge: EdgeId,
    incoming_mask: lattice.Neighbours,
    at: ledger.BundleCell,
) bool {
    const transit = arrowheadTransit(counts, bundles, bundle_sets, arrow_edge, incoming_edge, at);
    const lateral: u32 = @popCount(lateralArms(tip, incoming_mask).toMask());
    counts.arm_into_head += lateral;
    return transit or lateral != 0;
}

/// Any cell: the structural origins license every position, so the tests that
/// speak for them pass an arbitrary one.
const ANY: ledger.BundleCell = .{ .x = 0, .y = 0 };

const H: lattice.Neighbours = .{ .e = true, .w = true };
const V: lattice.Neighbours = .{ .n = true, .s = true };

test "isStraightPair recognizes only clean H/V runs" {
    try std.testing.expect(isStraightPair(H));
    try std.testing.expect(isStraightPair(V));
    try std.testing.expect(!isStraightPair(.{ .n = true, .e = true }));
    try std.testing.expect(!isStraightPair(.{ .n = true, .e = true, .s = true }));
    try std.testing.expect(!isStraightPair(.{}));
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

test "sameBundle: same owner and selected-bundle co-members" {
    var members = [_]EdgeId{ 10, 11, 12 };
    var sel = [_]ledger.SelectedBundle{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &members }};
    const bundles: ledger.RealizedBundles = .{ .selected_bundles = &sel };

    try std.testing.expect(sameBundle(5, 5, bundles, &.{}, ANY));
    try std.testing.expect(sameBundle(10, 12, bundles, &.{}, ANY));
    try std.testing.expect(!sameBundle(10, 99, bundles, &.{}, ANY));
    try std.testing.expect(!sameBundle(98, 99, .{}, &.{}, ANY));
}

test "sameBundle: bundle membership answers what the plan answers" {
    var members = [_]EdgeId{ 10, 11, 12 };
    var others = [_]EdgeId{ 20, 21 };
    var sel = [_]ledger.SelectedBundle{
        .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &members },
        .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &others },
    };
    const bundles: ledger.RealizedBundles = .{ .selected_bundles = &sel };

    const derived = try ledger.bundlesFromPlan(std.testing.allocator, bundles);
    defer std.testing.allocator.free(derived);

    for ([_]EdgeId{ 10, 11, 12, 20, 21, 99 }) |a| {
        for ([_]EdgeId{ 10, 11, 12, 20, 21, 99 }) |b| {
            try std.testing.expectEqual(
                sameBundle(a, b, bundles, &.{}, ANY),
                sameBundle(a, b, .{}, derived, ANY),
            );
        }
    }
    var fan = [_]EdgeId{ 4, 5 };
    const fan_sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(sameBundle(4, 5, .{}, &fan_sets, ANY));
    try std.testing.expect(!sameBundle(4, 6, .{}, &fan_sets, ANY));
}

test "segmentOverlap: exempt merges; foreign perpendicular keeps first writer" {
    var counts: CrossingCounts = .{};
    try std.testing.expect(segmentOverlap(&counts, .{}, &.{}, 1, H, 2, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);
    counts = .{};

    var members = [_]EdgeId{ 1, 3 };
    var sel = [_]ledger.SelectedBundle{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &members }};
    const bundles: ledger.RealizedBundles = .{ .selected_bundles = &sel };
    try std.testing.expect(segmentOverlap(&counts, bundles, &.{}, 1, H, 2, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);

    try std.testing.expect(!segmentOverlap(&counts, bundles, &.{}, 1, H, 3, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);

    try std.testing.expect(segmentOverlap(&counts, bundles, &.{}, 1, H, 2, H, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.foreign_junction_violation);

    var fan = [_]EdgeId{ 1, 2 };
    const fan_sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(!segmentOverlap(&counts, .{}, &fan_sets, 1, H, 2, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.legal_crossing);
}

test "arrowheadTransit: own terminal exempt, foreign refused" {
    var counts: CrossingCounts = .{};
    try std.testing.expect(!arrowheadTransit(&counts, .{}, &.{}, 7, 7, ANY));
    try std.testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);
    try std.testing.expect(arrowheadTransit(&counts, .{}, &.{}, 7, 8, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
    var fan = [_]EdgeId{ 7, 8 };
    const fan_sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(!arrowheadTransit(&counts, .{}, &fan_sets, 7, 8, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}

test "headEntry: a lateral arm is refused for co-members too; an on-axis co-member rides" {
    var counts: CrossingCounts = .{};
    var fan = [_]EdgeId{ 7, 8 };
    const fan_sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(!headEntry(&counts, .{}, &fan_sets, 7, .south, 8, V, ANY));
    try std.testing.expectEqual(@as(u32, 0), counts.arm_into_head);
    try std.testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);

    try std.testing.expect(headEntry(&counts, .{}, &fan_sets, 7, .south, 8, .{ .n = true, .e = true }, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.arm_into_head);
    try std.testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);

    try std.testing.expect(headEntry(&counts, .{}, &.{}, 7, .east, 9, V, ANY));
    try std.testing.expectEqual(@as(u32, 3), counts.arm_into_head);
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);

    try std.testing.expect(headEntry(&counts, .{}, &.{}, 7, .east, 9, H, ANY));
    try std.testing.expectEqual(@as(u32, 3), counts.arm_into_head);
    try std.testing.expectEqual(@as(u32, 2), counts.arrowhead_transit_violation);
}

test "lateralArms keeps only the bits off the head's axis" {
    const all: lattice.Neighbours = .{ .n = true, .e = true, .s = true, .w = true };
    try std.testing.expectEqual(H.toMask(), lateralArms(.north, all).toMask());
    try std.testing.expectEqual(V.toMask(), lateralArms(.west, all).toMask());
    try std.testing.expectEqual(@as(u4, 0), lateralArms(.south, V).toMask());
}

test "CrossingCounts.add folds every field" {
    var a: CrossingCounts = .{ .legal_crossing = 1, .arm_into_head = 2 };
    a.add(.{ .arm_into_head = 3, .b_frame_bridge = 1 });
    try std.testing.expectEqual(@as(u32, 1), a.legal_crossing);
    try std.testing.expectEqual(@as(u32, 5), a.arm_into_head);
    try std.testing.expectEqual(@as(u32, 1), a.b_frame_bridge);
}

test {
    _ = @import("crossings_test.zig");
}

test "sameBundle: a cell-scoped bundle answers only on its own cells" {
    const licensed = [_]ledger.BundleCell{ .{ .x = 30, .y = 12 }, .{ .x = 30, .y = 13 } };
    const sets = [_]ledger.Bundle{.{ .origin = .port_share, .members = &.{ 9, 11 }, .cells = &licensed }};
    try std.testing.expect(sameBundle(9, 11, .{}, &sets, .{ .x = 30, .y = 12 }));
    try std.testing.expect(sameBundle(9, 11, .{}, &sets, .{ .x = 30, .y = 13 }));
    try std.testing.expect(!sameBundle(9, 11, .{}, &sets, .{ .x = 21, .y = 15 }));
    const fan = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &.{ 9, 11 } }};
    try std.testing.expect(sameBundle(9, 11, .{}, &fan, .{ .x = 21, .y = 15 }));
}

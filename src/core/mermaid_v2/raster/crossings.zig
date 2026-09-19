const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ledger = @import("../base/ledger.zig");
const prim = @import("prim");

pub const EdgeId = ledger.EdgeId;
pub const BundleCell = ledger.BundleCell;

pub fn cellAt(x: u32, y: u32) ledger.BundleCell {
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

pub const CrossingClass = enum {
    legal_crossing,
    foreign_junction_violation,
    arrowhead_transit_violation,
};

pub const CrossingCounts = struct {
    legal_crossing: u32 = 0,
    foreign_junction_violation: u32 = 0,
    arrowhead_transit_violation: u32 = 0,
    b_frame_bridge: u32 = 0,
    b_border_fusion_refused: u32 = 0,
    arm_into_head: u32 = 0,

    pub fn add(self: *CrossingCounts, other: CrossingCounts) void {
        inline for (@typeInfo(CrossingCounts).@"struct".fields) |f| {
            @field(self, f.name) += @field(other, f.name);
        }
    }
};

pub const Ctx = struct {
    bundles: ledger.RealizedBundles = .{},
    bundle_sets: []const ledger.Bundle = &.{},
    stamp_state: sketch.BundleStampState = .unattempted,
    counts: *CrossingCounts,
    mode: prim.SubgraphEdges = .bridge,
};

/// @guarded-by: crossings.zig "sameBundle: bundle membership answers what the plan answers"
/// @guarded-by: crossings.zig "sameBundle: a cell-scoped bundle answers only on its own cells"
pub fn sameBundle(
    a: EdgeId,
    b: EdgeId,
    bundles: ledger.RealizedBundles,
    bundle_sets: []const ledger.Bundle,
    at: ledger.BundleCell,
) bool {
    return ledger.derivedSameBundle(bundles, bundle_sets, a, b, at);
}

/// @guarded-by: crossings_test.zig "carrierKindFor trusts identity only after a complete consistent stamp"
/// @guarded-by: crossings_test.zig "carrierKind asks a rail's bundle by name, so a member of two bundles is licensed on both rails"
pub fn carrierKind(
    bundle_sets: []const ledger.Bundle,
    stamp_state: sketch.BundleStampState,
    held: EdgeId,
    writer: EdgeId,
    rail: ?ledger.BundleId,
    at: ledger.BundleCell,
) lattice.CarrierKind {
    if (stamp_state != .complete or !ledger.bundleSetsNumbered(bundle_sets)) return .merged_untested;
    if (held == writer) return .merged_licensed;
    const licensed = if (rail) |id|
        ledger.memberOfBundleAt(bundle_sets, id, held, at)
    else
        ledger.bundleMembersAt(bundle_sets, held, writer, at);
    return if (licensed) .merged_licensed else .merged_foreign;
}

pub fn carrierKindFor(
    held: EdgeId,
    incoming: EdgeId,
    bundle_sets: []const ledger.Bundle,
    stamp_state: sketch.BundleStampState,
    at: ledger.BundleCell,
) lattice.CarrierKind {
    return carrierKind(bundle_sets, stamp_state, held, incoming, null, at);
}

pub fn carrierKindOnto(
    cell: *const lattice.Cell,
    bundle_sets: []const ledger.Bundle,
    stamp_state: sketch.BundleStampState,
    writer: EdgeId,
    rail: ?ledger.BundleId,
    at: ledger.BundleCell,
) lattice.CarrierKind {
    const held: EdgeId = switch (cell.occupant) {
        .edge_segment => |seg| seg.edge,
        .arrowhead => |h| h.edge,
        else => return .merged_untested,
    };
    return carrierKind(bundle_sets, stamp_state, held, writer, rail, at);
}

pub fn isStraightPair(m: lattice.Neighbours) bool {
    const h = m.e and m.w and !m.n and !m.s;
    const v = m.n and m.s and !m.e and !m.w;
    return h or v;
}

pub fn classifySegment(existing: lattice.Neighbours, incoming: lattice.Neighbours) CrossingClass {
    if (isStraightPair(existing) and isStraightPair(incoming)) {
        const existing_h = existing.e and existing.w;
        const incoming_h = incoming.e and incoming.w;
        if (existing_h != incoming_h) return .legal_crossing;
        return .foreign_junction_violation;
    }
    return .foreign_junction_violation;
}

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

pub fn lateralArms(tip: lattice.Dir4, mask: lattice.Neighbours) lattice.Neighbours {
    return switch (tip) {
        .north, .south => .{ .e = mask.e, .w = mask.w },
        .east, .west => .{ .n = mask.n, .s = mask.s },
    };
}

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

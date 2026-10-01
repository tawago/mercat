const std = @import("std");
const lattice = @import("../lattice.zig");
const geo = @import("geometry.zig");
const ledger = @import("../base/ledger.zig");
const bundle_mod = @import("../base/bundle.zig");
const sharing_mod = @import("../base/sharing.zig");
const prim = @import("prim");

pub const EdgeId = ledger.EdgeId;
pub const BundleCell = bundle_mod.BundleCell;

pub fn bundleCellAt(x: u32, y: u32) bundle_mod.BundleCell {
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

pub const CrossingCounts = struct {
    foreign_junction_violation: u32 = 0,
    arrowhead_transit_violation: u32 = 0,
};

pub const Ctx = struct {
    sharing: sharing_mod.Sharing = .{},
    counts: *CrossingCounts,
    mode: prim.SubgraphEdges = .bridge,

    pub fn segmentOverlap(
        self: Ctx,
        existing_edge: EdgeId,
        existing_mask: lattice.Neighbours,
        incoming_edge: EdgeId,
        incoming_mask: lattice.Neighbours,
        at: bundle_mod.BundleCell,
    ) bool {
        if (self.sharing.sameBundle(existing_edge, incoming_edge, at)) return false;
        if (!isLegalCrossing(existing_mask, incoming_mask)) self.counts.foreign_junction_violation += 1;
        return true;
    }

    pub fn arrowheadTransit(self: Ctx, arrow_edge: EdgeId, incoming_edge: EdgeId, at: bundle_mod.BundleCell) bool {
        if (self.sharing.sameBundle(arrow_edge, incoming_edge, at)) return false;
        self.counts.arrowhead_transit_violation += 1;
        return true;
    }

    pub fn headEntry(
        self: Ctx,
        arrow_edge: EdgeId,
        tip: lattice.Dir4,
        incoming_edge: EdgeId,
        incoming_mask: lattice.Neighbours,
        at: bundle_mod.BundleCell,
    ) bool {
        const transit = self.arrowheadTransit(arrow_edge, incoming_edge, at);
        return transit or geo.lateralArms(tip, incoming_mask).toMask() != 0;
    }
};

pub fn isStraightPair(m: lattice.Neighbours) bool {
    const h = m.e and m.w and !m.n and !m.s;
    const v = m.n and m.s and !m.e and !m.w;
    return h or v;
}

pub fn isLegalCrossing(existing: lattice.Neighbours, incoming: lattice.Neighbours) bool {
    return isStraightPair(existing) and isStraightPair(incoming) and existing.e != incoming.e;
}

const ANY: bundle_mod.BundleCell = .{ .x = 0, .y = 0 };

fn ctxOf(counts: *CrossingCounts, bundles: ledger.RealizedBundles, sets: []const bundle_mod.Bundle) Ctx {
    return .{ .sharing = .{ .realized = bundles, .bundles = sets }, .counts = counts };
}

const H: lattice.Neighbours = .{ .e = true, .w = true };
const V: lattice.Neighbours = .{ .n = true, .s = true };

test "isStraightPair recognizes only clean H/V runs" {
    try std.testing.expect(isStraightPair(H));
    try std.testing.expect(isStraightPair(V));
    try std.testing.expect(!isStraightPair(.{ .n = true, .e = true }));
    try std.testing.expect(!isStraightPair(.{ .n = true, .e = true, .s = true }));
    try std.testing.expect(!isStraightPair(.{}));
}

test "isLegalCrossing: perpendicular is legal, collinear/corner are violations" {
    try std.testing.expect(isLegalCrossing(H, V));
    try std.testing.expect(isLegalCrossing(V, H));
    try std.testing.expect(!isLegalCrossing(H, H));
    try std.testing.expect(!isLegalCrossing(V, V));
    try std.testing.expect(!isLegalCrossing(.{ .n = true, .e = true }, V));
}

test "segmentOverlap: exempt merges; foreign perpendicular keeps first writer" {
    var counts: CrossingCounts = .{};
    try std.testing.expect(ctxOf(&counts, .{}, &.{}).segmentOverlap(1, H, 2, V, ANY));
    try std.testing.expectEqual(@as(u32, 0), counts.foreign_junction_violation);

    var members = [_]EdgeId{ 1, 3 };
    var sel = [_]ledger.SelectedBundle{.{ .id = 0, .candidate_bundle = 0, .members = &members }};
    const bundles: ledger.RealizedBundles = .{ .selected_bundles = &sel };
    try std.testing.expect(ctxOf(&counts, bundles, &.{}).segmentOverlap(1, H, 2, V, ANY));
    try std.testing.expect(!ctxOf(&counts, bundles, &.{}).segmentOverlap(1, H, 3, V, ANY));
    try std.testing.expectEqual(@as(u32, 0), counts.foreign_junction_violation);

    try std.testing.expect(ctxOf(&counts, bundles, &.{}).segmentOverlap(1, H, 2, H, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.foreign_junction_violation);

    var fan = [_]EdgeId{ 1, 2 };
    const fan_sets = [_]bundle_mod.Bundle{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(!ctxOf(&counts, .{}, &fan_sets).segmentOverlap(1, H, 2, H, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.foreign_junction_violation);
}

test "arrowheadTransit: own terminal exempt, foreign refused" {
    var counts: CrossingCounts = .{};
    try std.testing.expect(!ctxOf(&counts, .{}, &.{}).arrowheadTransit(7, 7, ANY));
    try std.testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);
    try std.testing.expect(ctxOf(&counts, .{}, &.{}).arrowheadTransit(7, 8, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
    var fan = [_]EdgeId{ 7, 8 };
    const fan_sets = [_]bundle_mod.Bundle{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(!ctxOf(&counts, .{}, &fan_sets).arrowheadTransit(7, 8, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}

test "headEntry: a lateral arm is refused for co-members too; an on-axis co-member rides" {
    var counts: CrossingCounts = .{};
    var fan = [_]EdgeId{ 7, 8 };
    const fan_sets = [_]bundle_mod.Bundle{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(!ctxOf(&counts, .{}, &fan_sets).headEntry(7, .south, 8, V, ANY));
    try std.testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);

    try std.testing.expect(ctxOf(&counts, .{}, &fan_sets).headEntry(7, .south, 8, .{ .n = true, .e = true }, ANY));
    try std.testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);

    try std.testing.expect(ctxOf(&counts, .{}, &.{}).headEntry(7, .east, 9, V, ANY));
    try std.testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);

    try std.testing.expect(ctxOf(&counts, .{}, &.{}).headEntry(7, .east, 9, H, ANY));
    try std.testing.expectEqual(@as(u32, 2), counts.arrowhead_transit_violation);
}

test {
    _ = @import("crossings_test.zig");
}

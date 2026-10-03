const std = @import("std");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const bundle_mod = @import("../base/bundle.zig");
const stitch = @import("stitch.zig");
const stitch_sharing = @import("stitch_sharing.zig");

test "superSize wraps child bbox with frame padding (scale 0 = full inset)" {
    const sz = stitch.superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 0, false);
    try std.testing.expectEqual(@as(u32, 28), sz.w);
    try std.testing.expectEqual(@as(u32, 12), sz.h);
}

test "superSize shrinks x inset under pressure (scale > 0), y unchanged" {
    const sz = stitch.superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 1, false);
    try std.testing.expectEqual(@as(u32, 24), sz.w);
    try std.testing.expectEqual(@as(u32, 12), sz.h);
}

test "superSize for a synthetic packing cluster is exactly the child bbox" {
    const sz = stitch.superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 0, true);
    try std.testing.expectEqual(@as(u32, 20), sz.w);
    try std.testing.expectEqual(@as(u32, 8), sz.h);
}

test "shiftSet carries a port-share set's cell scope and pairwise table across the id shift" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem = [_]bundle_mod.BundleCell{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 8 } };
    const port_only = [_]bundle_mod.BundleCell{.{ .x = 5, .y = 3 }};
    const pairwise = [_]bundle_mod.PairCells{
        .{ .a = 0, .b = 1, .cells = &stem },
        .{ .a = 0, .b = 2, .cells = &port_only },
    };
    const cs: bundle_mod.Bundle = .{
        .origin = .port_share,
        .members = &.{ 0, 1, 2 },
        .cells = &stem,
        .pairwise = &pairwise,
    };

    const shifted = try stitch_sharing.shiftSet(a, cs, 100, 10, 20);
    try std.testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101, 102 }, shifted.members);
    try std.testing.expect(shifted.cells != null);
    try std.testing.expectEqual(@as(i32, 15), shifted.cells.?[0].x);
    try std.testing.expectEqual(@as(i32, 23), shifted.cells.?[0].y);
    try std.testing.expect(shifted.pairwise != null);
    try std.testing.expectEqual(@as(sketch.EdgeId, 100), shifted.pairwise.?[0].a);
    try std.testing.expectEqual(@as(sketch.EdgeId, 101), shifted.pairwise.?[0].b);
    try std.testing.expectEqual(@as(i32, 15), shifted.pairwise.?[0].cells[0].x);
    try std.testing.expectEqual(@as(sketch.EdgeId, 102), shifted.pairwise.?[1].b);
    try std.testing.expectEqual(@as(usize, 1), shifted.pairwise.?[1].cells.len);
    try std.testing.expectEqual(@as(i32, 15), shifted.pairwise.?[1].cells[0].x);
    try std.testing.expectEqual(@as(i32, 23), shifted.pairwise.?[1].cells[0].y);

    const wide: bundle_mod.Bundle = .{ .origin = .fan_rail, .members = &.{ 5, 6 } };
    const shifted_wide = try stitch_sharing.shiftSet(a, wide, 0, 1, 1);
    try std.testing.expect(shifted_wide.cells == null);
    try std.testing.expect(shifted_wide.pairwise == null);
}

test "merge renumbers bundles per piece and shifts every edge id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const m0 = [_]ledger.EdgeId{ 0, 1 };
    const m1 = [_]ledger.EdgeId{ 2, 3 };
    const piece_a: ledger.RealizedBundles = .{
        .selected_bundles = &.{.{ .id = 0, .candidate_bundle = 0, .members = &m0 }},
        .memberships = &.{
            .{ .edge = 0, .source = .{ .selected = 0 }, .target = null },
            .{ .edge = 1, .source = .{ .selected = 0 }, .target = null },
        },
        .discharged = &.{1},
    };
    const piece_b: ledger.RealizedBundles = .{
        .selected_bundles = &.{.{ .id = 0, .candidate_bundle = 2, .members = &m1 }},
        .memberships = &.{
            .{ .edge = 2, .source = null, .target = .{ .selected = 0 } },
        },
    };
    const merged = try stitch_sharing.merge(a, &.{
        .{ .bundles = piece_a, .edge_base = 0 },
        .{ .bundles = piece_b, .edge_base = 10 },
    });

    try std.testing.expectEqual(@as(usize, 2), merged.selected_bundles.len);
    try std.testing.expectEqual(@as(ledger.SelectedBundleId, 0), merged.selected_bundles[0].id);
    try std.testing.expectEqual(@as(ledger.SelectedBundleId, 1), merged.selected_bundles[1].id);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{ 0, 1 }, merged.selected_bundles[0].members);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{ 12, 13 }, merged.selected_bundles[1].members);
    try std.testing.expectEqual(@as(ledger.EdgeId, 12), merged.memberships[2].edge);
    try std.testing.expectEqual(ledger.MembershipDisposition{ .selected = 1 }, merged.memberships[2].target.?);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{1}, merged.discharged);
}

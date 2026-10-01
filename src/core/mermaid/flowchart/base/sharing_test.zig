const std = @import("std");
const ledger = @import("ledger.zig");
const bundle_mod = @import("bundle.zig");
const bundle_plan = @import("bundle_plan.zig");
const sharing_mod = @import("sharing.zig");

const EdgeId = ledger.EdgeId;
const ANY: bundle_mod.BundleCell = .{ .x = 0, .y = 0 };

fn sharingOf(bundles: ledger.RealizedBundles, sets: []const bundle_mod.Bundle) sharing_mod.Sharing {
    return .{ .realized = bundles, .bundles = sets };
}

test "sameBundle: same owner and selected-bundle co-members" {
    var members = [_]EdgeId{ 10, 11, 12 };
    var sel = [_]ledger.SelectedBundle{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &members }};
    const bundles: ledger.RealizedBundles = .{ .selected_bundles = &sel };

    try std.testing.expect(sharingOf(bundles, &.{}).sameBundle(5, 5, ANY));
    try std.testing.expect(sharingOf(bundles, &.{}).sameBundle(10, 12, ANY));
    try std.testing.expect(!sharingOf(bundles, &.{}).sameBundle(10, 99, ANY));
    try std.testing.expect(!sharingOf(.{}, &.{}).sameBundle(98, 99, ANY));
}

test "sameBundle: bundle membership answers what the plan answers" {
    var members = [_]EdgeId{ 10, 11, 12 };
    var others = [_]EdgeId{ 20, 21 };
    var sel = [_]ledger.SelectedBundle{
        .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &members },
        .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &others },
    };
    const bundles: ledger.RealizedBundles = .{ .selected_bundles = &sel };

    const derived = try bundle_plan.bundlesFromPlan(std.testing.allocator, bundles);
    defer std.testing.allocator.free(derived);

    for ([_]EdgeId{ 10, 11, 12, 20, 21, 99 }) |a| {
        for ([_]EdgeId{ 10, 11, 12, 20, 21, 99 }) |b| {
            try std.testing.expectEqual(
                sharingOf(bundles, &.{}).sameBundle(a, b, ANY),
                sharingOf(.{}, derived).sameBundle(a, b, ANY),
            );
        }
    }
    var fan = [_]EdgeId{ 4, 5 };
    const fan_sets = [_]bundle_mod.Bundle{.{ .origin = .fan_rail, .members = &fan }};
    try std.testing.expect(sharingOf(.{}, &fan_sets).sameBundle(4, 5, ANY));
    try std.testing.expect(!sharingOf(.{}, &fan_sets).sameBundle(4, 6, ANY));
}

test "sameBundle: a cell-scoped bundle answers only on its own cells" {
    const licensed = [_]bundle_mod.BundleCell{ .{ .x = 30, .y = 12 }, .{ .x = 30, .y = 13 } };
    const sets = [_]bundle_mod.Bundle{.{ .origin = .port_share, .members = &.{ 9, 11 }, .cells = &licensed }};
    try std.testing.expect(sharingOf(.{}, &sets).sameBundle(9, 11, .{ .x = 30, .y = 12 }));
    try std.testing.expect(sharingOf(.{}, &sets).sameBundle(9, 11, .{ .x = 30, .y = 13 }));
    try std.testing.expect(!sharingOf(.{}, &sets).sameBundle(9, 11, .{ .x = 21, .y = 15 }));
    const fan = [_]bundle_mod.Bundle{.{ .origin = .fan_rail, .members = &.{ 9, 11 } }};
    try std.testing.expect(sharingOf(.{}, &fan).sameBundle(9, 11, .{ .x = 21, .y = 15 }));
}

test "derived sameness follows declared membership and licensed cells" {
    const members = [_]EdgeId{ 4, 5 };
    const declared = [_]bundle_mod.Bundle{.{ .origin = .fan_rail, .members = &members }};
    try std.testing.expect(sharingOf(.{}, &declared).sameBundle(4, 5, null));
    try std.testing.expect(!sharingOf(.{}, &declared).sameBundle(4, 6, null));

    const here = [_]bundle_mod.BundleCell{.{ .x = 2, .y = 2 }};
    const scoped = [_]bundle_mod.Bundle{.{ .origin = .port_share, .members = &members, .cells = &here }};
    try std.testing.expect(sharingOf(.{}, &scoped).sameBundle(4, 5, .{ .x = 2, .y = 2 }));
    try std.testing.expect(!sharingOf(.{}, &scoped).sameBundle(4, 5, .{ .x = 7, .y = 7 }));
}

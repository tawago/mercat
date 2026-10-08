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

test "sameBundle: bundle membership answers what the plan answers" {
    var members = [_]EdgeId{ 10, 11, 12 };
    var others = [_]EdgeId{ 20, 21 };
    var sel = [_]ledger.SelectedBundle{
        .{ .id = 0, .candidate_bundle = 0, .members = &members },
        .{ .id = 1, .candidate_bundle = 1, .members = &others },
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
    // An edge is always in its own bundle, even with nothing selected.
    try std.testing.expect(sharingOf(.{}, &.{}).sameBundle(5, 5, ANY));
    try std.testing.expect(!sharingOf(.{}, &.{}).sameBundle(98, 99, ANY));
}

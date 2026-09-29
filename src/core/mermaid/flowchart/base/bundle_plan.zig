const std = @import("std");
const ledger = @import("ledger.zig");
const bundle_mod = @import("bundle.zig");

const EdgeId = ledger.EdgeId;
const RealizedBundles = ledger.RealizedBundles;
const Bundle = bundle_mod.Bundle;
const BundleCell = bundle_mod.BundleCell;
const bundleMembersAt = bundle_mod.bundleMembersAt;

pub fn derivedSameBundle(
    bundles: RealizedBundles,
    sets: []const Bundle,
    first: EdgeId,
    second: EdgeId,
    at: ?BundleCell,
) bool {
    if (first == second) return true;
    if (bundleMembersAt(sets, first, second, at)) return true;
    for (bundles.selected_bundles) |j| {
        if (holds(j.members, first) and holds(j.members, second)) return true;
    }
    return false;
}

fn holds(edges: []const EdgeId, edge: EdgeId) bool {
    for (edges) |e| {
        if (e == edge) return true;
    }
    return false;
}

pub fn bundlesFromPlan(
    allocator: std.mem.Allocator,
    bundles: RealizedBundles,
) error{OutOfMemory}![]const Bundle {
    if (bundles.selected_bundles.len == 0) return &.{};
    var out: std.ArrayListUnmanaged(Bundle) = .empty;
    for (bundles.fused) |u| try out.append(allocator, .{ .origin = .selected_bundle, .members = u });
    for (bundles.selected_bundles) |j| {
        if (subsetOfAny(bundles.fused, j.members)) continue;
        try out.append(allocator, .{ .origin = .selected_bundle, .members = j.members });
    }
    return out.toOwnedSlice(allocator);
}

fn subsetOfAny(unions: []const []const EdgeId, members: []const EdgeId) bool {
    for (unions) |u| {
        var all = true;
        for (members) |m| {
            if (!holds(u, m)) all = false;
        }
        if (all) return true;
    }
    return false;
}

const std = @import("std");
const ledger = @import("ledger.zig");
const bundle_mod = @import("bundle.zig");

pub fn bundlesFromPlan(
    allocator: std.mem.Allocator,
    bundles: ledger.RealizedBundles,
) error{OutOfMemory}![]const bundle_mod.Bundle {
    if (bundles.selected_bundles.len == 0) return &.{};
    var out: std.ArrayListUnmanaged(bundle_mod.Bundle) = .empty;
    for (bundles.fused) |u| try out.append(allocator, .{ .origin = .selected_bundle, .members = u });
    for (bundles.selected_bundles) |j| {
        if (subsetOfAny(bundles.fused, j.members)) continue;
        try out.append(allocator, .{ .origin = .selected_bundle, .members = j.members });
    }
    return out.toOwnedSlice(allocator);
}

fn subsetOfAny(unions: []const []const ledger.EdgeId, members: []const ledger.EdgeId) bool {
    for (unions) |u| {
        for (members) |m| {
            if (!ledger.containsEdge(u, m)) break;
        } else return true;
    }
    return false;
}

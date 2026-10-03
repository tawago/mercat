const ledger = @import("ledger.zig");
const bundle_mod = @import("bundle.zig");
const rail_star = @import("rail_star.zig");

pub const Sharing = struct {
    realized: ledger.RealizedBundles = .{},
    bundles: []const bundle_mod.Bundle = &.{},
    claims: []const rail_star.RailClaim = &.{},

    pub fn sameBundle(self: Sharing, first: ledger.EdgeId, second: ledger.EdgeId, at: ?bundle_mod.BundleCell) bool {
        if (first == second) return true;
        if (bundle_mod.bundleMembersAt(self.bundles, first, second, at)) return true;
        for (self.realized.selected_bundles) |selected| {
            if (ledger.containsEdge(selected.members, first) and ledger.containsEdge(selected.members, second)) return true;
        }
        return false;
    }
};

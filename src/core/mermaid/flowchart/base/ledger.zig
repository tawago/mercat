const std = @import("std");

pub const NodeId = u32;
pub const EdgeId = u32;
pub const CandidateBundleId = u32;
pub const SelectedBundleId = u32;

pub const BundlePolicy = enum { joined };

pub const BundleDirection = enum { out, in };

pub const CandidateBundle = struct {
    id: CandidateBundleId,
    direction: BundleDirection,
    pivot: NodeId,
    members: []const EdgeId,
};

pub const BundleMembership = struct {
    edge: EdgeId,
    source_group: ?CandidateBundleId,
    target_group: ?CandidateBundleId,
};

pub const BundlePermits = struct {
    policy: BundlePolicy,
    scope: Scope = .flat,
    groups: []const CandidateBundle = &.{},
    memberships: []const BundleMembership = &.{},

    pub const Scope = enum { flat, skipped_clustered, piece };

    pub fn isFlat(self: BundlePermits) bool {
        return self.scope == .flat;
    }
};

pub const IndependentReason = enum { not_selected, licence_refused };

pub const MembershipDisposition = union(enum) {
    selected: SelectedBundleId,
    independent: struct {
        candidate_bundle: CandidateBundleId,
        reason: IndependentReason,
    },
};

pub const SelectedBundle = struct {
    id: SelectedBundleId,
    candidate_bundle: CandidateBundleId,
    members: []const EdgeId,
};

pub const RealizedEdgeMembership = struct {
    edge: EdgeId,
    source: ?MembershipDisposition,
    target: ?MembershipDisposition,
};

pub const EndpointSide = enum(u1) { source_exit = 0, target_entry = 1 };

pub const RealizedBundles = struct {
    selected_bundles: []const SelectedBundle = &.{},
    memberships: []const RealizedEdgeMembership = &.{},
    discharged: []const EdgeId = &.{},
    fused: []const []const EdgeId = &.{},
};

pub fn containsEdge(edges: []const EdgeId, edge: EdgeId) bool {
    return std.mem.indexOfScalar(EdgeId, edges, edge) != null;
}

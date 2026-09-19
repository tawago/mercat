const std = @import("std");

// @guarded-by: ledger_test.zig "identity handles match prim's"

pub const NodeId = u32;
pub const EdgeId = u32;
pub const CandidateBundleId = u32;
pub const BundleProposalId = u32;
pub const SelectedBundleId = u32;

/// @guarded-by: ledger_test.zig "V-D-POLICY-01: BundlePolicy has exactly one variant, named joined"
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

pub const CandidateGeometryRef = union(enum) {
    rail: u32,
    edge_path: u32,
};

pub const BundleProposal = struct {
    id: BundleProposalId,
    candidate_bundle: CandidateBundleId,
    members: []const EdgeId,
    candidate_geometry: CandidateGeometryRef,
};

pub const SelectedBundle = struct {
    id: SelectedBundleId,
    proposal: BundleProposalId,
    candidate_bundle: CandidateBundleId,
    members: []const EdgeId,
};

pub const RealizedEdgeMembership = struct {
    edge: EdgeId,
    source: ?MembershipDisposition,
    target: ?MembershipDisposition,
};

pub const EndpointSide = enum(u1) { source_exit = 0, target_entry = 1 };

pub const TerminalPort = struct {
    node: NodeId,
    edge: EdgeId,
    endpoint_side: EndpointSide,
    port: u32,
};

/// @guarded-by: ledger_test.zig "empty RealizedBundles is default-constructible with all-empty fields"
pub const RealizedBundles = struct {
    selected_bundles: []const SelectedBundle = &.{},
    rejected_proposals: []const BundleProposalId = &.{},
    memberships: []const RealizedEdgeMembership = &.{},
    terminal_ports: []const TerminalPort = &.{},
    /// @guarded-by: rail_closure_test.zig "a fully declared clique keeps the rail and discharges every pair edge"
    discharged: []const EdgeId = &.{},
    /// @guarded-by: bundle_commit_test.zig "a complete bipartite of selected arrivals licenses one fused union"
    fused: []const []const EdgeId = &.{},
};

const rail_closure = @import("rail_closure.zig");

pub const doubleDischarged = rail_closure.doubleDischarged;

const rail_star = @import("rail_star.zig");

pub const RailPolarity = rail_star.RailPolarity;
pub const Endpoint = rail_star.Endpoint;
pub const AttachmentSite = rail_star.AttachmentSite;
pub const RailClaimMember = rail_star.RailClaimMember;
pub const RailClaim = rail_star.RailClaim;
pub const checkRailClaim = rail_star.check;
pub const RailLicenceMember = rail_star.RailLicenceMember;
pub const RailLicenceCheck = rail_star.LicenceCheckResult;
pub const checkRailLicence = rail_star.checkLicence;

pub const ClosureCounts = struct {
    rail_deco_mixed: u32 = 0,
    rail_member_style_mixed: u32 = 0,
    rail_star_violation: u32 = 0,
    rail_closure_undeclared: u32 = 0,
    co_undeclared: u32 = 0,
    co_double_discharge: u32 = 0,
};

pub const GapRows = struct {
    gap: u32,
    base: u32,
    reserved: u32,
    free: u32,
    rows_used: u32,
    claimed: u64,
    base_used: bool,
    near: i32 = 0,
    far: i32 = 0,
    claims: []const GapClaim = &.{},
};

pub const RailKey = struct { pivot: NodeId, out: bool };

pub const GapClaim = struct {
    row: i32,
    height: u32,
    edges: []const EdgeId = &.{},
    rails: []const RailKey = &.{},
    bridge: bool = false,
};

pub fn gapSpacingNeeded(rows_used: u32, base_used: bool) u32 {
    if (rows_used > 0) return rows_used + 2;
    return if (base_used) 2 else 0;
}

const bundle = @import("bundle.zig");

pub const Bundle = bundle.Bundle;
pub const BundleCell = bundle.BundleCell;
pub const PairCells = bundle.PairCells;
pub const concatBundles = bundle.concatBundles;
pub const bundleMembersAt = bundle.bundleMembersAt;
pub const memberOfBundleAt = bundle.memberOfBundleAt;
pub const BundleId = bundle.BundleId;
pub const no_bundle = bundle.no_bundle;
pub const numberBundles = bundle.numberBundles;
pub const bundleSetsNumbered = bundle.bundleSetsNumbered;
pub const resolveStructuralBundle = bundle.resolveStructuralBundle;
pub const structuralUnscoped = bundle.structuralUnscoped;

/// @guarded-by: ledger_test.zig "the derivation and the recorded identity answer alike on a declared bundle"
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

/// @guarded-by: select_test.zig "a clustered render's rail bundles come from its piece plan and survive the stitch"
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

pub const OrdinalEntry = struct { name: []const u8, ordinal: u8 };

/// @guarded-by: ledger_test.zig "D-PORT clause 4: every EdgeKind name→ordinal pair is pinned"
pub const edge_kind_ordinals = [_]OrdinalEntry{
    .{ .name = "solid", .ordinal = 0 },
    .{ .name = "dotted", .ordinal = 1 },
    .{ .name = "thick", .ordinal = 2 },
    .{ .name = "invisible", .ordinal = 3 },
};

/// @guarded-by: ledger_test.zig "D-PORT clause 4: every ArrowEnd name→ordinal pair is pinned"
pub const arrow_end_ordinals = [_]OrdinalEntry{
    .{ .name = "none", .ordinal = 0 },
    .{ .name = "open", .ordinal = 1 },
    .{ .name = "filled", .ordinal = 2 },
    .{ .name = "circle", .ordinal = 3 },
    .{ .name = "cross", .ordinal = 4 },
};

pub fn ordinalByName(table: []const OrdinalEntry, name: []const u8) ?u8 {
    for (table) |row| {
        if (std.mem.eql(u8, row.name, name)) return row.ordinal;
    }
    return null;
}

pub fn edgeKindOrdinal(kind: anytype) u8 {
    return enumOrdinal(&edge_kind_ordinals, kind);
}

pub fn arrowEndOrdinal(arrow: anytype) u8 {
    return enumOrdinal(&arrow_end_ordinals, arrow);
}

fn enumOrdinal(comptime table: []const OrdinalEntry, value: anytype) u8 {
    return switch (value) {
        inline else => |v| comptime ordinalByName(table, @tagName(v)) orelse
            @compileError("tag '" ++ @tagName(v) ++ "' has no pinned ordinal in ledger"),
    };
}

// @guarded-by: ledger_test.zig "comparator keys carry no numeric ids by construction"

pub fn nodeKeyOrder(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

pub fn labelOrder(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    const av = a orelse return if (b == null) .eq else .lt;
    const bv = b orelse return .gt;
    return std.mem.order(u8, av, bv);
}

/// @guarded-by: ledger_test.zig "edge key comparator orders field-by-field with no-label-first"
pub const EdgeKey = struct {
    from: []const u8,
    to: []const u8,
    kind: u8,
    arrow_from: u8,
    arrow_to: u8,
    label: ?[]const u8,
};

pub fn edgeKeyOrder(a: EdgeKey, b: EdgeKey) std.math.Order {
    const from = nodeKeyOrder(a.from, b.from);
    if (from != .eq) return from;
    const to = nodeKeyOrder(a.to, b.to);
    if (to != .eq) return to;
    const kind = std.math.order(a.kind, b.kind);
    if (kind != .eq) return kind;
    const af = std.math.order(a.arrow_from, b.arrow_from);
    if (af != .eq) return af;
    const at = std.math.order(a.arrow_to, b.arrow_to);
    if (at != .eq) return at;
    return labelOrder(a.label, b.label);
}

/// @guarded-by: ledger_test.zig "attachment key K orders field-by-field with pinned ordinals"
pub const AttachmentKey = struct {
    opposite: []const u8,
    endpoint_side: EndpointSide,
    kind: u8,
    arrow_from: u8,
    arrow_to: u8,
    label: ?[]const u8,
};

pub fn attachmentKeyOrder(a: AttachmentKey, b: AttachmentKey) std.math.Order {
    const opp = nodeKeyOrder(a.opposite, b.opposite);
    if (opp != .eq) return opp;
    const side = std.math.order(@intFromEnum(a.endpoint_side), @intFromEnum(b.endpoint_side));
    if (side != .eq) return side;
    const kind = std.math.order(a.kind, b.kind);
    if (kind != .eq) return kind;
    const af = std.math.order(a.arrow_from, b.arrow_from);
    if (af != .eq) return af;
    const at = std.math.order(a.arrow_to, b.arrow_to);
    if (at != .eq) return at;
    return labelOrder(a.label, b.label);
}

//! Base-tier pure-data vocabulary for the semantic bundle permits and the
//! candidate-local realized-bundle artifact (D-IR item 1): the
//! BundlePolicy storage, the BundlePermits / RealizedBundles logical records,
//! the bundle membership sets riding the Sketch beside that plan,
//! terminal-port identities, and the canonical semantic-key
//! comparators with the pinned D-PORT clause-4 ordinal tables.
//!
//! Pure data + pure functions only; imports only std. Universally
//! importable (every zone may reach it), mirroring base/lanes.zig —
//! enforced by tools/lint_imports.zig (base/ dir rule).
//! Tests live in ledger_test.zig, aggregated from entry.zig's test
//! block so this file keeps D-IR item 1's literal empty allowlist.

const std = @import("std");

// Identity handles. Structurally identical to base/types.zig's u32 handles.
// @guarded-by: ledger_test.zig "identity handles match prim's"

pub const NodeId = u32;
pub const EdgeId = u32;
pub const CandidateBundleId = u32;
pub const BundleProposalId = u32;
pub const SelectedBundleId = u32;

/// Exactly ONE constructible variant: the type system, not a runtime guard,
/// makes non-joined policy unrepresentable. Only entry.zig (the composition
/// root) may originate the value (D-POLICY item 3).
/// @guarded-by: ledger_test.zig "V-D-POLICY-01: BundlePolicy has exactly one variant, named joined"
pub const BundlePolicy = enum { joined };

pub const BundleDirection = enum { out, in };

/// One semantic endpoint incidence group: a fan-out (direction=.out, pivot
/// is the shared source) or fan-in (.in, pivot is the shared target) with
/// at least two member edges. Members are arena `[]const EdgeId` slices
/// (D-IR item 7 container rule).
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

/// The ONE shared semantic plan per render. `groups` states
/// where joining is semantically PERMITTED — it must never be read as an
/// instruction that a permitted group has a rail; only
/// `RealizedBundles.selected_bundles` authorizes shared group geometry.
pub const BundlePermits = struct {
    policy: BundlePolicy,
    /// `.flat`: computed from a cluster-free graph and consumable.
    /// `.skipped_clustered`: deliberately not computed because the graph is
    /// clustered (groups/memberships empty); consumers must not realize or
    /// apply it. Part of the plan itself so no flag rides beside the record.
    /// `.piece`: computed for one cluster-free recursion piece of a clustered
    /// original, keyed by ORIGIN (root-graph) edge ids; not realizable until
    /// the piece merge lands.
    scope: Scope = .flat,
    groups: []const CandidateBundle = &.{},
    memberships: []const BundleMembership = &.{},

    pub const Scope = enum { flat, skipped_clustered, piece };

    pub fn isFlat(self: BundlePermits) bool {
        return self.scope == .flat;
    }
};

/// `licence_refused`: the group failed the geometry-free licence check —
/// distinct from `not_selected`, where a licensed bundle simply realized no
/// shared rail (e.g. bridge-scope groups, whose realization is deferred).
pub const IndependentReason = enum { not_selected, licence_refused };

pub const MembershipDisposition = union(enum) {
    selected: SelectedBundleId,
    independent: struct {
        candidate_bundle: CandidateBundleId,
        reason: IndependentReason,
    },
};

/// Attribution reference into the candidate's OWN Sketch (D-IR item 6):
/// an index, never a coordinate; geometry derives from the owning Sketch
/// at consumption time.
pub const CandidateGeometryRef = union(enum) {
    /// Index into the candidate Sketch's `rails`.
    rail: u32,
    /// Index into the candidate Sketch's `edges`.
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

/// D-PORT clause 4: which end of the edge an attachment/terminal belongs
/// to. The numeric values participate in canonical key K
/// (source-exit=0, target-entry=1).
pub const EndpointSide = enum(u1) { source_exit = 0, target_entry = 1 };

/// Typed port terminal (D-IR item 6): identities and indices
/// only — `port` is a perimeter port ORDINAL, never a coordinate.
pub const TerminalPort = struct {
    node: NodeId,
    edge: EdgeId,
    endpoint_side: EndpointSide,
    port: u32,
};

/// The candidate-local artifact riding `Sketch.bundles` (D-IR item 4). All
/// fields defaulted so `.{}` is the valid empty plan.
/// @guarded-by: ledger_test.zig "empty RealizedBundles is default-constructible with all-empty fields"
pub const RealizedBundles = struct {
    selected_bundles: []const SelectedBundle = &.{},
    rejected_proposals: []const BundleProposalId = &.{},
    memberships: []const RealizedEdgeMembership = &.{},
    terminal_ports: []const TerminalPort = &.{},
    /// Declared edges whose ENTIRE rendering is another element's shared ink:
    /// the leaf-pair edges an all-arrow-free rail discharges by running its
    /// crossbar between their two taps (the rail-closure licence). A discharged
    /// edge owns no polyline, no port and no label of its own, so it must be
    /// withheld from independent routing — and it is NOT missing, because the
    /// crossbar between the taps IS its rendering.
    /// @guarded-by: rail_closure_test.zig "a fully declared clique keeps the rail and discharges every pair edge"
    discharged: []const EdgeId = &.{},
    /// Two-sided fusion licences: each entry is the member-edge UNION of a set
    /// of selected same-direction rails whose declared pairs are EXACTLY
    /// srcs x tgts with every member blocking the leaf-to-leaf trace (the
    /// closure test of base/rail_closure.zig, asked of the whole union). Such
    /// rails may share one rail row and their ink is ONE bundle; anything
    /// short of complete never appears here.
    /// @guarded-by: bundle_commit_test.zig "a complete bipartite of selected arrivals licenses one fused union"
    fused: []const []const EdgeId = &.{},
};

const rail_closure = @import("rail_closure.zig");

/// How many discharged edges also own private geometry (`co_double_discharge`);
/// the predicate itself lives in the sibling rail_closure.zig.
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

/// The all-arrow-free shared-rail closure licence's REPORT-ONLY inventory
/// (base/rail_closure.zig), carried on the Sketch so the shipped candidate's
/// counts reach telemetry. Never read by a layout decision: a refusal is
/// already expressed as the `independent` disposition that unfuses the
/// members, and these fields only NAME what happened. Field names are
/// the registry tags verbatim (pinned by test).
pub const ClosureCounts = struct {
    /// Construction groups with candidates excluded for mixed pivot decoration.
    rail_deco_mixed: u32 = 0,
    /// Construction groups with candidates excluded for mixed stroke style.
    rail_member_style_mixed: u32 = 0,
    /// Construction-time non-star proposals privatized safely.
    rail_star_violation: u32 = 0,
    /// Rails the licence refused as proposed — outright, or by salvaging a strict
    /// subset. One per refused rail.
    rail_closure_undeclared: u32 = 0,
    /// Leaf pairs of a proposed rail with no usable backing declaration:
    /// undeclared, decorated, labeled, or of the wrong stroke class.
    co_undeclared: u32 = 0,
    /// Discharged edges that ALSO kept private geometry — the withholding
    /// leaked and one relation is stated twice. Must stay zero.
    co_double_discharge: u32 = 0,
};

/// One inter-rank gap's row account, written by layout for the report-only
/// invariant: the gap's spacing is its base plus what the row ledger holds,
/// and every row the ledger holds is stood on by a claim.
pub const GapRows = struct {
    gap: u32,
    /// Rows the plain inter-layer spacing gives the gap before any claim.
    base: u32,
    /// Rows the layout placed between the two layers.
    reserved: u32,
    /// Ledger rows the base spacing already contains.
    free: u32,
    /// Ledger rows the packed claims occupy, counted from row 0.
    rows_used: u32,
    /// Bit r set iff some claim stands on ledger row r.
    claimed: u64,
    /// A claim stands on the base row (`wall - 2`).
    base_used: bool,
    /// The gap's first cell beside the target layer (`wall - 1`) and beside
    /// the source layer, on the layer axis, in the frame the ink is painted
    /// in: row r is `near - 2 - r` counted toward `far`.
    near: i32 = 0,
    far: i32 = 0,
    /// Every claim packed into this gap, so painted ink can be traced to it.
    claims: []const GapClaim = &.{},
};

/// The rail a gap claim answers for: a fan's pivot and its direction.
pub const RailKey = struct { pivot: NodeId, out: bool };

/// One packed claim: the rows it stands on and the ink it stands for. A
/// `bridge` claim stands for the cluster bridges routed after the piece,
/// whose edge ids the piece never learns.
pub const GapClaim = struct {
    row: i32,
    height: u32,
    edges: []const EdgeId = &.{},
    rails: []const RailKey = &.{},
    bridge: bool = false,
};

/// The spacing a gap needs for its claims: row 0 is `wall - 3`, so a gap
/// with a claimed row holds `rows_used + 2` cells, and one whose only run
/// is on the base row holds two.
pub fn gapSpacingNeeded(rows_used: u32, base_used: bool) u32 {
    if (rows_used > 0) return rows_used + 2;
    return if (base_used) 2 else 0;
}

const bundle = @import("bundle.zig");

pub const Bundle = bundle.Bundle;
pub const BundleCell = bundle.BundleCell;
pub const PairCells = bundle.PairCells;
pub const keepOrigin = bundle.keepOrigin;
pub const concatBundles = bundle.concatBundles;
pub const bundleMembersAt = bundle.bundleMembersAt;
pub const BundleId = bundle.BundleId;
pub const no_bundle = bundle.no_bundle;
pub const numberBundles = bundle.numberBundles;
pub const rosterNumbered = bundle.rosterNumbered;
pub const resolveStructuralBundle = bundle.resolveStructuralBundle;
pub const structuralUnscoped = bundle.structuralUnscoped;
pub const bundleOf = bundle.bundleOf;

/// The pre-identity DERIVATION of the bundle relation: a pairwise
/// membership scan over the roster AND the realized plan, asked at a position.
/// Two edges are on one bundle iff the same owner, or some set names both
/// here, or some selected bundle holds both.
///
/// This is the shape the raster used to ESTABLISH every licence with, before a
/// bundle had a name. It is kept — one copy, here — as the WITNESS the
/// recorded identity is measured against: it runs beside a `bundleOf`
/// comparison on every carrier a render files and counts the two answers
/// agreeing and disagreeing. Nothing that only LABELS a record calls it any more.
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

/// The bundle sets a realized plan authorizes: one per selected bundle,
/// members BORROWED from the plan (same arena, no copy). This is the flat
/// population; the caller applies it exactly where it applies the plan,
/// because nowhere earlier is the plan final.
///
/// Membership-equivalent to interrogating the plan directly: `bundleMembersAt` over
/// the result answers what a `selected_bundles` scan answers.
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

/// Both arrow fields (`arrow_from` and `arrow_to`) share this table.
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

/// Map an EdgeKind-shaped enum VALUE through the pinned table by tag name.
/// A tag missing from the table fails compilation instead of inventing an
/// ordinal.
pub fn edgeKindOrdinal(kind: anytype) u8 {
    return enumOrdinal(&edge_kind_ordinals, kind);
}

/// Map an ArrowEnd-shaped enum VALUE through the pinned table by tag name.
pub fn arrowEndOrdinal(arrow: anytype) u8 {
    return enumOrdinal(&arrow_end_ordinals, arrow);
}

fn enumOrdinal(comptime table: []const OrdinalEntry, value: anytype) u8 {
    return switch (value) {
        inline else => |v| comptime ordinalByName(table, @tagName(v)) orelse
            @compileError("tag '" ++ @tagName(v) ++ "' has no pinned ordinal in ledger"),
    };
}

// Canonical semantic-key comparators (D-JOIN-SELECT item 1; D-PORT
// clause 4). Purely semantic: node keys are raw_id BYTES and enum
// components are pinned ordinals, so numeric NodeId/EdgeId are
// unrepresentable in any key by construction.
// @guarded-by: ledger_test.zig "comparator keys carry no numeric ids by construction"

/// Canonical NODE key order: source-declared identifier bytes, bytewise.
pub fn nodeKeyOrder(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// Label component order: no-label sorts FIRST, then label bytes.
pub fn labelOrder(a: ?[]const u8, b: ?[]const u8) std.math.Order {
    const av = a orelse return if (b == null) .eq else .lt;
    const bv = b orelse return .gt;
    return std.mem.order(u8, av, bv);
}

/// Canonical EDGE key (D-JOIN-SELECT item 1b), compared field-by-field in
/// exactly this declaration order.
/// @guarded-by: ledger_test.zig "edge key comparator orders field-by-field with no-label-first"
pub const EdgeKey = struct {
    /// `from` node key: raw_id bytes.
    from: []const u8,
    /// `to` node key: raw_id bytes.
    to: []const u8,
    /// EdgeKind ordinal via `edge_kind_ordinals`.
    kind: u8,
    /// ArrowEnd ordinals via `arrow_end_ordinals`.
    arrow_from: u8,
    arrow_to: u8,
    /// Label bytes, or null for an unlabeled edge (sorts first).
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

/// Canonical attachment key K for one (node, side) attachment (D-PORT
/// clause 4), compared lexicographically field by field in exactly this
/// declaration order.
/// @guarded-by: ledger_test.zig "attachment key K orders field-by-field with pinned ordinals"
pub const AttachmentKey = struct {
    /// Opposite endpoint's node key: raw_id bytes.
    opposite: []const u8,
    endpoint_side: EndpointSide,
    /// EdgeKind ordinal via `edge_kind_ordinals`.
    kind: u8,
    /// ArrowEnd ordinals via `arrow_end_ordinals`.
    arrow_from: u8,
    arrow_to: u8,
    /// Edge label bytes, or null (sorts first).
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

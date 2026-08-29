//! Base-tier pure-data vocabulary for the semantic bundle permits and the
//! candidate-local realized-bundle artifact (D-IR item 1): the
//! BundlePolicy storage, the BundlePermits / RealizedBundles logical records,
//! the bundle membership sets riding the Sketch beside that plan,
//! terminal-port identities, the component-table result types
//! shared by both reachability validators, the canonical semantic-key
//! comparators with the pinned D-PORT clause-4 ordinal tables, and the
//! D-DISPOSITION diagnostic registry (in the sibling diagnostics.zig,
//! re-exported below).
//!
//! Pure data + pure functions only; imports only std. Universally
//! importable (every zone may reach it), mirroring base/lanes.zig —
//! enforced by tools/lint_imports.zig (base/ dir rule).
//! Tests live in ledger_test.zig, aggregated from entry.zig's test
//! block so this file keeps D-IR item 1's literal empty allowlist.

const std = @import("std");

// Identity handles. Structurally identical to base/types.zig's u32 handles.
// guarded-by: ledger_test.zig "identity handles match prim's"

pub const NodeId = u32;
pub const EdgeId = u32;
pub const CandidateBundleId = u32;
pub const BundleProposalId = u32;
pub const SelectedBundleId = u32;
pub const ComponentId = u32;

// Branch policy (D-POLICY item 1).

/// Exactly ONE constructible variant: the type system, not a runtime guard,
/// makes non-joined policy unrepresentable. Only entry.zig (the composition
/// root) may originate the value (D-POLICY item 3).
/// guarded-by: ledger_test.zig "V-D-POLICY-01: BundlePolicy has exactly one variant, named joined"
pub const BundlePolicy = enum { joined };

// Logical records (plan/permission side).

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

// Logical records (candidate-local realization side).

/// `licence_refused`: the group failed the geometry-free licence check —
/// distinct from `not_selected`, where a licensed bundle simply realized no
/// shared rail (e.g. bridge-scope groups, whose realization is deferred).
pub const IndependentReason = enum { not_selected, overlap_conflict, unsafe_component, licence_refused };

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

pub const BundleConflictReason = enum {
    overlapping_permissions,
    dual_edge_selected_at_both_ends,
    unsafe_connected_component,
};

/// A permission-overlap conflict between two groups. `shared_edges` MUST
/// retain EVERY shared EdgeId (D-DUAL clause 2: first-overlap-only is
/// insufficient).
pub const BundleConflict = struct {
    groups: [2]CandidateBundleId,
    shared_edges: []const EdgeId,
    proposals: []const BundleProposalId = &.{},
    reason: BundleConflictReason,
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

/// Owner-directed arrival re-merge preference (2026-07-18): a fan-IN
/// group whose arrival is a LEGAL PURE fan-in MAY be selected as one merged
/// entry even when it overlaps a fan-out group at a shared dual edge (the
/// carve-out's NEITHER output — the recorded conflict — stays retained; only
/// this group's verdict flips). Eligible iff: direction == .in. No fan-out-pivot
/// exclusion — OPEN-1 class-1 (D-PORT 2026-07-17 four-way) sets purity by the
/// ARRIVAL SHAPE alone (A,B,C → D); the mixing prohibition targets ink FUSION,
/// prevented STRUCTURALLY not here — arrival rail enters the target's entry
/// side, departures exit other sides, D-JOIN clause 4 keeps junctions group-
/// internal. Carve-out never checked fan-out pivots, so legality can't hinge on it.
pub fn fanInReMergeEligible(groups: []const CandidateBundle, index: usize) bool {
    return groups[index].direction == .in;
}

/// The candidate-local artifact riding `Sketch.bundles` (D-IR item 4). All
/// fields defaulted so `.{}` is the valid empty plan.
/// guarded-by: ledger_test.zig "empty RealizedBundles is default-constructible with all-empty fields"
pub const RealizedBundles = struct {
    selected_bundles: []const SelectedBundle = &.{},
    rejected_proposals: []const BundleProposalId = &.{},
    memberships: []const RealizedEdgeMembership = &.{},
    conflicts: []const BundleConflict = &.{},
    terminal_ports: []const TerminalPort = &.{},
    /// Declared edges whose ENTIRE rendering is another element's shared ink:
    /// the leaf-pair edges an all-arrow-free rail discharges by running its
    /// crossbar between their two taps (the rail-closure law). A discharged
    /// edge owns no polyline, no port and no label of its own, so it must be
    /// withheld from independent routing — and it is NOT missing, because the
    /// crossbar between the taps IS its rendering.
    /// guarded-by: rail_closure_test.zig "a fully declared clique keeps the rail and discharges every pair edge"
    discharged: []const EdgeId = &.{},
    /// Two-sided fusion licences: each entry is the member-edge UNION of a set
    /// of selected same-direction rails whose declared pairs are EXACTLY
    /// srcs x tgts with every member blocking the leaf-to-leaf trace (the
    /// closure test of base/rail_closure.zig, asked of the whole union). Such
    /// rails may share one rail row and their ink is ONE bundle; anything
    /// short of complete never appears here.
    /// guarded-by: bundle_commit_test.zig "a complete bipartite of selected arrivals licenses one fused union"
    fused: []const []const EdgeId = &.{},
};

// -- Rail-closure report-only inventory --------------------------------------

const rail_closure = @import("rail_closure.zig");

/// How many discharged edges also own private geometry (`co_double_discharge`);
/// the predicate itself lives in the sibling rail_closure.zig.
pub const doubleDischarged = rail_closure.doubleDischarged;

// The semantic RailClaim vocabulary is kept in a cap-safe base sibling and
// re-exported here with the other universally importable ledger records.
const rail_star = @import("rail_star.zig");

pub const RailClaimId = rail_star.RailClaimId;
pub const no_rail_claim = rail_star.no_rail_claim;
pub const RailPolarity = rail_star.RailPolarity;
pub const Endpoint = rail_star.Endpoint;
pub const AttachmentSite = rail_star.AttachmentSite;
pub const RailClaimMember = rail_star.RailClaimMember;
pub const RailClaim = rail_star.RailClaim;
pub const RailClaimCheck = rail_star.CheckResult;
pub const checkRailClaim = rail_star.check;
pub const RailLicenceMember = rail_star.RailLicenceMember;
pub const RailLicence = rail_star.RailLicence;
pub const RailLicenceCheck = rail_star.LicenceCheckResult;
pub const checkRailLicence = rail_star.checkLicence;

/// The all-arrow-free shared-rail closure law's REPORT-ONLY inventory
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
    /// Rails the law refused as proposed — outright, or by salvaging a strict
    /// subset. One per refused rail.
    rail_closure_undeclared: u32 = 0,
    /// Leaf pairs of a proposed rail with no usable backing declaration:
    /// undeclared, decorated, labeled, or of the wrong stroke class.
    co_undeclared: u32 = 0,
    /// Discharged edges that ALSO kept private geometry — the withholding
    /// leaked and one relation is stated twice. Must stay zero.
    co_double_discharge: u32 = 0,
};

// -- Bundle membership ---------------------------------------------------
// The set vocabulary itself lives in the sibling bundle.zig (split out
// at the 500-line cap); re-exported so every `pb.Bundle` / `pb.bundleMembers`
// call site is unchanged and type-identical.

const bundle = @import("bundle.zig");

pub const BundleOrigin = bundle.BundleOrigin;
pub const Bundle = bundle.Bundle;
pub const BundleCell = bundle.BundleCell;
pub const PairCells = bundle.PairCells;
pub const keepOrigin = bundle.keepOrigin;
pub const concatBundles = bundle.concatBundles;
pub const bundleMembers = bundle.bundleMembers;
pub const bundleMembersAt = bundle.bundleMembersAt;
pub const BundleId = bundle.BundleId;
pub const no_bundle = bundle.no_bundle;
pub const privateBundle = bundle.privateBundle;
pub const numberBundles = bundle.numberBundles;
pub const rosterNumbered = bundle.rosterNumbered;
pub const StructuralBundleResolution = bundle.StructuralBundleResolution;
pub const resolveStructuralBundle = bundle.resolveStructuralBundle;
pub const bundleOf = bundle.bundleOf;
pub const bundlesAgree = bundle.bundlesAgree;

/// The pre-identity DERIVATION of the bundle relation: a pairwise
/// membership scan over the roster AND the realized plan, asked at a position.
/// Two edges are on one bundle iff the same owner, or some set names both
/// here, or some selected bundle holds both.
///
/// This is the shape the raster used to ESTABLISH every licence with, before a
/// bundle had a name. It is kept — one copy, here, where both the raster and
/// the report-only audit can reach it — as the WITNESS the recorded identity
/// is measured against: `tiling/bundles.zig` runs it beside
/// `bundlesAgree` on every carrier a render files and counts the two
/// answers agreeing and disagreeing. Nothing that only LABELS a record calls
/// it any more.
/// guarded-by: ledger_test.zig "the derivation and the recorded identity answer alike on a declared bundle"
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
/// Membership-equivalent to interrogating the plan directly: `bundleMembers` over
/// the result answers what a `selected_bundles` scan answers.
/// guarded-by: select_test.zig "bundles applied with the plan carry the plan's own membership"
pub fn bundlesFromPlan(
    allocator: std.mem.Allocator,
    bundles: RealizedBundles,
) error{OutOfMemory}![]const Bundle {
    if (bundles.selected_bundles.len == 0) return &.{};
    var out: std.ArrayListUnmanaged(Bundle) = .empty;
    // A fused union replaces its rails' per-bundle sets: the rail is ONE
    // bundle, and a member named by two structural sets is no bundle at all
    // (`resolveStructuralBundle` reads that as .multiple).
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

// Component-table result types: the one shared output shape
// emitted by BOTH reachability validators (D-IR items 1, 9, 10).

pub const NodePair = struct {
    source: NodeId,
    target: NodeId,
};

pub const ComponentEntry = struct {
    id: ComponentId = 0,
    source_terminals: []const TerminalPort = &.{},
    target_terminals: []const TerminalPort = &.{},
    declared_pairs_in_component: []const NodePair = &.{},
    reachable_pairs: []const NodePair = &.{},
    missing_declared_pairs: []const NodePair = &.{},
    extra_undeclared_pairs: []const NodePair = &.{},
    selected_bundle_ids: []const SelectedBundleId = &.{},
    /// Structurally empty in the no-bridge P1a slice; carried so the shared
    /// table shape is complete.
    bridge_ids: []const u32 = &.{},
};

pub const ComponentTable = []const ComponentEntry;

// Pinned ordinal tables (D-PORT clause 4, recorded verbatim). These tables
// are the AUTHORITY for the enum components of canonical keys: values map
// through them by tag NAME, so a future enum reorder cannot change K.

pub const OrdinalEntry = struct { name: []const u8, ordinal: u8 };

/// guarded-by: ledger_test.zig "D-PORT clause 4: every EdgeKind name→ordinal pair is pinned"
pub const edge_kind_ordinals = [_]OrdinalEntry{
    .{ .name = "solid", .ordinal = 0 },
    .{ .name = "dotted", .ordinal = 1 },
    .{ .name = "thick", .ordinal = 2 },
    .{ .name = "invisible", .ordinal = 3 },
};

/// Both arrow fields (`arrow_from` and `arrow_to`) share this table.
/// guarded-by: ledger_test.zig "D-PORT clause 4: every ArrowEnd name→ordinal pair is pinned"
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
// guarded-by: ledger_test.zig "comparator keys carry no numeric ids by construction"

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
/// guarded-by: ledger_test.zig "edge key comparator orders field-by-field with no-label-first"
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
/// guarded-by: ledger_test.zig "attachment key K orders field-by-field with pinned ordinals"
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

// The static diagnostic registry lives in the sibling diagnostics.zig
// (split out at the 500-line cap). Re-exported so every existing `pb.*`
// call site (realized.zig, invariants.zig, the test tree) is unchanged.
const diagnostics = @import("diagnostics.zig");

pub const DispositionClass = diagnostics.DispositionClass;
pub const DiagnosticTag = diagnostics.DiagnosticTag;
pub const tagName = diagnostics.tagName;
pub const tagByName = diagnostics.tagByName;
pub const classOf = diagnostics.classOf;

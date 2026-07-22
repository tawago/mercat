//! Base-tier pure-data vocabulary for the semantic join permits and the
//! candidate-local realized-join artifact (TSD §6.1; D-IR item 1): the
//! JoinPolicy storage, the JoinPermits / RealizedJoins logical records,
//! terminal-port identities, the SDD §12.4 component-table result types
//! shared by both reachability validators, the canonical semantic-key
//! comparators with the pinned D-PORT clause-4 ordinal tables, and the
//! static 43-tag D-DISPOSITION diagnostic registry.
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
pub const JoinGroupId = u32;
pub const JoinProposalId = u32;
pub const RealizedJoinId = u32;
pub const MeshUnionId = u32;
pub const ComponentId = u32;

// Branch policy (TSD §5.1; D-POLICY item 1).

/// Exactly ONE constructible variant: the type system, not a runtime guard,
/// makes non-joined policy unrepresentable. Only entry.zig (the composition
/// root) may originate the value (D-POLICY item 3).
/// guarded-by: ledger_test.zig "V-D-POLICY-01: JoinPolicy has exactly one variant, named joined"
pub const JoinPolicy = enum { joined };

// TSD §6.1 logical records (plan/permission side).

pub const JoinDirection = enum { out, in };

/// One semantic endpoint incidence group: a fan-out (direction=.out, pivot
/// is the shared source) or fan-in (.in, pivot is the shared target) with
/// at least two member edges. Members are arena `[]const EdgeId` slices
/// (D-IR item 7 container rule).
pub const JoinGroup = struct {
    id: JoinGroupId,
    direction: JoinDirection,
    pivot: NodeId,
    members: []const EdgeId,
};

pub const JoinMembership = struct {
    edge: EdgeId,
    source_group: ?JoinGroupId,
    target_group: ?JoinGroupId,
};

/// The ONE shared semantic plan per render (TSD §7.7). `groups` states
/// where joining is semantically PERMITTED — it must never be read as an
/// instruction that a permitted group has a trunk; only
/// `RealizedJoins.selected_joins` authorizes shared group geometry.
pub const JoinPermits = struct {
    policy: JoinPolicy,
    groups: []const JoinGroup = &.{},
    memberships: []const JoinMembership = &.{},
};

// TSD §6.1 logical records (candidate-local realization side).

pub const IndependentReason = enum { not_selected, overlap_conflict, unsafe_component };

pub const MembershipDisposition = union(enum) {
    selected: RealizedJoinId,
    independent: struct {
        permission_group: JoinGroupId,
        reason: IndependentReason,
    },
};

/// Attribution reference into the candidate's OWN Sketch (D-IR item 6):
/// an index, never a coordinate; geometry derives from the owning Sketch
/// at consumption time.
pub const CandidateGeometryRef = union(enum) {
    /// Index into the candidate Sketch's `busbars`.
    busbar: u32,
    /// Index into the candidate Sketch's `edges`.
    edge_path: u32,
};

pub const JoinProposal = struct {
    id: JoinProposalId,
    permission_group: JoinGroupId,
    members: []const EdgeId,
    candidate_geometry: CandidateGeometryRef,
};

pub const SelectedJoin = struct {
    id: RealizedJoinId,
    proposal: JoinProposalId,
    permission_group: JoinGroupId,
    members: []const EdgeId,
};

pub const RealizedEdgeMembership = struct {
    edge: EdgeId,
    source: ?MembershipDisposition,
    target: ?MembershipDisposition,
};

pub const JoinConflictReason = enum {
    overlapping_permissions,
    dual_edge_selected_at_both_ends,
    unsafe_connected_component,
};

/// A permission-overlap conflict between two groups. `shared_edges` MUST
/// retain EVERY shared EdgeId (D-DUAL clause 2: first-overlap-only is
/// insufficient).
pub const JoinConflict = struct {
    groups: [2]JoinGroupId,
    shared_edges: []const EdgeId,
    proposals: []const JoinProposalId = &.{},
    reason: JoinConflictReason,
};

/// D-PORT clause 4: which end of the edge an attachment/terminal belongs
/// to. The numeric values participate in canonical key K
/// (source-exit=0, target-entry=1).
pub const EndpointSide = enum(u1) { source_exit = 0, target_entry = 1 };

/// Typed port terminal (TSD §12.4; D-IR item 6): identities and indices
/// only — `port` is a perimeter port ORDINAL, never a coordinate.
pub const TerminalPort = struct {
    node: NodeId,
    edge: EdgeId,
    endpoint_side: EndpointSide,
    port: u32,
};

/// One exempt complete-mesh union's recorded provenance (D-IR item 16):
/// union identity, its COMPLETE member-edge set, and both endpoint sets as
/// canonical node keys (raw_id bytes). This element IS the exemption's
/// required provenance — a fused run with no element is validated as
/// ordinary cross-owner sharing, never inferred from geometry.
pub const MeshUnion = struct {
    id: MeshUnionId,
    members: []const EdgeId,
    source_keys: []const []const u8,
    target_keys: []const []const u8,
};

/// Owner-directed arrival re-merge preference (D-PORT.md, 2026-07-18): a fan-IN
/// group whose arrival is a LEGAL PURE fan-in MAY be selected as one merged
/// entry even when it overlaps a fan-out group at a shared dual edge (the
/// carve-out's NEITHER output — the recorded conflict — stays retained; only
/// this group's verdict flips). Eligible iff: direction == .in; no member in
/// any mesh union (LOAD-BEARING — K3,3 stays a fused rail). No fan-out-pivot
/// exclusion — OPEN-1 class-1 (D-PORT 2026-07-17 four-way) sets purity by the
/// ARRIVAL SHAPE alone (A,B,C → D); the mixing prohibition targets ink FUSION,
/// prevented STRUCTURALLY not here — arrival trunk enters the target's entry
/// side, departures exit other sides, D-JOIN clause 4 keeps junctions group-
/// internal. Carve-out never checked fan-out pivots, so legality can't hinge on it.
pub fn fanInReMergeEligible(groups: []const JoinGroup, index: usize, mesh_unions: []const MeshUnion) bool {
    const g = groups[index];
    if (g.direction != .in) return false;
    for (g.members) |m| for (mesh_unions) |u| for (u.members) |um| if (um == m) return false;
    return true;
}

/// The candidate-local artifact riding `Sketch.joins` (D-IR item 4). All
/// fields defaulted so `.{}` is the valid empty plan.
/// guarded-by: ledger_test.zig "empty RealizedJoins is default-constructible with all-empty fields"
pub const RealizedJoins = struct {
    selected_joins: []const SelectedJoin = &.{},
    rejected_proposals: []const JoinProposalId = &.{},
    memberships: []const RealizedEdgeMembership = &.{},
    conflicts: []const JoinConflict = &.{},
    terminal_ports: []const TerminalPort = &.{},
    mesh_unions: []const MeshUnion = &.{},
};

// SDD §12.4 component-table result types — the one shared output shape
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
    selected_join_ids: []const RealizedJoinId = &.{},
    /// Structurally empty in the no-bridge P1a slice; carried so the SDD
    /// §12.4 table shape is complete.
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

// Static diagnostic registry (D-DISPOSITION items 1, 3, 5, 6).

/// TSD §12.5's four disposition classes, verbatim and exhaustive. The
/// `score_input` class is approved EMPTY of new members in this slice: no
/// registered tag maps to it.
pub const DispositionClass = enum {
    report_only,
    candidate_invalid,
    render_fatal,
    score_input,
};

/// The closed 43-tag registry, declared in D-DISPOSITION item 3's own
/// enumeration order (owning record noted per block). Tags whose
/// record-verbatim names carry dots (`join_select.*`) spell them with
/// underscores here; `tagName` returns the verbatim form.
pub const DiagnosticTag = enum {
    // D-DISPOSITION (3)
    disp_terminal_fallback_engaged,
    disp_unregistered_diagnostic,
    ink_grammar_render_fatal,
    // D-POLICY (1)
    join_policy_not_joined,
    // D-TRUNK (4)
    trunk_member_style_mixed,
    trunk_member_invisible,
    trunk_pivot_side_arrow,
    trunk_duplicate_pair,
    // D-DUAL (3)
    dual_membership_edges,
    dual_membership_selected_both_sides,
    permission_overlap_conflicts,
    // D-JOIN-SELECT (9)
    join_select_selected,
    join_select_independent_not_selected,
    join_select_independent_overlap_conflict,
    join_select_independent_unsafe_component,
    join_select_conflict_neither,
    join_select_invalidated,
    join_select_cluster_skipped,
    join_select_duplicate_key_blocked,
    join_select_proposal_multiplicity_blocked,
    // D-JOIN (1)
    intentional_joins,
    // D-PORT (5)
    port_capacity_exceeded,
    port_key_collision,
    port_coalesced,
    port_departure_conflict,
    port_skipped_clustered,
    // D-REACH (12)
    reach_undeclared_pair,
    reach_missing_declared,
    reach_split_trace,
    reach_duplicate_trace,
    reach_join_split,
    reach_independent_joined,
    reach_cross_connected,
    reach_one_sided_adjacency,
    reach_mixed_stroke_junction,
    reach_unknown_continuation,
    reach_vector_raster_mismatch,
    reach_skipped_clustered,
    // D-IR (3)
    join_permits_skipped_clustered,
    realized_plan_missing,
    selected_join_invalidated,
    // D-EDGE-ID (2)
    edgeid_scope_clustered_skipped,
    edgeid_unqualified_local_lookup,
};

/// Record-verbatim tag string (dotted for the `join_select.*` family).
/// guarded-by: ledger_test.zig "tag names round-trip through tagByName"
pub fn tagName(tag: DiagnosticTag) []const u8 {
    return switch (tag) {
        .join_select_selected => "join_select.selected",
        .join_select_independent_not_selected => "join_select.independent.not_selected",
        .join_select_independent_overlap_conflict => "join_select.independent.overlap_conflict",
        .join_select_independent_unsafe_component => "join_select.independent.unsafe_component",
        .join_select_conflict_neither => "join_select.conflict_neither",
        .join_select_invalidated => "join_select.invalidated",
        .join_select_cluster_skipped => "join_select.cluster_skipped",
        .join_select_duplicate_key_blocked => "join_select.duplicate_key_blocked",
        .join_select_proposal_multiplicity_blocked => "join_select.proposal_multiplicity_blocked",
        inline else => |t| @tagName(t),
    };
}

/// Registry lookup by record-verbatim name. Null means UNREGISTERED — the
/// disposition for firing such a tag is `disp_unregistered_diagnostic`
/// (render-fatal backstop, D-DISPOSITION item 4).
pub fn tagByName(name: []const u8) ?DiagnosticTag {
    inline for (@typeInfo(DiagnosticTag).@"enum".fields) |f| {
        const tag: DiagnosticTag = @enumFromInt(f.value);
        if (std.mem.eql(u8, tagName(tag), name)) return tag;
    }
    return null;
}

/// The static tag → class registry: every tag by explicit name, no
/// wildcard, no prefix, no else branch (D-DISPOSITION items 3, 5, 6).
/// guarded-by: ledger_test.zig "registry partitions the 43 tags RF 5 / CI 17 / RO 21"
/// guarded-by: ledger_test.zig "both invalidation tags are candidate-invalid (D-DISPOSITION item 5 row 4)"
pub fn classOf(tag: DiagnosticTag) DispositionClass {
    return switch (tag) {
        // RF (5): D-DISPOSITION item 4 + item 9(e) backstops; item 5 row 1;
        // item 6 rows for the two semantic/defensive fatals.
        .disp_unregistered_diagnostic,
        .ink_grammar_render_fatal,
        .join_policy_not_joined,
        .port_key_collision,
        .edgeid_unqualified_local_lookup,
        => .render_fatal,

        // CI (17): the 11 substantive reach_* oracle failures (item 6
        // row 4), the per-candidate port breaches (item 6 rows 5-6),
        // realized_plan_missing (item 6 row 7), and BOTH invalidated-
        // selected-join tags (item 5 row 4 names the pair).
        .reach_undeclared_pair,
        .reach_missing_declared,
        .reach_split_trace,
        .reach_duplicate_trace,
        .reach_join_split,
        .reach_independent_joined,
        .reach_cross_connected,
        .reach_one_sided_adjacency,
        .reach_mixed_stroke_junction,
        .reach_unknown_continuation,
        .reach_vector_raster_mismatch,
        .port_coalesced,
        .port_departure_conflict,
        .port_capacity_exceeded,
        .realized_plan_missing,
        .selected_join_invalidated,
        .join_select_invalidated,
        => .candidate_invalid,

        // RO (21): normal-operation inventory/style/safety-filter outcomes
        // (item 6 rows 1-2), the five clustered scope-gate skips (item 6
        // row 3), the terminal-fallback count (item 9(e)), and the
        // count-surfaced intentional_joins.
        .disp_terminal_fallback_engaged,
        .trunk_member_style_mixed,
        .trunk_member_invisible,
        .trunk_pivot_side_arrow,
        .trunk_duplicate_pair,
        .dual_membership_edges,
        .dual_membership_selected_both_sides,
        .permission_overlap_conflicts,
        .join_select_selected,
        .join_select_independent_not_selected,
        .join_select_independent_overlap_conflict,
        .join_select_independent_unsafe_component,
        .join_select_conflict_neither,
        .join_select_cluster_skipped,
        .join_select_duplicate_key_blocked,
        .join_select_proposal_multiplicity_blocked,
        .intentional_joins,
        .reach_skipped_clustered,
        .join_permits_skipped_clustered,
        .port_skipped_clustered,
        .edgeid_scope_clustered_skipped,
        => .report_only,
    };
}

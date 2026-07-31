//! Base-tier pure-data vocabulary for the semantic join permits and the
//! candidate-local realized-join artifact (TSD §6.1; D-IR item 1): the
//! JoinPolicy storage, the JoinPermits / RealizedJoins logical records,
//! the co-channel membership sets riding the Sketch beside that plan,
//! terminal-port identities, the SDD §12.4 component-table result types
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

// -- Co-channel membership ---------------------------------------------------

/// Where a co-channel set came from. Provenance only: every reader treats
/// the origins alike, and the tag exists so a set can be attributed in a
/// report and so a later law can scope itself to one origin.
pub const CoOrigin = enum {
    /// One realized selected join (`RealizedJoins.selected_joins`).
    selected_join,
    /// One exempt complete-mesh union (`RealizedJoins.mesh_unions`).
    mesh_union,
    /// One fan's peers sharing a rail lane (layout/fan.zig). The only
    /// population a clustered or recursed render can have: those renders
    /// carry an empty realized plan (V-D-IR-07).
    fan_rail,
    /// Edges a producer deliberately routed through ONE perimeter port, so
    /// their approach ink is one run (`sketch_ports.portShareCoSets`). Derived
    /// from the sketch's own declared polylines — the producers' agreement on
    /// a coordinate IS the declaration — and always APPENDED to the sets the
    /// other origins contributed, never substituted for them.
    port_share,
};

/// A CO-CHANNEL set: edges that legally share ink because ONE structural
/// decision put them on the same channel.
///
/// Membership is an EXPLICIT edge-id list, never a numeric channel id. Ids
/// are read in the id space of the Sketch that holds the set: a set built
/// inside a recursion child is rewritten by `cluster/stitch.zig` into the
/// merged Sketch's single, globally unique edge-id space, because carrying it
/// verbatim would fuse two children the moment both numbered a channel alike.
pub const CoSet = struct {
    origin: CoOrigin,
    members: []const EdgeId,
    /// The cells this set licenses, or `null` for "licenses everywhere".
    ///
    /// A structural decision (a realized join, a mesh union, a fan rail) makes
    /// its members ONE channel wherever they meet, so it leaves this null. A
    /// `.port_share` set is narrower: two edges routed through one perimeter
    /// port share the ink of their COMMON APPROACH and nothing else. Anywhere
    /// else the two are strangers and a meeting is still a transversal.
    /// guarded-by: sketch_ports_test.zig "a port share licenses only its shared approach"
    cells: ?[]const CoCell = null,
};

/// A lattice cell coordinate, in the Sketch's own integer space (raster's
/// `toCoord` is the identity on in-bounds points). Declared here rather than
/// borrowed from `sketch.zig` because `base/` may not import upward.
pub const CoCell = struct {
    x: i32,
    y: i32,
};

/// The co-channel sets a realized plan authorizes: one per selected join and
/// one per exempt mesh union, members BORROWED from the plan (same arena, no
/// copy). This is the flat population; the caller applies it exactly where it
/// applies the plan, because nowhere earlier is the plan final.
///
/// Membership-equivalent to interrogating the plan directly: `coMembers` over
/// the result answers what a `selected_joins` + `mesh_unions` scan answers.
/// guarded-by: select_test.zig "co-sets applied with the plan carry the plan's own membership"
pub fn coSetsFromPlan(
    allocator: std.mem.Allocator,
    joins: RealizedJoins,
) error{OutOfMemory}![]const CoSet {
    const n = joins.selected_joins.len + joins.mesh_unions.len;
    if (n == 0) return &.{};
    const out = try allocator.alloc(CoSet, n);
    var i: usize = 0;
    for (joins.selected_joins) |j| {
        out[i] = .{ .origin = .selected_join, .members = j.members };
        i += 1;
    }
    for (joins.mesh_unions) |m| {
        out[i] = .{ .origin = .mesh_union, .members = m.members };
        i += 1;
    }
    return out;
}

/// The sets whose origin is `origin`, in order — for a producer that REPLACES
/// one origin's population and must not take the others down with it.
/// guarded-by: ledger_test.zig "keepOrigin selects exactly one origin's sets"
pub fn keepOrigin(
    allocator: std.mem.Allocator,
    sets: []const CoSet,
    origin: CoOrigin,
) error{OutOfMemory}![]const CoSet {
    var n: usize = 0;
    for (sets) |s| {
        if (s.origin == origin) n += 1;
    }
    if (n == 0) return &.{};
    const out = try allocator.alloc(CoSet, n);
    var i: usize = 0;
    for (sets) |s| {
        if (s.origin != origin) continue;
        out[i] = s;
        i += 1;
    }
    return out;
}

/// `head ++ tail`, members BORROWED. Order is provenance only (every set is
/// scanned), but `head` first reads in the order the origins were established.
/// guarded-by: ledger_test.zig "keepOrigin selects exactly one origin's sets"
pub fn concatSets(
    allocator: std.mem.Allocator,
    head: []const CoSet,
    tail: []const CoSet,
) error{OutOfMemory}![]const CoSet {
    if (tail.len == 0) return head;
    if (head.len == 0) return tail;
    const out = try allocator.alloc(CoSet, head.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], tail);
    return out;
}

/// True iff both edges appear in one co-set. Asked about DISTINCT ids: an
/// edge and itself is a question about ownership, which the caller answers
/// before it gets here.
/// guarded-by: ledger_test.zig "co-membership needs both edges inside one set"
pub fn coMembers(sets: []const CoSet, first: EdgeId, second: EdgeId) bool {
    return coMembersAt(sets, first, second, null);
}

/// `coMembers`, asked ABOUT A CELL: a set whose `cells` list is non-null
/// answers only for the cells it licenses. `at = null` asks the membership
/// question with NO position — "are these two ever co-members?", the right
/// question for a report or a test — and no set's scope applies.
/// guarded-by: ledger_test.zig "a cell-scoped co-set answers only inside its licensed cells"
pub fn coMembersAt(sets: []const CoSet, first: EdgeId, second: EdgeId, at: ?CoCell) bool {
    for (sets) |set| {
        if (set.cells) |cells| if (at) |here| {
            var licensed = false;
            for (cells) |c| {
                if (c.x == here.x and c.y == here.y) {
                    licensed = true;
                    break;
                }
            }
            if (!licensed) continue;
        };
        var saw_first = false;
        var saw_second = false;
        for (set.members) |m| {
            if (m == first) saw_first = true;
            if (m == second) saw_second = true;
        }
        if (saw_first and saw_second) return true;
    }
    return false;
}

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

// The static diagnostic registry lives in the sibling diagnostics.zig
// (split out at the 500-line cap). Re-exported so every existing `pb.*`
// call site (realized.zig, invariants.zig, the test tree) is unchanged.
const diagnostics = @import("diagnostics.zig");

pub const DispositionClass = diagnostics.DispositionClass;
pub const DiagnosticTag = diagnostics.DiagnosticTag;
pub const tagName = diagnostics.tagName;
pub const tagByName = diagnostics.tagByName;
pub const classOf = diagnostics.classOf;

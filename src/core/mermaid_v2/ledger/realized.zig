//! Candidate-local realized-join planner and layout-commitment verifier.
const std = @import("std");
const pb = @import("../base/ledger.zig");
const sk = @import("../sketch.zig");
pub const Error = error{OutOfMemory};
/// Which step of the frozen selection order decided a group; the first
/// failing step names the tag (D-JOIN-SELECT item 3). Report-only.
pub const GroupClause = enum {
    selected, // (a)–(f) all pass → realized trunk
    duplicate_key, // item 1 canonicalization block (pre-clause)
    unresolved_member, // defensive: a member with no realized geometry
    incomplete, // (c) the single proposal covers a strict member subset
    overlap, // (d) permission overlap → NEITHER (conservative rule)
    style, // (e) D-TRUNK sub-clause failed (see trunk_detail)
    no_proposal, // (f) zero trunk proposals
    multiplicity, // (f) two or more trunk proposals (item 3)
};

pub const GroupVerdict = struct {
    group: pb.JoinGroupId,
    clause: GroupClause,
    /// First-fail naming tag (join_select.* family, pinned registry).
    tag: pb.DiagnosticTag,
    /// D-TRUNK first-failing sub-clause tag when clause == .style
    /// ((a) invisible → (b) kind mixed → (c) pivot-side arrow mixed).
    trunk_detail: ?pb.DiagnosticTag = null,
    /// Report-only D-TRUNK duplicate-(from,to) inventory; fires regardless
    /// of the first-fail clause (V-D-TRUNK-06 pairs it with duplicate_key).
    duplicate_pair: bool = false,
    /// Raw trunk-proposal count, identical-key duplicates included —
    /// item 3 reads this count and no other proposal property.
    proposal_count: u32 = 0,
};

/// Report-only planner outputs that do not ride the RealizedJoins
/// envelope (TSD §12.1; D-JOIN-SELECT item 6: never score input).
pub const Report = struct {
    verdicts: []const GroupVerdict = &.{},
    /// Canonical proposal records; identical-key entries collapsed into
    /// one multiplicity-counted entry (item 1d). Parallel `multiplicity`.
    proposals: []const pb.JoinProposal = &.{},
    multiplicity: []const u32 = &.{},
    dual_membership_edges: u32 = 0,
    permission_overlap_conflicts: u32 = 0,
    /// Proposed mesh-union elements failing N*M==D legality (plan N5).
    mesh_unions_rejected: u32 = 0,
    /// Candidate off the flat identity path (D-JOIN-SELECT item 10):
    /// nothing was planned; the plan is the empty `.{}`.
    skipped_clustered: bool = false,
};

pub const Result = struct {
    plan: pb.RealizedJoins = .{},
    report: Report = .{},
};

/// One member's realized style/endpoints read from the candidate's OWN
/// geometry (EdgePath fields, or the owning BusBar for tap-represented
/// members) — no sem_graph datum (D-IR item 8).
const MemberGeom = struct {
    from: sk.NodeId = 0,
    to: sk.NodeId = 0,
    kind: sk.EdgeKind = .solid,
    arrow_from: sk.ArrowKind = .none,
    arrow_to: sk.ArrowKind = .none,
    label: ?[]const u8 = null,
    /// The member's candidate geometry is a layout-reversed back-edge, so it
    /// is NOT a trunk-eligible member (D-PORT.md forward-subset composition):
    /// trunk completeness/style judge the forward subset only.
    back_edge: bool = false,
    found: bool = false,
};

fn busBarDirection(bb: sk.BusBar) pb.JoinDirection {
    return switch (bb.role) {
        .fan_in_rail, .fan_in_trunk => .in,
        else => .out,
    };
}

fn memberGeom(s: sk.Sketch, edge: pb.EdgeId) MemberGeom {
    for (s.edges) |e| if (e.id == edge) return .{
        .from = e.from,
        .to = e.to,
        .kind = e.kind,
        .arrow_from = e.arrow_from,
        .arrow_to = e.arrow_to,
        .label = e.label,
        .back_edge = e.role == .back_edge,
        .found = true,
    };
    for (s.busbars) |bb| for (bb.taps) |tap| if (tap.edge == edge) {
        // A BusBar owns exactly ONE pivot attachment, so the pivot-side
        // decoration is single-valued by construction (D-TRUNK item 5);
        // Tap.arrow is the member-end decoration; pivot_arrow is group-owned.
        const out = busBarDirection(bb) == .out;
        return .{
            .from = if (out) bb.pivot else tap.node,
            .to = if (out) tap.node else bb.pivot,
            .kind = bb.kind,
            .arrow_from = if (out) .none else tap.arrow,
            .arrow_to = if (out) tap.arrow else bb.pivot_arrow,
            .label = tap.label,
            .found = true,
        };
    };
    return .{};
}

fn labelEql(a: ?[]const u8, b: ?[]const u8) bool {
    const av = a orelse return b == null;
    const bv = b orelse return false;
    return std.mem.eql(u8, av, bv);
}

pub fn containsEdge(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |e| if (e == edge) return true;
    return false;
}

pub fn edgeRank(ms: []const pb.JoinMembership, edge: pb.EdgeId) ?usize {
    for (ms, 0..) |m, i| if (m.edge == edge) return i;
    return null;
}

pub fn groupIndexById(groups: []const pb.JoinGroup, id: pb.JoinGroupId) ?usize {
    for (groups, 0..) |g, i| if (g.id == id) return i;
    return null;
}

// -- Planner -------------------------------------------------------------

const Pending = struct {
    group: usize,
    members: []pb.EdgeId,
    ranks: []usize,
    geometry: pb.CandidateGeometryRef,
    count: u32,
    id: pb.JoinProposalId = 0,
};

/// Plan one candidate. `mesh_candidates` is the D-IR item 16 pass-through
/// channel: the producer is layout (P2v Step 7; empty until then); the
/// planner re-checks legality only and lands legal elements.
pub fn realize(
    allocator: std.mem.Allocator,
    join_permits: pb.JoinPermits,
    s: sk.Sketch,
    mesh_candidates: []const pb.MeshUnion,
) Error!Result {
    // Candidate-local identity gate (D-JOIN-SELECT item 10): a sketch
    // carrying cluster frames went through split/stitch, whose edge ids
    // are piece-local (D-EDGE-ID §4) — attribution would be unsound. This
    // covers motif-packed candidates (synthetic frames) even on flat
    // inputs; select.zig additionally gates on the top-level flat flag.
    // guarded-by: realized_test.zig "V-D-IR-02: motif_pack candidate is off the identity path and keeps an empty plan"
    if (s.clusters.len != 0) return .{ .report = .{ .skipped_clustered = true } };

    const groups = join_permits.groups;
    const ms = join_permits.memberships;

    const geoms = try allocator.alloc([]MemberGeom, groups.len);
    for (groups, geoms) |g, *slot| {
        const row = try allocator.alloc(MemberGeom, g.members.len);
        for (g.members, row) |edge, *mg| mg.* = memberGeom(s, edge);
        slot.* = row;
    }

    // Proposal extraction: one JoinProposal per BusBar whose tap set lies
    // inside a JoinPermits group at the busbar's pivot/direction.
    const raw_count = try allocator.alloc(u32, groups.len);
    @memset(raw_count, 0);
    var pend: std.ArrayListUnmanaged(Pending) = .empty;
    for (s.joins.selected_joins) |join| {
        const gi = groupIndexById(groups, join.permission_group) orelse continue;
        raw_count[gi] += 1;
        const members = try allocator.dupe(pb.EdgeId, join.members);
        std.mem.sort(pb.EdgeId, members, ms, rankLess);
        const ranks = try allocator.alloc(usize, members.len);
        for (members, ranks) |m, *r| r.* = edgeRank(ms, m) orelse std.math.maxInt(usize);
        try pend.append(allocator, .{ .group = gi, .members = members, .ranks = ranks, .geometry = .{ .edge_path = 0 }, .count = 1 });
    }
    if (s.joins.selected_joins.len == 0) for (s.busbars, 0..) |bb, bi| {
        const gi = findGroup(groups, busBarDirection(bb), bb.pivot) orelse continue;
        var corresponds = bb.taps.len > 0;
        for (bb.taps) |tap| {
            if (!containsEdge(groups[gi].members, tap.edge)) corresponds = false;
        }
        if (!corresponds) continue;
        raw_count[gi] += 1;
        const members = try allocator.alloc(pb.EdgeId, bb.taps.len);
        for (bb.taps, members) |tap, *m| m.* = tap.edge;
        std.mem.sort(pb.EdgeId, members, ms, rankLess);
        // Identical-key collision (item 1d): collapse to one multiplicity-
        // counted entry; no property of competing proposals is read.
        const merged = blk: {
            for (pend.items) |*p| {
                if (p.group == gi and std.mem.eql(pb.EdgeId, p.members, members)) {
                    p.count += 1;
                    break :blk true;
                }
            }
            break :blk false;
        };
        if (merged) continue;
        const ranks = try allocator.alloc(usize, members.len);
        for (members, ranks) |m, *r| r.* = edgeRank(ms, m) orelse std.math.maxInt(usize);
        try pend.append(allocator, .{
            .group = gi,
            .members = members,
            .ranks = ranks,
            .geometry = .{ .busbar = @intCast(bi) },
            .count = 1,
        });
    };
    // Canonical proposal order: (owning group key = group rank, canonical
    // member-set key = membership-rank sequence); ids assigned after sort.
    std.mem.sort(Pending, pend.items, {}, pendingLess);
    const proposals = try allocator.alloc(pb.JoinProposal, pend.items.len);
    const multiplicity = try allocator.alloc(u32, pend.items.len);
    for (pend.items, proposals, multiplicity, 0..) |*p, *rec, *mult, i| {
        p.id = @intCast(i);
        rec.* = .{
            .id = p.id,
            .permission_group = groups[p.group].id,
            .members = p.members,
            .candidate_geometry = p.geometry,
        };
        mult.* = p.count;
    }

    // §6.5 overlap graph FIRST, retaining EVERY shared EdgeId; conflicts
    // ordered by the pair of group ranks, shared edges in the first
    // group's canonical member order.
    var conflicts: std.ArrayListUnmanaged(pb.JoinConflict) = .empty;
    for (groups, 0..) |ga, i| {
        for (groups[i + 1 ..]) |gb| {
            var shared: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
            for (ga.members) |e| if (containsEdge(gb.members, e)) try shared.append(allocator, e);
            if (shared.items.len == 0) continue;
            var pids: std.ArrayListUnmanaged(pb.JoinProposalId) = .empty;
            for (proposals) |p| {
                if (p.permission_group == ga.id or p.permission_group == gb.id)
                    try pids.append(allocator, p.id);
            }
            try conflicts.append(allocator, .{
                .groups = .{ ga.id, gb.id },
                .shared_edges = try shared.toOwnedSlice(allocator),
                .proposals = try pids.toOwnedSlice(allocator),
                .reason = .overlapping_permissions,
            });
        }
    }

    // Frozen first-fail order per group: item 1 duplicate-key block, then
    // clauses (c) → (d) → (e) → (f); (a)/(b) hold by construction (groups
    // come from the JoinPermits and are single-pivot). With ≥2 proposals
    // clause (c) is unreadable — item 3 forbids reading any property of
    // competing proposals — so it applies to the exactly-one case only.
    // guarded-by: realized_test.zig "V-D-JOIN-SELECT-07: partial proposal fails clause (c) first"
    const verdicts = try allocator.alloc(GroupVerdict, groups.len);
    const join_of_group = try allocator.alloc(?pb.RealizedJoinId, groups.len);
    @memset(join_of_group, null);
    var selected: std.ArrayListUnmanaged(pb.SelectedJoin) = .empty;
    for (groups, geoms, verdicts, 0..) |g, row, *v, gi| {
        const single: ?*const Pending = blk: {
            if (raw_count[gi] != 1) break :blk null;
            for (pend.items) |*p| if (p.group == gi) break :blk p;
            break :blk null;
        };
        var detail: ?pb.DiagnosticTag = null;
        const clause: GroupClause = blk: {
            if (hasDuplicate(row, true)) break :blk .duplicate_key;
            if (hasUnresolved(row)) break :blk .unresolved_member;
            // Completeness (clause c) is measured against the forward-eligible
            // (non-back-edge) members: a fan-IN trunk composes its forward
            // subset and the reversed member(s) stay independent, exactly as
            // join_commit commits it (keeps the N6 agreement pin exact).
            if (single != null and single.?.members.len < forwardCount(row)) break :blk .incomplete;
            if (groupHasConflict(conflicts.items, g.id) and !pb.fanInReMergeEligible(groups, gi, s.joins.mesh_unions)) break :blk .overlap; // arrival re-merge: eligible fan-in falls through (conflict still recorded)
            if (styleFail(g.direction, row)) |t| {
                detail = t;
                break :blk .style;
            }
            if (raw_count[gi] == 0) break :blk .no_proposal;
            if (raw_count[gi] >= 2) break :blk .multiplicity;
            break :blk .selected;
        };
        if (clause == .selected) {
            const jid: pb.RealizedJoinId = @intCast(selected.items.len);
            join_of_group[gi] = jid;
            try selected.append(allocator, .{
                .id = jid,
                .proposal = single.?.id,
                .permission_group = g.id,
                .members = single.?.members,
            });
        }
        v.* = .{
            .group = g.id,
            .clause = clause,
            .tag = tagFor(clause),
            .trunk_detail = detail,
            .duplicate_pair = hasDuplicate(row, false),
            .proposal_count = raw_count[gi],
        };
    }

    // Every proposal of a non-realized group is rejected (ids ascend with
    // the canonical proposal order, so this list is canonical).
    var rejected: std.ArrayListUnmanaged(pb.JoinProposalId) = .empty;
    for (pend.items) |p| {
        if (verdicts[p.group].clause != .selected) try rejected.append(allocator, p.id);
    }

    // Dispositions: exactly one per endpoint membership, in canonical
    // membership order (item 7's frozen mapping).
    var dual_edges: u32 = 0;
    const rms = try allocator.alloc(pb.RealizedEdgeMembership, ms.len);
    for (ms, rms) |m, *rm| {
        var mesh = false;
        for (s.joins.mesh_unions) |mu| {
            if (containsEdge(mu.members, m.edge)) mesh = true;
        }
        rm.* = .{
            .edge = m.edge,
            .source = if (mesh) null else dispose(groups, verdicts, join_of_group, selected.items, m.source_group, m.edge),
            .target = if (mesh) null else dispose(groups, verdicts, join_of_group, selected.items, m.target_group, m.edge),
        };
        if (m.source_group != null and m.target_group != null) dual_edges += 1;
    }

    // Terminal ports: identity tuples, source before target per edge in
    // canonical edge order. Ordinal 0 = today's midpoint semantics until
    // Step 7's allocator re-derives ordinals (OPEN-6).
    var ports: std.ArrayListUnmanaged(pb.TerminalPort) = .empty;
    for (ms) |m| {
        const geo = memberGeom(s, m.edge);
        if (!geo.found) continue;
        var source_port: u32 = 0;
        var target_port: u32 = 0;
        for (s.joins.terminal_ports) |p| if (p.edge == m.edge) {
            if (p.endpoint_side == .source_exit) source_port = p.port else target_port = p.port;
        };
        try ports.append(allocator, .{ .node = geo.from, .edge = m.edge, .endpoint_side = .source_exit, .port = source_port });
        try ports.append(allocator, .{ .node = geo.to, .edge = m.edge, .endpoint_side = .target_entry, .port = target_port });
    }

    // Mesh-union pass-through (D-IR item 16): legality re-checked here;
    // elements are produced by layout from Step 7 on.
    var unions: std.ArrayListUnmanaged(pb.MeshUnion) = .empty;
    var mesh_rejected: u32 = 0;
    const proposed_unions = if (mesh_candidates.len > 0) mesh_candidates else s.joins.mesh_unions;
    for (proposed_unions) |mu| {
        if (meshUnionLegal(join_permits, mu.members)) {
            try unions.append(allocator, mu);
        } else mesh_rejected += 1;
    }

    const conflict_slice = try conflicts.toOwnedSlice(allocator);
    return .{
        .plan = .{
            .selected_joins = try selected.toOwnedSlice(allocator),
            .rejected_proposals = try rejected.toOwnedSlice(allocator),
            .memberships = rms,
            .conflicts = conflict_slice,
            .terminal_ports = try ports.toOwnedSlice(allocator),
            .mesh_unions = try unions.toOwnedSlice(allocator),
        },
        .report = .{
            .verdicts = verdicts,
            .proposals = proposals,
            .multiplicity = multiplicity,
            .dual_membership_edges = dual_edges,
            .permission_overlap_conflicts = @intCast(conflict_slice.len),
            .mesh_unions_rejected = mesh_rejected,
        },
    };
}

/// First-fail naming tag per D-JOIN-SELECT items 3/7 (the pinned
/// join_select.* registry family).
fn tagFor(clause: GroupClause) pb.DiagnosticTag {
    return switch (clause) {
        .selected => .join_select_selected,
        .duplicate_key => .join_select_duplicate_key_blocked,
        .overlap => .join_select_conflict_neither,
        .multiplicity => .join_select_proposal_multiplicity_blocked,
        .unresolved_member, .incomplete, .style, .no_proposal => .join_select_independent_not_selected,
    };
}

fn findGroup(groups: []const pb.JoinGroup, dir: pb.JoinDirection, pivot: sk.NodeId) ?usize {
    for (groups, 0..) |g, i| if (g.direction == dir and g.pivot == pivot) return i;
    return null;
}

fn rankLess(ms: []const pb.JoinMembership, a: pb.EdgeId, b: pb.EdgeId) bool {
    return (edgeRank(ms, a) orelse std.math.maxInt(usize)) <
        (edgeRank(ms, b) orelse std.math.maxInt(usize));
}

fn pendingLess(_: void, a: Pending, b: Pending) bool {
    if (a.group != b.group) return a.group < b.group;
    const n = @min(a.ranks.len, b.ranks.len);
    for (a.ranks[0..n], b.ranks[0..n]) |ra, rb| {
        if (ra != rb) return ra < rb;
    }
    return a.ranks.len < b.ranks.len;
}

/// Duplicate scan: `full_key` compares the whole canonical edge key
/// (item 1 D-DUPLICATE trigger); otherwise the (from,to) pair only
/// (D-TRUNK duplicate-pair inventory).
fn hasDuplicate(row: []const MemberGeom, full_key: bool) bool {
    for (row, 0..) |a, i| for (row[0..i]) |b| {
        if (!a.found or !b.found) continue;
        const pair = a.from == b.from and a.to == b.to;
        if (!full_key) {
            if (pair) return true;
        } else if (pair and a.kind == b.kind and a.arrow_from == b.arrow_from and
            a.arrow_to == b.arrow_to and labelEql(a.label, b.label)) return true;
    };
    return false;
}

fn hasUnresolved(row: []const MemberGeom) bool {
    for (row) |g| if (!g.found) return true;
    return false;
}

/// Count of trunk-eligible (forward, non-back-edge) members.
fn forwardCount(row: []const MemberGeom) usize {
    var n: usize = 0;
    for (row) |g| {
        if (!g.back_edge) n += 1;
    }
    return n;
}

fn groupHasConflict(conflicts: []const pb.JoinConflict, id: pb.JoinGroupId) bool {
    for (conflicts) |c| if (c.groups[0] == id or c.groups[1] == id) return true;
    return false;
}

/// D-TRUNK item 1 sub-clauses in frozen order; the FIRST failing
/// sub-clause names the report-only tag. Null = clause (e) TRUE.
fn styleFail(direction: pb.JoinDirection, row: []const MemberGeom) ?pb.DiagnosticTag {
    // Judge the forward-eligible members only: a reversed member is not part
    // of the trunk, so its style never gates the trunk (mirrors join_commit's
    // forward-subset eff_group; keeps N6 exact for mixed-style back-edges).
    var ref: ?MemberGeom = null;
    for (row) |g| {
        if (g.back_edge) continue;
        if (g.kind == .invisible) return .trunk_member_invisible;
        const r = ref orelse {
            ref = g;
            continue;
        };
        if (g.kind != r.kind) return .trunk_member_style_mixed;
        const a = if (direction == .out) g.arrow_from else g.arrow_to;
        const b = if (direction == .out) r.arrow_from else r.arrow_to;
        if (a != b) return .trunk_pivot_side_arrow;
    }
    return null;
}

fn dispose(
    groups: []const pb.JoinGroup,
    verdicts: []const GroupVerdict,
    join_of_group: []const ?pb.RealizedJoinId,
    selected: []const pb.SelectedJoin,
    group_id: ?pb.JoinGroupId,
    edge: pb.EdgeId,
) ?pb.MembershipDisposition {
    const id = group_id orelse return null;
    const gi = groupIndexById(groups, id) orelse return null;
    if (verdicts[gi].clause == .selected) {
        // The realized trunk may carry only the forward subset; a member left
        // out (a layout-reversed back-edge) is independent, not selected.
        const jid = join_of_group[gi].?;
        for (selected) |sj| if (sj.id == jid and containsEdge(sj.members, edge)) return .{ .selected = jid };
        return .{ .independent = .{ .permission_group = id, .reason = .not_selected } };
    }
    return .{ .independent = .{
        .permission_group = id,
        .reason = if (verdicts[gi].clause == .overlap) .overlap_conflict else .not_selected,
    } };
}

/// Complete-mesh-union legality (TSD §7.4-as-amended, D-IR item 16) lives in
/// mesh_legal.zig (split for the 500-line cap); re-exported so invariants.zig
/// and realized_test2.zig keep reaching it as `realized.meshUnionLegal`.
pub const meshUnionLegal = @import("mesh_legal.zig").meshUnionLegal;

/// Clause-(g)-pre unsafe-component withdrawal (P2v Step 8) also lives in
/// mesh_legal.zig (the 500-line-cap plan-rewrite sibling); re-exported so
/// select.zig and the test siblings reach it as `realized.disposeUnsafe`.
pub const disposeUnsafe = @import("mesh_legal.zig").disposeUnsafe;

//! Candidate-local realized-bundle planner and layout-commitment verifier.
const std = @import("std");
const pb = @import("../base/ledger.zig");
const sk = @import("../sketch.zig");
pub const Error = error{OutOfMemory};

/// The report-only output vocabulary lives in the sibling
/// realized_report.zig (split out at the 500-line cap); re-exported so every
/// `realized.GroupClause` / `realized.Report` call site is unchanged.
const report_types = @import("realized_report.zig");

pub const GroupClause = report_types.GroupClause;
pub const GroupVerdict = report_types.GroupVerdict;
pub const Report = report_types.Report;
pub const Result = report_types.Result;
const tagFor = report_types.tagFor;

/// One member's realized style/endpoints read from the candidate's OWN
/// geometry (EdgePath fields, or the owning Rail for tap-represented
/// members) — no sem_graph datum (D-IR item 8).
const MemberGeom = struct {
    from: sk.NodeId = 0,
    to: sk.NodeId = 0,
    kind: sk.EdgeKind = .solid,
    arrow_from: sk.ArrowKind = .none,
    arrow_to: sk.ArrowKind = .none,
    label: ?[]const u8 = null,
    /// The member's candidate geometry is a layout-reversed back-edge, so it
    /// is NOT a rail-eligible member (D-PORT forward-subset composition):
    /// rail completeness/style judge the forward subset only.
    back_edge: bool = false,
    found: bool = false,
};

fn railDirection(rail: sk.Rail) pb.BundleDirection {
    return switch (rail.role) {
        .fan_in_dropper, .fan_in_rail => .in,
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
    for (s.rails) |rail| for (rail.taps) |tap| if (tap.edge == edge) {
        // A Rail owns exactly ONE pivot attachment, so the pivot-side
        // decoration is single-valued by construction (D-TRUNK item 5);
        // Tap.arrow is the member-end decoration; pivot_arrow is group-owned.
        const out = railDirection(rail) == .out;
        return .{
            .from = if (out) rail.pivot else tap.node,
            .to = if (out) tap.node else rail.pivot,
            .kind = rail.kind,
            .arrow_from = if (out) .none else tap.arrow,
            .arrow_to = if (out) tap.arrow else rail.pivot_arrow,
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

pub fn edgeRank(ms: []const pb.BundleMembership, edge: pb.EdgeId) ?usize {
    for (ms, 0..) |m, i| if (m.edge == edge) return i;
    return null;
}

pub fn groupIndexById(groups: []const pb.CandidateBundle, id: pb.CandidateBundleId) ?usize {
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
    id: pb.BundleProposalId = 0,
};

/// Plan one candidate.
pub fn realize(
    allocator: std.mem.Allocator,
    bundle_permits: pb.BundlePermits,
    s: sk.Sketch,
) Error!Result {
    // Candidate-local identity gate (D-JOIN-SELECT item 10): a sketch
    // carrying cluster frames went through split/stitch, whose edge ids
    // are piece-local (D-EDGE-ID item 4) — attribution would be unsound. This
    // covers motif-packed candidates (synthetic frames) even on flat
    // inputs; select.zig additionally gates on the top-level flat flag.
    // guarded-by: realized_test.zig "V-D-IR-02: motif_pack candidate is off the identity path and keeps an empty plan"
    if (s.clusters.len != 0) return .{ .report = .{ .skipped_clustered = true } };

    const groups = bundle_permits.groups;
    const ms = bundle_permits.memberships;

    const group_geoms = try allocator.alloc([]MemberGeom, groups.len);
    for (groups, group_geoms) |g, *slot| {
        const row = try allocator.alloc(MemberGeom, g.members.len);
        for (g.members, row) |edge, *mg| mg.* = memberGeom(s, edge);
        slot.* = row;
    }

    // Proposal extraction: one BundleProposal per Rail whose tap set lies
    // inside a BundlePermits group at the rail's pivot/direction.
    const raw_count = try allocator.alloc(u32, groups.len);
    @memset(raw_count, 0);
    var pend: std.ArrayListUnmanaged(Pending) = .empty;
    for (s.bundles.selected_bundles) |sel| {
        const gi = groupIndexById(groups, sel.candidate_bundle) orelse continue;
        raw_count[gi] += 1;
        const members = try allocator.dupe(pb.EdgeId, sel.members);
        std.mem.sort(pb.EdgeId, members, ms, rankLess);
        const ranks = try allocator.alloc(usize, members.len);
        for (members, ranks) |m, *r| r.* = edgeRank(ms, m) orelse std.math.maxInt(usize);
        try pend.append(allocator, .{ .group = gi, .members = members, .ranks = ranks, .geometry = .{ .edge_path = 0 }, .count = 1 });
    }
    if (s.bundles.selected_bundles.len == 0) for (s.rails, 0..) |rail, bi| {
        const gi = findGroup(groups, railDirection(rail), rail.pivot) orelse continue;
        var corresponds = rail.taps.len > 0;
        for (rail.taps) |tap| {
            if (!containsEdge(groups[gi].members, tap.edge)) corresponds = false;
        }
        if (!corresponds) continue;
        raw_count[gi] += 1;
        const members = try allocator.alloc(pb.EdgeId, rail.taps.len);
        for (rail.taps, members) |tap, *m| m.* = tap.edge;
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
            .geometry = .{ .rail = @intCast(bi) },
            .count = 1,
        });
    };
    // Canonical proposal order: (owning group key = group rank, canonical
    // member-set key = membership-rank sequence); ids assigned after sort.
    std.mem.sort(Pending, pend.items, {}, pendingLess);
    const proposals = try allocator.alloc(pb.BundleProposal, pend.items.len);
    const multiplicity = try allocator.alloc(u32, pend.items.len);
    for (pend.items, proposals, multiplicity, 0..) |*p, *rec, *mult, i| {
        p.id = @intCast(i);
        rec.* = .{
            .id = p.id,
            .candidate_bundle = groups[p.group].id,
            .members = p.members,
            .candidate_geometry = p.geometry,
        };
        mult.* = p.count;
    }

    // Build the overlap graph FIRST, retaining EVERY shared EdgeId; conflicts
    // ordered by the pair of group ranks, shared edges in the first
    // group's canonical member order.
    var conflicts: std.ArrayListUnmanaged(pb.BundleConflict) = .empty;
    for (groups, 0..) |ga, i| {
        for (groups[i + 1 ..]) |gb| {
            var shared: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
            for (ga.members) |e| if (containsEdge(gb.members, e)) try shared.append(allocator, e);
            if (shared.items.len == 0) continue;
            var pids: std.ArrayListUnmanaged(pb.BundleProposalId) = .empty;
            for (proposals) |p| {
                if (p.candidate_bundle == ga.id or p.candidate_bundle == gb.id)
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
    // come from the BundlePermits and are single-pivot). With ≥2 proposals
    // clause (c) is unreadable — item 3 forbids reading any property of
    // competing proposals — so it applies to the exactly-one case only.
    // guarded-by: realized_test.zig "V-D-JOIN-SELECT-07: partial proposal fails clause (c) first"
    const verdicts = try allocator.alloc(GroupVerdict, groups.len);
    const bundle_of_group = try allocator.alloc(?pb.SelectedBundleId, groups.len);
    @memset(bundle_of_group, null);
    var selected: std.ArrayListUnmanaged(pb.SelectedBundle) = .empty;
    for (groups, group_geoms, verdicts, 0..) |g, permission_row, *v, gi| {
        const single: ?*const Pending = blk: {
            if (raw_count[gi] != 1) break :blk null;
            for (pend.items) |*p| if (p.group == gi) break :blk p;
            break :blk null;
        };
        // The pre-sizing commitment is authoritative about which members own
        // the rail already present in this sketch. Excluded permission members
        // have private geometry and cannot invalidate or enlarge that rail.
        const row = if (single) |proposal|
            try memberRow(allocator, s, proposal.members)
        else
            permission_row;
        var detail: ?pb.DiagnosticTag = null;
        const clause: GroupClause = blk: {
            if (hasDuplicate(row, true)) break :blk .duplicate_key;
            if (hasUnresolved(row)) break :blk .unresolved_member;
            // Completeness (clause c) is measured against the forward-eligible
            // (non-back-edge) members: a fan-IN rail composes its forward
            // subset and the reversed member(s) stay independent, exactly as
            // bundle_commit commits it (keeps the N6 agreement pin exact).
            if (single != null and single.?.members.len < committedCount(s.bundles, g.id, forwardCount(permission_row))) break :blk .incomplete;
            if (groupHasConflict(conflicts.items, g.id) and !pb.fanInReMergeEligible(groups, gi)) break :blk .overlap; // arrival re-merge: eligible fan-in falls through (conflict still recorded)
            if (styleFail(g.direction, row)) |t| {
                detail = t;
                break :blk .style;
            }
            if (raw_count[gi] == 0) break :blk .no_proposal;
            if (raw_count[gi] >= 2) break :blk .multiplicity;
            break :blk .selected;
        };
        if (clause == .selected) {
            const jid: pb.SelectedBundleId = @intCast(selected.items.len);
            bundle_of_group[gi] = jid;
            try selected.append(allocator, .{
                .id = jid,
                .proposal = single.?.id,
                .candidate_bundle = g.id,
                .members = single.?.members,
            });
        }
        v.* = .{
            .group = g.id,
            .clause = clause,
            .tag = tagFor(clause),
            .rail_detail = detail,
            .duplicate_pair = hasDuplicate(row, false),
            .proposal_count = raw_count[gi],
        };
    }

    // Every proposal of a non-realized group is rejected (ids ascend with
    // the canonical proposal order, so this list is canonical).
    var rejected: std.ArrayListUnmanaged(pb.BundleProposalId) = .empty;
    for (pend.items) |p| {
        if (verdicts[p.group].clause != .selected) try rejected.append(allocator, p.id);
    }

    // Dispositions: exactly one per endpoint membership, in canonical
    // membership order (item 7's frozen mapping).
    var dual_edges: u32 = 0;
    const rms = try allocator.alloc(pb.RealizedEdgeMembership, ms.len);
    for (ms, rms) |m, *rm| {
        rm.* = .{
            .edge = m.edge,
            .source = dispose(groups, verdicts, bundle_of_group, selected.items, m.source_group, m.edge),
            .target = dispose(groups, verdicts, bundle_of_group, selected.items, m.target_group, m.edge),
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
        for (s.bundles.terminal_ports) |p| if (p.edge == m.edge) {
            if (p.endpoint_side == .source_exit) source_port = p.port else target_port = p.port;
        };
        try ports.append(allocator, .{ .node = geo.from, .edge = m.edge, .endpoint_side = .source_exit, .port = source_port });
        try ports.append(allocator, .{ .node = geo.to, .edge = m.edge, .endpoint_side = .target_entry, .port = target_port });
    }

    // Co-realization is a fact of the candidate's OWN emitted geometry, not a
    // permission re-decided here: the discharges were made before the sketch
    // existed, so the record travels with the plan describing it. What IS
    // re-checked is that no discharged edge also owns an EdgePath.
    const routed = try allocator.alloc(pb.EdgeId, s.edges.len);
    for (s.edges, routed) |e, *slot| slot.* = e.id;
    const double_discharge = pb.doubleDischarged(s.bundles.discharged, routed);

    const conflict_slice = try conflicts.toOwnedSlice(allocator);
    const selected_slice = try selected.toOwnedSlice(allocator);
    return .{
        .plan = .{
            .selected_bundles = selected_slice,
            .rejected_proposals = try rejected.toOwnedSlice(allocator),
            .memberships = rms,
            .conflicts = conflict_slice,
            .terminal_ports = try ports.toOwnedSlice(allocator),
            .discharged = s.bundles.discharged,
            // The fusion licence travels with the plan that earned it, valid
            // only while every union member still rides a selected rail here
            // (the N6 agreement pin makes that the common case).
            .fused = keepValidFused(s.bundles.fused, selected_slice),
        },
        .report = .{
            .verdicts = verdicts,
            .proposals = proposals,
            .multiplicity = multiplicity,
            .dual_membership_edges = dual_edges,
            .permission_overlap_conflicts = @intCast(conflict_slice.len),
            .co_double_discharge = double_discharge,
        },
    };
}

/// A licence whose union names an edge no re-realized rail carries lapses
/// wholesale — the conservative rail for a record nothing here re-derives.
fn keepValidFused(fused: []const []const pb.EdgeId, selected: []const pb.SelectedBundle) []const []const pb.EdgeId {
    for (fused) |u| for (u) |e| {
        var found = false;
        for (selected) |j| if (containsEdge(j.members, e)) {
            found = true;
        };
        if (!found) return &.{};
    };
    return fused;
}

fn memberRow(allocator: std.mem.Allocator, s: sk.Sketch, members: []const pb.EdgeId) error{OutOfMemory}![]MemberGeom {
    const row = try allocator.alloc(MemberGeom, members.len);
    for (members, row) |edge, *mg| mg.* = memberGeom(s, edge);
    return row;
}

fn findGroup(groups: []const pb.CandidateBundle, dir: pb.BundleDirection, pivot: sk.NodeId) ?usize {
    for (groups, 0..) |g, i| if (g.direction == dir and g.pivot == pivot) return i;
    return null;
}

fn rankLess(ms: []const pb.BundleMembership, a: pb.EdgeId, b: pb.EdgeId) bool {
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

/// The member count clause (c) measures completeness against: the candidate's
/// OWN pre-sizing commitment when it named a strict subset for this group,
/// otherwise the forward-eligible count.
///
/// A layout builds the rail it was committed to build. The closure law can
/// commit a strict subset — the salvage: the members whose leaf pairs the
/// graph declares keep the rail, the rest unfuse — exactly as the reversal
/// rule already does. Judging the geometry against the whole PERMISSION group
/// then calls that rail `incomplete`, withdraws it, and leaves the ink the
/// layout genuinely fused with no bundle to license it: the reach oracle
/// reports an unknown continuation, the CI filter drops every candidate, and
/// the render falls back to the forced all-independent terminal layout — a
/// worse picture, produced by two halves of the planner disagreeing about
/// what was drawn.
/// guarded-by: realized_production_test.zig "a salvaged rail is complete against the commitment the layout drew"
fn committedCount(bundles: pb.RealizedBundles, group: pb.CandidateBundleId, forward: usize) usize {
    for (bundles.selected_bundles) |sj| {
        if (sj.candidate_bundle == group) return @min(forward, sj.members.len);
    }
    return forward;
}

/// Count of rail-eligible (forward, non-back-edge) members.
fn forwardCount(row: []const MemberGeom) usize {
    var n: usize = 0;
    for (row) |g| {
        if (!g.back_edge) n += 1;
    }
    return n;
}

fn groupHasConflict(conflicts: []const pb.BundleConflict, id: pb.CandidateBundleId) bool {
    for (conflicts) |c| if (c.groups[0] == id or c.groups[1] == id) return true;
    return false;
}

/// D-TRUNK item 1 sub-clauses in frozen order; the FIRST failing
/// sub-clause names the report-only tag. Null = clause (e) TRUE.
fn styleFail(direction: pb.BundleDirection, row: []const MemberGeom) ?pb.DiagnosticTag {
    // Judge the forward-eligible members only: a reversed member is not part
    // of the rail, so its style never gates the rail (mirrors bundle_commit's
    // forward-subset eff_group; keeps N6 exact for mixed-style back-edges).
    var ref: ?MemberGeom = null;
    for (row) |g| {
        if (g.back_edge) continue;
        if (g.kind == .invisible) return .rail_member_invisible;
        const r = ref orelse {
            ref = g;
            continue;
        };
        if (g.kind != r.kind) return .rail_member_style_mixed;
        const a = if (direction == .out) g.arrow_from else g.arrow_to;
        const b = if (direction == .out) r.arrow_from else r.arrow_to;
        if (a != b) return .rail_pivot_side_arrow;
    }
    return null;
}

fn dispose(
    groups: []const pb.CandidateBundle,
    verdicts: []const GroupVerdict,
    bundle_of_group: []const ?pb.SelectedBundleId,
    selected: []const pb.SelectedBundle,
    group_id: ?pb.CandidateBundleId,
    edge: pb.EdgeId,
) ?pb.MembershipDisposition {
    const id = group_id orelse return null;
    const gi = groupIndexById(groups, id) orelse return null;
    if (verdicts[gi].clause == .selected) {
        // The realized rail may carry only the forward subset; a member left
        // out (a layout-reversed back-edge) is independent, not selected.
        const jid = bundle_of_group[gi].?;
        for (selected) |sj| if (sj.id == jid and containsEdge(sj.members, edge)) return .{ .selected = jid };
        return .{ .independent = .{ .candidate_bundle = id, .reason = .not_selected } };
    }
    return .{ .independent = .{
        .candidate_bundle = id,
        .reason = if (verdicts[gi].clause == .overlap) .overlap_conflict else .not_selected,
    } };
}

/// Clause-(g)-pre unsafe-component withdrawal (P2v Step 8) lives in
/// dispose.zig (the plan-rewrite sibling); re-exported so select_filter.zig
/// and the test siblings reach it as `realized.disposeUnsafe`.
pub const disposeUnsafe = @import("dispose.zig").disposeUnsafe;

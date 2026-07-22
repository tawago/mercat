//! mesh_legal.zig — TSD §7.4-as-amended complete-mesh-union legality, split
//! out of realized.zig for the mermaid_v2 500-line cap (D-IR item 16). Pure
//! function over (JoinPermits, member edge ids); never reads geometry.
//! Shared by realized.zig (pass-through re-check) and invariants.zig (§6.7
//! landed-element check, via realized's re-export).
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger.

const std = @import("std");
const pb = @import("../base/ledger.zig");

/// TSD §7.4-as-amended legality of one proposed mesh-union element, from
/// JoinPermits declared edges only (never geometry): the represented member
/// relation is exactly the complete bipartite relation over its endpoint
/// sets, every Cartesian pair declared, and N*M == D. **D is pinned as the
/// DECLARED member-edge count** (`members.len`, duplicate declared edges
/// counted) — deliberately diverging from `fan_lanes.isIncomplete`'s
/// unique-pair count (plan N5): a complete pair set carrying duplicate
/// declared edges is NOT a legal union.
/// guarded-by: realized_test2.zig "N5: duplicate-containing complete pair set fails mesh legality (D = declared edge count)"
pub fn meshUnionLegal(join_permits: pb.JoinPermits, members: []const pb.EdgeId) bool {
    if (members.len == 0) return false;
    var sources: usize = 0;
    var targets: usize = 0;
    var pairs: usize = 0;
    for (members, 0..) |edge, i| {
        for (members[0..i]) |prev| if (prev == edge) return false;
        const ep = endpointsOf(join_permits, edge) orelse return false;
        var new_src = true;
        var new_tgt = true;
        var new_pair = true;
        for (members[0..i]) |prev| {
            const pep = endpointsOf(join_permits, prev).?;
            if (pep.from == ep.from) new_src = false;
            if (pep.to == ep.to) new_tgt = false;
            if (pep.from == ep.from and pep.to == ep.to) new_pair = false;
        }
        if (new_src) sources += 1;
        if (new_tgt) targets += 1;
        if (new_pair) pairs += 1;
    }
    if (sources < 2 or targets < 2) return false;
    return pairs == sources * targets and members.len == sources * targets;
}

// -- Clause-(g)-pre re-disposition (P2v Step 8) --------------------------------

/// Clause-(g) pre-half withdrawal (D-JOIN-SELECT item 7 frozen mapping;
/// D-DISPOSITION item 5 row 3): a candidate the pre-raster reachability
/// filter excludes has EVERY realized trunk withdrawn — each `selected`
/// membership flips to `independent{ its group, .unsafe_component }`, and the
/// emptied joins' proposals move to `rejected_proposals` so the §6.7 proposal
/// accounting (selected XOR rejected) still balances under
/// `invariants.validate`. Pure over the plan (no Sketch, no reach_report):
/// conflicts, terminal ports, mesh unions, and every already-`independent`/
/// null disposition are unchanged.
///
/// GRANULARITY (record decision): the WHOLE excluded plan's selected set is
/// withdrawn, not one component. Clause (g) validates the WHOLE candidate's
/// reachability (D-JOIN-SELECT clause (g): "the candidate passes complete
/// component-reachability validation … pre- and post-raster"); item 7 names
/// the outcome "group fails clause (g) … → independent(unsafe_component)" and
/// item 2 makes all-independent the always-expressible conservative baseline.
/// A candidate-level reachability failure carries no record-sanctioned
/// attribution to ONE surviving safe trunk, so the conservative bar (spine
/// item 1(d) "NEITHER") withdraws the entire selected set.
/// guarded-by: disposition_test.zig "V-D-DISPOSITION-01: incomplete-2x2 conflicts survive disposeUnsafe, all-independent withdrawal, render succeeds"
pub fn disposeUnsafe(a: std.mem.Allocator, plan: pb.RealizedJoins) error{OutOfMemory}!pb.RealizedJoins {
    if (plan.selected_joins.len == 0) return plan;

    const memberships = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
    for (plan.memberships, memberships) |m, *out| out.* = .{
        .edge = m.edge,
        .source = flipUnsafe(plan.selected_joins, m.source),
        .target = flipUnsafe(plan.selected_joins, m.target),
    };

    var rejected = std.ArrayListUnmanaged(pb.JoinProposalId).empty;
    try rejected.appendSlice(a, plan.rejected_proposals);
    for (plan.selected_joins) |join| try rejected.append(a, join.proposal);
    const rejected_slice = try rejected.toOwnedSlice(a);
    std.mem.sort(pb.JoinProposalId, rejected_slice, {}, std.sort.asc(pb.JoinProposalId));

    return .{
        .selected_joins = &.{},
        .rejected_proposals = rejected_slice,
        .memberships = memberships,
        .conflicts = plan.conflicts,
        .terminal_ports = plan.terminal_ports,
        .mesh_unions = plan.mesh_unions,
    };
}

/// A `selected` disposition becomes `independent{ its join's group,
/// unsafe_component }` (the flipped group id equals the permits endpoint
/// group, so `invariants.checkDisposition` still matches); every other
/// disposition passes through unchanged.
fn flipUnsafe(selected: []const pb.SelectedJoin, disp: ?pb.MembershipDisposition) ?pb.MembershipDisposition {
    const d = disp orelse return null;
    return switch (d) {
        .independent => d,
        .selected => |jid| blk: {
            for (selected) |join| if (join.id == jid) break :blk .{ .independent = .{
                .permission_group = join.permission_group,
                .reason = .unsafe_component,
            } };
            break :blk d;
        },
    };
}

const Endpoints = struct { from: pb.NodeId, to: pb.NodeId };

/// A member's endpoints derived from its JoinPermits groups (in an exactly
/// complete N≥2×M≥2 union every member carries BOTH endpoint groups).
fn endpointsOf(join_permits: pb.JoinPermits, edge: pb.EdgeId) ?Endpoints {
    const rank = edgeRank(join_permits.memberships, edge) orelse return null;
    const m = join_permits.memberships[rank];
    const si = groupIndexById(join_permits.groups, m.source_group orelse return null) orelse return null;
    const ti = groupIndexById(join_permits.groups, m.target_group orelse return null) orelse return null;
    return .{ .from = join_permits.groups[si].pivot, .to = join_permits.groups[ti].pivot };
}

fn edgeRank(ms: []const pb.JoinMembership, edge: pb.EdgeId) ?usize {
    for (ms, 0..) |m, i| if (m.edge == edge) return i;
    return null;
}

fn groupIndexById(groups: []const pb.JoinGroup, id: pb.JoinGroupId) ?usize {
    for (groups, 0..) |g, i| if (g.id == id) return i;
    return null;
}

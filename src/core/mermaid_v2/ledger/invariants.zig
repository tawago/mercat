//! invariants.zig — the TSD §6.7 realized-plan output validator
//! (P2v Step 4; D-JOIN-SELECT item 8), split out of realized.zig for the
//! mermaid_v2 500-line cap. Pure function over (JoinPermits,
//! RealizedJoins): every §6.7 bullet except component reachability
//! (D-REACH; landed by reach_vector in Steps 6 and 8–9).
//! Report-only — used by tests and by select.zig's debug path; it never
//! affects candidate selection or output bytes.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! sketch, realized.zig.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const jp = @import("realized.zig");

pub const Error = jp.Error;
const containsEdge = jp.containsEdge;
const edgeRank = jp.edgeRank;
const groupIndexById = jp.groupIndexById;
const meshUnionLegal = jp.meshUnionLegal;

pub const ValidationTag = enum {
    membership_set_mismatch,
    disposition_missing,
    disposition_unexpected,
    disposition_group_mismatch,
    disposition_join_mismatch,
    selected_both_sides,
    selected_join_group_missing,
    selected_join_foreign_member,
    selected_join_duplicate_member,
    selected_join_proposal_missing,
    selected_member_multiple_joins,
    selected_joins_not_canonical,
    conflict_missing,
    conflict_unknown_group,
    conflict_shared_edges_wrong,
    conflicts_not_canonical,
    rejected_proposal_unknown,
    proposal_both_outcomes,
    proposal_unaccounted,
    terminal_edge_unknown,
    terminal_ports_not_canonical,
    mesh_union_illegal,
};

pub const Finding = struct {
    tag: ValidationTag,
    group: ?pb.JoinGroupId = null,
    edge: ?pb.EdgeId = null,
};

pub const ValidationReport = struct {
    findings: []const Finding,

    pub fn valid(self: ValidationReport) bool {
        return self.findings.len == 0;
    }
};

/// TSD §6.7 output validation over (JoinPermits, RealizedJoins): every
/// bullet except component reachability (D-REACH; Steps 6 and 8–9).
/// `proposals` is the planner report's canonical list, needed for the
/// referenced-proposal-exists bullet. Pure and report-only.
pub fn validate(
    allocator: std.mem.Allocator,
    join_permits: pb.JoinPermits,
    plan: pb.RealizedJoins,
    proposals: []const pb.JoinProposal,
) Error!ValidationReport {
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    const groups = join_permits.groups;
    const ms = join_permits.memberships;

    // Bullets 1 + 7: exactly one realized membership per declared edge, in
    // canonical membership order (one declared edge stays one record).
    if (plan.memberships.len != ms.len) {
        try add(&out, allocator, .membership_set_mismatch, null, null);
    } else for (ms, plan.memberships) |bm, rm| {
        if (bm.edge != rm.edge) {
            try add(&out, allocator, .membership_set_mismatch, null, rm.edge);
            continue;
        }
        try checkDisposition(&out, allocator, plan, rm.edge, bm.source_group, rm.source);
        try checkDisposition(&out, allocator, plan, rm.edge, bm.target_group, rm.target);
        // Bullet 6: never-both (D-DUAL item 1).
        const src_sel = rm.source != null and rm.source.? == .selected;
        if (src_sel and rm.target != null and rm.target.? == .selected)
            try add(&out, allocator, .selected_both_sides, null, rm.edge);
    }

    // Bullets 2–4: selected joins reference one existing group + proposal,
    // contain only its members, every member's disposition at that
    // endpoint is selected(this join) — an independent membership never
    // appears — and no member holds two joins at one endpoint.
    var prev_rank: ?usize = null;
    for (plan.selected_joins) |join| {
        const gi = groupIndexById(groups, join.permission_group) orelse {
            try add(&out, allocator, .selected_join_group_missing, join.permission_group, null);
            continue;
        };
        if (prev_rank != null and gi <= prev_rank.?)
            try add(&out, allocator, .selected_joins_not_canonical, join.permission_group, null);
        prev_rank = gi;
        const found = blk: {
            for (proposals) |p| {
                if (p.id == join.proposal) break :blk p.permission_group == join.permission_group;
            }
            break :blk false;
        };
        if (!found) try add(&out, allocator, .selected_join_proposal_missing, join.permission_group, null);
        for (join.members, 0..) |edge, k| {
            if (!containsEdge(groups[gi].members, edge))
                try add(&out, allocator, .selected_join_foreign_member, join.permission_group, edge);
            for (join.members[0..k]) |prev| if (prev == edge)
                try add(&out, allocator, .selected_join_duplicate_member, join.permission_group, edge);
            const disp = dispositionAt(plan, edge, groups[gi].direction);
            const links = disp != null and disp.? == .selected and disp.?.selected == join.id;
            if (!links) try add(&out, allocator, .disposition_join_mismatch, join.permission_group, edge);
        }
        for (plan.selected_joins) |other| {
            if (other.id == join.id) continue;
            const oi = groupIndexById(groups, other.permission_group) orelse continue;
            if (groups[oi].direction != groups[gi].direction) continue;
            for (join.members) |edge| if (containsEdge(other.members, edge))
                try add(&out, allocator, .selected_member_multiple_joins, join.permission_group, edge);
        }
    }

    // §6.5 completeness (bullet 9's retained-permissions half): every
    // overlapping group pair has ONE conflict retaining the full shared
    // set, in canonical (group-rank pair) order.
    var prev_pair: ?[2]usize = null;
    for (plan.conflicts) |c| {
        const ia = groupIndexById(groups, c.groups[0]) orelse {
            try add(&out, allocator, .conflict_unknown_group, c.groups[0], null);
            continue;
        };
        const ib = groupIndexById(groups, c.groups[1]) orelse {
            try add(&out, allocator, .conflict_unknown_group, c.groups[1], null);
            continue;
        };
        if (c.reason != .overlapping_permissions) continue;
        if (prev_pair) |pp| {
            if (ia < pp[0] or (ia == pp[0] and ib <= pp[1]))
                try add(&out, allocator, .conflicts_not_canonical, c.groups[0], null);
        }
        prev_pair = .{ ia, ib };
    }
    for (groups, 0..) |ga, i| {
        for (groups[i + 1 ..]) |gb| {
            var shared_n: usize = 0;
            var retained: usize = 0;
            const conflict = conflictFor(plan.conflicts, ga.id, gb.id);
            for (ga.members) |e| if (containsEdge(gb.members, e)) {
                shared_n += 1;
                if (conflict != null and containsEdge(conflict.?.shared_edges, e)) retained += 1;
            };
            if (shared_n == 0) continue;
            if (conflict == null) {
                try add(&out, allocator, .conflict_missing, ga.id, null);
            } else if (retained != shared_n or conflict.?.shared_edges.len != shared_n) {
                try add(&out, allocator, .conflict_shared_edges_wrong, ga.id, null);
            }
        }
    }

    // Rejections are not defects (item 9), but every proposal is accounted
    // exactly once (selected XOR rejected) and rejected ids resolve.
    for (plan.rejected_proposals) |pid| {
        var known = false;
        for (proposals) |p| {
            if (p.id == pid) known = true;
        }
        if (!known) try add(&out, allocator, .rejected_proposal_unknown, null, null);
        for (plan.selected_joins) |join| if (join.proposal == pid)
            try add(&out, allocator, .proposal_both_outcomes, join.permission_group, null);
    }
    for (proposals) |p| {
        var accounted = containsProposal(plan.rejected_proposals, p.id);
        for (plan.selected_joins) |join| {
            if (join.proposal == p.id) accounted = true;
        }
        if (!accounted) try add(&out, allocator, .proposal_unaccounted, p.permission_group, null);
    }

    // Terminal ports: known edges, canonical (edge rank, source-then-
    // target) order, at most one tuple per endpoint.
    var prev_key: ?usize = null;
    for (plan.terminal_ports) |tp| {
        const rank = edgeRank(ms, tp.edge) orelse {
            try add(&out, allocator, .terminal_edge_unknown, null, tp.edge);
            continue;
        };
        const key = rank * 2 + @intFromEnum(tp.endpoint_side);
        if (prev_key != null and key <= prev_key.?)
            try add(&out, allocator, .terminal_ports_not_canonical, null, tp.edge);
        prev_key = key;
    }

    // D-IR item 16: every landed mesh-union element is legal (N*M == D).
    for (plan.mesh_unions) |mu| {
        if (!meshUnionLegal(join_permits, mu.members))
            try add(&out, allocator, .mesh_union_illegal, null, null);
    }

    return .{ .findings = try out.toOwnedSlice(allocator) };
}

fn dispositionAt(plan: pb.RealizedJoins, edge: pb.EdgeId, direction: pb.JoinDirection) ?pb.MembershipDisposition {
    for (plan.memberships) |rm| {
        if (rm.edge == edge) return if (direction == .out) rm.source else rm.target;
    }
    return null;
}

fn conflictFor(conflicts: []const pb.JoinConflict, a: pb.JoinGroupId, b: pb.JoinGroupId) ?pb.JoinConflict {
    for (conflicts) |c| {
        if (c.reason != .overlapping_permissions) continue;
        if ((c.groups[0] == a and c.groups[1] == b) or (c.groups[0] == b and c.groups[1] == a)) return c;
    }
    return null;
}

fn checkDisposition(
    out: *std.ArrayListUnmanaged(Finding),
    allocator: std.mem.Allocator,
    plan: pb.RealizedJoins,
    edge: pb.EdgeId,
    group_id: ?pb.JoinGroupId,
    disp: ?pb.MembershipDisposition,
) Error!void {
    const id = group_id orelse {
        if (disp != null) try add(out, allocator, .disposition_unexpected, null, edge);
        return;
    };
    const d = disp orelse return add(out, allocator, .disposition_missing, id, edge);
    switch (d) {
        .independent => |ind| if (ind.permission_group != id)
            try add(out, allocator, .disposition_group_mismatch, id, edge),
        .selected => |jid| {
            const ok = blk: {
                for (plan.selected_joins) |join| {
                    if (join.id == jid) break :blk join.permission_group == id and
                        containsEdge(join.members, edge);
                }
                break :blk false;
            };
            if (!ok) try add(out, allocator, .disposition_join_mismatch, id, edge);
        },
    }
}

fn containsProposal(ids: []const pb.JoinProposalId, id: pb.JoinProposalId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

fn add(
    out: *std.ArrayListUnmanaged(Finding),
    allocator: std.mem.Allocator,
    tag: ValidationTag,
    group: ?pb.JoinGroupId,
    edge: ?pb.EdgeId,
) Error!void {
    try out.append(allocator, .{ .tag = tag, .group = group, .edge = edge });
}

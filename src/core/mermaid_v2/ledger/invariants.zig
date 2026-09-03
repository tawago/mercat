//! invariants.zig — the realized-plan output validator
//! (P2v Step 4; D-JOIN-SELECT item 8), split out of realized.zig for the
//! mermaid_v2 500-line cap. Pure function over (BundlePermits,
//! RealizedBundles): every structural invariant except component reachability
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

pub const ValidationTag = enum {
    membership_set_mismatch,
    disposition_missing,
    disposition_unexpected,
    disposition_group_mismatch,
    disposition_bundle_mismatch,
    selected_bundle_group_missing,
    selected_bundle_foreign_member,
    selected_bundle_duplicate_member,
    selected_bundle_proposal_missing,
    selected_member_multiple_bundles,
    selected_bundles_not_canonical,
    rejected_proposal_unknown,
    proposal_both_outcomes,
    proposal_unaccounted,
    terminal_edge_unknown,
    terminal_ports_not_canonical,
};

pub const Finding = struct {
    tag: ValidationTag,
    group: ?pb.CandidateBundleId = null,
    edge: ?pb.EdgeId = null,
};

pub const ValidationReport = struct {
    findings: []const Finding,

    pub fn valid(self: ValidationReport) bool {
        return self.findings.len == 0;
    }
};

/// Output validation over (BundlePermits, RealizedBundles): every structural
/// invariant except component reachability (D-REACH; Steps 6 and 8–9).
/// `proposals` is the planner report's canonical list, needed for the
/// referenced-proposal-exists bullet. Pure and report-only.
pub fn validate(
    allocator: std.mem.Allocator,
    bundle_permits: pb.BundlePermits,
    plan: pb.RealizedBundles,
    proposals: []const pb.BundleProposal,
) Error!ValidationReport {
    var out: std.ArrayListUnmanaged(Finding) = .empty;
    const groups = bundle_permits.groups;
    const ms = bundle_permits.memberships;

    if (plan.memberships.len != ms.len) {
        try add(&out, allocator, .membership_set_mismatch, null, null);
    } else for (ms, plan.memberships) |bm, rm| {
        if (bm.edge != rm.edge) {
            try add(&out, allocator, .membership_set_mismatch, null, rm.edge);
            continue;
        }
        try checkDisposition(&out, allocator, plan, rm.edge, bm.source_group, rm.source);
        try checkDisposition(&out, allocator, plan, rm.edge, bm.target_group, rm.target);
    }

    var prev_rank: ?usize = null;
    for (plan.selected_bundles) |sel| {
        const gi = groupIndexById(groups, sel.candidate_bundle) orelse {
            try add(&out, allocator, .selected_bundle_group_missing, sel.candidate_bundle, null);
            continue;
        };
        if (prev_rank != null and gi <= prev_rank.?)
            try add(&out, allocator, .selected_bundles_not_canonical, sel.candidate_bundle, null);
        prev_rank = gi;
        const found = blk: {
            for (proposals) |p| {
                if (p.id == sel.proposal) break :blk p.candidate_bundle == sel.candidate_bundle;
            }
            break :blk false;
        };
        if (!found) try add(&out, allocator, .selected_bundle_proposal_missing, sel.candidate_bundle, null);
        for (sel.members, 0..) |edge, k| {
            if (!containsEdge(groups[gi].members, edge))
                try add(&out, allocator, .selected_bundle_foreign_member, sel.candidate_bundle, edge);
            for (sel.members[0..k]) |prev| if (prev == edge)
                try add(&out, allocator, .selected_bundle_duplicate_member, sel.candidate_bundle, edge);
            const disp = dispositionAt(plan, edge, groups[gi].direction);
            const links = disp != null and disp.? == .selected and disp.?.selected == sel.id;
            if (!links) try add(&out, allocator, .disposition_bundle_mismatch, sel.candidate_bundle, edge);
        }
        for (plan.selected_bundles) |other| {
            if (other.id == sel.id) continue;
            const oi = groupIndexById(groups, other.candidate_bundle) orelse continue;
            if (groups[oi].direction != groups[gi].direction) continue;
            for (sel.members) |edge| if (containsEdge(other.members, edge))
                try add(&out, allocator, .selected_member_multiple_bundles, sel.candidate_bundle, edge);
        }
    }

    for (plan.rejected_proposals) |pid| {
        var known = false;
        for (proposals) |p| {
            if (p.id == pid) known = true;
        }
        if (!known) try add(&out, allocator, .rejected_proposal_unknown, null, null);
        for (plan.selected_bundles) |sel| if (sel.proposal == pid)
            try add(&out, allocator, .proposal_both_outcomes, sel.candidate_bundle, null);
    }
    for (proposals) |p| {
        var accounted = containsProposal(plan.rejected_proposals, p.id);
        for (plan.selected_bundles) |sel| {
            if (sel.proposal == p.id) accounted = true;
        }
        if (!accounted) try add(&out, allocator, .proposal_unaccounted, p.candidate_bundle, null);
    }

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

    return .{ .findings = try out.toOwnedSlice(allocator) };
}

fn dispositionAt(plan: pb.RealizedBundles, edge: pb.EdgeId, direction: pb.BundleDirection) ?pb.MembershipDisposition {
    for (plan.memberships) |rm| {
        if (rm.edge == edge) return if (direction == .out) rm.source else rm.target;
    }
    return null;
}

fn checkDisposition(
    out: *std.ArrayListUnmanaged(Finding),
    allocator: std.mem.Allocator,
    plan: pb.RealizedBundles,
    edge: pb.EdgeId,
    group_id: ?pb.CandidateBundleId,
    disp: ?pb.MembershipDisposition,
) Error!void {
    const id = group_id orelse {
        if (disp != null) try add(out, allocator, .disposition_unexpected, null, edge);
        return;
    };
    const d = disp orelse return add(out, allocator, .disposition_missing, id, edge);
    switch (d) {
        .independent => |ind| if (ind.candidate_bundle != id)
            try add(out, allocator, .disposition_group_mismatch, id, edge),
        .selected => |jid| {
            const ok = blk: {
                for (plan.selected_bundles) |sel| {
                    if (sel.id == jid) break :blk sel.candidate_bundle == id and
                        containsEdge(sel.members, edge);
                }
                break :blk false;
            };
            if (!ok) try add(out, allocator, .disposition_bundle_mismatch, id, edge);
        },
    }
}

fn containsProposal(ids: []const pb.BundleProposalId, id: pb.BundleProposalId) bool {
    for (ids) |candidate| if (candidate == id) return true;
    return false;
}

fn add(
    out: *std.ArrayListUnmanaged(Finding),
    allocator: std.mem.Allocator,
    tag: ValidationTag,
    group: ?pb.CandidateBundleId,
    edge: ?pb.EdgeId,
) Error!void {
    try out.append(allocator, .{ .tag = tag, .group = group, .edge = edge });
}

//! dispose.zig — clause-(g)-pre re-disposition (P2v Step 8): the one plan
//! rewrite the ledger performs. Pure over a RealizedJoins envelope; no Sketch,
//! no geometry, no reach report.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger.

const std = @import("std");
const pb = @import("../base/ledger.zig");

/// Clause-(g) pre-half withdrawal (D-JOIN-SELECT item 7 frozen mapping;
/// D-DISPOSITION item 5 row 3): a candidate the pre-raster reachability
/// filter excludes has EVERY realized trunk withdrawn — each `selected`
/// membership flips to `independent{ its group, .unsafe_component }`, and the
/// emptied joins' proposals move to `rejected_proposals` so the §6.7 proposal
/// accounting (selected XOR rejected) still balances under
/// `invariants.validate`. Pure over the plan (no Sketch, no reach_report):
/// conflicts, terminal ports, and every already-`independent`/
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
        // Withdrawing a trunk is a PERMISSION rewrite; the candidate's already
        // emitted geometry is untouched, and a co-realized edge still has no
        // private ink in it. Dropping the record would report that edge as
        // missing from a sketch that never drew it.
        .co_realized = plan.co_realized,
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

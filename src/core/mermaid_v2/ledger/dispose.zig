//! dispose.zig — clause-(g)-pre re-disposition (P2v Step 8): the one plan
//! rewrite the ledger performs. Pure over a RealizedBundles envelope; no Sketch,
//! no geometry, no reach report.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger.

const std = @import("std");
const pb = @import("../base/ledger.zig");

/// Clause-(g) pre-half withdrawal (D-JOIN-SELECT item 7 frozen mapping;
/// D-DISPOSITION item 5 row 3): a candidate the pre-raster reachability
/// filter excludes has EVERY realized rail withdrawn — each `selected`
/// membership flips to `independent{ its group, .unsafe_component }`, and the
/// emptied bundles' proposals move to `rejected_proposals` so invariant proposal
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
/// attribution to ONE surviving safe rail, so the conservative rail (spine
/// item 1(d) "NEITHER") withdraws the entire selected set.
pub fn disposeUnsafe(a: std.mem.Allocator, plan: pb.RealizedBundles) error{OutOfMemory}!pb.RealizedBundles {
    if (plan.selected_bundles.len == 0) return plan;

    const memberships = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
    for (plan.memberships, memberships) |m, *out| out.* = .{
        .edge = m.edge,
        .source = flipUnsafe(plan.selected_bundles, m.source),
        .target = flipUnsafe(plan.selected_bundles, m.target),
    };

    var rejected = std.ArrayListUnmanaged(pb.BundleProposalId).empty;
    try rejected.appendSlice(a, plan.rejected_proposals);
    for (plan.selected_bundles) |sel| try rejected.append(a, sel.proposal);
    const rejected_slice = try rejected.toOwnedSlice(a);
    std.mem.sort(pb.BundleProposalId, rejected_slice, {}, std.sort.asc(pb.BundleProposalId));

    return .{
        .selected_bundles = &.{},
        .rejected_proposals = rejected_slice,
        .memberships = memberships,
        .terminal_ports = plan.terminal_ports,
        .discharged = plan.discharged,
        .fused = &.{},
    };
}

/// A `selected` disposition becomes `independent{ its bundle's group,
/// unsafe_component }` (the flipped group id equals the permits endpoint
/// group, so `invariants.checkDisposition` still matches); every other
/// disposition passes through unchanged.
fn flipUnsafe(selected: []const pb.SelectedBundle, disp: ?pb.MembershipDisposition) ?pb.MembershipDisposition {
    const d = disp orelse return null;
    return switch (d) {
        .independent => d,
        .selected => |jid| blk: {
            for (selected) |sel| if (sel.id == jid) break :blk .{ .independent = .{
                .candidate_bundle = sel.candidate_bundle,
                .reason = .unsafe_component,
            } };
            break :blk d;
        },
    };
}

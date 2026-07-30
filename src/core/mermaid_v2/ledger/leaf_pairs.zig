//! leaf_pairs.zig — the ledger's narrowed legality predicate for one proposed
//! union element, plus the JoinPermits endpoint lookup it reads. Pure function
//! over (JoinPermits, member edge ids); never reads geometry, never reads the
//! SemGraph.
//!
//! SCOPE (deliberately narrow): this predicate refuses exactly the three
//! things the PRODUCER of a union cannot already have ruled out —
//!   * a member edge id declared twice in the same element;
//!   * two members carrying the SAME (from,to) leaf pair;
//!   * a member whose endpoints the permits cannot resolve (no membership
//!     rank, or a side without a declared group).
//! Two-sided width (at least two distinct sources and targets) and the
//! completeness equation are structural guarantees of union CONSTRUCTION, not
//! of this file: every production element is built from a whole connected
//! permission component and is emitted only after its builder has verified
//! them. Re-deriving them here bought nothing but a second, subtly different
//! definition of "endpoint" (permits pivots vs. graph node keys) — so the
//! ledger keeps only the checks whose input it alone owns. The post-selection
//! pin in realized_production_test.zig holds a complete element's landed
//! members and keys fixed against this narrowing.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger.

const std = @import("std");
const pb = @import("../base/ledger.zig");

/// Legality of one proposed union element from JoinPermits declared edges
/// only (never geometry): no member declared twice, no two members sharing a
/// leaf pair, every member's endpoints resolvable. Duplicate DECLARED edges
/// are refused even when the underlying pair relation looks complete — the
/// divergence from `fan_lanes.isIncomplete`'s unique-pair count is deliberate
/// (plan N5): a pair set carrying duplicate declared edges is not a legal
/// element. An empty member list is refused as degenerate.
/// guarded-by: realized_test2.zig "N5: a duplicate declared edge fails leaf-pair legality"
pub fn noDuplicateLeafPairs(join_permits: pb.JoinPermits, members: []const pb.EdgeId) bool {
    if (members.len == 0) return false;
    for (members, 0..) |edge, i| {
        for (members[0..i]) |prev| if (prev == edge) return false;
        const ep = endpointsOf(join_permits, edge) orelse return false;
        for (members[0..i]) |prev| {
            const pep = endpointsOf(join_permits, prev).?;
            if (pep.from == ep.from and pep.to == ep.to) return false;
        }
    }
    return true;
}

pub const Endpoints = struct { from: pb.NodeId, to: pb.NodeId };

/// A member's endpoints derived from its JoinPermits groups: a member of a
/// two-sided element carries BOTH endpoint groups, and each group's pivot is
/// the node on that side. Null when the edge has no membership rank or when
/// either side is undeclared — the "unresolvable endpoint" refusal above.
pub fn endpointsOf(join_permits: pb.JoinPermits, edge: pb.EdgeId) ?Endpoints {
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

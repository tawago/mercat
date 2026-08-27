//! Semantic branch-permission discovery and structural validation.
//! Groups come only from original SemGraph endpoint incidence.

const std = @import("std");
const prim = @import("prim");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");

pub const BuildError = error{ OutOfMemory, InvalidSemGraph };

pub const BuildReport = struct {
    duplicate_canonical_edge_keys: u32 = 0,
    join_select_duplicate_key_blocked: bool = false,
    join_permits_skipped_clustered: bool = false,
    edgeid_scope_clustered_skipped: bool = false,
};

pub const BuildResult = struct {
    plan: pb.JoinPermits,
    report: BuildReport = .{},
};

pub const RailPreparation = struct { members: []const pb.EdgeId, deco_mixed: bool = false, style_mixed: bool = false, star_violation: bool = false };

const RailCandidate = struct { edge: sg.Edge, leaf: sg.NodeId };

/// Select one deterministic maximal star before layout can commit shared ink.
/// Decoration gets largest-class priority; style then selects the largest
/// class inside it. Invisible edges never compete with drawable classes. Ties
/// retain the class of the smallest canonical edge, independent of caller
/// order.
pub fn prepareRailMembers(a: std.mem.Allocator, graph: sg.SemGraph, direction: pb.JoinDirection, pivot: sg.NodeId, source: []const pb.EdgeId) error{OutOfMemory}!RailPreparation {
    var star_violation = false;
    var canonical: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (source) |id| {
        const edge = edgeById(graph, id) orelse {
            star_violation = true;
            continue;
        };
        if (edge.kind == .invisible) continue;
        if (containsEdge(canonical.items, id)) {
            star_violation = true;
            continue;
        }
        try canonical.append(a, id);
    }
    std.mem.sort(pb.EdgeId, canonical.items, EdgeSort{ .graph = graph }, EdgeSort.idLessThan);

    const source_check = if (canonical.items.len == 0) null else try prospectiveRailCheck(a, graph, direction, pivot, canonical.items);
    const deco_mixed = source_check != null and !source_check.?.decoration.isValid();
    const style_mixed = source_check != null and !source_check.?.style.isValid();
    if (source_check) |checked| star_violation = star_violation or !checked.bnd_s.isValid();

    var best_deco: ?sg.ArrowEnd = null;
    var best_deco_n: usize = 0;
    for (canonical.items, 0..) |_, i| {
        const candidate = railCandidate(graph, direction, pivot, canonical.items, i) orelse continue;
        const deco = pivotArrow(direction, candidate.edge);
        const n = railClassCount(graph, direction, pivot, canonical.items, deco, null);
        if (n > best_deco_n) {
            best_deco = deco;
            best_deco_n = n;
        }
    }
    const deco = best_deco orelse return .{ .deco_mixed = deco_mixed, .style_mixed = style_mixed, .star_violation = star_violation, .members = &.{} };

    var best_kind: ?sg.EdgeKind = null;
    var best_kind_n: usize = 0;
    for (canonical.items, 0..) |_, i| {
        const candidate = railCandidate(graph, direction, pivot, canonical.items, i) orelse continue;
        if (pivotArrow(direction, candidate.edge) != deco) continue;
        const n = railClassCount(graph, direction, pivot, canonical.items, deco, candidate.edge.kind);
        if (n > best_kind_n) {
            best_kind = candidate.edge.kind;
            best_kind_n = n;
        }
    }
    const kind = best_kind orelse return .{ .deco_mixed = deco_mixed, .style_mixed = style_mixed, .star_violation = star_violation, .members = &.{} };
    if (best_kind_n < 2) return .{ .deco_mixed = deco_mixed, .style_mixed = style_mixed, .star_violation = star_violation, .members = &.{} };

    var kept: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (canonical.items, 0..) |id, i| {
        const candidate = railCandidate(graph, direction, pivot, canonical.items, i) orelse continue;
        if (candidate.edge.kind != kind or pivotArrow(direction, candidate.edge) != deco) continue;
        if (railEquivalentBefore(graph, direction, pivot, canonical.items, i, deco, kind, candidate)) continue;
        try kept.append(a, id);
    }
    if (kept.items.len < 2) return .{ .deco_mixed = deco_mixed, .style_mixed = style_mixed, .star_violation = star_violation, .members = &.{} };
    const members = try kept.toOwnedSlice(a);
    if (!(try prospectiveRailCheck(a, graph, direction, pivot, members)).isValid()) return .{ .members = &.{}, .deco_mixed = deco_mixed, .style_mixed = style_mixed, .star_violation = true };
    return .{ .members = members, .deco_mixed = deco_mixed, .style_mixed = style_mixed, .star_violation = star_violation };
}

fn railCandidate(graph: sg.SemGraph, direction: pb.JoinDirection, pivot: sg.NodeId, source: []const pb.EdgeId, index: usize) ?RailCandidate {
    const id = source[index];
    for (source[0..index]) |prior| if (prior == id) return null;
    const candidate = edgeById(graph, id) orelse return null;
    if (candidate.from == candidate.to) return null;
    const member_pivot = if (direction == .out) candidate.from else candidate.to;
    const leaf = if (direction == .out) candidate.to else candidate.from;
    if (member_pivot != pivot or leaf == pivot) return null;
    return .{ .edge = candidate, .leaf = leaf };
}

fn railClassCount(graph: sg.SemGraph, direction: pb.JoinDirection, pivot: sg.NodeId, source: []const pb.EdgeId, deco: sg.ArrowEnd, kind: ?sg.EdgeKind) usize {
    var count: usize = 0;
    for (source, 0..) |_, i| {
        const candidate = railCandidate(graph, direction, pivot, source, i) orelse continue;
        if (pivotArrow(direction, candidate.edge) != deco or (kind != null and candidate.edge.kind != kind.?)) continue;
        if (!railEquivalentBefore(graph, direction, pivot, source, i, deco, kind, candidate)) count += 1;
    }
    return count;
}

fn railEquivalentBefore(graph: sg.SemGraph, direction: pb.JoinDirection, pivot: sg.NodeId, source: []const pb.EdgeId, index: usize, deco: sg.ArrowEnd, kind: ?sg.EdgeKind, candidate: RailCandidate) bool {
    for (source[0..index], 0..) |_, i| {
        const prior = railCandidate(graph, direction, pivot, source, i) orelse continue;
        if (pivotArrow(direction, prior.edge) != deco or (kind != null and prior.edge.kind != kind.?)) continue;
        if (prior.edge.id == candidate.edge.id or prior.leaf == candidate.leaf) return true;
    }
    return false;
}

fn prospectiveRailCheck(a: std.mem.Allocator, graph: sg.SemGraph, direction: pb.JoinDirection, pivot: sg.NodeId, ids: []const pb.EdgeId) error{OutOfMemory}!pb.RailLicenceCheck {
    const members = try a.alloc(pb.RailLicenceMember, ids.len);
    const pivot_end: pb.Endpoint = if (direction == .out) .source else .target;
    for (ids, members) |id, *member| {
        const candidate = edgeById(graph, id).?;
        member.* = .{
            .edge = id,
            .endpoints = .{ candidate.from, candidate.to },
            .arrows = .{ mapArrow(candidate.arrow_from), mapArrow(candidate.arrow_to) },
            .kind = candidate.kind,
            .pivot_end = pivot_end,
        };
    }
    return pb.checkRailLicence(.{
        .id = 1,
        .polarity = if (direction == .out) .out else .in,
        .pivot = pivot,
        .members = members,
    });
}

fn pivotArrow(direction: pb.JoinDirection, candidate: sg.Edge) sg.ArrowEnd {
    return if (direction == .out) candidate.arrow_from else candidate.arrow_to;
}

fn mapArrow(arrow: sg.ArrowEnd) prim.ArrowKind {
    return @enumFromInt(@intFromEnum(arrow));
}

/// Build the one render-wide permission plan. Policy is explicit because only
/// the composition root may originate it.
pub fn build(
    allocator: std.mem.Allocator,
    graph: sg.SemGraph,
    policy: pb.JoinPolicy,
) BuildError!BuildResult {
    // Child recursion pieces may look cluster-free after IDs were localized;
    // only the original graph's cluster array opens or closes this gate.
    // guarded-by: permits_test.zig "V-D-EDGE-ID-02: clustered graph returns empty plan and both skip markers"
    if (graph.clusters.len != 0) return .{
        .plan = .{ .policy = policy, .scope = .skipped_clustered },
        .report = .{
            .join_permits_skipped_clustered = true,
            .edgeid_scope_clustered_skipped = true,
        },
    };

    try verifyNodes(graph);

    const Incidence = struct {
        pivot: sg.NodeId,
        outgoing: std.ArrayListUnmanaged(pb.EdgeId) = .empty,
        incoming: std.ArrayListUnmanaged(pb.EdgeId) = .empty,
    };
    const incidence = try allocator.alloc(Incidence, graph.nodes.len);
    for (graph.nodes, incidence) |node, *item| item.* = .{ .pivot = node.id };

    // guarded-by: permits_test.zig "V-D-EDGE-ID-05: edge-array permutation preserves canonical plan bytes"
    for (graph.edges, 0..) |edge, i| {
        const from = nodeIndex(graph, edge.from) orelse return error.InvalidSemGraph;
        const to = nodeIndex(graph, edge.to) orelse return error.InvalidSemGraph;
        for (graph.edges[0..i]) |prior| if (prior.id == edge.id) return error.InvalidSemGraph;
        // A self-loop is not a plain directed edge between two distinct nodes, so it is
        // never an endpoint-incidence join-group member (its source==target makes fan-in/
        // fan-out classification degenerate). Excluded here, before the carve-out predicate;
        // it still takes a (null,null) membership below and still renders its own lollipop.
        // guarded-by: permits_test.zig "V-D-JOIN-SELECT-14: self-loop excluded from fan-in group leaves residual member independent"
        // D-JOIN-SELECT self-loop join exclusion (2026-07-18) / V-D-JOIN-SELECT-14.
        if (edge.from == edge.to) continue;
        try incidence[from].outgoing.append(allocator, edge.id);
        try incidence[to].incoming.append(allocator, edge.id);
    }

    var groups: std.ArrayListUnmanaged(pb.JoinGroup) = .empty;
    for (incidence) |*item| {
        try appendGroup(allocator, graph, &groups, .out, item.pivot, &item.outgoing);
        try appendGroup(allocator, graph, &groups, .in, item.pivot, &item.incoming);
    }
    std.mem.sort(pb.JoinGroup, groups.items, GroupSort{ .graph = graph }, GroupSort.lessThan);
    for (groups.items, 0..) |*group, i| group.id = @intCast(i);

    const memberships = try allocator.alloc(pb.JoinMembership, graph.edges.len);
    for (graph.edges, memberships) |edge, *membership| membership.* = .{
        .edge = edge.id,
        .source_group = membershipGroup(groups.items, edge.id, .out),
        .target_group = membershipGroup(groups.items, edge.id, .in),
    };
    std.mem.sort(pb.JoinMembership, memberships, EdgeSort{ .graph = graph }, EdgeSort.membershipLessThan);

    const duplicate_count = countDuplicateCanonicalKeys(graph, memberships);
    return .{
        .plan = .{
            .policy = policy,
            .groups = try groups.toOwnedSlice(allocator),
            .memberships = memberships,
        },
        .report = .{
            .duplicate_canonical_edge_keys = duplicate_count,
            .join_select_duplicate_key_blocked = duplicate_count != 0,
        },
    };
}

/// Piece-scoped licence discovery: the same endpoint-incidence discovery as
/// `build`, run on one CLUSTER-FREE recursion piece of a clustered original
/// and keyed by ORIGIN (root-graph) edge ids, so piece plans can merge across
/// the stitch. Edges born synthetic (origin == SENTINEL, e.g. placement
/// edges) never enter a bundle and take no membership row.
pub fn buildPiece(allocator: std.mem.Allocator, graph: sg.SemGraph) BuildError!BuildResult {
    std.debug.assert(graph.clusters.len == 0);
    var edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    for (graph.edges) |e| {
        if (e.origin == sg.SENTINEL) continue;
        var copy = e;
        copy.id = e.origin;
        try edges.append(allocator, copy);
    }
    var shadow = graph;
    shadow.edges = edges.items;
    var result = try build(allocator, shadow, .joined);
    result.plan.scope = .piece;
    return result;
}

fn verifyNodes(graph: sg.SemGraph) BuildError!void {
    for (graph.nodes, 0..) |node, i| {
        for (graph.nodes[0..i]) |prior| {
            if (prior.id == node.id or std.mem.eql(u8, prior.raw_id, node.raw_id))
                return error.InvalidSemGraph;
        }
    }
}

fn appendGroup(
    allocator: std.mem.Allocator,
    graph: sg.SemGraph,
    groups: *std.ArrayListUnmanaged(pb.JoinGroup),
    direction: pb.JoinDirection,
    pivot: sg.NodeId,
    members: *std.ArrayListUnmanaged(pb.EdgeId),
) BuildError!void {
    if (members.items.len < 2) return;
    std.mem.sort(pb.EdgeId, members.items, EdgeSort{ .graph = graph }, EdgeSort.idLessThan);
    try groups.append(allocator, .{
        .id = 0,
        .direction = direction,
        .pivot = pivot,
        .members = try members.toOwnedSlice(allocator),
    });
}

const GroupSort = struct {
    graph: sg.SemGraph,

    fn lessThan(self: @This(), a: pb.JoinGroup, b: pb.JoinGroup) bool {
        const ad: u1 = if (a.direction == .out) 0 else 1;
        const bd: u1 = if (b.direction == .out) 0 else 1;
        if (ad != bd) return ad < bd;
        const ak = nodeById(self.graph, a.pivot).?.raw_id;
        const bk = nodeById(self.graph, b.pivot).?.raw_id;
        return pb.nodeKeyOrder(ak, bk) == .lt;
    }
};

const EdgeSort = struct {
    graph: sg.SemGraph,

    fn idLessThan(self: @This(), a: pb.EdgeId, b: pb.EdgeId) bool {
        return self.orderIds(a, b) == .lt;
    }

    fn membershipLessThan(self: @This(), a: pb.JoinMembership, b: pb.JoinMembership) bool {
        return self.orderIds(a.edge, b.edge) == .lt;
    }

    fn orderIds(self: @This(), a: pb.EdgeId, b: pb.EdgeId) std.math.Order {
        const a_edge = edgeById(self.graph, a) orelse return std.math.order(a, b);
        const b_edge = edgeById(self.graph, b) orelse return std.math.order(a, b);
        if (nodeById(self.graph, a_edge.from) == null or nodeById(self.graph, a_edge.to) == null or
            nodeById(self.graph, b_edge.from) == null or nodeById(self.graph, b_edge.to) == null)
            return std.math.order(a, b);
        const order = pb.edgeKeyOrder(
            edgeKey(self.graph, a_edge),
            edgeKey(self.graph, b_edge),
        );
        if (order != .eq) return order;
        return std.math.order(a, b);
    }
};

fn edgeKey(graph: sg.SemGraph, edge: sg.Edge) pb.EdgeKey {
    return .{
        .from = nodeById(graph, edge.from).?.raw_id,
        .to = nodeById(graph, edge.to).?.raw_id,
        .kind = pb.edgeKindOrdinal(edge.kind),
        .arrow_from = pb.arrowEndOrdinal(edge.arrow_from),
        .arrow_to = pb.arrowEndOrdinal(edge.arrow_to),
        .label = edge.label,
    };
}

fn edgeOrder(graph: sg.SemGraph, a: sg.Edge, b: sg.Edge) std.math.Order {
    return pb.edgeKeyOrder(edgeKey(graph, a), edgeKey(graph, b));
}

fn nodeById(graph: sg.SemGraph, id: sg.NodeId) ?sg.Node {
    for (graph.nodes) |node| if (node.id == id) return node;
    return null;
}

fn nodeIndex(graph: sg.SemGraph, id: sg.NodeId) ?usize {
    for (graph.nodes, 0..) |node, i| if (node.id == id) return i;
    return null;
}

fn edgeById(graph: sg.SemGraph, id: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| if (edge.id == id) return edge;
    return null;
}

fn membershipGroup(groups: []const pb.JoinGroup, edge: pb.EdgeId, direction: pb.JoinDirection) ?pb.JoinGroupId {
    for (groups) |group| {
        if (group.direction == direction and containsEdge(group.members, edge)) return group.id;
    }
    return null;
}

fn containsEdge(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |candidate| if (candidate == edge) return true;
    return false;
}

fn countDuplicateCanonicalKeys(graph: sg.SemGraph, memberships: []const pb.JoinMembership) u32 {
    if (memberships.len < 2) return 0;
    var count: u32 = 0;
    for (memberships[1..], 1..) |membership, i| {
        const a = edgeById(graph, memberships[i - 1].edge).?;
        const b = edgeById(graph, membership.edge).?;
        if (edgeOrder(graph, a, b) == .eq) count += 1;
    }
    return count;
}

pub const ValidationTag = enum {
    policy_not_joined,
    group_id_not_canonical,
    groups_not_canonical,
    group_too_small,
    group_duplicate_member,
    pivot_missing,
    member_edge_missing,
    member_pivot_mismatch,
    members_not_canonical,
    membership_edge_missing,
    membership_duplicate_edge,
    membership_missing_edge,
    memberships_not_canonical,
    membership_group_missing,
    membership_wrong_direction,
    membership_group_lacks_edge,
    group_membership_missing,
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

/// Validate plan structure without logging, mutation, or disposition policy.
pub fn validate(allocator: std.mem.Allocator, graph: sg.SemGraph, plan: pb.JoinPermits) error{OutOfMemory}!ValidationReport {
    var out: std.ArrayListUnmanaged(Finding) = .empty;

    if (plan.policy != .joined) try add(&out, allocator, .policy_not_joined, null, null);

    for (plan.groups, 0..) |group, i| {
        if (group.id != i) try add(&out, allocator, .group_id_not_canonical, group.id, null);
        if (i > 0 and !GroupSort.lessThan(.{ .graph = graph }, plan.groups[i - 1], group))
            try add(&out, allocator, .groups_not_canonical, group.id, null);
        if (group.members.len < 2) try add(&out, allocator, .group_too_small, group.id, null);
        if (nodeById(graph, group.pivot) == null) try add(&out, allocator, .pivot_missing, group.id, null);
        for (group.members, 0..) |edge_id, j| {
            const edge = edgeById(graph, edge_id) orelse {
                try add(&out, allocator, .member_edge_missing, group.id, edge_id);
                continue;
            };
            const pivot_matches = if (group.direction == .out) edge.from == group.pivot else edge.to == group.pivot;
            if (!pivot_matches) try add(&out, allocator, .member_pivot_mismatch, group.id, edge_id);
            for (group.members[0..j]) |prior| if (prior == edge_id)
                try add(&out, allocator, .group_duplicate_member, group.id, edge_id);
            if (j > 0 and EdgeSort.idLessThan(.{ .graph = graph }, edge_id, group.members[j - 1]))
                try add(&out, allocator, .members_not_canonical, group.id, edge_id);
            const membership = membershipByEdge(plan.memberships, edge_id);
            const linked = if (group.direction == .out)
                membership != null and membership.?.source_group == group.id
            else
                membership != null and membership.?.target_group == group.id;
            if (!linked) try add(&out, allocator, .group_membership_missing, group.id, edge_id);
        }
    }

    for (plan.memberships, 0..) |membership, i| {
        if (edgeById(graph, membership.edge) == null)
            try add(&out, allocator, .membership_edge_missing, null, membership.edge);
        for (plan.memberships[0..i]) |prior| if (prior.edge == membership.edge)
            try add(&out, allocator, .membership_duplicate_edge, null, membership.edge);
        if (i > 0 and edgeById(graph, membership.edge) != null and edgeById(graph, plan.memberships[i - 1].edge) != null and
            EdgeSort.membershipLessThan(.{ .graph = graph }, membership, plan.memberships[i - 1]))
            try add(&out, allocator, .memberships_not_canonical, null, membership.edge);
        try validateLink(&out, allocator, graph, plan.groups, membership, .out, membership.source_group);
        try validateLink(&out, allocator, graph, plan.groups, membership, .in, membership.target_group);
    }
    for (graph.edges) |edge| if (membershipByEdge(plan.memberships, edge.id) == null)
        try add(&out, allocator, .membership_missing_edge, null, edge.id);

    return .{ .findings = try out.toOwnedSlice(allocator) };
}

fn validateLink(
    out: *std.ArrayListUnmanaged(Finding),
    allocator: std.mem.Allocator,
    graph: sg.SemGraph,
    groups: []const pb.JoinGroup,
    membership: pb.JoinMembership,
    direction: pb.JoinDirection,
    group_id: ?pb.JoinGroupId,
) error{OutOfMemory}!void {
    const id = group_id orelse return;
    const group = groupById(groups, id) orelse {
        try add(out, allocator, .membership_group_missing, id, membership.edge);
        return;
    };
    if (group.direction != direction) try add(out, allocator, .membership_wrong_direction, id, membership.edge);
    if (!containsEdge(group.members, membership.edge))
        try add(out, allocator, .membership_group_lacks_edge, id, membership.edge);
    const edge = edgeById(graph, membership.edge) orelse return;
    const pivot_matches = if (direction == .out) edge.from == group.pivot else edge.to == group.pivot;
    if (!pivot_matches) try add(out, allocator, .member_pivot_mismatch, id, membership.edge);
}

fn groupById(groups: []const pb.JoinGroup, id: pb.JoinGroupId) ?pb.JoinGroup {
    for (groups) |group| if (group.id == id) return group;
    return null;
}

fn membershipByEdge(memberships: []const pb.JoinMembership, edge: pb.EdgeId) ?pb.JoinMembership {
    for (memberships) |membership| if (membership.edge == edge) return membership;
    return null;
}

fn add(
    out: *std.ArrayListUnmanaged(Finding),
    allocator: std.mem.Allocator,
    tag: ValidationTag,
    group: ?pb.JoinGroupId,
    edge: ?pb.EdgeId,
) error{OutOfMemory}!void {
    try out.append(allocator, .{ .tag = tag, .group = group, .edge = edge });
}

pub const EdgeIdentity = union(enum) {
    original: prim.EdgeId,
    unqualified_local: prim.EdgeId,
};

pub const MembershipLookup = struct {
    membership: ?pb.JoinMembership = null,
    diagnostic: ?pb.DiagnosticTag = null,
};

/// Membership lookup accepts an explicit identity domain. A local ID without
/// an original-edge mapping can never alias an original membership.
pub fn lookupMembership(plan: pb.JoinPermits, identity: EdgeIdentity) MembershipLookup {
    return switch (identity) {
        .original => |id| .{ .membership = membershipByEdge(plan.memberships, id) },
        .unqualified_local => .{ .diagnostic = .edgeid_unqualified_local_lookup },
    };
}

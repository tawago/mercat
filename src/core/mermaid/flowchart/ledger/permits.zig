const std = @import("std");
const prim = @import("prim");
const pb = @import("../base/ledger.zig");
const tie_break = @import("../base/tie_break.zig");
const sg = @import("../sem_graph.zig");

pub const BuildError = error{ OutOfMemory, InvalidSemGraph };

pub const BuildReport = struct {
    bundle_permits_skipped_clustered: bool = false,
};

pub const BuildResult = struct {
    plan: pb.BundlePermits,
    report: BuildReport = .{},
};

/// The star licence's rail among `source`, all meeting `pivot` at the end `direction` names: the
/// most common decoration at the pivot, then the most common kind, one member per divergent node
/// (the first in canonical order). It stands only when every member blocks or none has a
/// directional end; empty when fewer than two members remain.
pub fn prepareRailMembers(a: std.mem.Allocator, graph: sg.SemGraph, direction: pb.BundleDirection, pivot: sg.NodeId, source: []const pb.EdgeId) error{OutOfMemory}![]const pb.EdgeId {
    var pool: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (source) |id| {
        const edge = graph.edgeById(id) orelse continue;
        if (edge.kind == .invisible or edge.from == edge.to or pivotOf(direction, edge) != pivot) continue;
        if (!pb.containsEdge(pool.items, id)) try pool.append(a, id);
    }
    std.mem.sort(pb.EdgeId, pool.items, EdgeSort{ .graph = graph }, EdgeSort.idLessThan);

    var deco: ?sg.ArrowEnd = null;
    var widest: usize = 0;
    for (pool.items) |id| {
        const end = pivotArrow(direction, graph.edgeById(id).?);
        const width = (try firstPerLeaf(a, graph, direction, pool.items, end, null)).len;
        if (width > widest) {
            deco = end;
            widest = width;
        }
    }
    var rail: []const pb.EdgeId = &.{};
    for (pool.items) |id| {
        const edge = graph.edgeById(id).?;
        if (pivotArrow(direction, edge) != deco) continue;
        const kept = try firstPerLeaf(a, graph, direction, pool.items, deco, edge.kind);
        if (kept.len > rail.len) rail = kept;
    }
    if (rail.len < 2) return &.{};
    var all_free = true;
    var all_block = true;
    for (rail) |id| {
        const edge = graph.edgeById(id).?;
        all_free = all_free and sg.arrowFree(edge);
        all_block = all_block and prim.memberBlocks(edge.arrow_from, edge.arrow_to, edge.stands_for);
    }
    return if (all_free or all_block) rail else &.{};
}

fn firstPerLeaf(a: std.mem.Allocator, graph: sg.SemGraph, direction: pb.BundleDirection, pool: []const pb.EdgeId, deco: ?sg.ArrowEnd, kind: ?sg.EdgeKind) error{OutOfMemory}![]const pb.EdgeId {
    var out: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    var leaves: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    defer leaves.deinit(a);
    for (pool) |id| {
        const edge = graph.edgeById(id).?;
        if (pivotArrow(direction, edge) != deco or (kind != null and edge.kind != kind.?)) continue;
        const leaf = if (direction == .out) edge.to else edge.from;
        if (std.mem.indexOfScalar(sg.NodeId, leaves.items, leaf) != null) continue;
        try leaves.append(a, leaf);
        try out.append(a, id);
    }
    return out.toOwnedSlice(a);
}

fn pivotOf(direction: pb.BundleDirection, edge: sg.Edge) sg.NodeId {
    return if (direction == .out) edge.from else edge.to;
}

fn pivotArrow(direction: pb.BundleDirection, edge: sg.Edge) sg.ArrowEnd {
    return if (direction == .out) edge.arrow_from else edge.arrow_to;
}

pub fn build(
    allocator: std.mem.Allocator,
    graph: sg.SemGraph,
    policy: pb.BundlePolicy,
) BuildError!BuildResult {
    if (graph.clusters.len != 0) return .{
        .plan = .{ .policy = policy, .scope = .skipped_clustered },
        .report = .{ .bundle_permits_skipped_clustered = true },
    };

    try verifyNodes(graph);

    const Incidence = struct {
        pivot: sg.NodeId,
        outgoing: std.ArrayListUnmanaged(pb.EdgeId) = .empty,
        incoming: std.ArrayListUnmanaged(pb.EdgeId) = .empty,
    };
    const incidence = try allocator.alloc(Incidence, graph.nodes.len);
    for (graph.nodes, incidence) |node, *item| item.* = .{ .pivot = node.id };

    for (graph.edges, 0..) |edge, i| {
        const from = nodeIndex(graph, edge.from) orelse return error.InvalidSemGraph;
        const to = nodeIndex(graph, edge.to) orelse return error.InvalidSemGraph;
        for (graph.edges[0..i]) |prior| if (prior.id == edge.id) return error.InvalidSemGraph;
        if (edge.from == edge.to) continue;
        try incidence[from].outgoing.append(allocator, edge.id);
        try incidence[to].incoming.append(allocator, edge.id);
    }

    var groups: std.ArrayListUnmanaged(pb.CandidateBundle) = .empty;
    for (incidence) |*item| {
        try appendGroup(allocator, graph, &groups, .out, item.pivot, &item.outgoing);
        try appendGroup(allocator, graph, &groups, .in, item.pivot, &item.incoming);
    }
    std.mem.sort(pb.CandidateBundle, groups.items, GroupSort{ .graph = graph }, GroupSort.lessThan);
    for (groups.items, 0..) |*group, i| group.id = @intCast(i);

    const memberships = try allocator.alloc(pb.BundleMembership, graph.edges.len);
    for (graph.edges, memberships) |edge, *membership| membership.* = .{
        .edge = edge.id,
        .source_group = membershipGroup(groups.items, edge.id, .out),
        .target_group = membershipGroup(groups.items, edge.id, .in),
    };
    std.mem.sort(pb.BundleMembership, memberships, EdgeSort{ .graph = graph }, EdgeSort.membershipLessThan);

    return .{ .plan = .{
        .policy = policy,
        .groups = try groups.toOwnedSlice(allocator),
        .memberships = memberships,
    } };
}

pub fn buildPiece(allocator: std.mem.Allocator, graph: sg.SemGraph) BuildError!BuildResult {
    std.debug.assert(graph.clusters.len == 0);
    var edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    for (graph.edges) |e| {
        if (e.origin == sg.SENTINEL) continue;
        try edges.append(allocator, e);
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
    groups: *std.ArrayListUnmanaged(pb.CandidateBundle),
    direction: pb.BundleDirection,
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

    fn lessThan(self: @This(), a: pb.CandidateBundle, b: pb.CandidateBundle) bool {
        const ad: u1 = if (a.direction == .out) 0 else 1;
        const bd: u1 = if (b.direction == .out) 0 else 1;
        if (ad != bd) return ad < bd;
        const ak = self.graph.nodeById(a.pivot).?.raw_id;
        const bk = self.graph.nodeById(b.pivot).?.raw_id;
        return tie_break.nodeKeyOrder(ak, bk) == .lt;
    }
};

const EdgeSort = struct {
    graph: sg.SemGraph,

    fn idLessThan(self: @This(), a: pb.EdgeId, b: pb.EdgeId) bool {
        return self.orderIds(a, b) == .lt;
    }

    fn membershipLessThan(self: @This(), a: pb.BundleMembership, b: pb.BundleMembership) bool {
        return self.orderIds(a.edge, b.edge) == .lt;
    }

    fn orderIds(self: @This(), a: pb.EdgeId, b: pb.EdgeId) std.math.Order {
        const a_edge = self.graph.edgeById(a) orelse return std.math.order(a, b);
        const b_edge = self.graph.edgeById(b) orelse return std.math.order(a, b);
        if (self.graph.nodeById(a_edge.from) == null or self.graph.nodeById(a_edge.to) == null or
            self.graph.nodeById(b_edge.from) == null or self.graph.nodeById(b_edge.to) == null)
            return std.math.order(a, b);
        const order = tie_break.edgeKeyOrder(
            edgeKey(self.graph, a_edge),
            edgeKey(self.graph, b_edge),
        );
        if (order != .eq) return order;
        return std.math.order(a, b);
    }
};

fn edgeKey(graph: sg.SemGraph, edge: sg.Edge) tie_break.EdgeKey {
    return .{
        .from = graph.nodeById(edge.from).?.raw_id,
        .to = graph.nodeById(edge.to).?.raw_id,
        .kind = tie_break.edgeKindOrdinal(edge.kind),
        .arrow_from = tie_break.arrowEndOrdinal(edge.arrow_from),
        .arrow_to = tie_break.arrowEndOrdinal(edge.arrow_to),
        .label = edge.label,
    };
}

fn nodeIndex(graph: sg.SemGraph, id: sg.NodeId) ?usize {
    for (graph.nodes, 0..) |node, i| if (node.id == id) return i;
    return null;
}

fn membershipGroup(groups: []const pb.CandidateBundle, edge: pb.EdgeId, direction: pb.BundleDirection) ?pb.CandidateBundleId {
    for (groups) |group| {
        if (group.direction == direction and pb.containsEdge(group.members, edge)) return group.id;
    }
    return null;
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
    group: ?pb.CandidateBundleId = null,
    edge: ?pb.EdgeId = null,
};

pub const ValidationReport = struct {
    findings: []const Finding,

    pub fn valid(self: ValidationReport) bool {
        return self.findings.len == 0;
    }
};

pub fn validate(allocator: std.mem.Allocator, graph: sg.SemGraph, plan: pb.BundlePermits) error{OutOfMemory}!ValidationReport {
    var out: std.ArrayListUnmanaged(Finding) = .empty;

    if (plan.policy != .joined) try add(&out, allocator, .policy_not_joined, null, null);

    for (plan.groups, 0..) |group, i| {
        if (group.id != i) try add(&out, allocator, .group_id_not_canonical, group.id, null);
        if (i > 0 and !GroupSort.lessThan(.{ .graph = graph }, plan.groups[i - 1], group))
            try add(&out, allocator, .groups_not_canonical, group.id, null);
        if (group.members.len < 2) try add(&out, allocator, .group_too_small, group.id, null);
        if (graph.nodeById(group.pivot) == null) try add(&out, allocator, .pivot_missing, group.id, null);
        for (group.members, 0..) |edge_id, j| {
            const edge = graph.edgeById(edge_id) orelse {
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
        if (graph.edgeById(membership.edge) == null)
            try add(&out, allocator, .membership_edge_missing, null, membership.edge);
        for (plan.memberships[0..i]) |prior| if (prior.edge == membership.edge)
            try add(&out, allocator, .membership_duplicate_edge, null, membership.edge);
        if (i > 0 and graph.edgeById(membership.edge) != null and graph.edgeById(plan.memberships[i - 1].edge) != null and
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
    groups: []const pb.CandidateBundle,
    membership: pb.BundleMembership,
    direction: pb.BundleDirection,
    group_id: ?pb.CandidateBundleId,
) error{OutOfMemory}!void {
    const id = group_id orelse return;
    const group = groupById(groups, id) orelse {
        try add(out, allocator, .membership_group_missing, id, membership.edge);
        return;
    };
    if (group.direction != direction) try add(out, allocator, .membership_wrong_direction, id, membership.edge);
    if (!pb.containsEdge(group.members, membership.edge))
        try add(out, allocator, .membership_group_lacks_edge, id, membership.edge);
    const edge = graph.edgeById(membership.edge) orelse return;
    const pivot_matches = if (direction == .out) edge.from == group.pivot else edge.to == group.pivot;
    if (!pivot_matches) try add(out, allocator, .member_pivot_mismatch, id, membership.edge);
}

fn groupById(groups: []const pb.CandidateBundle, id: pb.CandidateBundleId) ?pb.CandidateBundle {
    for (groups) |group| if (group.id == id) return group;
    return null;
}

fn membershipByEdge(memberships: []const pb.BundleMembership, edge: pb.EdgeId) ?pb.BundleMembership {
    for (memberships) |membership| if (membership.edge == edge) return membership;
    return null;
}

fn add(
    out: *std.ArrayListUnmanaged(Finding),
    allocator: std.mem.Allocator,
    tag: ValidationTag,
    group: ?pb.CandidateBundleId,
    edge: ?pb.EdgeId,
) error{OutOfMemory}!void {
    try out.append(allocator, .{ .tag = tag, .group = group, .edge = edge });
}

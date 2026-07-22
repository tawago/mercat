//! Pre-sizing realization commitment for the flat layout path.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");

pub fn build(a: std.mem.Allocator, graph: sg.SemGraph, permits: ?*const pb.JoinPermits, flat: bool, reversed_edges: []const pb.EdgeId, disable: bool) error{OutOfMemory}!pb.RealizedJoins {
    if (!flat or permits == null) return .{};
    const plan = permits.?.*;
    // P2v Step 8 (D-DISPOSITION item 9(b)): the forced all-independent terminal
    // layout. Every grouped endpoint takes an independent(not_selected)
    // disposition, so no trunk is realized and no mesh union is provenanced —
    // fan_busbar.resolve then declines (memberships present, none selected),
    // leaving per-edge D-PORT ports. The always-expressible conservative
    // baseline (TSD §6.6 step 2), materialized as layout geometry.
    if (disable) {
        const memberships = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
        for (plan.memberships, memberships) |m, *out| out.* = .{
            .edge = m.edge,
            .source = independentOf(m.source_group),
            .target = independentOf(m.target_group),
        };
        return .{ .memberships = memberships };
    }
    // Complete-mesh provenance is needed BEFORE selection now: the arrival
    // re-merge preference (D-PORT.md, 2026-07-18) exempts mesh members, so
    // the unions must be known when the fan-in overlap relaxation is decided.
    const unions = try meshUnions(a, graph, plan);
    const selected_group = try a.alloc(?pb.RealizedJoinId, plan.groups.len);
    @memset(selected_group, null);
    var selected: std.ArrayListUnmanaged(pb.SelectedJoin) = .empty;

    for (plan.groups, 0..) |group, gi| {
        // A fan-IN group whose arrival is a legal pure fan-in stays eligible
        // despite an overlap (arrival re-merge preference); the shared
        // conflict is still retained by the memberships pass below. Fan-OUT
        // groups keep the strict overlap exclusion.
        const overlap = overlaps(plan.groups, gi);
        const remerge = overlap and pb.fanInReMergeEligible(plan.groups, gi, unions);
        // Forward-subset composition (owner ruling 2026-07-18): a fan-IN group
        // blocked ONLY by a layout-reversed member composes its FORWARD subset
        // (>=2 members) as one merged trunk; the reversed member(s) take
        // independent side entries. `eff` drops the reversed members so every
        // gate below (style, duplicate, floor) judges exactly the trunk
        // members — keeping join_commit and realized.realize in agreement (N6).
        // Fan-out and non-reversed groups keep the whole member set unchanged.
        const reversed = containsReversed(group, reversed_edges);
        const eff = if (reversed and group.direction == .in)
            try forwardSubset(a, group.members, reversed_edges)
        else
            group.members;
        const eff_group: pb.JoinGroup = .{ .id = group.id, .direction = group.direction, .pivot = group.pivot, .members = eff };
        if ((overlap and !remerge) or !styleCompatible(graph, eff_group) or hasDuplicateKey(graph, eff_group) or
            containsReversed(eff_group, reversed_edges) or eff.len < 2) continue;
        const jid: pb.RealizedJoinId = @intCast(selected.items.len);
        selected_group[gi] = jid;
        try selected.append(a, .{
            .id = jid,
            .proposal = @intCast(gi),
            .permission_group = group.id,
            .members = try a.dupe(pb.EdgeId, eff),
        });
    }

    const memberships = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
    for (plan.memberships, memberships) |m, *out| {
        if (inMesh(unions, m.edge)) {
            out.* = .{ .edge = m.edge, .source = null, .target = null };
            continue;
        }
        out.* = .{
            .edge = m.edge,
            .source = disposition(graph, plan.groups, selected_group, selected.items, m.source_group, reversed_edges, m.edge),
            .target = disposition(graph, plan.groups, selected_group, selected.items, m.target_group, reversed_edges, m.edge),
        };
    }
    return .{
        .selected_joins = try selected.toOwnedSlice(a),
        .memberships = memberships,
        .mesh_unions = unions,
    };
}

/// An all-independent(not_selected) disposition for a grouped endpoint (null
/// when the endpoint has no ≥2-member group). The terminal-layout builder.
fn independentOf(group: ?pb.JoinGroupId) ?pb.MembershipDisposition {
    const gid = group orelse return null;
    return .{ .independent = .{ .permission_group = gid, .reason = .not_selected } };
}

fn containsReversed(group: pb.JoinGroup, reversed_edges: []const pb.EdgeId) bool {
    for (group.members) |member| for (reversed_edges) |reversed| {
        if (member == reversed) return true;
    };
    return false;
}

/// The group's forward (non-layout-reversed) members, in canonical member
/// order (deterministic under edge-array permutation because `members` is
/// already canonical). Used as the trunk-eligible subset for a fan-IN group.
fn forwardSubset(a: std.mem.Allocator, members: []const pb.EdgeId, reversed_edges: []const pb.EdgeId) error{OutOfMemory}![]const pb.EdgeId {
    var out: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (members) |m| {
        var rev = false;
        for (reversed_edges) |r| if (r == m) {
            rev = true;
        };
        if (!rev) try out.append(a, m);
    }
    return out.toOwnedSlice(a);
}

fn disposition(graph: sg.SemGraph, groups: []const pb.JoinGroup, selected_group: []const ?pb.RealizedJoinId, selected_joins: []const pb.SelectedJoin, id: ?pb.JoinGroupId, reversed_edges: []const pb.EdgeId, edge: pb.EdgeId) ?pb.MembershipDisposition {
    const gid = id orelse return null;
    for (groups, 0..) |g, i| if (g.id == gid) {
        if (selected_group[i]) |jid| {
            // A committed trunk may carry only the forward subset; a reversed
            // member excluded from it takes an independent side entry.
            for (selected_joins) |sj| if (sj.id == jid) {
                for (sj.members) |mem| if (mem == edge) return .{ .selected = jid };
            };
            return .{ .independent = .{ .permission_group = gid, .reason = .not_selected } };
        }
        if (containsReversed(g, reversed_edges) and !overlaps(groups, i) and styleCompatible(graph, g) and !hasDuplicateKey(graph, g)) return null;
        return .{ .independent = .{ .permission_group = gid, .reason = if (overlaps(groups, i)) .overlap_conflict else .not_selected } };
    };
    return null;
}

fn overlaps(groups: []const pb.JoinGroup, idx: usize) bool {
    for (groups, 0..) |other, oi| {
        if (oi == idx) continue;
        for (groups[idx].members) |edge| for (other.members) |candidate| {
            if (edge == candidate) return true;
        };
    }
    return false;
}

fn styleCompatible(graph: sg.SemGraph, group: pb.JoinGroup) bool {
    var first: ?sg.Edge = null;
    for (group.members) |id| {
        const edge = edgeById(graph, id) orelse return false;
        if (edge.kind == .invisible) return false;
        if (first) |f| {
            if (edge.kind != f.kind) return false;
            const arrow = if (group.direction == .out) edge.arrow_from else edge.arrow_to;
            const first_arrow = if (group.direction == .out) f.arrow_from else f.arrow_to;
            if (arrow != first_arrow) return false;
        } else first = edge;
    }
    return first != null;
}

fn hasDuplicateKey(graph: sg.SemGraph, group: pb.JoinGroup) bool {
    for (group.members, 0..) |id, i| {
        const edge = edgeById(graph, id) orelse return true;
        for (group.members[0..i]) |prev_id| {
            const prev = edgeById(graph, prev_id) orelse return true;
            if (edge.from == prev.from and edge.to == prev.to and edge.kind == prev.kind and
                edge.arrow_from == prev.arrow_from and edge.arrow_to == prev.arrow_to and labelsEqual(edge.label, prev.label)) return true;
        }
    }
    return false;
}

fn meshUnions(a: std.mem.Allocator, graph: sg.SemGraph, plan: pb.JoinPermits) error{OutOfMemory}![]const pb.MeshUnion {
    const seen = try a.alloc(bool, plan.groups.len);
    @memset(seen, false);
    var result: std.ArrayListUnmanaged(pb.MeshUnion) = .empty;
    for (plan.groups, 0..) |_, start| {
        if (seen[start]) continue;
        var queue: std.ArrayListUnmanaged(usize) = .empty;
        var members: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        try queue.append(a, start);
        seen[start] = true;
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const gi = queue.items[qi];
            for (plan.groups[gi].members) |edge| try appendUnique(pb.EdgeId, a, &members, edge);
            for (plan.groups, 0..) |other, oi| {
                if (seen[oi] or !groupsShare(plan.groups[gi], other)) continue;
                seen[oi] = true;
                try queue.append(a, oi);
            }
        }
        if (try completeUnion(a, graph, members.items)) |sets| {
            try result.append(a, .{
                .id = @intCast(result.items.len),
                .members = try a.dupe(pb.EdgeId, members.items),
                .source_keys = sets.sources,
                .target_keys = sets.targets,
            });
        }
    }
    return result.toOwnedSlice(a);
}

const KeySets = struct { sources: []const []const u8, targets: []const []const u8 };

fn completeUnion(a: std.mem.Allocator, graph: sg.SemGraph, members: []const pb.EdgeId) error{OutOfMemory}!?KeySets {
    var sources: std.ArrayListUnmanaged([]const u8) = .empty;
    var targets: std.ArrayListUnmanaged([]const u8) = .empty;
    var pairs: std.ArrayListUnmanaged([2]pb.NodeId) = .empty;
    for (members) |id| {
        const edge = edgeById(graph, id) orelse return null;
        const from = nodeKey(graph, edge.from) orelse return null;
        const to = nodeKey(graph, edge.to) orelse return null;
        try appendUniqueBytes(a, &sources, from);
        try appendUniqueBytes(a, &targets, to);
        for (pairs.items) |p| if (p[0] == edge.from and p[1] == edge.to) return null;
        try pairs.append(a, .{ edge.from, edge.to });
    }
    if (sources.items.len < 2 or targets.items.len < 2 or pairs.items.len != sources.items.len * targets.items.len) return null;
    std.mem.sort([]const u8, sources.items, {}, bytesLess);
    std.mem.sort([]const u8, targets.items, {}, bytesLess);
    return .{ .sources = try sources.toOwnedSlice(a), .targets = try targets.toOwnedSlice(a) };
}

fn groupsShare(a: pb.JoinGroup, b: pb.JoinGroup) bool {
    for (a.members) |x| for (b.members) |y| if (x == y) return true;
    return false;
}

fn inMesh(unions: []const pb.MeshUnion, edge: pb.EdgeId) bool {
    for (unions) |u| for (u.members) |member| if (member == edge) return true;
    return false;
}

fn edgeById(graph: sg.SemGraph, id: pb.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| if (edge.id == id) return edge;
    return null;
}

fn nodeKey(graph: sg.SemGraph, id: pb.NodeId) ?[]const u8 {
    for (graph.nodes) |node| if (node.id == id) return node.raw_id;
    return null;
}

fn labelsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    const av = a orelse return b == null;
    return b != null and std.mem.eql(u8, av, b.?);
}

fn appendUnique(comptime T: type, a: std.mem.Allocator, list: *std.ArrayListUnmanaged(T), value: T) !void {
    for (list.items) |item| if (item == value) return;
    try list.append(a, value);
}

fn appendUniqueBytes(a: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) !void {
    for (list.items) |item| if (std.mem.eql(u8, item, value)) return;
    try list.append(a, value);
}

fn bytesLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

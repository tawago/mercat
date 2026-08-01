//! Pre-sizing realization commitment for the flat layout path.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const rc = @import("../base/rail_closure.zig");
const sg = @import("../sem_graph.zig");

/// The closure law's report-only inventory (base/ledger.zig). One type for
/// every producer — the flat commitment here and the clustered lane pass —
/// so the shipped Sketch carries a single set of counts.
pub const Report = pb.ClosureCounts;

pub fn buildReported(a: std.mem.Allocator, graph: sg.SemGraph, permits: ?*const pb.JoinPermits, flat: bool, reversed_edges: []const pb.EdgeId, disable: bool, report: ?*Report) error{OutOfMemory}!pb.RealizedJoins {
    if (!flat or permits == null) return .{};
    const plan = permits.?.*;
    // P2v Step 8 (D-DISPOSITION item 9(b)): the forced all-independent terminal
    // layout. Every grouped endpoint takes an independent(not_selected)
    // disposition, so no trunk is realized and no mesh union is provenanced —
    // fan_rail.resolve then declines (memberships present, none selected),
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

    // Phase 1 — provisional eligibility under the frozen gates. `eff_of[gi]`
    // is the member set the group would commit as a trunk, or null when a
    // gate refuses it.
    const eff_of = try a.alloc(?[]const pb.EdgeId, plan.groups.len);
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
        const blocked = (overlap and !remerge) or !styleCompatible(graph, eff_group) or hasDuplicateKey(graph, eff_group) or
            containsReversed(eff_group, reversed_edges) or eff.len < 2;
        eff_of[gi] = if (blocked) null else eff;
    }

    // Phase 2 — the all-arrow-free shared-rail closure law. A rail whose every
    // member is arrow-free asserts each unordered LEAF PAIR too, so it may fuse
    // only over pairs the graph declares. `drawn` is the plan-wide record of
    // declarations that ALREADY carry ink — every provisionally eligible rail's
    // own members, plus every declaration an earlier rail discharged. They
    // license a pair (the relation is on the page) but are never discharged
    // again, which is the plan-wide "one rail renders one declaration" clause;
    // refusing over them instead would unfuse every fully declared clique,
    // whose leaf pairs are by construction other stars' members.
    // guarded-by: join_commit_test.zig "a clique whose pair edges are other rails' members keeps every rail"
    const closure_refused = try a.alloc(bool, plan.groups.len);
    @memset(closure_refused, false);
    var discharged: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    var drawn: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (eff_of) |maybe| {
        if (maybe) |eff| try drawn.appendSlice(a, eff);
    }
    for (plan.groups, 0..) |group, gi| {
        const eff = eff_of[gi] orelse continue;
        const verdict = try closureVerdict(a, graph, group, eff, drawn.items);
        if (report) |r| {
            if (verdict.outcome == .refuse or verdict.outcome == .salvage) r.rail_closure_undeclared += 1;
            r.co_undeclared += verdict.undeclared_pairs;
        }
        switch (verdict.outcome) {
            .untouched, .keep => {},
            // A salvaged rail keeps a strict subset; the dropped members fall
            // to independent lanes exactly like a member the style gate
            // excluded, and keep their own ink (so they stay `drawn`).
            .salvage => eff_of[gi] = verdict.members,
            .refuse => {
                eff_of[gi] = null;
                closure_refused[gi] = true;
            },
        }
        for (verdict.discharges) |d| {
            if (d.drawn) continue;
            try discharged.append(a, d.backer);
            try drawn.append(a, d.backer);
        }
    }

    // Phase 3 — commitment. Ids ascend with group rank, unchanged.
    const selected_group = try a.alloc(?pb.RealizedJoinId, plan.groups.len);
    @memset(selected_group, null);
    var selected: std.ArrayListUnmanaged(pb.SelectedJoin) = .empty;
    for (plan.groups, 0..) |group, gi| {
        const eff = eff_of[gi] orelse continue;
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
            .source = disposition(graph, plan.groups, selected_group, closure_refused, selected.items, m.source_group, reversed_edges, m.edge),
            .target = disposition(graph, plan.groups, selected_group, closure_refused, selected.items, m.target_group, reversed_edges, m.edge),
        };
    }
    return .{
        .selected_joins = try selected.toOwnedSlice(a),
        .memberships = memberships,
        .mesh_unions = unions,
        .co_realized = try discharged.toOwnedSlice(a),
    };
}

/// Project one provisionally eligible group into the closure law's own
/// vocabulary and ask it. Members carry the LEAF endpoint (the one that is
/// not the pivot); every other declared non-self edge is a candidate backer.
fn closureVerdict(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    group: pb.JoinGroup,
    eff: []const pb.EdgeId,
    drawn: []const pb.EdgeId,
) error{OutOfMemory}!rc.Verdict {
    const members = try a.alloc(rc.Member, eff.len);
    for (eff, members) |id, *m| {
        const edge = edgeById(graph, id) orelse return .{ .outcome = .untouched, .members = eff };
        m.* = .{
            .edge = id,
            .leaf = if (group.direction == .out) edge.to else edge.from,
            .kind = pb.edgeKindOrdinal(edge.kind),
            .arrow_free = arrowFree(edge),
        };
    }
    var backers: std.ArrayListUnmanaged(rc.Backer) = .empty;
    for (graph.edges) |edge| {
        if (edge.from == edge.to or containsEdge(eff, edge.id)) continue;
        try backers.append(a, .{
            .edge = edge.id,
            .a = edge.from,
            .b = edge.to,
            .kind = pb.edgeKindOrdinal(edge.kind),
            .arrow_free = arrowFree(edge),
            .unlabeled = edge.label == null or edge.label.?.len == 0,
            .drawn = containsEdge(drawn, edge.id),
        });
    }
    return rc.decide(a, members, backers.items);
}

fn arrowFree(edge: sg.Edge) bool {
    return edge.arrow_from == .none and edge.arrow_to == .none;
}

fn containsEdge(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |e| if (e == edge) return true;
    return false;
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

fn disposition(graph: sg.SemGraph, groups: []const pb.JoinGroup, selected_group: []const ?pb.RealizedJoinId, closure_refused: []const bool, selected_joins: []const pb.SelectedJoin, id: ?pb.JoinGroupId, reversed_edges: []const pb.EdgeId, edge: pb.EdgeId) ?pb.MembershipDisposition {
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
        // A closure refusal must reach the member as `independent`: that
        // disposition is what unfuses it (per-member fan lanes in TD, a port of
        // its own in LR/RL). The null-disposition escape below is for a group
        // the reversal rule left ungrouped, never for a refused rail.
        // guarded-by: join_commit_test.zig "a reversed member does not hide a closure refusal behind a null disposition"
        if (!closure_refused[i] and containsReversed(g, reversed_edges) and !overlaps(groups, i) and styleCompatible(graph, g) and !hasDuplicateKey(graph, g)) return null;
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

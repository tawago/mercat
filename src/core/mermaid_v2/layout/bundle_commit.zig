const std = @import("std");
const pb = @import("../base/ledger.zig");
const rc = @import("../base/rail_closure.zig");
const sg = @import("../sem_graph.zig");
const permit_mod = @import("../ledger/permits.zig");

pub const Report = pb.ClosureCounts;

pub fn effectivePlan(a: std.mem.Allocator, graph: sg.SemGraph, root: ?*const pb.BundlePermits) error{OutOfMemory}!?pb.BundlePermits {
    const rp = root orelse return null;
    if (graph.clusters.len != 0) return null;
    if (rp.isFlat()) return rp.*;
    const piece = permit_mod.buildPiece(a, graph) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSemGraph => return null,
    };
    return piece.plan;
}

pub fn buildReported(a: std.mem.Allocator, graph: sg.SemGraph, permits: ?*const pb.BundlePermits, reversed_edges: []const pb.EdgeId, long_edges: []const pb.EdgeId, report: ?*Report) error{OutOfMemory}!pb.RealizedBundles {
    const plan_ptr = permits orelse return .{};
    if (graph.clusters.len != 0) return .{};
    if (plan_ptr.scope == .skipped_clustered) return .{};
    const plan = plan_ptr.*;
    const eff_of = try a.alloc(?[]const pb.EdgeId, plan.groups.len);
    for (plan.groups, 0..) |group, gi| {
        const reversed = containsReversed(group, reversed_edges);
        const forward = if (reversed and group.direction == .in)
            try forwardSubset(a, group.members, reversed_edges)
        else
            group.members;
        const eff = (try permit_mod.prepareRailMembers(a, graph, group.direction, group.pivot, forward)).members;
        const eff_group: pb.CandidateBundle = .{ .id = group.id, .direction = group.direction, .pivot = group.pivot, .members = eff };
        const blocked = !styleCompatible(graph, eff_group) or hasDuplicateKey(graph, eff_group) or
            containsReversed(eff_group, reversed_edges) or eff.len < 2;
        eff_of[gi] = if (blocked) null else eff;
    }

    const closure_refused = try a.alloc(bool, plan.groups.len);
    @memset(closure_refused, false);
    const verdicts = try a.alloc(?rc.Verdict, plan.groups.len);
    @memset(verdicts, null);
    for (plan.groups, 0..) |group, gi| {
        const eff = eff_of[gi] orelse continue;
        const verdict = try closureVerdict(a, graph, group, eff, plan.scope == .piece);
        if (report) |r| {
            if (verdict.outcome == .refuse or verdict.outcome == .salvage) r.rail_closure_undeclared += 1;
            r.co_undeclared += verdict.undeclared_pairs;
        }
        switch (verdict.outcome) {
            .untouched => continue,
            .keep => {},
            .salvage => eff_of[gi] = verdict.members,
            .refuse => {
                eff_of[gi] = null;
                closure_refused[gi] = true;
                continue;
            },
        }
        verdicts[gi] = verdict;
    }
    try keepOneNearRail(a, graph, plan, eff_of, verdicts, closure_refused, long_edges);
    try reserve(a, graph, plan, eff_of, verdicts, closure_refused, report);

    // @guarded-by: bundle_commit_test.zig "a clique whose pair edges are other rails' members keeps a rail"
    var discharged: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    var drawn: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (eff_of) |maybe| {
        if (maybe) |eff| try drawn.appendSlice(a, eff);
    }
    for (verdicts, 0..) |maybe, gi| {
        const verdict = maybe orelse continue;
        if (eff_of[gi] == null) continue;
        for (verdict.discharges) |d| {
            if (containsEdge(drawn.items, d.backer)) continue;
            try discharged.append(a, d.backer);
            try drawn.append(a, d.backer);
        }
    }

    const selected_group = try a.alloc(?pb.SelectedBundleId, plan.groups.len);
    @memset(selected_group, null);
    var selected: std.ArrayListUnmanaged(pb.SelectedBundle) = .empty;
    for (plan.groups, 0..) |group, gi| {
        const eff = eff_of[gi] orelse continue;
        const jid: pb.SelectedBundleId = @intCast(selected.items.len);
        selected_group[gi] = jid;
        try selected.append(a, .{
            .id = jid,
            .proposal = @intCast(gi),
            .candidate_bundle = group.id,
            .members = try a.dupe(pb.EdgeId, eff),
        });
    }

    const memberships = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
    for (plan.memberships, memberships) |m, *out| {
        out.* = .{
            .edge = m.edge,
            .source = disposition(graph, plan.groups, selected_group, closure_refused, selected.items, m.source_group, reversed_edges, m.edge),
            .target = disposition(graph, plan.groups, selected_group, closure_refused, selected.items, m.target_group, reversed_edges, m.edge),
        };
    }
    const selected_slice = try selected.toOwnedSlice(a);
    return .{
        .selected_bundles = selected_slice,
        .memberships = memberships,
        .discharged = try discharged.toOwnedSlice(a),
        .fused = try fusionLicence(a, graph, plan.groups, selected_slice),
    };
}

/// @guarded-by: bundle_commit_test.zig "a complete bipartite of selected arrivals licenses one fused union"
fn fusionLicence(a: std.mem.Allocator, graph: sg.SemGraph, groups: []const pb.CandidateBundle, selected: []const pb.SelectedBundle) error{OutOfMemory}![]const []const pb.EdgeId {
    const n = selected.len;
    if (n < 2) return &.{};
    const parent = try a.alloc(usize, n);
    for (parent, 0..) |*p, i| p.* = i;
    for (selected, 0..) |x, i| {
        const dx = directionOf(groups, x.candidate_bundle) orelse continue;
        for (selected[i + 1 ..], i + 1..) |y, j| {
            if (directionOf(groups, y.candidate_bundle) != dx) continue;
            if (leafSetEqual(graph, dx, x.members, y.members)) uniteBundles(parent, i, j);
        }
    }
    var out: std.ArrayListUnmanaged([]const pb.EdgeId) = .empty;
    for (0..n) |root| {
        if (findBundle(parent, root) != root) continue;
        var member_joins: u32 = 0;
        var edges: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        for (selected, 0..) |j, ji| {
            if (findBundle(parent, ji) != root) continue;
            member_joins += 1;
            try edges.appendSlice(a, j.members);
        }
        if (member_joins < 2) continue;
        if (try unionComplete(a, graph, edges.items)) {
            std.mem.sort(pb.EdgeId, edges.items, {}, std.sort.asc(pb.EdgeId));
            try out.append(a, try edges.toOwnedSlice(a));
        } else edges.deinit(a);
    }
    return out.toOwnedSlice(a);
}

fn directionOf(groups: []const pb.CandidateBundle, id: pb.CandidateBundleId) ?pb.BundleDirection {
    for (groups) |g| if (g.id == id) return g.direction;
    return null;
}

fn leafSetEqual(graph: sg.SemGraph, dir: pb.BundleDirection, xs: []const pb.EdgeId, ys: []const pb.EdgeId) bool {
    return leafSubset(graph, dir, xs, ys) and leafSubset(graph, dir, ys, xs);
}

fn leafSubset(graph: sg.SemGraph, dir: pb.BundleDirection, xs: []const pb.EdgeId, ys: []const pb.EdgeId) bool {
    for (xs) |xi| {
        const x = edgeById(graph, xi) orelse return false;
        const lx = if (dir == .in) x.from else x.to;
        const held = for (ys) |yi| {
            const y = edgeById(graph, yi) orelse return false;
            if ((if (dir == .in) y.from else y.to) == lx) break true;
        } else false;
        if (!held) return false;
    }
    return true;
}

fn unionComplete(a: std.mem.Allocator, graph: sg.SemGraph, members: []const pb.EdgeId) error{OutOfMemory}!bool {
    var srcs: std.ArrayListUnmanaged(pb.NodeId) = .empty;
    defer srcs.deinit(a);
    var tgts: std.ArrayListUnmanaged(pb.NodeId) = .empty;
    defer tgts.deinit(a);
    var pairs: std.ArrayListUnmanaged([2]pb.NodeId) = .empty;
    defer pairs.deinit(a);
    var style: ?u48 = null;
    for (members) |id| {
        const e = edgeById(graph, id) orelse return false;
        if (e.kind == .invisible or !sg.forwardOneWayHead(e)) return false;
        const key: u48 = (@as(u48, pb.edgeKindOrdinal(e.kind)) << 8) |
            (@as(u48, @intFromEnum(e.arrow_from)) << 4) | @intFromEnum(e.arrow_to);
        if (style) |st| {
            if (st != key) return false;
        } else style = key;
        try addUniqueNode(a, &srcs, e.from);
        try addUniqueNode(a, &tgts, e.to);
        var seen = false;
        for (pairs.items) |p| if (p[0] == e.from and p[1] == e.to) {
            seen = true;
        };
        if (!seen) try pairs.append(a, .{ e.from, e.to });
    }
    if (srcs.items.len <= 1 or tgts.items.len <= 1) return false;
    return pairs.items.len == srcs.items.len * tgts.items.len;
}

fn addUniqueNode(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(pb.NodeId), v: pb.NodeId) error{OutOfMemory}!void {
    for (list.items) |x| if (x == v) return;
    try list.append(a, v);
}

fn findBundle(parent: []usize, i: usize) usize {
    var r = i;
    while (parent[r] != r) r = parent[r];
    return r;
}

fn uniteBundles(parent: []usize, i: usize, j: usize) void {
    const ri = findBundle(parent, i);
    const rj = findBundle(parent, j);
    if (ri != rj) parent[@max(ri, rj)] = @min(ri, rj);
}

/// @guarded-by: bundle_commit_test.zig "two rails asserting one declared pair both refuse"
fn reserve(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    plan: pb.BundlePermits,
    eff_of: []?[]const pb.EdgeId,
    verdicts: []?rc.Verdict,
    closure_refused: []bool,
    report: ?*Report,
) error{OutOfMemory}!void {
    var order: std.ArrayListUnmanaged(usize) = .empty;
    for (verdicts, 0..) |verdict, gi| {
        if (verdict != null and eff_of[gi] != null) try order.append(a, gi);
    }
    std.mem.sort(usize, order.items, eff_of, widestFirst);

    for (order.items, 0..) |ri, rank| {
        if (eff_of[ri] == null) continue;
        for (order.items[rank + 1 ..]) |gi| {
            const eff = eff_of[gi] orelse continue;
            var kept: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
            for (eff) |member| if (!dischargedBy(verdicts[ri].?, member)) try kept.append(a, member);
            if (kept.items.len == eff.len) continue;
            if (kept.items.len < 2) {
                eff_of[gi] = null;
                closure_refused[gi] = true;
                continue;
            }
            const rest = try kept.toOwnedSlice(a);
            const again = try closureVerdict(a, graph, plan.groups[gi], rest, plan.scope == .piece);
            switch (again.outcome) {
                .untouched, .keep => eff_of[gi] = rest,
                .salvage => eff_of[gi] = again.members,
                .refuse => {
                    eff_of[gi] = null;
                    closure_refused[gi] = true;
                    continue;
                },
            }
            verdicts[gi] = again;
        }
    }

    const conflicted = try a.alloc(bool, eff_of.len);
    @memset(conflicted, false);
    for (order.items, 0..) |x, rank| {
        if (eff_of[x] == null) continue;
        for (order.items[rank + 1 ..]) |y| {
            if (eff_of[y] == null or !sharesPair(verdicts[x].?, verdicts[y].?)) continue;
            conflicted[x] = true;
            conflicted[y] = true;
        }
    }
    for (conflicted, 0..) |hit, gi| {
        if (!hit) continue;
        eff_of[gi] = null;
        closure_refused[gi] = true;
        // @guarded-by: bundle_commit_test.zig "a salvaged rail that then loses its pair is one refusal, not two"
        const counted = if (verdicts[gi]) |v| v.outcome == .salvage else false;
        if (!counted) {
            if (report) |r| r.rail_closure_undeclared += 1;
        }
    }
}

fn widestFirst(eff_of: []?[]const pb.EdgeId, x: usize, y: usize) bool {
    const nx = (eff_of[x] orelse &.{}).len;
    const ny = (eff_of[y] orelse &.{}).len;
    return if (nx == ny) x < y else nx > ny;
}

fn dropMember(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    plan: pb.BundlePermits,
    eff_of: []?[]const pb.EdgeId,
    verdicts: []?rc.Verdict,
    closure_refused: []bool,
    gi: usize,
    member: pb.EdgeId,
    group: pb.CandidateBundle,
) error{OutOfMemory}!void {
    var kept: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (eff_of[gi].?) |m| if (m != member) try kept.append(a, m);
    if (kept.items.len < 2) {
        eff_of[gi] = null;
        return;
    }
    const rest = try kept.toOwnedSlice(a);
    if (verdicts[gi] != null) {
        const again = try closureVerdict(a, graph, group, rest, plan.scope == .piece);
        switch (again.outcome) {
            .untouched, .keep => eff_of[gi] = rest,
            .salvage => eff_of[gi] = again.members,
            .refuse => {
                eff_of[gi] = null;
                closure_refused[gi] = true;
                return;
            },
        }
        verdicts[gi] = again;
    } else eff_of[gi] = rest;
}

/// @guarded-by: bundle_commit_test.zig "a near member selected at both ends keeps its arrival rail, a long member keeps both"
fn keepOneNearRail(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    plan: pb.BundlePermits,
    eff_of: []?[]const pb.EdgeId,
    verdicts: []?rc.Verdict,
    closure_refused: []bool,
    long_edges: []const pb.EdgeId,
) error{OutOfMemory}!void {
    for (graph.edges) |e| {
        if (containsEdge(long_edges, e.id)) continue;
        var gi_out: ?usize = null;
        var gi_in: ?usize = null;
        for (plan.groups, 0..) |g, gi| {
            const eff = eff_of[gi] orelse continue;
            if (!containsEdge(eff, e.id)) continue;
            if (g.direction == .out) gi_out = gi else gi_in = gi;
        }
        const o = gi_out orelse continue;
        if (gi_in == null) continue;
        try dropMember(a, graph, plan, eff_of, verdicts, closure_refused, o, e.id, plan.groups[o]);
    }
}

fn dischargedBy(verdict: rc.Verdict, member: pb.EdgeId) bool {
    for (verdict.discharges) |d| if (d.backer == member) return true;
    return false;
}

fn sharesPair(x: rc.Verdict, y: rc.Verdict) bool {
    for (x.discharges) |dx| {
        for (y.discharges) |dy| {
            if (dx.pair[0] == dy.pair[0] and dx.pair[1] == dy.pair[1]) return true;
        }
    }
    return false;
}

fn closureVerdict(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    group: pb.CandidateBundle,
    eff: []const pb.EdgeId,
    piece_scope: bool,
) error{OutOfMemory}!rc.Verdict {
    const members = try a.alloc(rc.Member, eff.len);
    for (eff, members) |id, *m| {
        const edge = edgeById(graph, id) orelse return .{ .outcome = .untouched, .members = eff };
        m.* = .{
            .edge = id,
            .leaf = if (group.direction == .out) edge.to else edge.from,
            .kind = pb.edgeKindOrdinal(edge.kind),
            .arrow_free = sg.arrowFree(edge),
            .undecorated = undecorated(edge),
        };
    }
    var backers: std.ArrayListUnmanaged(rc.Backer) = .empty;
    for (graph.edges) |edge| {
        if (edge.from == edge.to or containsEdge(eff, edge.id)) continue;
        if (piece_scope and edge.origin == sg.SENTINEL) continue;
        try backers.append(a, .{
            .edge = edge.id,
            .a = edge.from,
            .b = edge.to,
            .kind = pb.edgeKindOrdinal(edge.kind),
            .undecorated = undecorated(edge),
            .unlabeled = edge.label == null or edge.label.?.len == 0,
        });
    }
    return rc.decide(a, members, backers.items);
}

fn undecorated(edge: sg.Edge) bool {
    return sg.undecorated(edge);
}

fn containsEdge(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |e| if (e == edge) return true;
    return false;
}

fn containsReversed(group: pb.CandidateBundle, reversed_edges: []const pb.EdgeId) bool {
    for (group.members) |member| for (reversed_edges) |reversed| {
        if (member == reversed) return true;
    };
    return false;
}

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

fn disposition(graph: sg.SemGraph, groups: []const pb.CandidateBundle, selected_group: []const ?pb.SelectedBundleId, closure_refused: []const bool, selected_bundles: []const pb.SelectedBundle, id: ?pb.CandidateBundleId, reversed_edges: []const pb.EdgeId, edge: pb.EdgeId) ?pb.MembershipDisposition {
    const gid = id orelse return null;
    for (groups, 0..) |g, i| if (g.id == gid) {
        if (selected_group[i]) |jid| {
            for (selected_bundles) |sj| if (sj.id == jid) {
                for (sj.members) |mem| if (mem == edge) return .{ .selected = jid };
            };
            return .{ .independent = .{ .candidate_bundle = gid, .reason = .not_selected } };
        }
        // @guarded-by: bundle_commit_test.zig "a reversed member does not hide a closure refusal behind a null disposition"
        if (!closure_refused[i] and containsReversed(g, reversed_edges) and styleCompatible(graph, g) and !hasDuplicateKey(graph, g)) return null;
        return .{ .independent = .{ .candidate_bundle = gid, .reason = .not_selected } };
    };
    return null;
}

fn styleCompatible(graph: sg.SemGraph, group: pb.CandidateBundle) bool {
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

fn hasDuplicateKey(graph: sg.SemGraph, group: pb.CandidateBundle) bool {
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

fn edgeById(graph: sg.SemGraph, id: pb.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| if (edge.id == id) return edge;
    return null;
}

fn labelsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    const av = a orelse return b == null;
    return b != null and std.mem.eql(u8, av, b.?);
}

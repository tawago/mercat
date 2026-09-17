//! Pre-sizing realization commitment for the flat layout path.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const permit_mod = @import("../ledger/permits.zig");

/// The plan THIS graph's layout realizes against: the root plan when it is
/// flat, a fresh piece-scoped plan (piece-local edge ids) for a cluster-free
/// piece of a clustered original, and null when no plan applies (no permits,
/// clusters present — authored or motif-pack synthetic — or invalid piece).
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

/// Commit the rails this layout will build: one selected bundle per permit
/// group whose eligible members (`permits.prepareRailMembers`) are two or
/// more, style-compatible, free of duplicate keys and of layout-reversed
/// edges — then the one-rail-per-near-member rule below. Every grouped
/// endpoint gets a disposition: `selected` into its rail, or `independent`.
pub fn buildReported(a: std.mem.Allocator, graph: sg.SemGraph, permits: ?*const pb.BundlePermits, reversed_edges: []const pb.EdgeId, long_edges: []const pb.EdgeId) error{OutOfMemory}!pb.RealizedBundles {
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
    try keepOneNearRail(a, graph, plan, eff_of, long_edges);

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
            .source = disposition(graph, plan.groups, selected_group, selected.items, m.source_group, reversed_edges, m.edge),
            .target = disposition(graph, plan.groups, selected_group, selected.items, m.target_group, reversed_edges, m.edge),
        };
    }
    return .{
        .selected_bundles = try selected.toOwnedSlice(a),
        .memberships = memberships,
    };
}

/// Remove one member from a surviving candidate; a candidate left with one
/// member builds no rail.
fn dropMember(
    a: std.mem.Allocator,
    eff_of: []?[]const pb.EdgeId,
    gi: usize,
    member: pb.EdgeId,
) error{OutOfMemory}!void {
    var kept: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (eff_of[gi].?) |m| if (m != member) try kept.append(a, m);
    eff_of[gi] = if (kept.items.len < 2) null else try kept.toOwnedSlice(a);
}

/// A member selected at both ends whose two pivots sit on adjacent layers
/// would put two rails in one gap, each owning the whole edge: one path of
/// ink drawn twice. Realization keeps ONE membership for such a NEAR
/// member: the arrival's. Two reasons, neither a licence: a two-sided rail
/// is built from same-direction rails, and keeping arrivals together is
/// what lets a complete S x T share one rail row; and it is the drawing
/// every existing render already has. A LONG member (its ends span a gap or
/// more) keeps both: each rail owns one drop cell and the member's own
/// stroke runs between them. Both memberships stay licensed; which side of
/// a near member ships could later be a scored candidate axis.
/// @guarded-by: bundle_commit_test.zig "a near member selected at both ends keeps its arrival rail, a long member keeps both"
fn keepOneNearRail(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    plan: pb.BundlePermits,
    eff_of: []?[]const pb.EdgeId,
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
        try dropMember(a, eff_of, o, e.id);
    }
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

/// The group's forward (non-layout-reversed) members, in canonical member
/// order (deterministic under edge-array permutation because `members` is
/// already canonical). Used as the rail-eligible subset for a fan-IN group.
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

fn disposition(graph: sg.SemGraph, groups: []const pb.CandidateBundle, selected_group: []const ?pb.SelectedBundleId, selected_bundles: []const pb.SelectedBundle, id: ?pb.CandidateBundleId, reversed_edges: []const pb.EdgeId, edge: pb.EdgeId) ?pb.MembershipDisposition {
    const gid = id orelse return null;
    for (groups, 0..) |g, i| if (g.id == gid) {
        if (selected_group[i]) |jid| {
            for (selected_bundles) |sj| if (sj.id == jid) {
                for (sj.members) |mem| if (mem == edge) return .{ .selected = jid };
            };
            return .{ .independent = .{ .candidate_bundle = gid, .reason = .not_selected } };
        }
        // A group the reversal rule left ungrouped keeps the null disposition;
        // every other unselected group reaches its members as `independent`,
        // which is what unfuses them (per-member fan lanes in TD, a port of
        // their own in LR/RL).
        if (containsReversed(g, reversed_edges) and styleCompatible(graph, g) and !hasDuplicateKey(graph, g)) return null;
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

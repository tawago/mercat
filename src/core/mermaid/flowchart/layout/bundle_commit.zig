const std = @import("std");
const pb = @import("../base/ledger.zig");
const tie_break = @import("../base/tie_break.zig");
const rc = @import("../base/rail_closure.zig");
const sg = @import("../sem_graph.zig");
const permit_mod = @import("../ledger/permits.zig");

/// The plan a layout realizes: a flat render's plan as it stands, a cluster piece's own.
pub fn effectivePlan(a: std.mem.Allocator, graph: sg.SemGraph, root: ?*const pb.BundlePermits) error{OutOfMemory}!?pb.BundlePermits {
    const rp = root orelse return null;
    if (rp.isFlat()) return rp.*;
    const piece = permit_mod.buildPiece(a, graph) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSemGraph => return null,
    };
    return piece.plan;
}

/// The declared edges that may back a pair a rail of `members` connects. In a cluster piece the
/// stand-ins for crossings declare nothing and back nothing.
pub fn backersOf(a: std.mem.Allocator, graph: sg.SemGraph, members: []const rc.Member) error{OutOfMemory}![]rc.Backer {
    var piece = false;
    for (graph.edges) |edge| piece = piece or edge.origin != sg.SENTINEL;
    var out: std.ArrayListUnmanaged(rc.Backer) = .empty;
    outer: for (graph.edges) |edge| {
        if (edge.from == edge.to or (piece and edge.origin == sg.SENTINEL)) continue;
        for (members) |m| if (m.edge == edge.id) continue :outer;
        try out.append(a, .{
            .edge = edge.id,
            .a = edge.from,
            .b = edge.to,
            .kind = tie_break.edgeKindOrdinal(edge.kind),
            .undecorated = sg.undecorated(edge),
            .unlabeled = edge.labelText() == null,
        });
    }
    return out.toOwnedSlice(a);
}

/// Where one candidate bundle stands while the phases run.
const Slot = union(enum) {
    /// No rail: fewer than two members stand, or a member is reversed.
    none,
    /// The closure licence or the discharge settlement refused it.
    refused,
    rail: Rail,
};

const Rail = struct {
    members: []const pb.EdgeId,
    /// The pair edges the rail draws, one per pair of divergent nodes; empty unless every member is arrow-free.
    discharges: []const rc.Discharge = &.{},
};

const Ctx = struct {
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    plan: pb.BundlePermits,
    reversed: []const pb.EdgeId,
};

/// Which candidate bundles of `permits` are drawn as rails, which pair edges those rails discharge
/// and which rails fuse. Reads the graph, the plan and the layering's reversed and long edges,
/// never a coordinate. Phases: star licence, closure licence, near rule, discharge settlement,
/// then the fusion licence over the rails that stand.
pub fn realize(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    permits: ?*const pb.BundlePermits,
    reversed: []const pb.EdgeId,
    long: []const pb.EdgeId,
) error{OutOfMemory}!pb.RealizedBundles {
    const plan = (permits orelse return .{}).*;
    const c: Ctx = .{ .a = a, .graph = graph, .plan = plan, .reversed = reversed };
    const slots = try a.alloc(Slot, plan.groups.len);
    for (plan.groups, slots) |group, *slot| slot.* = try starLicence(c, group);
    try nearRule(c, slots, long);
    try settle(c, slots);
    return realized(c, slots);
}

/// A reversed member bars an out-rail; an in-rail is formed without its reversed members.
fn starLicence(c: Ctx, group: pb.CandidateBundle) error{OutOfMemory}!Slot {
    const pool = if (group.direction == .in) try without(c.a, group.members, c.reversed) else group.members;
    const members = try permit_mod.prepareRailMembers(c.a, c.graph, group.direction, group.pivot, pool);
    if (members.len < 2 or anyIn(members, c.reversed)) return .none;
    return closureLicence(c, group, members);
}

fn closureLicence(c: Ctx, group: pb.CandidateBundle, rail: []const pb.EdgeId) error{OutOfMemory}!Slot {
    const members = try c.a.alloc(rc.Member, rail.len);
    for (rail, members) |id, *m| {
        const edge = c.graph.edgeById(id) orelse return .{ .rail = .{ .members = rail } };
        m.* = .{
            .edge = id,
            .leaf = divergentOf(group.direction, edge),
            .kind = tie_break.edgeKindOrdinal(edge.kind),
            .arrow_free = sg.arrowFree(edge),
            .undecorated = sg.undecorated(edge),
        };
    }
    const verdict = try rc.decide(c.a, members, try backersOf(c.a, c.graph, members));
    if (verdict.outcome == .refuse) return .refused;
    return .{ .rail = .{ .members = verdict.members, .discharges = verdict.discharges } };
}

/// An edge that is a member of an out-rail and an in-rail keeps only the in-rail, unless it spans
/// more than one layer. A rail that loses a member is judged again before the next edge.
fn nearRule(c: Ctx, slots: []Slot, long: []const pb.EdgeId) error{OutOfMemory}!void {
    for (c.graph.edges) |edge| {
        if (pb.containsEdge(long, edge.id)) continue;
        var out: ?usize = null;
        var in: ?usize = null;
        for (c.plan.groups, slots, 0..) |group, slot, gi| {
            if (slot != .rail or !pb.containsEdge(slot.rail.members, edge.id)) continue;
            if (group.direction == .out) out = gi else in = gi;
        }
        const gi = out orelse continue;
        if (in == null) continue;
        const rest = try without(c.a, slots[gi].rail.members, &.{edge.id});
        slots[gi] = if (rest.len < 2) .none else try closureLicence(c, c.plan.groups[gi], rest);
    }
}

/// A pair edge is discharged by at most one rail: the wider rail keeps it and the other loses the
/// member that edge is; two rails still asserting one pair both refuse.
fn settle(c: Ctx, slots: []Slot) error{OutOfMemory}!void {
    var order: std.ArrayListUnmanaged(usize) = .empty;
    for (slots, 0..) |slot, gi| if (slot == .rail) try order.append(c.a, gi);
    std.mem.sort(usize, order.items, @as([]const Slot, slots), widestFirst);

    for (order.items, 0..) |ki, rank| {
        const keeper = switch (slots[ki]) {
            .rail => |rail| rail,
            else => continue,
        };
        for (order.items[rank + 1 ..]) |gi| {
            const rail = switch (slots[gi]) {
                .rail => |r| r,
                else => continue,
            };
            var kept: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
            for (rail.members) |member| if (!rc.backs(keeper.discharges, member)) try kept.append(c.a, member);
            if (kept.items.len == rail.members.len) continue;
            slots[gi] = if (kept.items.len < 2) .refused else try closureLicence(c, c.plan.groups[gi], kept.items);
        }
    }

    const clash = try c.a.alloc(bool, slots.len);
    @memset(clash, false);
    for (order.items, 0..) |x, rank| {
        for (order.items[rank + 1 ..]) |y| {
            if (slots[x] != .rail or slots[y] != .rail) continue;
            if (!rc.sharesPair(slots[x].rail.discharges, slots[y].rail.discharges)) continue;
            clash[x] = true;
            clash[y] = true;
        }
    }
    for (clash, slots) |hit, *slot| if (hit) {
        slot.* = .refused;
    };
}

fn widestFirst(slots: []const Slot, x: usize, y: usize) bool {
    const nx = slots[x].rail.members.len;
    const ny = slots[y].rail.members.len;
    return if (nx == ny) x < y else nx > ny;
}

fn realized(c: Ctx, slots: []const Slot) error{OutOfMemory}!pb.RealizedBundles {
    const selected_id = try c.a.alloc(?pb.SelectedBundleId, slots.len);
    @memset(selected_id, null);
    var selected: std.ArrayListUnmanaged(pb.SelectedBundle) = .empty;
    var drawn: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (c.plan.groups, slots, selected_id) |group, slot, *id| {
        if (slot != .rail) continue;
        const jid: pb.SelectedBundleId = @intCast(selected.items.len);
        id.* = jid;
        try selected.append(c.a, .{ .id = jid, .candidate_bundle = group.id, .members = slot.rail.members });
        try drawn.appendSlice(c.a, slot.rail.members);
    }

    var discharged: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (slots) |slot| {
        if (slot != .rail) continue;
        for (slot.rail.discharges) |d| {
            if (pb.containsEdge(drawn.items, d.backer)) continue;
            try discharged.append(c.a, d.backer);
            try drawn.append(c.a, d.backer);
        }
    }

    const memberships = try c.a.alloc(pb.RealizedEdgeMembership, c.plan.memberships.len);
    for (c.plan.memberships, memberships) |m, *out| out.* = .{
        .edge = m.edge,
        .source = disposition(c, slots, selected_id, m.source_group, m.edge),
        .target = disposition(c, slots, selected_id, m.target_group, m.edge),
    };
    return .{
        .selected_bundles = selected.items,
        .memberships = memberships,
        .discharged = discharged.items,
        .fused = try fusion(c, selected.items),
    };
}

/// How the end of `edge` at candidate bundle `want` is drawn. None when the bundle failed only
/// because a member is reversed: that end is not the bundle's to draw.
fn disposition(c: Ctx, slots: []const Slot, selected_id: []const ?pb.SelectedBundleId, want: ?pb.CandidateBundleId, edge: pb.EdgeId) ?pb.MembershipDisposition {
    const id = want orelse return null;
    const not_selected: pb.MembershipDisposition = .{ .independent = .{ .candidate_bundle = id, .reason = .not_selected } };
    for (c.plan.groups, slots, selected_id) |group, slot, selected| {
        if (group.id != id) continue;
        return switch (slot) {
            .rail => |rail| if (pb.containsEdge(rail.members, edge)) .{ .selected = selected.? } else not_selected,
            .refused => not_selected,
            .none => if (reversalOnly(c, group)) null else not_selected,
        };
    }
    return null;
}

/// The group holds a reversed member and nothing else would bar it: its members are visible, of
/// one kind and one pivot decoration, with no two alike.
fn reversalOnly(c: Ctx, group: pb.CandidateBundle) bool {
    if (!anyIn(group.members, c.reversed)) return false;
    var first: ?sg.Edge = null;
    for (group.members, 0..) |id, i| {
        const edge = c.graph.edgeById(id) orelse return false;
        if (edge.kind == .invisible) return false;
        if (first) |f| {
            if (edge.kind != f.kind or pivotArrow(group.direction, edge) != pivotArrow(group.direction, f)) return false;
        } else first = edge;
        for (group.members[0..i]) |prior| if (sameKey(edge, c.graph.edgeById(prior).?)) return false;
    }
    return first != null;
}

fn sameKey(x: sg.Edge, y: sg.Edge) bool {
    if (x.from != y.from or x.to != y.to or x.kind != y.kind or x.arrow_from != y.arrow_from or x.arrow_to != y.arrow_to) return false;
    return tie_break.labelOrder(x.label, y.label) == .eq;
}

/// The fusion licence: rails of one direction whose divergent nodes are one set unite when
/// together they declare exactly every pair of sources and targets, each with a forward head.
fn fusion(c: Ctx, selected: []const pb.SelectedBundle) error{OutOfMemory}![]const []const pb.EdgeId {
    var out: std.ArrayListUnmanaged([]const pb.EdgeId) = .empty;
    const united = try c.a.alloc(bool, selected.len);
    @memset(united, false);
    for (selected, 0..) |first, i| {
        if (united[i]) continue;
        var edges: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        var rails: u32 = 0;
        for (selected[i..], i..) |other, j| {
            if (united[j] or !sameDivergent(c, first, other)) continue;
            united[j] = true;
            rails += 1;
            try edges.appendSlice(c.a, other.members);
        }
        if (rails < 2 or !try complete(c, edges.items)) continue;
        std.mem.sort(pb.EdgeId, edges.items, {}, std.sort.asc(pb.EdgeId));
        try out.append(c.a, edges.items);
    }
    return out.toOwnedSlice(c.a);
}

fn sameDivergent(c: Ctx, x: pb.SelectedBundle, y: pb.SelectedBundle) bool {
    const dir = directionOf(c, x) orelse return false;
    if (directionOf(c, y) != dir) return false;
    return divergentIn(c, dir, x.members, y.members) and divergentIn(c, dir, y.members, x.members);
}

fn directionOf(c: Ctx, bundle: pb.SelectedBundle) ?pb.BundleDirection {
    for (c.plan.groups) |g| if (g.id == bundle.candidate_bundle) return g.direction;
    return null;
}

fn divergentIn(c: Ctx, dir: pb.BundleDirection, xs: []const pb.EdgeId, ys: []const pb.EdgeId) bool {
    for (xs) |xi| {
        const x = c.graph.edgeById(xi) orelse return false;
        const held = for (ys) |yi| {
            const y = c.graph.edgeById(yi) orelse return false;
            if (divergentOf(dir, y) == divergentOf(dir, x)) break true;
        } else false;
        if (!held) return false;
    }
    return true;
}

fn complete(c: Ctx, members: []const pb.EdgeId) error{OutOfMemory}!bool {
    var sources: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    var targets: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    var pairs: std.ArrayListUnmanaged([2]sg.NodeId) = .empty;
    var style: ?u48 = null;
    for (members) |id| {
        const edge = c.graph.edgeById(id) orelse return false;
        if (edge.kind == .invisible or !sg.forwardOneWayHead(edge)) return false;
        const key: u48 = (@as(u48, tie_break.edgeKindOrdinal(edge.kind)) << 8) |
            (@as(u48, @intFromEnum(edge.arrow_from)) << 4) | @intFromEnum(edge.arrow_to);
        if (style) |s| {
            if (s != key) return false;
        } else style = key;
        if (std.mem.indexOfScalar(sg.NodeId, sources.items, edge.from) == null) try sources.append(c.a, edge.from);
        if (std.mem.indexOfScalar(sg.NodeId, targets.items, edge.to) == null) try targets.append(c.a, edge.to);
        const seen = for (pairs.items) |p| {
            if (p[0] == edge.from and p[1] == edge.to) break true;
        } else false;
        if (!seen) try pairs.append(c.a, .{ edge.from, edge.to });
    }
    if (sources.items.len <= 1 or targets.items.len <= 1) return false;
    return pairs.items.len == sources.items.len * targets.items.len;
}

fn divergentOf(dir: pb.BundleDirection, edge: sg.Edge) sg.NodeId {
    return if (dir == .in) edge.from else edge.to;
}

fn pivotArrow(dir: pb.BundleDirection, edge: sg.Edge) sg.ArrowEnd {
    return if (dir == .out) edge.arrow_from else edge.arrow_to;
}

fn without(a: std.mem.Allocator, members: []const pb.EdgeId, drop: []const pb.EdgeId) error{OutOfMemory}![]const pb.EdgeId {
    var out: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (members) |m| if (!pb.containsEdge(drop, m)) try out.append(a, m);
    return out.toOwnedSlice(a);
}

fn anyIn(members: []const pb.EdgeId, edges: []const pb.EdgeId) bool {
    for (members) |m| if (pb.containsEdge(edges, m)) return true;
    return false;
}

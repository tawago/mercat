const std = @import("std");
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const rc = @import("../base/rail_closure.zig");
const fan_mod = @import("fan.zig");
const sugiyama = @import("sugiyama.zig");

const Fan = fan_mod.Fan;

const Claim = struct {
    members: []rc.Member,
    verdict: rc.Verdict,
    claiming: bool,
};

/// @guarded-by: fan_lanes_test.zig "a clustered undirected fan with no declared leaf pairs unfuses onto separate lanes"
pub fn refuseUndeclared(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    fans: []Fan,
    invisible: std.AutoHashMapUnmanaged(sg.EdgeId, void),
    report: ?*pb.ClosureCounts,
) error{OutOfMemory}!void {
    const claims = try a.alloc(Claim, fans.len);
    defer a.free(claims);
    for (fans, claims) |f, *claim| {
        claim.members = try membersOf(a, graph, lg, f, invisible);
        claim.verdict = .{ .outcome = .untouched };
        claim.claiming = false;
    }
    // @guarded-by: layout_test2.zig "a production render carries the closure licence's counts on its Sketch"
    const order = try a.alloc(usize, claims.len);
    defer a.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, claims, widestProposalFirst);
    for (order, 0..) |ci, rank| {
        const claim = &claims[ci];
        var kept: std.ArrayListUnmanaged(rc.Member) = .empty;
        for (claim.members) |m| {
            var subordinated = false;
            for (order[0..rank]) |pi| {
                if (!claims[pi].claiming) continue;
                for (claims[pi].verdict.discharges) |d| if (d.backer == m.edge) {
                    subordinated = true;
                };
            }
            if (!subordinated) try kept.append(a, m);
        }
        a.free(claim.members);
        claim.members = try kept.toOwnedSlice(a);
        if (claim.members.len < 2) continue;
        claim.verdict = try rc.decide(a, claim.members, try backersOf(a, graph, claim.members));
        claim.claiming = claim.verdict.outcome == .keep or claim.verdict.outcome == .salvage;
        if (report) |r| {
            if (claim.verdict.outcome == .refuse or claim.verdict.outcome == .salvage) r.rail_closure_undeclared += 1;
            r.co_undeclared += claim.verdict.undeclared_pairs;
        }
    }

    const refused = try reserve(a, claims, report);
    defer a.free(refused);

    for (fans, claims, refused) |*f, claim, lost_pair| {
        defer a.free(claim.members);
        if (lost_pair) {
            assignPrivateLanes(f, claim.members, &.{}, invisible);
            continue;
        }
        switch (claim.verdict.outcome) {
            .untouched, .keep => {},
            .refuse, .salvage => assignPrivateLanes(f, claim.members, claim.verdict.members, invisible),
        }
    }
}

/// @guarded-by: fan_lanes_test.zig "two clustered rails implying one declared leaf pair both refuse"
fn reserve(a: std.mem.Allocator, claims: []Claim, report: ?*pb.ClosureCounts) error{OutOfMemory}![]bool {
    const order = try a.alloc(usize, claims.len);
    defer a.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, claims, widestFirst);

    const refused = try a.alloc(bool, claims.len);
    @memset(refused, false);
    for (order, 0..) |x, rank| {
        if (!claims[x].claiming) continue;
        for (order[rank + 1 ..]) |y| {
            if (!claims[y].claiming or !sharesPair(claims[x].verdict, claims[y].verdict)) continue;
            refused[x] = true;
            refused[y] = true;
        }
    }
    for (refused, claims) |hit, claim| {
        if (hit and claim.verdict.outcome != .salvage) {
            if (report) |r| r.rail_closure_undeclared += 1;
        }
    }
    return refused;
}

fn widestProposalFirst(claims: []const Claim, x: usize, y: usize) bool {
    const nx = claims[x].members.len;
    const ny = claims[y].members.len;
    return if (nx == ny) x < y else nx > ny;
}

fn widestFirst(claims: []const Claim, x: usize, y: usize) bool {
    const nx = claims[x].verdict.members.len;
    const ny = claims[y].verdict.members.len;
    return if (nx == ny) x < y else nx > ny;
}

fn sharesPair(x: rc.Verdict, y: rc.Verdict) bool {
    for (x.discharges) |dx| {
        for (y.discharges) |dy| {
            if (dx.pair[0] == dy.pair[0] and dx.pair[1] == dy.pair[1]) return true;
        }
    }
    return false;
}

fn membersOf(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    f: Fan,
    invisible: std.AutoHashMapUnmanaged(sg.EdgeId, void),
) error{OutOfMemory}![]rc.Member {
    var out: std.ArrayListUnmanaged(rc.Member) = .empty;
    for (f.peers) |p| {
        if (invisible.contains(p.edge_id)) continue;
        const edge = edgeById(graph, p.edge_id) orelse continue;
        const leaf = if (p.long) (if (f.direction == .out) edge.to else edge.from) else nodeId(lg, p.peer_idx);
        out.append(a, .{
            .edge = p.edge_id,
            .leaf = leaf,
            .kind = kindOrdinal(edge.kind),
            .arrow_free = sg.arrowFree(edge),
            .undecorated = sg.undecorated(edge),
        }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a);
}

fn backersOf(a: std.mem.Allocator, graph: sg.SemGraph, members: []const rc.Member) error{OutOfMemory}![]rc.Backer {
    var out: std.ArrayListUnmanaged(rc.Backer) = .empty;
    for (graph.edges) |edge| {
        if (edge.from == edge.to) continue;
        var is_member = false;
        for (members) |m| {
            if (m.edge == edge.id) is_member = true;
        }
        if (is_member) continue;
        try out.append(a, .{
            .edge = edge.id,
            .a = edge.from,
            .b = edge.to,
            .kind = kindOrdinal(edge.kind),
            .undecorated = sg.undecorated(edge),
            .unlabeled = edge.label == null or edge.label.?.len == 0,
        });
    }
    return out.toOwnedSlice(a);
}

fn assignPrivateLanes(
    f: *Fan,
    members: []const rc.Member,
    kept: []const rc.EdgeId,
    invisible: std.AutoHashMapUnmanaged(sg.EdgeId, void),
) void {
    var next: u32 = if (kept.len == 0) 0 else 1;
    for (f.peers) |*peer| {
        if (invisible.contains(peer.edge_id) or rc.contains(kept, peer.edge_id)) continue;
        var modeled = false;
        for (members) |m| {
            if (m.edge == peer.edge_id) modeled = true;
        }
        if (!modeled) continue;
        peer.lane = next;
        next += 1;
    }
}

fn nodeId(lg: sugiyama.LayeredGraph, idx: u32) sg.NodeId {
    return switch (lg.nodes[idx]) {
        .real => |id| id,
        .virtual => 0,
    };
}

fn edgeById(graph: sg.SemGraph, id: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| {
        if (edge.id == id) return edge;
    }
    return null;
}

fn kindOrdinal(kind: sg.EdgeKind) u8 {
    return pb.edgeKindOrdinal(kind);
}

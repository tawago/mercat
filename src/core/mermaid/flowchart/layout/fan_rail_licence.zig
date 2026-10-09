const std = @import("std");
const sg = @import("../sem_graph.zig");
const tie_break = @import("../base/tie_break.zig");
const rc = @import("../base/rail_closure.zig");
const fan_mod = @import("fan.zig");
const sugiyama = @import("sugiyama.zig");
const bundle_commit = @import("bundle_commit.zig");

const Fan = fan_mod.Fan;

const Claim = struct {
    members: []rc.Member,
    verdict: rc.Verdict,
    claiming: bool,
};

pub fn refuseUndeclared(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    fans: []Fan,
    invisible: std.AutoHashMapUnmanaged(sg.EdgeId, void),
) error{OutOfMemory}!void {
    const claims = try a.alloc(Claim, fans.len);
    defer a.free(claims);
    for (fans, claims) |f, *claim| {
        claim.members = try membersOf(a, graph, lg, f, invisible);
        claim.verdict = .{ .outcome = .untouched };
        claim.claiming = false;
    }
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
                if (rc.backs(claims[pi].verdict.discharges, m.edge)) subordinated = true;
            }
            if (!subordinated) try kept.append(a, m);
        }
        a.free(claim.members);
        claim.members = try kept.toOwnedSlice(a);
        if (claim.members.len < 2) continue;
        claim.verdict = try rc.decide(a, claim.members, try bundle_commit.backersOf(a, graph, claim.members));
        claim.claiming = claim.verdict.outcome == .keep or claim.verdict.outcome == .salvage;
    }

    const refused = try reserve(a, claims);
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

fn reserve(a: std.mem.Allocator, claims: []Claim) error{OutOfMemory}![]bool {
    const order = try a.alloc(usize, claims.len);
    defer a.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    std.mem.sort(usize, order, claims, widestFirst);

    const refused = try a.alloc(bool, claims.len);
    @memset(refused, false);
    for (order, 0..) |x, rank| {
        if (!claims[x].claiming) continue;
        for (order[rank + 1 ..]) |y| {
            if (!claims[y].claiming or !rc.sharesPair(claims[x].verdict.discharges, claims[y].verdict.discharges)) continue;
            refused[x] = true;
            refused[y] = true;
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
        const edge = graph.edgeById(p.edge_id) orelse continue;
        const leaf = if (p.long) (if (f.direction == .out) edge.to else edge.from) else nodeId(lg, p.peer_idx);
        out.append(a, .{
            .edge = p.edge_id,
            .leaf = leaf,
            .kind = tie_break.edgeKindOrdinal(edge.kind),
            .arrow_free = sg.arrowFree(edge),
            .undecorated = sg.undecorated(edge),
        }) catch return error.OutOfMemory;
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

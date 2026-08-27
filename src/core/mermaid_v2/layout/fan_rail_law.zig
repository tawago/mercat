//! fan_rail_law.zig — the all-arrow-free shared-rail closure law applied to
//! DETECTED FANS, for the renders that have no realized plan to apply it to.
//!
//! Where a plan realized — a flat graph, or a cluster-free piece realizing
//! its own plan — the law is decided before sizing by
//! `join_commit.buildReported`: a refused rail's members take `independent`
//! dispositions and `fan_lanes`' per-member pass gives each its own rail row.
//! A render with no realized plan (a motif-packed candidate, a plan
//! failure) has no permits, no dispositions, nothing for that pass to read —
//! its fans fuse on lane 0 by default. That is where an undeclared leaf pair
//! would survive untouched, so the same predicate (base/rail_closure.zig)
//! runs here, directly over the child graph the fans were detected in.
//!
//! Refusal-only by design. The flat path additionally CO-REALIZES a kept
//! rail's backing edges (withholding them from routing); a recursion child
//! must not, because its edge ids are piece-local — `cluster/stitch.zig`
//! rewrites them into the merged id space, and an id-keyed withholding
//! decided before that rewrite would name the wrong edge afterwards. A kept
//! rail here simply keeps its fusion, and the backing edge keeps its own ink:
//! a relation drawn twice, never one invented.
//!
//! The plan-wide clause runs here all the same. A pair is spendable ONCE:
//! two rails whose crossbars imply the same leaf pair fabricate together even
//! though each tells the truth alone — the reader walks one crossbar, down a
//! shared leaf column, and along the other, arriving at a relation neither
//! declaration covers. Geometry, not bookkeeping, is what makes that trace
//! readable, so it does not care that this path discharges nothing: both
//! rails refuse. The over-refusal the flat lever has to guard against — the
//! fully declared clique, whose pair edges are themselves rails — cannot
//! arise here, and `reserve` says why.
//!
//! Allowed imports (layout zone): std + sem_graph + layout siblings + base.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const rc = @import("../base/rail_closure.zig");
const fan_mod = @import("fan.zig");
const sugiyama = @import("sugiyama.zig");

const Fan = fan_mod.Fan;

/// One fan's proposed rail, judged: the closure members it models plus the
/// predicate's answer about them.
const Claim = struct {
    members: []rc.Member,
    verdict: rc.Verdict,
    /// Cleared when the plan-wide clause takes the rail's fusion away.
    claiming: bool,
};

/// Give every member of an undeclared all-arrow-free fan its own rail lane,
/// so the fan's rails no longer fuse into one crossbar asserting leaf pairs
/// the graph never declared. Fans the law leaves alone (directed, mixed, or
/// fully declared) keep every lane at zero — byte-identical.
///
/// `invisible` are edges drawing no ink: they can neither fuse nor fabricate,
/// so they are outside the rail model entirely (same exclusion `fan_lanes`
/// applies when it builds its trunks).
/// guarded-by: fan_lanes_test.zig "a clustered undirected fan with no declared leaf pairs unfuses onto separate lanes"
pub fn refuseUndeclared(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    fans: []Fan,
    invisible: std.AutoHashMapUnmanaged(sg.EdgeId, void),
    /// Report-only sink: the same counts the flat commitment fills, so a
    /// clustered refusal is counted where a flat one is.
    report: ?*pb.ClosureCounts,
) error{OutOfMemory}!void {
    // Per-rail pass: each fan judged against the declarations around it.
    const claims = try a.alloc(Claim, fans.len);
    defer a.free(claims);
    for (fans, claims) |f, *claim| {
        claim.members = try membersOf(a, graph, lg, f, invisible);
        claim.verdict = try rc.decide(a, claim.members, try backersOf(a, graph, claim.members));
        claim.claiming = claim.verdict.outcome == .keep or claim.verdict.outcome == .salvage;
        if (report) |r| {
            if (claim.verdict.outcome == .refuse or claim.verdict.outcome == .salvage) r.rail_closure_undeclared += 1;
            r.co_undeclared += claim.verdict.undeclared_pairs;
        }
    }

    // Plan-wide pass: at most one rail per implied pair, both refuse otherwise.
    const refused = try reserve(a, claims, report);
    defer a.free(refused);

    for (fans, claims, refused) |*f, claim, lost_pair| {
        defer a.free(claim.members);
        // A rail the reservation took apart keeps nothing: its whole member
        // set goes to private lanes, exactly like an outright refusal.
        if (lost_pair) {
            assignPrivateLanes(f, claim.members, &.{}, invisible);
            continue;
        }
        switch (claim.verdict.outcome) {
            .untouched, .keep => {},
            // Refuse: no subset fuses truthfully, so every member gets its own
            // row. Salvage: the kept subset stays on lane 0 (one truthful
            // crossbar) and only the excluded members are lifted off it.
            .refuse, .salvage => assignPrivateLanes(f, claim.members, claim.verdict.members, invisible),
        }
    }
}

/// The plan-wide clause: an implied leaf pair may be claimed by AT MOST ONE
/// rail, and a second claimant makes it nobody's. Returns one flag per claim
/// — true where the rail must give its fusion up.
///
/// The flat lever pairs this clause with a SUBORDINATION one: a candidate
/// every one of whose members is a wider rail's backing declaration is that
/// rail's discharge seen from the other side, and counting it as a second
/// claimant refuses the fully declared clique. No such candidate exists here.
/// `fan.detect` admits only peers exactly one layer from the pivot, so a
/// rail's leaves all share ONE layer and every declaration between two of
/// them is an intra-layer edge — which no fan can ever hold as a member. A
/// discharge is therefore never somebody else's rail on this path, and the
/// clause has nothing to subordinate.
/// guarded-by: fan_lanes_test.zig "two clustered rails implying one declared leaf pair both refuse"
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
        // A salvage was already counted by the per-rail pass; counting the
        // same group twice would tell the harness two rails refused.
        if (hit and claim.verdict.outcome != .salvage) {
            if (report) |r| r.rail_closure_undeclared += 1;
        }
    }
    return refused;
}

/// Wider rails first, then by fan order — the deterministic claim order.
fn widestFirst(claims: []const Claim, x: usize, y: usize) bool {
    const nx = claims[x].verdict.members.len;
    const ny = claims[y].verdict.members.len;
    return if (nx == ny) x < y else nx > ny;
}

/// The two rails imply one and the same unordered leaf pair. `pair` is
/// already normalized low-id first by the closure law.
fn sharesPair(x: rc.Verdict, y: rc.Verdict) bool {
    for (x.discharges) |dx| {
        for (y.discharges) |dy| {
            if (dx.pair[0] == dy.pair[0] and dx.pair[1] == dy.pair[1]) return true;
        }
    }
    return false;
}

/// The fan's ink-drawing peers as closure members: the LEAF is the peer node
/// (the pivot is the other end of every member by construction).
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
        out.append(a, .{
            .edge = p.edge_id,
            .leaf = nodeId(lg, p.peer_idx),
            .kind = kindOrdinal(edge.kind),
            .arrow_free = sg.arrowFree(edge),
        }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a);
}

/// Every declared non-self edge that is not itself a member of this rail.
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
            .arrow_free = sg.arrowFree(edge),
            .unlabeled = edge.label == null or edge.label.?.len == 0,
        });
    }
    return out.toOwnedSlice(a);
}

/// Lane 0 stays the shared crossbar (empty on a full refusal, the salvaged
/// remainder otherwise); every excluded member is lifted onto a row of its
/// own, in the fan's own peer order.
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
        // Fans never contain virtual peers (see fan.detect).
        .virtual => 0,
    };
}

fn edgeById(graph: sg.SemGraph, id: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| {
        if (edge.id == id) return edge;
    }
    return null;
}

/// The ledger's pinned stroke-class ordinal table — the same one the flat
/// lever projects through, so both sites compare stroke classes alike.
fn kindOrdinal(kind: sg.EdgeKind) u8 {
    return pb.edgeKindOrdinal(kind);
}

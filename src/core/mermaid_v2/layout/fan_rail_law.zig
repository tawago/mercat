//! fan_rail_law.zig — the all-arrow-free shared-rail closure law applied to
//! DETECTED FANS, for the renders that have no realized plan to apply it to.
//!
//! On a flat graph the law is decided once, before sizing, by
//! `join_commit.buildReported`: a refused rail's members take `independent`
//! dispositions and `fan_lanes`' per-member pass gives each its own rail row.
//! A clustered or recursed render carries the EMPTY plan (V-D-IR-07) — no
//! permits, no dispositions, nothing for that pass to read — and its fans
//! fuse on lane 0 by default. That is where an undeclared leaf pair would
//! survive untouched, so the same predicate (base/rail_closure.zig) runs
//! here, directly over the child graph the fans were detected in.
//!
//! Refusal-only by design. The flat path additionally CO-REALIZES a kept
//! rail's backing edges (withholding them from routing); a recursion child
//! must not, because its edge ids are piece-local — `cluster/stitch.zig`
//! rewrites them into the merged id space, and an id-keyed withholding
//! decided before that rewrite would name the wrong edge afterwards. A kept
//! rail here simply keeps its fusion, and the backing edge keeps its own ink:
//! a relation drawn twice, never one invented.
//!
//! Allowed imports (layout zone): std + sem_graph + layout siblings + base.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const rc = @import("../base/rail_closure.zig");
const fan_mod = @import("fan.zig");
const sugiyama = @import("sugiyama.zig");

const Fan = fan_mod.Fan;

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
    // Every candidate rail's own ink is DRAWN plan-wide before any verdict, and
    // the record must not depend on the order the fans happen to be visited: a
    // declaration another fan already inks licenses a pair here (the relation
    // is on the page) but is never discharged. This pass discharges nothing at
    // all (see the module docs), so `drawn` is the whole record.
    var drawn: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    defer drawn.deinit(a);
    for (fans) |f| {
        for (f.peers) |p| {
            if (!invisible.contains(p.edge_id)) try drawn.append(a, p.edge_id);
        }
    }

    for (fans) |*f| {
        const members = try membersOf(a, graph, lg, f.*, invisible);
        defer a.free(members);
        const verdict = try rc.decide(a, members, try backersOf(a, graph, members, drawn.items));
        if (report) |r| {
            if (verdict.outcome == .refuse or verdict.outcome == .salvage) r.rail_closure_undeclared += 1;
            r.co_undeclared += verdict.undeclared_pairs;
        }
        switch (verdict.outcome) {
            .untouched, .keep => {},
            // Refuse: no subset fuses truthfully, so every member gets its own
            // row. Salvage: the kept subset stays on lane 0 (one truthful
            // crossbar) and only the excluded members are lifted off it.
            .refuse, .salvage => assignPrivateLanes(f, members, verdict.members, invisible),
        }
    }
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
            .arrow_free = edge.arrow_from == .none and edge.arrow_to == .none,
        }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a);
}

/// Every declared non-self edge that is not itself a member of this rail.
/// `drawn` names the edges some fan already inks — usable as a licence, never
/// dischargeable.
fn backersOf(a: std.mem.Allocator, graph: sg.SemGraph, members: []const rc.Member, drawn: []const sg.EdgeId) error{OutOfMemory}![]rc.Backer {
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
            .arrow_free = edge.arrow_from == .none and edge.arrow_to == .none,
            .unlabeled = edge.label == null or edge.label.?.len == 0,
            .drawn = rc.contains(drawn, edge.id),
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

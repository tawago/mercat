//! Two-sided fan lane separation.
//! Several fans that share one inter-layer gap put their
//! horizontal rails on the SAME row (`fan_polyline`/`fan_rail` both anchor
//! `rail_y` to the target perimeter). When two such rails occupy
//! overlapping-or-abutting x-spans they FUSE at raster time into one
//! continuous `├──┼──┤` run — one run standing for a shared endpoint. If the
//! UNION of the fused rails' declared edges is TWO-SIDED (more than one
//! distinct source AND more than one distinct target) there is no shared
//! endpoint to stand for, and the run speaks for a pivot nothing in the source
//! declares — unless the source declares every pair that run asserts, which is
//! the closure test stated below.
//! This pass groups rail-producing rails by collinear overlap and assigns
//! each a row. Distinct rails land on distinct rows, so each edge
//! keeps its own traceable rail; honest merges (a shared target column) are
//! preserved as a single vertical.
//! Inert (every `lane == 0`, byte-identical) for gaps with a single rail and
//! for pure fan-in or fan-out groups (N==1 or M==1; a lone pivot never
//! fabricates). Beyond that the gate is the declared-pair closure test
//! `base/rail_closure.zig` states: a run may fuse only
//! where the source DECLARES every leaf pair the run would ASSERT, and what
//! it asserts turns on whether a leaf-to-leaf trace RUNS AGAINST AN ARROW,
//! which takes a one-way head. A run one of whose members does not block the
//! trace asserts every unordered pair among its endpoints, so a two-sided
//! group asserts within-side pairs no two-sided source declares and is refused
//! — unchanged. A run every member of which blocks it asserts only the cross
//! pairs, so a two-sided group whose declared set is the whole of srcs x tgts
//! asserts nothing undeclared and keeps one shared row.
//!
//! The test is asked of the group's MODEL. A model missing ink is not a
//! declaration count: a discharged edge and a peer on its pivot's own column
//! draw no run of their own yet touch the shared crossbar, and dropping them
//! can make an incomplete group read complete. Such a gap never takes it.
//!
//! Runs after x-assignment and before row reservation. It is keyed only on gap
//! topology and geometry.
const std = @import("std");
const sg = @import("../sem_graph.zig");
const fan_mod = @import("fan.zig");
const sugiyama = @import("sugiyama.zig");
const lanes = @import("../base/lanes.zig");
const pb = @import("../base/ledger.zig");
const rc = @import("../base/rail_closure.zig");
const rail_law = @import("fan_rail_law.zig");

const Fan = fan_mod.Fan;
const Edge = struct { from: sg.NodeId, to: sg.NodeId, blocks_leaf_trace: bool, style: u16 };

const Pair = struct { lo: sg.NodeId, hi: sg.NodeId };

// The one-way-head-at-target test lives in sem_graph.forwardOneWayHead,
// shared with the plan-side fusion licence (`layout/bundle_commit.zig`): a head
// at the SOURCE end also stops a trace, but in the direction a fused rail
// would read backwards, so only a forward head qualifies a member.
const forwardOneWayHead = sg.forwardOneWayHead;

/// Stroke kind + both head glyphs: members of ONE fused run must agree on all
/// three, or the shared ink restates somebody's declaration in a foreign style.
fn styleKey(e: sg.Edge) u16 {
    return (@as(u16, pb.edgeKindOrdinal(e.kind)) << 8) |
        (@as(u16, @intFromEnum(e.arrow_from)) << 4) | @intFromEnum(e.arrow_to);
}

const Rail = struct {
    fan_idx: u32,
    gap: u32,
    lo: i32,
    hi: i32,
    edges: []Edge,
    /// False for a MODEL-ONLY rail: every member sits on the pivot column,
    /// so it draws pure verticals and owns no run to lane-separate.
    has_run: bool,
    /// A fan-OUT whose every peer rides a selected arrival rail: it stays in
    /// the MODEL yet draws nothing, so it is never foreign ink to a class.
    phantom: bool,
};

fn centerX(comptime G: type, g: G) i32 {
    return g.x + @divTrunc(@as(i32, @intCast(g.w)), 2);
}

fn nodeId(lg: sugiyama.LayeredGraph, idx: u32) sg.NodeId {
    return switch (lg.nodes[idx]) {
        .real => |id| id,
        // Fans never contain virtual peers/pivots (see fan.detect); this is
        // unreachable for any fan-derived index.
        .virtual => 0,
    };
}

/// Assign `fan.lane` for every fan so that no incomplete-bipartite group of
/// rails fuses into a fabricating run. Mutates `fans` in place; leaves every
/// lane at 0 when nothing fabricates. `geom` is parallel to `lg.nodes`.
pub fn assignLanes(
    comptime G: type,
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const G,
    fans: []Fan,
    bundles: pb.RealizedBundles,
    /// Report-only closure-law sink for the clustered arm (null in tests).
    report: ?*pb.ClosureCounts,
) error{OutOfMemory}!void {
    if (fans.len == 0 or lg.layers.len < 2) return;
    const ngaps: u32 = @intCast(lg.layers.len - 1);

    // Invisible and discharged links draw no independent rail ink.
    var invisible: std.AutoHashMapUnmanaged(sg.EdgeId, void) = .empty;
    defer invisible.deinit(a);
    var blocking: std.AutoHashMapUnmanaged(sg.EdgeId, void) = .empty;
    defer blocking.deinit(a);
    var style_of: std.AutoHashMapUnmanaged(sg.EdgeId, u16) = .empty;
    defer style_of.deinit(a);
    for (graph.edges) |e| {
        if (e.kind == .invisible or rc.contains(bundles.discharged, e.id)) try invisible.put(a, e.id, {});
        if (forwardOneWayHead(e)) try blocking.put(a, e.id, {});
        try style_of.put(a, e.id, styleKey(e));
    }

    // A rail model missing ink that still touches a crossbar is not complete.
    // guarded-by: fan_lanes_test2.zig "a discharged edge never shrinks a group into looking complete"
    var pruned_gaps: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer pruned_gaps.deinit(a);

    // Edges that a fan-OUT owns: their rail belongs to the fan-OUT rail, so a
    // fan-IN into the same target must NOT double-count them as its own rail
    // (the fan-IN would otherwise inflate a group with a phantom rail).
    //
    // A fan-OUT EVERY one of whose peers was selected into an arrival rail is
    // the exception: it draws no run of its own, so there is nothing to defer
    // to and the arrivals ARE the rails of that gap. That is the shape a
    // complete all-to-all takes — every edge is somebody's arrival member —
    // and without this its arrivals model no rail at all, so nothing keeps
    // their crossbars off one shared row.
    // guarded-by: fan_lanes_test.zig "a gap whose departures all defer lane-separates the arrival rails that draw its rails"
    var fanout_edges: std.AutoHashMapUnmanaged(sg.EdgeId, void) = .empty;
    defer fanout_edges.deinit(a);
    for (fans) |f| {
        if (f.direction != .out or allPeersJoinArrivals(f, bundles)) continue;
        for (f.peers) |p| if (p.shared) try fanout_edges.put(a, p.edge_id, {});
    }

    var rails: std.ArrayListUnmanaged(Rail) = .empty;
    defer {
        for (rails.items) |t| a.free(t.edges);
        rails.deinit(a);
    }
    for (fans, 0..) |f, fi| {
        if (f.source_layer >= ngaps) continue;
        const pivot_cx = centerX(G, geom[f.pivot_idx]);
        var lo: i32 = pivot_cx;
        var hi: i32 = pivot_cx;
        var has_run = false;
        var edges: std.ArrayListUnmanaged(Edge) = .empty;
        errdefer edges.deinit(a);

        if (f.direction == .out) {
            // A fan-OUT draws its rail (first-class or per-peer polyline) for every
            // visible peer.
            for (f.peers) |p| {
                if (!p.shared) continue;
                if (invisible.contains(p.edge_id)) {
                    if (rc.contains(bundles.discharged, p.edge_id)) try pruned_gaps.put(a, f.source_layer, {});
                    continue;
                }
                const cx = centerX(G, geom[p.peer_idx]);
                if (cx != pivot_cx) has_run = true;
                lo = @min(lo, cx);
                hi = @max(hi, cx);
                try edges.append(a, .{
                    .from = nodeId(lg, f.pivot_idx),
                    .to = nodeId(lg, p.peer_idx),
                    .blocks_leaf_trace = blocking.contains(p.edge_id),
                    .style = style_of.get(p.edge_id) orelse 0,
                });
            }
        } else {
            // A fan-IN draws a rail only for peers it actually owns: edges also
            // owned by a fan-OUT are drawn by that fan-OUT, and a peer sitting
            // on the pivot column descends straight (no horizontal rail).
            for (f.peers) |p| {
                if (!p.shared) continue;
                if (invisible.contains(p.edge_id)) {
                    if (rc.contains(bundles.discharged, p.edge_id)) try pruned_gaps.put(a, f.source_layer, {});
                    continue;
                }
                if (fanout_edges.contains(p.edge_id)) continue;
                const cx = centerX(G, geom[p.peer_idx]);
                // A peer on the pivot's own column draws no horizontal run,
                // but its vertical still touches the crossbar, so it stays in
                // the MODEL (never widening the span): dropping it could make
                // an incomplete group read complete.
                // guarded-by: fan_lanes_test2.zig "a peer on its pivot's own column never shrinks a group into looking complete"
                if (cx != pivot_cx) has_run = true;
                lo = @min(lo, cx);
                hi = @max(hi, cx);
                try edges.append(a, .{
                    .from = nodeId(lg, p.peer_idx),
                    .to = nodeId(lg, f.pivot_idx),
                    .blocks_leaf_trace = blocking.contains(p.edge_id),
                    .style = style_of.get(p.edge_id) orelse 0,
                });
            }
        }
        if (edges.items.len == 0) {
            edges.deinit(a);
            continue;
        }
        try rails.append(a, .{
            .fan_idx = @intCast(fi),
            .gap = f.source_layer,
            .lo = lo,
            .hi = hi,
            .edges = try edges.toOwnedSlice(a),
            .has_run = has_run,
            .phantom = f.direction == .out and allPeersJoinArrivals(f, bundles),
        });
    }

    var gap: u32 = 0;
    while (gap < ngaps) : (gap += 1) {
        var members: std.ArrayListUnmanaged(u32) = .empty;
        defer members.deinit(a);
        for (rails.items, 0..) |t, ti| {
            if (t.gap == gap) try members.append(a, @intCast(ti));
        }
        if (members.items.len < 2) continue;
        try processGap(a, rails.items, members.items, fans, pruned_gaps.contains(gap));
    }

    // Clustered/recursed renders have no plan, so apply the closure law here.
    if (bundles.memberships.len == 0) {
        try refuseSharedOnly(a, graph, lg, fans, invisible, report);
        separatePrivatePeers(fans);
        return;
    }

    // A carve-out-unrealized fan is edge-owned. A PARTLY selected fan still
    // owns lane `fan.lane`, so
    // the independent members start one lane ABOVE it. Starting at the fan's
    // own lane would put an excluded member back on the crossbar it was
    // excluded from — re-fusing exactly the pair the salvage refused, and
    // handing the reach oracle an unlicensed shared cell.
    // guarded-by: fan_lanes_test.zig "a salvaged fan's excluded members never land on the kept rail's lane"
    for (fans) |*fan| {
        if (fanSelected(fan.*, bundles)) continue;
        // A fan-OUT every one of whose peers joined an arrival rail draws no
        // run of its own: its members' ink belongs to those arrivals, so no
        // per-member lane (and no reserved row) is owed here.
        if (fan.direction == .out and allPeersJoinArrivals(fan.*, bundles)) continue;
        var next_lane = fan.lane + @as(u32, if (anySelected(fan.*, bundles)) 1 else 0);
        for (fan.peers) |*peer| {
            if (!peer.shared) continue;
            if (invisible.contains(peer.edge_id) or !peerIndependent(fan.direction, peer.edge_id, bundles.memberships)) continue;
            peer.lane = next_lane;
            next_lane += 1;
        }
    }
    separatePrivatePeers(fans);
}

fn refuseSharedOnly(a: std.mem.Allocator, graph: sg.SemGraph, lg: sugiyama.LayeredGraph, fans: []Fan, invisible: std.AutoHashMapUnmanaged(sg.EdgeId, void), report: ?*pb.ClosureCounts) error{OutOfMemory}!void {
    const gated = try a.dupe(Fan, fans);
    for (fans, gated) |source, *target| {
        var peers: std.ArrayListUnmanaged(fan_mod.FanEdge) = .empty;
        for (source.peers) |peer| if (peer.shared) try peers.append(a, peer);
        target.peers = try peers.toOwnedSlice(a);
    }
    try rail_law.refuseUndeclared(a, graph, lg, gated, invisible, report);
    for (gated, fans) |source, *target| {
        target.lane = source.lane;
        for (source.peers) |peer| for (target.peers) |*out| if (out.edge_id == peer.edge_id) {
            out.lane = peer.lane;
            break;
        };
    }
}

fn separatePrivatePeers(fans: []Fan) void {
    for (fans) |*fan| {
        var next = fan.lane + 1;
        for (fan.peers) |peer| if (peer.shared) {
            next = @max(next, peer.lane + 1);
        };
        // Start private rails beyond retained labels' tap-anchor block.
        for (fan.peers) |peer| if (peer.shared and peer.label_width != 0) {
            next += fan_mod.LABEL_RUN_EXTRA_ROWS;
        };
        for (fan.peers) |*peer| {
            if (peer.shared) continue;
            peer.lane = next;
            next += 1 + @as(u32, if (peer.label_width != 0) fan_mod.LABEL_RUN_EXTRA_ROWS else 0);
        }
    }
}

/// True iff a realized plan put EVERY peer of this fan-OUT into an arrival
/// rail, so the departure side draws no run of its own.
fn allPeersJoinArrivals(fan: Fan, bundles: pb.RealizedBundles) bool {
    if (bundles.memberships.len == 0 or fan.peers.len == 0) return false;
    var any = false;
    for (fan.peers) |peer| {
        if (!peer.shared) continue;
        any = true;
        const membership = membershipFor(bundles.memberships, peer.edge_id) orelse return false;
        const arrival = membership.target orelse return false;
        if (arrival != .selected) return false;
    }
    return any;
}

/// True iff at least one peer joined a realized rail — the salvage shape the
/// closure law produces (`fanSelected` demands ALL of them).
fn anySelected(fan: Fan, bundles: pb.RealizedBundles) bool {
    for (fan.peers) |peer| {
        if (!peer.shared) continue;
        const membership = membershipFor(bundles.memberships, peer.edge_id) orelse continue;
        const disposition = if (fan.direction == .out) membership.source else membership.target;
        if (disposition) |value| {
            if (value == .selected) return true;
        }
    }
    return false;
}

fn fanSelected(fan: Fan, bundles: pb.RealizedBundles) bool {
    var selected: ?pb.SelectedBundleId = null;
    for (fan.peers) |peer| {
        if (!peer.shared) continue;
        const membership = membershipFor(bundles.memberships, peer.edge_id) orelse return false;
        const disposition = if (fan.direction == .out) membership.source else membership.target;
        const jid = switch (disposition orelse return false) {
            .selected => |id| id,
            .independent => return false,
        };
        if (selected) |id| {
            if (id != jid) return false;
        } else selected = jid;
    }
    return selected != null;
}

fn peerIndependent(direction: fan_mod.Direction, edge: pb.EdgeId, memberships: []const pb.RealizedEdgeMembership) bool {
    const membership = membershipFor(memberships, edge) orelse return false;
    const disposition = if (direction == .out) membership.source else membership.target;
    return if (disposition) |value| value == .independent else false;
}

fn membershipFor(memberships: []const pb.RealizedEdgeMembership, edge: pb.EdgeId) ?pb.RealizedEdgeMembership {
    for (memberships) |membership| if (membership.edge == edge) return membership;
    return null;
}

fn processGap(
    a: std.mem.Allocator,
    rails: []const Rail,
    members: []const u32,
    fans: []Fan,
    gap_pruned: bool,
) error{OutOfMemory}!void {
    const n = members.len;
    // Union-find over `members` by overlapping/abutting x-spans.
    const parent = try a.alloc(u32, n);
    defer a.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (spansTouch(rails[members[i]], rails[members[j]])) {
                unite(parent, @intCast(i), @intCast(j));
            }
        }
    }

    // For each root, gather its group and process it.
    var seen: std.ArrayListUnmanaged(u32) = .empty;
    defer seen.deinit(a);
    for (0..n) |i| {
        const r = find(parent, @intCast(i));
        var already = false;
        for (seen.items) |s| {
            if (s == r) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try seen.append(a, r);

        var group: std.ArrayListUnmanaged(u32) = .empty;
        defer group.deinit(a);
        for (0..n) |k| {
            if (find(parent, @intCast(k)) == r) try group.append(a, @intCast(k));
        }
        if (group.items.len < 2) continue;
        try laneAssignGroup(a, rails, members, group.items, fans, gap_pruned);
    }
}

fn laneAssignGroup(
    a: std.mem.Allocator,
    rails: []const Rail,
    members: []const u32,
    group: []const u32,
    fans: []Fan,
    gap_pruned: bool,
) error{OutOfMemory}!void {
    if (!fusionForbidden(a, rails, members, group, gap_pruned)) return;

    // A refused union may still hold complete SUB-unions: rails of one
    // direction over one and the same leaf set (two disjoint K2,2s chained by
    // a shared source refuse as a whole, yet each half is licensable alone).
    // Such a class keeps ONE shared claim; every other rail claims alone.
    // Model-only rails (pure verticals) own no run: they stay lane 0 and
    // take no row of their own.
    var runs: std.ArrayListUnmanaged(u32) = .empty;
    defer runs.deinit(a);
    for (group) |gi| if (rails[members[gi]].has_run) try runs.append(a, gi);

    const claim_of = try a.alloc(u32, runs.items.len);
    defer a.free(claim_of);
    var nclaims: u32 = 0;
    for (runs.items, 0..) |gi, i| {
        claim_of[i] = for (runs.items[0..i], 0..) |gj, j| {
            if (sameFusionClass(rails, members, fans, gi, gj) and
                classFusable(a, rails, members, group, fans, runs.items[0..i], claim_of[0..i], claim_of[j], gap_pruned, gi))
                break claim_of[j];
        } else blk: {
            nclaims += 1;
            break :blk nclaims - 1;
        };
    }

    // Lane-pack: pack each claim's x-span into the innermost lane it fits,
    // treating overlapping/abutting spans as conflicting (so they land on
    // distinct rows). `base = 0` — we only want the lane INDEX.
    var min_x: i32 = std.math.maxInt(i32);
    for (runs.items) |gi| min_x = @min(min_x, rails[members[gi]].lo);

    const demands = try a.alloc(lanes.LaneClaim, nclaims);
    defer a.free(demands);
    for (demands, 0..) |*d, ci| {
        var lo: i32 = std.math.maxInt(i32);
        var hi: i32 = std.math.minInt(i32);
        for (runs.items, claim_of) |gi, c| if (c == ci) {
            lo = @min(lo, rails[members[gi]].lo);
            hi = @max(hi, rails[members[gi]].hi);
        };
        d.* = .{ .lo = @intCast(lo - min_x), .hi = @intCast(hi - min_x), .base = 0 };
    }
    var asg = try lanes.assign(a, demands, 1);
    defer asg.deinit(a);

    for (runs.items, claim_of) |gi, c| {
        fans[rails[members[gi]].fan_idx].lane = asg.lane_of[c];
    }
}

/// One direction, one and the same leaf set — the sub-union key.
fn sameFusionClass(rails: []const Rail, members: []const u32, fans: []const Fan, x_gi: u32, y_gi: u32) bool {
    const x = rails[members[x_gi]];
    const y = rails[members[y_gi]];
    const dx = fans[x.fan_idx].direction;
    if (dx != fans[y.fan_idx].direction) return false;
    return leafSubset(dx, x.edges, y.edges) and leafSubset(dx, y.edges, x.edges);
}

fn leafSubset(dir: fan_mod.Direction, xs: []const Edge, ys: []const Edge) bool {
    for (xs) |x| {
        const leaf = if (dir == .in) x.from else x.to;
        const held = for (ys) |y| {
            if ((if (dir == .in) y.from else y.to) == leaf) break true;
        } else false;
        if (!held) return false;
    }
    return true;
}

/// Would the claim `ci` STAY complete with `gi` joined? Asked of the same
/// closure test the whole group failed, over the claim's current rails + gi —
/// and of the group's OTHER ink: a foreign rail incident to a node whose
/// entry (or, for a departure class, any face) the class's rail serves could
/// merge with the rail at that node, so a reader would trace pairs the class
/// never declared. Placement never decides this: the node incidence does.
fn classFusable(a: std.mem.Allocator, rails: []const Rail, members: []const u32, group: []const u32, fans: []const Fan, runs: []const u32, claim_of: []const u32, ci: u32, gap_pruned: bool, gi: u32) bool {
    var sub: std.ArrayListUnmanaged(u32) = .empty;
    defer sub.deinit(a);
    for (runs, claim_of) |gj, c| {
        if (c == ci) sub.append(a, gj) catch return false;
    }
    sub.append(a, gi) catch return false;
    if (fusionForbidden(a, rails, members, sub.items, gap_pruned)) return false;
    return !foreignTouches(a, rails, members, group, sub.items, fans);
}

fn foreignTouches(a: std.mem.Allocator, rails: []const Rail, members: []const u32, group: []const u32, sub: []const u32, fans: []const Fan) bool {
    var guarded: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    defer guarded.deinit(a);
    const dir = fans[rails[members[sub[0]]].fan_idx].direction;
    for (sub) |gi| for (rails[members[gi]].edges) |e| {
        // An arrival class's rail serves its pivot ENTRIES; a departure
        // class's rail serves both its pivot exits and its target entries.
        addUnique(a, &guarded, e.to) catch return true;
        if (dir == .out) addUnique(a, &guarded, e.from) catch return true;
    };
    for (group) |gi| {
        var in_sub = false;
        for (sub) |sj| if (sj == gi) {
            in_sub = true;
        };
        if (in_sub or rails[members[gi]].phantom) continue;
        for (rails[members[gi]].edges) |e| {
            for (guarded.items) |n| if (e.from == n or e.to == n) return true;
        }
    }
    return false;
}

fn spansTouch(x: Rail, y: Rail) bool {
    return !(x.hi < y.lo or y.hi < x.lo);
}

/// The group's rails must not fuse into one run when the run would assert a
/// leaf pair the source does not declare — the closure test of
/// `base/rail_closure.zig`, asked of a whole group.
///
/// Order matters. A lone pivot on either side (N==1 or M==1) can never
/// fabricate and escapes first. Then a member that does not block the
/// leaf-to-leaf trace makes the run assert UNORDERED pairs, so a two-sided
/// group carrying one is refused outright. Then a gap whose model lost ink is
/// refused, its counts not being a declaration count. A group surviving both
/// asserts only the CROSS pairs, so it may fuse exactly when its declared set
/// IS srcs x tgts. Keyed only on the group's declared edges, their arrow
/// fields, and whether the model is whole: never on a fixture, label, node
/// count, width, or direction.
fn fusionForbidden(
    a: std.mem.Allocator,
    rails: []const Rail,
    members: []const u32,
    group: []const u32,
    gap_pruned: bool,
) bool {
    var srcs: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    defer srcs.deinit(a);
    var tgts: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    defer tgts.deinit(a);
    // Distinct declared pairs, as unordered {min, max} keys. One declared edge
    // CAN be modelled by two rails of a group (a fan-OUT all of whose peers
    // joined arrival rails stays a rail yet is absent from `fanout_edges`),
    // so "the same declared edge" is its unordered endpoint pair; within a gap
    // sources sit on the upper stage and targets on the lower one, so the key
    // never conflates two declarations. Summing `edges.len` would count a
    // twice-modelled edge twice and wrongly admit an incomplete group.
    var pairs: std.ArrayListUnmanaged(Pair) = .empty;
    defer pairs.deinit(a);
    var any_open_trace = false;
    var style: ?u16 = null;
    var style_mixed = false;
    for (group) |gi| {
        for (rails[members[gi]].edges) |e| {
            addUnique(a, &srcs, e.from) catch return true;
            addUnique(a, &tgts, e.to) catch return true;
            addUniquePair(a, &pairs, e) catch return true;
            if (!e.blocks_leaf_trace) any_open_trace = true;
            if (style) |st| {
                if (st != e.style) style_mixed = true;
            } else style = e.style;
        }
    }
    if (srcs.items.len <= 1 or tgts.items.len <= 1) return false;
    if (any_open_trace) return true;
    // Mixed stroke kind or head glyphs: one run would restate a member's
    // declaration in a foreign style, so a two-sided union never fuses mixed.
    if (style_mixed) return true;
    if (gap_pruned) return true;
    return pairs.items.len != srcs.items.len * tgts.items.len;
}

fn addUniquePair(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(Pair), e: Edge) !void {
    const lo = @min(e.from, e.to);
    const hi = @max(e.from, e.to);
    for (list.items) |x| if (x.lo == lo and x.hi == hi) return;
    try list.append(a, .{ .lo = lo, .hi = hi });
}

fn addUnique(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(sg.NodeId), v: sg.NodeId) !void {
    for (list.items) |x| if (x == v) return;
    try list.append(a, v);
}

fn find(parent: []u32, x: u32) u32 {
    var r = x;
    while (parent[r] != r) r = parent[r];
    var c = x;
    while (parent[c] != c) {
        const nx = parent[c];
        parent[c] = r;
        c = nx;
    }
    return r;
}

fn unite(parent: []u32, x: u32, y: u32) void {
    const rx = find(parent, x);
    const ry = find(parent, y);
    if (rx != ry) parent[ry] = rx;
}

test {
    _ = @import("fan_lanes_test.zig");
    _ = @import("fan_lanes_test2.zig");
}

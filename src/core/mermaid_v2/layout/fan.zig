//! Unified decision-fan layout: fan-OUT and fan-IN share one rail row with
//! descent/ascent polylines. `layout.zig` reserves its inter-layer row.

const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const permits = @import("../ledger/permits.zig");
const sugiyama = @import("sugiyama.zig");
const fan_grid = @import("fan_grid.zig");

pub const Direction = enum { out, in };

/// Positional role of a peer within its fan.
pub const ChildRole = enum {
    /// Left-most peer. Owns the outer rail corner.
    leftmost,
    /// Right-most peer. Owns the outer rail corner.
    rightmost,
    /// Middle peer whose column ≠ pivot column.
    middle,
    /// Middle peer whose column == pivot column.
    center,
};

pub const FanEdge = struct {
    edge_id: sg.EdgeId,
    /// Index into lg.nodes of the peer node (child for fan-OUT, source
    /// for fan-IN).
    peer_idx: u32,
    role: ChildRole,
    /// Per-member rail lane for unrealized groups; zero preserves merged ink.
    lane: u32 = 0,
    /// False when the construction gate retained the edge only as private ink.
    shared: bool = true,
    /// Display columns in this member's non-empty label; zero means unlabeled.
    label_width: u32 = 0,
    /// The peer sits beyond the next layer: `peer_idx` names the member's
    /// first virtual node (the corridor cell the tap descends into), and
    /// the leaf is the edge's far end. The rail owns one drop cell; the
    /// member's own `.member_stroke` carries the rest.
    long: bool = false,
};

pub const Fan = struct {
    direction: Direction,
    pivot: sg.NodeId = 0,
    /// Index into lg.nodes of the pivot (source for fan-OUT, target for
    /// fan-IN). Always a real node and always names `pivot`.
    pivot_idx: u32,
    /// Layer index where the SOURCES sit. The rail row lives in the gap
    /// between `source_layer` and `source_layer + 1`.
    source_layer: u32,
    /// Peer edges, in left-to-right order after `assignRoles`.
    peers: []FanEdge,
    /// Number of stacked child rows. 1 = the classic single-row fan
    /// (rail row + one child layer). >1 means a wide fan-OUT was wrapped
    /// into a grid by `wrapWideFanOut` because a single row would exceed
    /// the width budget; each child then carries its own short rail at
    /// its grid row (see buildPolyline's grid branch). Only fan-OUT
    /// wraps; fan-IN keeps rows == 1.
    rows: u32 = 1,
    /// Rail row within its inter-layer gap, 0 = the classic single shared row.
    /// Assigned by `fan_lanes.assignLanes`: a fan whose rail would fuse with a
    /// neighbouring fan's into a TWO-SIDED run — one run standing for a pivot
    /// none of its members shares — is lifted to its own lane so every declared
    /// edge stays traceable. 0 for single-rail gaps and pure fan-in/out.
    lane: u32 = 0,
    /// True iff any member edge carries a label. A labeled fan reserves
    /// `LABEL_RUN_EXTRA_ROWS` extra gap rows (extraRowsPerGap) so each
    /// labeled member's PRIVATE vertical dropper is >= 4 cells long —
    /// flank, on-run label row, flank, arrowhead — the DECORATED sandwich
    /// raster/labels_onrun.zig places over (FLANKED-RESUMPTION RULE: an arrowhead is not a
    /// flank, so the head needs its own cell below the lower flank).
    /// Unlabeled fans stay byte-identical.
    /// @guarded-by: fan_test.zig "a labeled fan reserves three extra gap rows; an unlabeled fan reserves one"
    labeled: bool = false,
    construction_deco_mixed: bool = false,
    construction_style_mixed: bool = false,
    construction_star_violation: bool = false,
};

const PreparedPeers = struct { peers: []FanEdge, deco_mixed: bool = false, style_mixed: bool = false, star_violation: bool = false };

/// The rail row a member's ink actually occupies within the fan's gap:
/// `fan_polyline` paints at exactly this lane, so any grouping of peers
/// into shared-rail sets keys on this value. Sole partition authority (single authority);
/// a partition keyed on `peer.lane` or `f.lane` alone is a re-derivation.
pub fn effectiveLane(f: Fan, peer_lane: u32) u32 {
    return @max(f.lane, peer_lane);
}

/// Extra gap rows a LABELED fan reserves beyond its lane rows: the
/// decorated on-run sandwich needs a 4-cell private dropper (flank, label,
/// flank, head) where the classic gap yields 1.
pub const LABEL_RUN_EXTRA_ROWS: u32 = 3;

pub fn labelRowsOnLane(f: Fan, lane: u32) u32 {
    var labels: u32 = 0;
    for (f.peers) |peer| {
        if (peer.label_width != 0 and effectiveLane(f, peer.lane) == lane) labels += 1;
    }
    return labels * LABEL_RUN_EXTRA_ROWS;
}

pub fn additionalLabelLift(f: Fan, lane: u32) u32 {
    return labelRowsOnLane(f, lane) -| LABEL_RUN_EXTRA_ROWS;
}

/// Detect every fan in the layered graph (both fan-OUT and fan-IN).
/// A node qualifies as a fan-OUT pivot iff it has ≥2 outgoing forward
/// edges; a peer on the immediately-next layer taps the rail directly, a
/// peer reached through a virtual node is a `long` member (the licence
/// reads only the declared graph — distance on the page is not an input).
/// A long member's label rides its own member stroke, not its one-cell
/// drop, so a fan counts it as unlabeled (no label rows reserved for it)
/// and keeps it, labeled or not. Symmetric criterion for fan-IN. Returned
/// slice and inner `peers` slices are arena-allocated via `a`.
pub fn detect(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
) error{OutOfMemory}![]Fan {
    var node_layer = try a.alloc(u32, lg.nodes.len);
    @memset(node_layer, 0);
    for (lg.layers, 0..) |row, li| {
        const lu: u32 = @intCast(li);
        for (row) |idx| node_layer[idx] = lu;
    }

    var fans: std.ArrayListUnmanaged(Fan) = .empty;

    // Two-pass to preserve fan-OUT-then-fan-IN ordering. @guarded-by: fan_test.zig "detect distinguishes fan-OUT and fan-IN in the same graph"
    var pivot: u32 = 0;
    while (pivot < lg.nodes.len) : (pivot += 1) {
        const pivot_id = switch (lg.nodes[pivot]) {
            .real => |id| id,
            .virtual => continue,
        };
        const p_layer = node_layer[pivot];
        if (try collectFanOut(a, graph, lg, node_layer, pivot, pivot_id, p_layer)) |prepared| {
            const found: Fan = .{
                .direction = .out,
                .pivot = pivot_id,
                .pivot_idx = pivot,
                .source_layer = p_layer,
                .peers = prepared.peers,
                .labeled = anyPeerLabeled(graph, prepared.peers),
                .construction_deco_mixed = prepared.deco_mixed,
                .construction_style_mixed = prepared.style_mixed,
                .construction_star_violation = prepared.star_violation,
            };
            assertPivotConsistency(found, lg);
            try fans.append(a, found);
        }
    }
    pivot = 0;
    while (pivot < lg.nodes.len) : (pivot += 1) {
        const pivot_id = switch (lg.nodes[pivot]) {
            .real => |id| id,
            .virtual => continue,
        };
        const p_layer = node_layer[pivot];
        if (p_layer == 0) continue;
        if (try collectFanIn(a, graph, lg, node_layer, pivot, pivot_id, p_layer - 1)) |prepared| {
            const found: Fan = .{
                .direction = .in,
                .pivot = pivot_id,
                .pivot_idx = pivot,
                .source_layer = p_layer - 1,
                .peers = prepared.peers,
                .labeled = anyPeerLabeled(graph, prepared.peers),
                .construction_deco_mixed = prepared.deco_mixed,
                .construction_style_mixed = prepared.style_mixed,
                .construction_star_violation = prepared.star_violation,
            };
            assertPivotConsistency(found, lg);
            try fans.append(a, found);
        }
    }

    return try fans.toOwnedSlice(a);
}

fn assertPivotConsistency(f: Fan, lg: sugiyama.LayeredGraph) void {
    std.debug.assert(f.pivot_idx < lg.nodes.len);
    switch (lg.nodes[f.pivot_idx]) {
        .real => |id| std.debug.assert(id == f.pivot),
        .virtual => unreachable,
    }
}

/// True iff any peer's semantic edge carries a non-empty label.
fn anyPeerLabeled(graph: sg.SemGraph, peers: []const FanEdge) bool {
    for (peers) |p| {
        if (p.long) continue;
        if (peerLabel(graph, p.edge_id) != null) return true;
    }
    return false;
}

/// The non-empty semantic label of edge `edge_id`, or null.
fn peerLabel(graph: sg.SemGraph, edge_id: u32) ?[]const u8 {
    for (graph.edges) |e| {
        if (e.id != edge_id) continue;
        if (e.label) |lbl| {
            if (lbl.len > 0) return lbl;
        }
        return null;
    }
    return null;
}

/// Refresh per-member display widths before row reservation. Width pressure is
/// explicit in the bbox diagnostic; it never licenses silent label loss.
pub fn gateLabelReservations(comptime G: type, graph: sg.SemGraph, fans: []Fan, geom: []const G, budget: u32, h_spacing: u32) void {
    _ = geom;
    _ = budget;
    _ = h_spacing;
    for (fans) |*f| {
        f.labeled = false;
        for (f.peers) |*p| {
            // A long member's label rides its own stroke, never a tap.
            p.label_width = if (p.long) 0 else if (peerLabel(graph, p.edge_id)) |label| prim.displayWidth(label) else 0;
            if (p.label_width != 0) f.labeled = true;
        }
    }
}

/// On-run tap labels of a fan-IN all share the ONE band row the gap reserves
/// above the crossbar, each centered on its member's own dropper column. A
/// label is feasible there only when its span clears every sibling dropper
/// column (span emptiness + foreign-ink margin) and every sibling label's
/// text by >= 2 blanks — the layout-time mirror of the constraints
/// raster/labels_onrun.zig enforces (OWN-INK RULE span emptiness, ISOLATION LAW
/// isolation), judged conservatively on placed x centers. The constants here
/// MIRROR raster/labels_onrun.zig's OWN-INK RULE / ISOLATION LAW and can drift from them;
/// drift degrades to counted displacement via the labels_edge ladder, never
/// to a lost label or a re-decided sharing question. An infeasible fan
/// reverts its labeled members to private routes (the pre-rail behavior),
/// so no label is ever silently lost to an on-run refusal with no lateral
/// room left for the fallback ladder.
pub fn gateFanInSharedLabels(comptime G: type, fans: []Fan, geom: []const G) void {
    for (fans) |*f| {
        if (f.direction != .in) continue;
        var infeasible = false;
        for (f.peers) |p| {
            if (!p.shared or p.label_width == 0) continue;
            const cx = centerX(G, geom, p.peer_idx);
            const w: i32 = @intCast(p.label_width);
            const left = cx - @divTrunc(w - 1, 2);
            const right = cx + @divTrunc(w, 2);
            for (f.peers) |q| {
                if (q.peer_idx == p.peer_idx or !q.shared) continue;
                const qx = centerX(G, geom, q.peer_idx);
                if (q.label_width != 0) {
                    const qw: i32 = @intCast(q.label_width);
                    const q_left = qx - @divTrunc(qw - 1, 2);
                    const q_right = qx + @divTrunc(qw, 2);
                    if (!(right + 3 <= q_left or q_right + 3 <= left)) infeasible = true;
                } else if (left - 2 < qx and qx < right + 2) infeasible = true;
            }
            // Another fan's drops and stem in the same gap are foreign ink to
            // this label just as a sibling's are; the raster's OWN-INK RULE
            // does not care whose rail the ink belongs to.
            // @guarded-by: fan_test.zig "a fan-in tap label crowded by a neighbouring fan's drop unshares"
            for (fans) |g| {
                if (g.source_layer != f.source_layer or g.pivot_idx == f.pivot_idx) continue;
                if (left - 2 < centerX(G, geom, g.pivot_idx) and centerX(G, geom, g.pivot_idx) < right + 2) infeasible = true;
                for (g.peers) |q| {
                    if (!q.shared) continue;
                    const qx = centerX(G, geom, q.peer_idx);
                    if (left - 2 < qx and qx < right + 2) infeasible = true;
                }
            }
        }
        if (!infeasible) continue;
        for (f.peers) |*p| {
            if (p.label_width != 0) p.shared = false;
        }
    }
}

fn centerX(comptime G: type, geom: []const G, idx: u32) i32 {
    const g = geom[idx];
    return g.x + @as(i32, @intCast(g.w / 2));
}

fn collectFanOut(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    node_layer: []const u32,
    src_idx: u32,
    pivot: sg.NodeId,
    src_layer: u32,
) error{OutOfMemory}!?PreparedPeers {
    var candidates: std.ArrayListUnmanaged(FanEdge) = .empty;
    defer candidates.deinit(a);

    for (lg.edges) |le| {
        if (le.from != src_idx) continue;
        if (le.reversed) continue;
        if (node_layer[le.to] != src_layer + 1) continue;
        // @guarded-by: fan_test.zig "detect keeps a long member as a fan-out peer, labeled or not"
        const long = switch (lg.nodes[le.to]) {
            .real => false,
            .virtual => true,
        };
        try candidates.append(a, .{
            .edge_id = le.edge,
            .peer_idx = le.to,
            .role = .middle,
            .long = long,
        });
    }
    return preparePeers(a, graph, .out, pivot, candidates.items);
}

fn collectFanIn(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    node_layer: []const u32,
    tgt_idx: u32,
    pivot: sg.NodeId,
    want_src_layer: u32,
) error{OutOfMemory}!?PreparedPeers {
    var candidates: std.ArrayListUnmanaged(FanEdge) = .empty;
    defer candidates.deinit(a);

    for (lg.edges) |le| {
        if (le.to != tgt_idx) continue;
        if (le.reversed) continue;
        if (node_layer[le.from] != want_src_layer) continue;
        const long = switch (lg.nodes[le.from]) {
            .real => false,
            .virtual => true,
        };
        try candidates.append(a, .{
            .edge_id = le.edge,
            .peer_idx = le.from,
            .role = .middle,
            .long = long,
        });
    }
    return preparePeers(a, graph, .in, pivot, candidates.items);
}

fn preparePeers(a: std.mem.Allocator, graph: sg.SemGraph, direction: ledger.BundleDirection, pivot: sg.NodeId, candidates: []const FanEdge) error{OutOfMemory}!?PreparedPeers {
    if (candidates.len < 2) return null;
    const out = try a.dupe(FanEdge, candidates);
    if (graph.edges.len == 0) return .{ .peers = out };
    const ids = try a.alloc(ledger.EdgeId, candidates.len);
    for (candidates, ids) |candidate, *id| id.* = candidate.edge_id;
    const prepared = try permits.prepareRailMembers(a, graph, direction, pivot, ids);
    const shared_ids = prepared.members;
    for (out) |*candidate| {
        candidate.label_width = if (!candidate.long) (if (peerLabel(graph, candidate.edge_id)) |label| prim.displayWidth(label) else 0) else 0;
        candidate.shared = containsEdge(shared_ids, candidate.edge_id);
    }
    return .{ .peers = out, .deco_mixed = prepared.deco_mixed, .style_mixed = prepared.style_mixed, .star_violation = prepared.star_violation };
}

fn containsEdge(edges: []const ledger.EdgeId, edge: ledger.EdgeId) bool {
    for (edges) |candidate| if (candidate == edge) return true;
    return false;
}

/// Per-gap extra rows. Entry i is extra rows in the gap between layer i
/// and layer i+1. Each fan reserves `fan.lane + 1` rows at its `source_layer`
/// gap; the gap takes the max across its fans. With every `lane == 0` (the
/// pre-lane-separation default) this is exactly one row per fan gap.
/// @guarded-by: layout/fan_lanes_test.zig "lane assignment reserves one extra gap row per lane"
pub fn extraRowsPerGap(
    a: std.mem.Allocator,
    lg: sugiyama.LayeredGraph,
    fans: []const Fan,
) error{OutOfMemory}![]u32 {
    if (lg.layers.len < 2) return try a.alloc(u32, 0);
    const out = try a.alloc(u32, lg.layers.len - 1);
    @memset(out, 0);
    for (fans) |f| {
        if (f.source_layer < out.len) {
            var max_lane = f.lane;
            for (f.peers) |peer| max_lane = @max(max_lane, peer.lane);
            var need = max_lane + 1;
            for (f.peers) |peer| {
                if (peer.label_width == 0) continue;
                const lane = effectiveLane(f, peer.lane);
                if (!peer.shared) {
                    need = @max(need, lane + 1 + LABEL_RUN_EXTRA_ROWS);
                    continue;
                }
                if (f.direction == .in) {
                    need = @max(need, lane + 1 + LABEL_RUN_EXTRA_ROWS);
                    continue;
                }
                need = @max(need, lane + 1 + labelRowsOnLane(f, lane));
            }
            if (need > out[f.source_layer]) out[f.source_layer] = need;
        }
    }
    return out;
}

pub fn wrapWideFanOut(comptime G: type, fans: []Fan, geom: []G, budget: u32, h: u32, v: u32) void {
    wrapGated(G, .out, fans, geom, budget, h, v);
}

pub fn wrapWideFanIn(comptime G: type, fans: []Fan, geom: []G, budget: u32, h: u32, v: u32) void {
    wrapGated(G, .in, fans, geom, budget, h, v);
}

fn wrapGated(comptime G: type, direction: Direction, fans: []Fan, geom: []G, budget: u32, h: u32, v: u32) void {
    for (fans) |*f| {
        var has_private = false;
        for (f.peers) |peer| if (!peer.shared) {
            has_private = true;
        };
        if (has_private) continue;
        var one = [_]Fan{f.*};
        if (direction == .out) fan_grid.wrapWideFanOut(G, &one, geom, budget, h, v) else fan_grid.wrapWideFanIn(G, &one, geom, budget, h, v);
        f.* = one[0];
    }
}

/// Fill in peer roles based on each peer's center x. Must be called
/// AFTER coords.assignInitialX / centerByBarycenter / normalizeX but
/// BEFORE applyDirection.
pub fn assignRoles(fans: []Fan, center_x: []const i32) void {
    for (fans) |*f| {
        const Ctx = struct {
            cx: []const i32,
            fn lt(c: @This(), a_e: FanEdge, b_e: FanEdge) bool {
                const ax = c.cx[a_e.peer_idx];
                const bx = c.cx[b_e.peer_idx];
                if (ax != bx) return ax < bx;
                return a_e.edge_id < b_e.edge_id;
            }
        };
        std.mem.sort(FanEdge, f.peers, Ctx{ .cx = center_x }, Ctx.lt);

        const pivot_cx = center_x[f.pivot_idx];
        const n = f.peers.len;
        for (f.peers, 0..) |*p, i| {
            const px = center_x[p.peer_idx];
            if (i == 0) {
                p.role = .leftmost;
            } else if (i == n - 1) {
                p.role = .rightmost;
            } else if (px == pivot_cx) {
                p.role = .center;
            } else {
                p.role = .middle;
            }
        }
    }
}

pub const LookupHit = struct {
    fan: *const Fan,
    peer: *const FanEdge,
};

/// Find the fan/peer matching `edge_id`. Returns null if not part of
/// any detected fan.
pub fn lookup(fans: []const Fan, edge_id: sg.EdgeId) ?LookupHit {
    for (fans) |*f| {
        for (f.peers) |*p| {
            if (p.edge_id == edge_id) return .{ .fan = f, .peer = p };
        }
    }
    return null;
}

/// The bundle sets the detected fans authorize: one per group of peers
/// sharing a rail lane (`effectiveLane` — the row the ink occupies), in fan
/// order then peer order.
///
/// Peers on one effective lane paint one shared rail run, so their ink
/// sharing is a structural consequence of the fan, not an accident of
/// routing — exactly the sharing a crossing law must not read as a
/// fabricated junction. A lane holding a single peer is no set: that peer
/// shares with nobody.
///
/// `peer.lane` is the per-member lane `fan_lanes.assignLanes` hands out when
/// a carve-out leaves a group unrealized, and stays 0 everywhere else — so
/// the ordinary result is one set per fan holding all of its peers, which is
/// what a clustered render (empty realized plan, no per-member lanes) always
/// gets. Members are edge ids in the caller's own id space.
/// @guarded-by: fan_test.zig "bundles group a fan's peers by rail lane"
pub fn coSets(
    a: std.mem.Allocator,
    fans: []const Fan,
) error{OutOfMemory}![]const ledger.Bundle {
    var out: std.ArrayListUnmanaged(ledger.Bundle) = .empty;
    var members: std.ArrayListUnmanaged(ledger.EdgeId) = .empty;
    defer members.deinit(a);
    for (fans) |f| {
        for (f.peers, 0..) |seed, i| {
            if (!seed.shared) continue;
            const seed_lane = effectiveLane(f, seed.lane);
            var already = false;
            for (f.peers[0..i]) |earlier| {
                if (earlier.shared and effectiveLane(f, earlier.lane) == seed_lane) already = true;
            }
            if (already) continue;

            members.clearRetainingCapacity();
            for (f.peers) |p| {
                if (!p.shared) continue;
                if (effectiveLane(f, p.lane) == seed_lane) try members.append(a, p.edge_id);
            }
            if (members.items.len < 2) continue;
            try out.append(a, .{
                .origin = .fan_rail,
                .members = try a.dupe(ledger.EdgeId, members.items),
            });
        }
    }
    return out.toOwnedSlice(a);
}

/// Returns the source-centroid x for a node iff it satisfies the fan-IN
/// criterion. Caller (layout.zig::centerByBarycenter) uses this as the
/// desired-x override during initial centering.
pub fn fanInCentroid(
    comptime G: type,
    geom: []const G,
    lg: sugiyama.LayeredGraph,
    idx: u32,
) ?i32 {
    switch (lg.nodes[idx]) {
        .real => {},
        .virtual => return null,
    }
    const tgt_layer = geom[idx].layer;
    if (tgt_layer == 0) return null;
    const want_src_layer = tgt_layer - 1;

    var sum: i64 = 0;
    var n: u32 = 0;
    for (lg.edges) |e| {
        if (e.to != idx) continue;
        if (e.reversed) continue;
        if (geom[e.from].layer != want_src_layer) continue;
        switch (lg.nodes[e.from]) {
            .real => {},
            .virtual => return null,
        }
        const g = geom[e.from];
        sum += g.x + @divTrunc(@as(i32, @intCast(g.w)), 2);
        n += 1;
    }
    if (n < 2) return null;
    return @intCast(@divTrunc(sum, @as(i64, @intCast(n))));
}

test {
    _ = @import("fan_test.zig");
    _ = @import("fan_provenance_test.zig");
}

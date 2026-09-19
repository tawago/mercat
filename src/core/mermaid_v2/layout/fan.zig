const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const permits = @import("../ledger/permits.zig");
const sugiyama = @import("sugiyama.zig");
const fan_grid = @import("fan_grid.zig");

pub const Direction = enum { out, in };

pub const ChildRole = enum {
    leftmost,
    rightmost,
    middle,
    center,
};

pub const FanEdge = struct {
    edge_id: sg.EdgeId,
    peer_idx: u32,
    role: ChildRole,
    lane: u32 = 0,
    shared: bool = true,
    label_width: u32 = 0,
    long: bool = false,
};

pub const Fan = struct {
    direction: Direction,
    pivot: sg.NodeId = 0,
    pivot_idx: u32,
    source_layer: u32,
    peers: []FanEdge,
    rows: u32 = 1,
    lane: u32 = 0,
    /// @guarded-by: gap_rows_test.zig "a labeled fan claims its rail row and one label band; an unlabeled fan claims one row"
    /// @guarded-by: gap_rows_test.zig "a fan-OUT with three labeled members claims the same rows as one with a single labeled member"
    labeled: bool = false,
    construction_deco_mixed: bool = false,
    construction_style_mixed: bool = false,
    construction_star_violation: bool = false,
};

const PreparedPeers = struct { peers: []FanEdge, deco_mixed: bool = false, style_mixed: bool = false, star_violation: bool = false };

pub fn effectiveLane(f: Fan, peer_lane: u32) u32 {
    return @max(f.lane, peer_lane);
}

pub const LABEL_RUN_EXTRA_ROWS: u32 = 3;

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

    // @guarded-by: fan_test.zig "detect distinguishes fan-OUT and fan-IN in the same graph"
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

fn anyPeerLabeled(graph: sg.SemGraph, peers: []const FanEdge) bool {
    for (peers) |p| {
        if (p.long) continue;
        if (peerLabel(graph, p.edge_id) != null) return true;
    }
    return false;
}

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

pub fn refreshLabelWidths(graph: sg.SemGraph, fans: []Fan) void {
    for (fans) |*f| {
        f.labeled = false;
        for (f.peers) |*p| {
            p.label_width = if (p.long) 0 else if (peerLabel(graph, p.edge_id)) |label| prim.displayWidth(label) else 0;
            if (p.label_width != 0) f.labeled = true;
        }
    }
}

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

pub fn lookup(fans: []const Fan, edge_id: sg.EdgeId) ?LookupHit {
    for (fans) |*f| {
        for (f.peers) |*p| {
            if (p.edge_id == edge_id) return .{ .fan = f, .peer = p };
        }
    }
    return null;
}

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

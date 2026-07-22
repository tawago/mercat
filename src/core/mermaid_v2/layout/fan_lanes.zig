//! fan_lanes.zig — incomplete-bipartite fan lane separation (plan-06 R1a).
//!
//! THE fabrication fix. Several fans that share one inter-layer gap put their
//! horizontal rails on the SAME row (`fan_polyline`/`fan_busbar` both anchor
//! `rail_y` to the target perimeter). When two such rails occupy
//! overlapping-or-abutting x-spans they FUSE at raster time into one
//! continuous `├──┼──┤` bus. If the UNION of the fused rails' declared edges
//! is an INCOMPLETE bipartite (distinct-sources × distinct-targets > declared
//! pairs), that single bus asserts every source→target pair — inventing edges
//! that were never declared.
//!
//! This pass groups a gap's rail-producing trunks by collinear overlap, tests
//! each group's union bipartite, and — only for INCOMPLETE groups — assigns
//! each constituent trunk its own rail row (`fan.lane`) via the pure interval
//! packer. Distinct rails then land on distinct rows, so each declared edge
//! keeps its own traceable rail; the honest merges (a shared target column) are
//! preserved because they stay a single vertical.
//!
//! Inert (every `lane == 0`, byte-identical) for: complete meshes (K3,3,
//! N×M==D), gaps with a single trunk, and pure fan-in or fan-out groups
//! (N==1 or M==1 — a lone pivot never fabricates).
//!
//! Runs AFTER x-assignment (needs placed columns to know which rails overlap)
//! and BEFORE row reservation (`fan.extraRowsPerGap` reads the resulting
//! `fan.lane`). Anti-patch: keyed purely on gap topology + placed geometry —
//! never a fixture/label conditional.
//!
//! Allowed imports (layout zone): std + sem_graph + layout siblings + lanes.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const fan_mod = @import("fan.zig");
const sugiyama = @import("sugiyama.zig");
const lanes = @import("../base/lanes.zig");
const pb = @import("../base/ledger.zig");

const Fan = fan_mod.Fan;

/// One declared edge asserted by a trunk's rail.
const Edge = struct { from: sg.NodeId, to: sg.NodeId };

/// A rail-producing trunk for one fan within a gap: its horizontal x-span
/// `[lo, hi]` (in placed centre-column coordinates) plus the declared edges
/// its rail asserts.
const Trunk = struct {
    fan_idx: u32,
    gap: u32,
    lo: i32,
    hi: i32,
    edges: []Edge,
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
/// rails fuses into a fabricating bus. Mutates `fans` in place; leaves every
/// lane at 0 when nothing fabricates. `geom` is parallel to `lg.nodes`.
pub fn assignLanes(
    comptime G: type,
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const G,
    fans: []Fan,
    joins: pb.RealizedJoins,
) error{OutOfMemory}!void {
    if (fans.len == 0 or lg.layers.len < 2) return;
    const ngaps: u32 = @intCast(lg.layers.len - 1);

    // Invisible (`~~~`) links draw no ink, so they can neither fuse into a bus
    // nor fabricate — exclude them from every rail model.
    var invisible: std.AutoHashMapUnmanaged(sg.EdgeId, void) = .empty;
    defer invisible.deinit(a);
    for (graph.edges) |e| {
        if (e.kind == .invisible) try invisible.put(a, e.id, {});
    }

    // Edges that a fan-OUT owns: their rail belongs to the fan-OUT trunk, so a
    // fan-IN into the same target must NOT double-count them as its own rail
    // (the fan-IN would otherwise inflate a group with a phantom trunk).
    var fanout_edges: std.AutoHashMapUnmanaged(sg.EdgeId, void) = .empty;
    defer fanout_edges.deinit(a);
    for (fans) |f| {
        if (f.direction != .out) continue;
        for (f.peers) |p| try fanout_edges.put(a, p.edge_id, {});
    }

    // Build one trunk per rail-producing fan.
    var trunks: std.ArrayListUnmanaged(Trunk) = .empty;
    defer {
        for (trunks.items) |t| a.free(t.edges);
        trunks.deinit(a);
    }
    for (fans, 0..) |f, fi| {
        if (f.source_layer >= ngaps) continue;
        const pivot_cx = centerX(G, geom[f.pivot_idx]);
        var lo: i32 = pivot_cx;
        var hi: i32 = pivot_cx;
        var edges: std.ArrayListUnmanaged(Edge) = .empty;
        errdefer edges.deinit(a);

        if (f.direction == .out) {
            // A fan-OUT draws its rail (bus-bar or per-peer polyline) for every
            // visible peer.
            for (f.peers) |p| {
                if (invisible.contains(p.edge_id)) continue;
                const cx = centerX(G, geom[p.peer_idx]);
                lo = @min(lo, cx);
                hi = @max(hi, cx);
                try edges.append(a, .{ .from = nodeId(lg, f.pivot_idx), .to = nodeId(lg, p.peer_idx) });
            }
        } else {
            // A fan-IN draws a rail only for peers it actually owns: edges also
            // owned by a fan-OUT are drawn by that fan-OUT, and a peer sitting
            // on the pivot column descends straight (no horizontal rail).
            for (f.peers) |p| {
                if (invisible.contains(p.edge_id)) continue;
                if (fanout_edges.contains(p.edge_id)) continue;
                const cx = centerX(G, geom[p.peer_idx]);
                if (cx == pivot_cx) continue;
                lo = @min(lo, cx);
                hi = @max(hi, cx);
                try edges.append(a, .{ .from = nodeId(lg, p.peer_idx), .to = nodeId(lg, f.pivot_idx) });
            }
        }
        if (edges.items.len == 0) {
            edges.deinit(a);
            continue;
        }
        try trunks.append(a, .{
            .fan_idx = @intCast(fi),
            .gap = f.source_layer,
            .lo = lo,
            .hi = hi,
            .edges = try edges.toOwnedSlice(a),
        });
    }

    // Process each gap independently: the fabricating groups live within one
    // gap (rails only ever share the gap's own row).
    var gap: u32 = 0;
    while (gap < ngaps) : (gap += 1) {
        var members: std.ArrayListUnmanaged(u32) = .empty;
        defer members.deinit(a);
        for (trunks.items, 0..) |t, ti| {
            if (t.gap == gap) try members.append(a, @intCast(ti));
        }
        if (members.items.len < 2) continue;
        try processGap(a, trunks.items, members.items, fans);
    }

    // A carve-out-unrealized fan is edge-owned: every member gets a distinct
    // rail lane. Selected trunks and exempt complete meshes retain lane zero.
    if (joins.memberships.len == 0) return;
    for (fans) |*fan| {
        if (fanSelected(fan.*, joins) or fanMeshExempt(fan.*, joins.mesh_unions)) continue;
        var next_lane = fan.lane;
        for (fan.peers) |*peer| {
            if (invisible.contains(peer.edge_id) or !peerIndependent(fan.direction, peer.edge_id, joins.memberships)) continue;
            peer.lane = next_lane;
            next_lane += 1;
        }
    }
}

fn fanSelected(fan: Fan, joins: pb.RealizedJoins) bool {
    var selected: ?pb.RealizedJoinId = null;
    for (fan.peers) |peer| {
        const membership = membershipFor(joins.memberships, peer.edge_id) orelse return false;
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

fn fanMeshExempt(fan: Fan, unions: []const pb.MeshUnion) bool {
    for (unions) |mesh_union| {
        var all = true;
        for (fan.peers) |peer| {
            if (!contains(mesh_union.members, peer.edge_id)) all = false;
        }
        if (all) return true;
    }
    return false;
}

fn contains(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |item| if (item == edge) return true;
    return false;
}

/// Group the gap's trunks by transitive x-overlap and, per incomplete group,
/// lane-pack them so their rails no longer fuse.
fn processGap(
    a: std.mem.Allocator,
    trunks: []const Trunk,
    members: []const u32,
    fans: []Fan,
) error{OutOfMemory}!void {
    const n = members.len;
    // Union-find over `members` by overlapping/abutting x-spans.
    const parent = try a.alloc(u32, n);
    defer a.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);
    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (spansTouch(trunks[members[i]], trunks[members[j]])) {
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

        var group: std.ArrayListUnmanaged(u32) = .empty; // indices into `members`
        defer group.deinit(a);
        for (0..n) |k| {
            if (find(parent, @intCast(k)) == r) try group.append(a, @intCast(k));
        }
        if (group.items.len < 2) continue;
        try laneAssignGroup(a, trunks, members, group.items, fans);
    }
}

/// Assign lanes to one connected group. Complete / pure-fan groups keep lane 0.
fn laneAssignGroup(
    a: std.mem.Allocator,
    trunks: []const Trunk,
    members: []const u32,
    group: []const u32, // indices into `members`
    fans: []Fan,
) error{OutOfMemory}!void {
    if (!isIncomplete(a, trunks, members, group)) return;

    // Lane-pack: pack each trunk's x-span into the innermost lane it fits,
    // treating overlapping/abutting spans as conflicting (so they land on
    // distinct rows). `base = 0` — we only want the lane INDEX.
    var min_x: i32 = std.math.maxInt(i32);
    for (group) |gi| min_x = @min(min_x, trunks[members[gi]].lo);

    const demands = try a.alloc(lanes.Demand, group.len);
    defer a.free(demands);
    for (group, demands) |gi, *d| {
        const t = trunks[members[gi]];
        d.* = .{ .lo = @intCast(t.lo - min_x), .hi = @intCast(t.hi - min_x), .base = 0 };
    }
    var asg = try lanes.assign(a, demands, 1);
    defer asg.deinit(a);

    for (group, 0..) |gi, k| {
        fans[trunks[members[gi]].fan_idx].lane = asg.lane_of[k];
    }
}

/// True iff the two trunks' x-spans overlap or abut (share ≥1 column or touch
/// at a single endpoint column) — the exact condition under which their rails
/// fuse into one line at raster time.
fn spansTouch(x: Trunk, y: Trunk) bool {
    return !(x.hi < y.lo or y.hi < x.lo);
}

/// Union of the group's declared edges is an incomplete bipartite: distinct
/// sources × distinct targets strictly exceeds distinct declared pairs.
fn isIncomplete(
    a: std.mem.Allocator,
    trunks: []const Trunk,
    members: []const u32,
    group: []const u32,
) bool {
    var srcs: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    defer srcs.deinit(a);
    var tgts: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    defer tgts.deinit(a);
    var pairs: std.ArrayListUnmanaged(Edge) = .empty;
    defer pairs.deinit(a);

    for (group) |gi| {
        for (trunks[members[gi]].edges) |e| {
            addUnique(a, &srcs, e.from) catch return false;
            addUnique(a, &tgts, e.to) catch return false;
            addUniquePair(a, &pairs, e) catch return false;
        }
    }
    const nn = srcs.items.len;
    const mm = tgts.items.len;
    const dd = pairs.items.len;
    // A lone pivot on either side (N==1 or M==1) can never fabricate; a
    // complete mesh (N×M == D) is a truthful all-to-all.
    if (nn <= 1 or mm <= 1) return false;
    return nn * mm > dd;
}

fn addUnique(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(sg.NodeId), v: sg.NodeId) !void {
    for (list.items) |x| if (x == v) return;
    try list.append(a, v);
}

fn addUniquePair(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(Edge), e: Edge) !void {
    for (list.items) |x| if (x.from == e.from and x.to == e.to) return;
    try list.append(a, e);
}

// -- tiny union-find -------------------------------------------------------

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
}

const std = @import("std");
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const rail_closure = @import("../base/rail_closure.zig");
const sugiyama = @import("sugiyama.zig");
const fan_mod = @import("fan.zig");
const fan_rail = @import("fan_rail.zig");
const port_plan = @import("port_plan.zig");
const rt = @import("routing_terminal.zig");
const pack_mod = @import("gap_rows_pack.zig");
const NodeGeom = @import("node_geom.zig").NodeGeom;
const bridge = @import("gap_rows_bridge.zig");
const census_mod = @import("gap_rows_census.zig");
const fans_mod = @import("gap_rows_fans.zig");

pub const Kind = pack_mod.Kind;
pub const End = pack_mod.End;
pub const Claim = pack_mod.Claim;
pub const Post = pack_mod.Post;
pub const Ledger = pack_mod.Ledger;
pub const Super = census_mod.Super;
const packSub = pack_mod.packSub;
const edgeClaim = pack_mod.edgeClaim;
const Census = census_mod.Census;
const drawnByEligible = fans_mod.drawnByEligible;

fn edgeClaims(a: std.mem.Allocator, c: Census, fans: []const fan_mod.Fan, eligible: []const bool, bundles: pb.RealizedBundles, per_peer: std.AutoHashMapUnmanaged(sg.EdgeId, void), claims: *std.ArrayListUnmanaged(Claim), posts: *std.ArrayListUnmanaged(Post)) error{OutOfMemory}!void {
    for (c.graph.edges) |e| {
        if (e.kind == .invisible or e.from == e.to or c.isReversed(e.id) or c.isPlacement(e)) continue;
        if (rail_closure.contains(bundles.discharged, e.id) or per_peer.contains(e.id)) continue;
        if (drawnByEligible(fans, eligible, e.id, .out, bundles.discharged) or drawnByEligible(fans, eligible, e.id, .in, bundles.discharged)) continue;
        var fused = false;
        for (bundles.fused) |u| if (std.mem.indexOfScalar(pb.EdgeId, u, e.id) != null) {
            fused = true;
        };
        if (fused) continue;
        const sl = c.layerOfNode(e.from) orelse continue;
        const tl = c.layerOfNode(e.to) orelse continue;
        const target_gap = c.gapOf(sl, tl) orelse continue;
        const scol = c.portCol(e, .source_exit);
        const tcol = c.portCol(e, .target_entry);
        const virtuals = try rt.collectVirtuals(a, c.lg, e.id);
        if (virtuals.len == 0) {
            const si = c.lg.real_index.get(e.from) orelse continue;
            const ti = c.lg.real_index.get(e.to) orelse continue;
            const exit_gap = if (c.flow_down) c.gapAbove(ti) orelse continue else target_gap;
            var from_col = scol;
            if (c.flow_down) if (c.stackedObstacle(si, ti, scol)) |ob| {
                const entry_gap = c.gapAbove(ob) orelse continue;
                from_col = c.corridorColumn(si, ti, tcol, true);
                if (from_col != scol) try claims.append(a, try edgeClaim(a, entry_gap, scol, from_col, .corridor_entry, .entry, e.arrow_from == .none, e.arrow_from != .none, e.id));
            };
            if (from_col != tcol) {
                try claims.append(a, try edgeClaim(a, exit_gap, from_col, tcol, if (from_col == scol) .run else .corridor_exit, .exit, e.arrow_to == .none and e.arrow_from == .none and from_col == scol, e.arrow_from != .none and from_col == scol, e.id));
            } else if (e.arrow_to != .none) try posts.append(a, .{ .gap = exit_gap, .x = tcol });
            continue;
        }
        if (!c.flow_down) continue;
        const corridor = c.geom[virtuals[0]].centerX();
        if (scol != corridor) try claims.append(a, try edgeClaim(a, sl, scol, corridor, .corridor_entry, .entry, e.arrow_from == .none, e.arrow_from != .none, e.id));
        if (corridor != tcol) {
            try claims.append(a, try edgeClaim(a, target_gap, corridor, tcol, .corridor_exit, .exit, e.arrow_to == .none, false, e.id));
        } else if (e.arrow_to != .none) try posts.append(a, .{ .gap = target_gap, .x = tcol });
    }
}

fn returnClaims(a: std.mem.Allocator, c: Census, claims: *std.ArrayListUnmanaged(Claim)) error{OutOfMemory}!void {
    for (c.graph.edges) |e| {
        if (!c.isPlacement(e) or e.from == e.to or !c.isReversed(e.id)) continue;
        const upper = c.layerOfNode(e.to) orelse continue;
        const gap = c.gapBelow(upper) orelse continue;
        const ui = c.lg.real_index.get(e.to) orelse continue;
        const li = c.lg.real_index.get(e.from) orelse continue;
        const port = c.geom[ui].centerX();
        const corridor = c.geom[li].centerX();
        const edges = try a.alloc(sg.EdgeId, 1);
        edges[0] = e.id;
        try claims.append(a, .{ .gap = gap, .lo = @min(port, corridor), .hi = @max(port, corridor), .height = 2, .kind = .bridge_return, .end = .entry, .edges = edges });
    }
}

fn departureClaims(a: std.mem.Allocator, c: Census, claims: *std.ArrayListUnmanaged(Claim)) error{OutOfMemory}!void {
    var lo: i32 = std.math.maxInt(i32);
    var hi: i32 = std.math.minInt(i32);
    for (c.lg.nodes, 0..) |ln, i| if (ln == .real) {
        lo = @min(lo, c.geom[i].x);
        hi = @max(hi, c.geom[i].right() - 1);
    };
    for (c.departures, 0..) |node, di| {
        if (std.mem.indexOfScalar(sg.NodeId, c.departures[0..di], node) != null) continue;
        const mi = c.lg.real_index.get(node) orelse continue;
        const layer = c.geom[mi].layer;
        const gap = c.gapBelow(layer) orelse continue;
        const col = c.geom[mi].centerX();
        var pierced = false;
        for (c.lg.nodes, 0..) |ln, i| {
            if (ln != .real or i == mi) continue;
            const below = if (c.geom[i].layer == layer) c.geom[i].y > c.geom[mi].y else if (c.flow_down) c.geom[i].layer > layer else c.geom[i].layer < layer;
            if (below and c.geom[i].x <= col and col < c.geom[i].right()) pierced = true;
        }
        if (!pierced) continue;
        try claims.append(a, .{ .gap = gap, .lo = lo, .hi = hi, .kind = .bridge_return, .end = .entry });
    }
}

pub fn buildPiece(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
    fans: []const fan_mod.Fan,
    bundles: pb.RealizedBundles,
    plan: port_plan.Plan,
    bases: []const u32,
    supers: []const Super,
    departures: []const sg.NodeId,
) error{OutOfMemory}!Ledger {
    if (bases.len == 0) return .{};
    const c = try Census.init(a, graph, lg, geom, plan, supers, departures, bases.len);
    const all_bases = try a.alloc(u32, bases.len + c.sub_gaps.len);
    @memcpy(all_bases[0..bases.len], bases);
    for (c.sub_gaps) |s| all_bases[s.gap] = s.base;

    const eligible = try a.alloc(bool, fans.len);
    for (fans, eligible) |f, *ok| ok.* = fan_rail.eligible(f, graph, bundles);

    var claims: std.ArrayListUnmanaged(Claim) = .empty;
    var posts: std.ArrayListUnmanaged(Post) = .empty;
    var per_peer: std.AutoHashMapUnmanaged(sg.EdgeId, void) = .empty;
    var detours: std.ArrayListUnmanaged(fans_mod.Detour) = .empty;
    var proxies: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    for (graph.edges) |e| if (c.isPlacement(e)) try proxies.append(a, e.id);
    try fans_mod.fanClaims(a, c, fans, eligible, bundles, &claims, &per_peer, &detours);
    try fans_mod.detourClaims(a, c, detours.items, &claims);
    try fans_mod.strokeClaims(a, c, fans, eligible, bundles, &claims);
    try edgeClaims(a, c, fans, eligible, bundles, per_peer, &claims, &posts);
    try returnClaims(a, c, &claims);
    try bridge.jogClaims(a, c, &claims);
    try departureClaims(a, c, &claims);
    var out = try packSub(a, claims.items, posts.items, all_bases, c.sub_gaps);
    out.proxies = try proxies.toOwnedSlice(a);
    return out;
}

test {
    _ = @import("gap_rows_test.zig");
}

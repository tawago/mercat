//! gap_rows.zig — the one row ledger of every inter-rank gap.
//!
//! An inter-rank gap holds the horizontal runs of the ink that crosses it:
//! fan rails, per-peer fan runs, private jogs, skip-corridor entries and
//! exits, member-stroke jogs, the jogs of the cluster bridges. Each run
//! claims the rows it needs here with its cross-axis span; the gap's
//! spacing is its base spacing plus the rows the packed claims occupy,
//! nothing else adds a row, and every producer reads its row back from
//! this ledger.
//!
//! Row r of a gap is the line `wall - 3 - r`, `wall` being the target
//! layer's near edge: `wall-1` and `wall-2` are the arrival cell and its
//! straight base cell and hold verticals only. Row -1 (`wall-2`) is open
//! to a run with no decorated end in that gap when no other claim shares a
//! column with it. Two claims share a row only when at least one blank
//! cell separates their ink, so no two runs ever abut. Rows the base
//! spacing already contains cost nothing; the rest widen the gap. In an RL
//! piece the layers run the other way and the wall is the target's far
//! side; the rows count from it just the same.
//!
//! Only realized ink claims. A fan claims through the one producer that
//! draws its members — its rail, or the per-peer path — and a member drawn
//! by another fan's rail claims nothing of its own. A fan whose lane pass
//! licensed its fusion with a neighbour (same lane, shared column) is one
//! claim with it. A placement edge into a cluster stand-in claims nothing
//! of its own: the bridges paint its ink, and their jogs are claimed for
//! them (`gap_rows_bridge.zig`).
//!
//! When an arrival rail and a departure rail stack in one gap the arrival
//! sits nearer the target. A rail whose stem column is a foreign tap's
//! column sits where that tap ends before reaching its junction.
//!
//! A gridded layer's stacked sub-rows add sub-gaps (`gap_rows_grid.zig`):
//! a run claims the gap above the sub-row it lands in, a route that must
//! corridor past a stacked box claims its entry in the gap above that box.
//!
//! Imports (layout zone): std + sem_graph + sketch + base/* + siblings.

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
const grid = @import("gap_rows_grid.zig");
const bridge = @import("gap_rows_bridge.zig");
const census_mod = @import("gap_rows_census.zig");
const fans_mod = @import("gap_rows_fans.zig");

pub const Kind = pack_mod.Kind;
pub const End = pack_mod.End;
pub const FanKey = pack_mod.FanKey;
pub const Claim = pack_mod.Claim;
pub const Post = pack_mod.Post;
pub const GapAccount = pack_mod.GapAccount;
pub const GapWalls = pack_mod.GapWalls;
pub const Ledger = pack_mod.Ledger;
pub const pack = pack_mod.pack;
pub const Super = census_mod.Super;
pub const predictPorts = census_mod.predictPorts;
const packSub = pack_mod.packSub;
const Census = census_mod.Census;
const centerOf = census_mod.centerOf;
const drawnByEligible = fans_mod.drawnByEligible;

/// A run from the column `dep`, where its ink comes down from the source
/// side, to the column `arr`, where it goes on toward the target.
/// `decorated_source`: the run leaves a decorated port, whose departure
/// cell stays straight, so the band holds the row above the run too.
pub fn edgeClaim(a: std.mem.Allocator, gap: u32, dep: i32, arr: i32, kind: Kind, end: End, base_ok: bool, decorated_source: bool, edge: sg.EdgeId) error{OutOfMemory}!Claim {
    const edges = try a.alloc(sg.EdgeId, 1);
    edges[0] = edge;
    const stems = try a.alloc(i32, 1);
    stems[0] = dep;
    const taps = try a.alloc(i32, 1);
    taps[0] = arr;
    return .{ .gap = gap, .lo = @min(dep, arr), .hi = @max(dep, arr), .height = 1 + @as(u32, @intFromBool(decorated_source)), .kind = kind, .end = end, .base_ok = base_ok, .edges = edges, .stems = stems, .taps = taps };
}

/// The claims of every edge the forward router draws: a jog per adjacent
/// offset edge, an entry and an exit run per skip corridor.
fn edgeClaims(comptime G: type, a: std.mem.Allocator, c: Census, geom: []const G, fans: []const fan_mod.Fan, eligible: []const bool, bundles: pb.RealizedBundles, per_peer: std.AutoHashMapUnmanaged(sg.EdgeId, void), claims: *std.ArrayListUnmanaged(Claim), posts: *std.ArrayListUnmanaged(Post)) error{OutOfMemory}!void {
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
        const scol = c.portCol(G, geom, e, .source_exit);
        const tcol = c.portCol(G, geom, e, .target_entry);
        const virtuals = try rt.collectVirtuals(a, c.lg, e.id);
        if (virtuals.len == 0) {
            // The jog lands in the gap above the target's sub-row. A
            // stacked box on the source column makes the route a corridor
            // beside it: an entry run in the gap above that box, the exit
            // run from the corridor column.
            const si = c.idx_of.get(e.from) orelse continue;
            const ti = c.idx_of.get(e.to) orelse continue;
            const exit_gap = if (c.flow_down) c.sub.gapAbove(G, geom, ti) orelse continue else target_gap;
            var from_col = scol;
            if (c.flow_down) if (c.sub.stackedObstacle(G, geom, c.lg, si, ti, scol)) |ob| {
                const entry_gap = c.sub.gapAbove(G, geom, ob) orelse continue;
                from_col = c.sub.corridorColumn(G, geom, c.lg, si, ti, tcol, true);
                if (from_col != scol) try claims.append(a, try edgeClaim(a, entry_gap, scol, from_col, .corridor_entry, .entry, e.arrow_from == .none, e.arrow_from != .none, e.id));
            };
            if (from_col != tcol) {
                try claims.append(a, try edgeClaim(a, exit_gap, from_col, tcol, if (from_col == scol) .run else .corridor_exit, .exit, e.arrow_to == .none and e.arrow_from == .none and from_col == scol, e.arrow_from != .none and from_col == scol, e.id));
            } else if (e.arrow_to != .none) try posts.append(a, .{ .gap = exit_gap, .x = tcol });
            continue;
        }
        // An RL corridor follows its virtuals through the layer bands; only a
        // flow-down corridor runs in the gaps.
        if (!c.flow_down) continue;
        const corridor = centerOf(G, geom, virtuals[0]);
        if (scol != corridor) try claims.append(a, try edgeClaim(a, sl, scol, corridor, .corridor_entry, .entry, e.arrow_from == .none, e.arrow_from != .none, e.id));
        if (corridor != tcol) {
            try claims.append(a, try edgeClaim(a, target_gap, corridor, tcol, .corridor_exit, .exit, e.arrow_to == .none, false, e.id));
        } else if (e.arrow_to != .none) try posts.append(a, .{ .gap = target_gap, .x = tcol });
    }
}

/// The bands the cluster bridges paint when a placement edge is reversed:
/// the bridge climbs back to the upper node and lands on its far face from
/// below — its head in the node's departure cell, its turn one row below,
/// from the port column to the corridor at the lower box's centre — a band
/// under the departure cells, above every run it conflicts with.
fn returnClaims(comptime G: type, a: std.mem.Allocator, c: Census, geom: []const G, claims: *std.ArrayListUnmanaged(Claim)) error{OutOfMemory}!void {
    for (c.graph.edges) |e| {
        if (!c.isPlacement(e) or e.from == e.to or !c.isReversed(e.id)) continue;
        const upper = c.layerOfNode(e.to) orelse continue;
        const gap = c.gapBelow(upper) orelse continue;
        const ui = c.idx_of.get(e.to) orelse continue;
        const li = c.idx_of.get(e.from) orelse continue;
        const port = centerOf(G, geom, ui);
        const corridor = centerOf(G, geom, li);
        const edges = try a.alloc(sg.EdgeId, 1);
        edges[0] = e.id;
        try claims.append(a, .{ .gap = gap, .lo = @min(port, corridor), .hi = @max(port, corridor), .height = 2, .kind = .bridge_return, .end = .entry, .edges = edges });
    }
}

/// The band a bridge leaving a member of this piece paints under it: where
/// a box of a lower layer stands on the member's column, the bridge's
/// straight elbow would pierce it and the stitch routes a corridor instead
/// (`bridge_scene.verticalCorridor`), which jogs in the row under the
/// member from its port to a column the stitch chooses — a band under the
/// departure cells, over the whole width, above every run it conflicts
/// with. The bridge's id is unknown here; the stitch files it in.
fn departureClaims(comptime G: type, a: std.mem.Allocator, c: Census, geom: []const G, claims: *std.ArrayListUnmanaged(Claim)) error{OutOfMemory}!void {
    var lo: i32 = std.math.maxInt(i32);
    var hi: i32 = std.math.minInt(i32);
    for (c.lg.nodes, 0..) |ln, i| if (ln == .real) {
        lo = @min(lo, geom[i].x);
        hi = @max(hi, geom[i].x + @as(i32, @intCast(geom[i].w)) - 1);
    };
    // A node's departures leave by one port and jog on one row
    // (`bridge_requests.assignJogs` merges bridges sharing a source port):
    // one band per node.
    for (c.departures, 0..) |node, di| {
        if (std.mem.indexOfScalar(sg.NodeId, c.departures[0..di], node) != null) continue;
        const mi = c.idx_of.get(node) orelse continue;
        const layer = c.node_layer[mi];
        const gap = c.gapBelow(layer) orelse continue;
        const col = centerOf(G, geom, mi);
        // A box in a lower layer, or stacked under the member in its own.
        var pierced = false;
        for (c.lg.nodes, 0..) |ln, i| {
            if (ln != .real or i == mi) continue;
            const below = if (c.node_layer[i] == layer) geom[i].y > geom[mi].y else if (c.flow_down) c.node_layer[i] > layer else c.node_layer[i] < layer;
            if (below and geom[i].x <= col and col < geom[i].x + @as(i32, @intCast(geom[i].w))) pierced = true;
        }
        if (!pierced) continue;
        try claims.append(a, .{ .gap = gap, .lo = lo, .hi = hi, .kind = .bridge_return, .end = .entry });
    }
}

/// Census every run the routers will paint and pack them. `bases[g]` is the
/// base spacing of gap g; `plan` the ports the routers will read; `supers`
/// the cluster stand-ins of a piece whose graph holds them; `departures`
/// the nodes a cross-border edge leaves. A node's `y` is its offset inside
/// its layer (zero unless a grid stacked it).
pub fn buildPiece(
    comptime G: type,
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const G,
    fans: []const fan_mod.Fan,
    bundles: pb.RealizedBundles,
    plan: port_plan.Plan,
    bases: []const u32,
    supers: []const Super,
    departures: []const sg.NodeId,
) error{OutOfMemory}!Ledger {
    if (bases.len == 0) return .{};
    const node_layer = try a.alloc(u32, lg.nodes.len);
    @memset(node_layer, 0);
    for (lg.layers, 0..) |row, li| for (row) |idx| {
        node_layer[idx] = @intCast(li);
    };
    var idx_of: std.AutoHashMapUnmanaged(sg.NodeId, u32) = .empty;
    for (lg.nodes, 0..) |ln, i| switch (ln) {
        .real => |id| try idx_of.put(a, id, @intCast(i)),
        .virtual => {},
    };
    const sub = try grid.census(G, a, lg, geom, @intCast(bases.len));
    const all_bases = try a.alloc(u32, bases.len + sub.gaps.len);
    @memcpy(all_bases[0..bases.len], bases);
    for (sub.gaps) |s| all_bases[s.gap] = s.base;
    const c: Census = .{ .graph = graph, .lg = lg, .plan = plan, .node_layer = node_layer, .idx_of = idx_of, .sub = sub, .supers = supers, .departures = departures, .flow_down = graph.direction != .RL, .ngaps = bases.len };

    const eligible = try a.alloc(bool, fans.len);
    for (fans, eligible) |f, *ok| ok.* = fan_rail.eligible(f, graph, bundles);

    var claims: std.ArrayListUnmanaged(Claim) = .empty;
    var posts: std.ArrayListUnmanaged(Post) = .empty;
    var per_peer: std.AutoHashMapUnmanaged(sg.EdgeId, void) = .empty;
    var detours: std.ArrayListUnmanaged(fans_mod.Detour) = .empty;
    var proxies: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    for (graph.edges) |e| if (c.isPlacement(e)) try proxies.append(a, e.id);
    try fans_mod.fanClaims(G, a, c, geom, fans, eligible, bundles, &claims, &per_peer, &detours);
    try fans_mod.detourClaims(G, a, lg, geom, detours.items, &claims);
    try fans_mod.strokeClaims(G, a, c, geom, fans, eligible, bundles, &claims);
    try edgeClaims(G, a, c, geom, fans, eligible, bundles, per_peer, &claims, &posts);
    try returnClaims(G, a, c, geom, &claims);
    try bridge.jogClaims(G, a, c, geom, &claims);
    try departureClaims(G, a, c, geom, &claims);
    var out = try packSub(a, claims.items, posts.items, all_bases, sub.gaps);
    out.proxies = try proxies.toOwnedSlice(a);
    return out;
}

test {
    _ = @import("gap_rows_test.zig");
    _ = @import("gap_rows_test2.zig");
}

//! gap_rows_bridge.zig — the bands the cluster bridges will paint in an
//! outer piece's gaps, claimed before the bridges exist.
//!
//! An outer piece holds cluster stand-ins; the edges that touch one are
//! placement edges, and the stitch drops their paths and routes the real
//! crossings as bridges (`cluster/bridges.zig`). A bridge into a node from
//! above jogs on the row `bridges.jogPref` prefers — the base row into a
//! plain node, the arrival row into a cluster frame — and the bridges of
//! one arrival group (`bridge_requests.assignJogs`: same target anchor,
//! same entry side) are one jog request per shared port — the bridges
//! into a plain node all end on its port, so they are one request; those
//! into a frame end on distinct inner ports — and requests whose spans
//! overlap stack outward one track each (`tracks.resolve`). One claim per
//! group reserves exactly those tracks, pinned at the preferred row, so
//! the outer piece's own runs pack above them and the gap grows only when
//! a third track is needed. A bridge that spans a layer runs a corridor:
//! its exit is claimed the same way, its entry as a band under the
//! source's departure cells.
//!
//! Imports (layout zone): std + sem_graph + base/lanes + gap_rows_pack.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const lanes = @import("../base/lanes.zig");
const pack_mod = @import("gap_rows_pack.zig");

const Claim = pack_mod.Claim;

/// `bundled`: the placement edge stands for several crossings that end
/// on one plain port — at most one of their bridges is straight, the rest
/// jog on the base row somewhere across the source frame's footprint.
const Request = struct { lo: i32, hi: i32, dep: i32, arr: i32, edge: sg.EdgeId, bundled: bool = false };

const Group = struct {
    target: sg.NodeId,
    gap: u32,
    /// -2 into a frame (the arrival row), -1 into a plain node (the base row).
    pin: i32,
    reqs: std.ArrayListUnmanaged(Request) = .empty,
};

/// `c` is the census (graph, layers, stand-ins, cross-axis columns).
pub fn jogClaims(comptime G: type, a: std.mem.Allocator, c: anytype, geom: []const G, claims: *std.ArrayListUnmanaged(Claim)) error{OutOfMemory}!void {
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    for (c.graph.edges) |e| {
        if (!c.isPlacement(e) or e.from == e.to or c.isReversed(e.id)) continue;
        const sl = c.layerOfNode(e.from) orelse continue;
        const tl = c.layerOfNode(e.to) orelse continue;
        const gap = c.gapOf(sl, tl) orelse continue;
        const ui = c.idx_of.get(e.from) orelse continue;
        const vi = c.idx_of.get(e.to) orelse continue;
        const u_col = centerOf(G, geom, ui);
        const v_col = centerOf(G, geom, vi);
        const pin: i32 = if (c.isDrawnSuper(e.to)) -2 else -1;
        // Into a plain node the bridge ends on its port; into a frame the
        // stand-in's centre stands for the inner port.
        const arr: i32 = if (pin == -1) c.portCol(G, geom, e, .target_entry) else v_col;
        if (c.layerDistance(sl, tl) > 1) {
            // A corridor: the entry jog one row off the source, the exit
            // jog on the target's preferred row.
            const entry_gap = c.gapBelow(sl) orelse continue;
            try claims.append(a, try one(a, entry_gap, u_col, v_col, .bridge_return, e.id, null));
            try claims.append(a, try one(a, gap, u_col, v_col, .bridge_jog, e.id, pin));
            continue;
        }
        const g: *Group = for (groups.items) |*existing| {
            if (existing.target == e.to) break existing;
        } else blk: {
            try groups.append(a, .{ .target = e.to, .gap = gap, .pin = pin });
            break :blk &groups.items[groups.items.len - 1];
        };
        var lo = @min(u_col, arr);
        var hi = @max(u_col, arr);
        // Several crossings behind one placement edge into a plain node
        // end on one port: their bridges leave the frame by distinct
        // columns of its footprint, and all but one jog to the port.
        // @guarded-by: gap_rows_test2.zig "a placement edge that stands for two crossings into a plain node claims the base row across its frame"
        const bundled = pin == -1 and e.crossings > 1 and c.isSuper(e.from);
        if (bundled) {
            lo = @min(lo, geom[ui].x);
            hi = @max(hi, geom[ui].x + @as(i32, @intCast(geom[ui].w)) - 1);
        }
        try g.reqs.append(a, .{ .lo = lo, .hi = hi, .dep = u_col, .arr = arr, .edge = e.id, .bundled = bundled });
    }
    for (groups.items) |*g| {
        // One request with aligned ends is a straight bridge
        // (`bridges.jogPref` is null): no run, no row — unless it is a
        // bundle, whose second bridge jogs; two from one frame
        // leave by distinct inner ports, so at least one jogs. A piece's
        // own run ending on the same plain
        // node's port is the same arrival bundle: it joins the band on
        // the base row instead of dropping through it from a row above.
        // @guarded-by: gap_rows_test2.zig "a skip edge into a plain node joins the bridge band that ends on its port"
        if (g.pin == -1) try adoptSamePortExits(a, g, claims);
        var lo: i32 = std.math.maxInt(i32);
        var hi: i32 = std.math.minInt(i32);
        var own: usize = 0;
        for (g.reqs.items) |r| own += @intFromBool(r.edge != sg.SENTINEL);
        const edges = try a.alloc(sg.EdgeId, own);
        const stems = try a.alloc(i32, own);
        const taps = try a.alloc(i32, own);
        var k: usize = 0;
        for (g.reqs.items) |r| {
            lo = @min(lo, r.lo);
            hi = @max(hi, r.hi);
            if (r.edge == sg.SENTINEL) continue;
            edges[k] = r.edge;
            stems[k] = r.dep;
            taps[k] = r.arr;
            k += 1;
        }
        if (lo == hi and g.reqs.items.len == 1 and !g.reqs.items[0].bundled) continue;
        var tracks: u32 = 1;
        if (g.pin == -2) {
            // Requests meeting at the arrival column from either side are
            // one request when they share the inner port and disjoint
            // runs when they do not: the column itself is no overlap.
            var demands: std.ArrayListUnmanaged(lanes.LaneClaim) = .empty;
            for (g.reqs.items) |r| {
                const lo_d = if (r.dep < r.arr) r.dep else r.arr + 1;
                const hi_d = if (r.dep < r.arr) r.arr - 1 else r.dep;
                if (lo_d > hi_d) continue;
                try demands.append(a, .{ .lo = @intCast(@max(0, lo_d)), .hi = @intCast(@max(0, hi_d)), .base = 0 });
            }
            if (demands.items.len > 1) {
                var asg = try lanes.assign(a, demands.items, 1);
                tracks = @intCast(@max(asg.lane_pos.len, 1));
                asg.deinit(a);
            }
        }
        try claims.append(a, .{ .gap = g.gap, .lo = lo, .hi = hi, .height = tracks, .kind = .bridge_jog, .end = .exit, .edges = edges, .stems = stems, .taps = taps, .pin = g.pin });
    }
}

/// Pin every exit claim of the group's gap that ends on one of its
/// arrival ports to the base row beside the band: the bundle shares the
/// row, and the claim keeps its own edge (the stitch maps a bridge
/// claim's edges to bridges).
fn adoptSamePortExits(a: std.mem.Allocator, g: *Group, claims: *std.ArrayListUnmanaged(Claim)) error{OutOfMemory}!void {
    for (claims.items) |*c| {
        if (c.gap != g.gap or c.end != .exit or c.fans.len != 0 or c.height != 1 or c.pin != null) continue;
        if (c.kind != .corridor_exit and c.kind != .run and c.kind != .stroke_exit) continue;
        const joins = blk: {
            for (c.taps) |t| for (g.reqs.items) |r| if (t == r.arr) break :blk true;
            break :blk false;
        };
        if (!joins) continue;
        c.pin = -1;
        try g.reqs.append(a, .{ .lo = c.lo, .hi = c.hi, .dep = c.lo, .arr = c.hi, .edge = sg.SENTINEL });
    }
}

fn one(a: std.mem.Allocator, gap: u32, x: i32, y: i32, kind: pack_mod.Kind, edge: sg.EdgeId, pin: ?i32) error{OutOfMemory}!Claim {
    const edges = try a.alloc(sg.EdgeId, 1);
    edges[0] = edge;
    const stems = try a.alloc(i32, 1);
    stems[0] = x;
    const taps = try a.alloc(i32, 1);
    taps[0] = y;
    return .{ .gap = gap, .lo = @min(x, y), .hi = @max(x, y), .kind = kind, .end = if (pin == null) .entry else .exit, .edges = edges, .stems = stems, .taps = taps, .pin = pin };
}

fn centerOf(comptime G: type, geom: []const G, idx: u32) i32 {
    const g = geom[idx];
    return g.x + @divTrunc(@as(i32, @intCast(g.w)), 2);
}

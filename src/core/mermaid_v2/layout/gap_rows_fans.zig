//! gap_rows_fans.zig — the row ledger's fan census: the runs a fan's rail
//! or per-peer path paints, the outside detours of exact duplicates, and
//! the strokes an eligible rail's long members own.
//!
//! Imports (layout zone): std + sem_graph + base/* + siblings.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const rail_closure = @import("../base/rail_closure.zig");
const sugiyama = @import("sugiyama.zig");
const fan_mod = @import("fan.zig");
const rt = @import("routing_terminal.zig");
const pack_mod = @import("gap_rows_pack.zig");
const census_mod = @import("gap_rows_census.zig");

const Claim = pack_mod.Claim;
const FanKey = pack_mod.FanKey;
const Census = census_mod.Census;
const Group = census_mod.Group;
const centerOf = census_mod.centerOf;
const edgeById = census_mod.edgeById;
const edgeClaim = @import("gap_rows.zig").edgeClaim;

/// The duplicate detours of one gap: exact private duplicates leave by
/// outside tracks (`port_plan.duplicateDetour`), `depth` deep at either
/// wall. `hi` is the rightmost port they turn from.
pub const Detour = struct {
    gap: u32,
    hi: i32,
    depth: u32,
    edges: std.ArrayListUnmanaged(sg.EdgeId) = .empty,
};

fn noteDetour(a: std.mem.Allocator, detours: *std.ArrayListUnmanaged(Detour), gap: u32, hi: i32, depth: u32, edge: sg.EdgeId) error{OutOfMemory}!void {
    const d: *Detour = for (detours.items) |*existing| {
        if (existing.gap == gap) break existing;
    } else blk: {
        try detours.append(a, .{ .gap = gap, .hi = hi, .depth = depth });
        break :blk &detours.items[detours.items.len - 1];
    };
    d.hi = @max(d.hi, hi);
    d.depth = @max(d.depth, depth);
    try d.edges.append(a, edge);
}

/// A gap's detours claim two bands: the target one holds the inward
/// turns (the base row and the rows above it, the shallowest detour
/// turning on the base row), the source one the outward turns under the
/// departure cells, so it sits above every run it conflicts with and the
/// gap reaches `2 * depth`. The track itself runs left of every node.
pub fn detourClaims(comptime G: type, a: std.mem.Allocator, lg: sugiyama.LayeredGraph, geom: []const G, detours: []Detour, claims: *std.ArrayListUnmanaged(Claim)) error{OutOfMemory}!void {
    var min_x: i32 = std.math.maxInt(i32);
    for (lg.nodes, 0..) |ln, i| if (ln == .real) {
        min_x = @min(min_x, geom[i].x);
    };
    for (detours) |*d| {
        const edges = try d.edges.toOwnedSlice(a);
        const depth: i32 = @intCast(d.depth);
        const lo = min_x - depth;
        try claims.append(a, .{ .gap = d.gap, .lo = lo, .hi = d.hi, .height = d.depth - 1, .kind = .detour_target, .end = .exit, .edges = edges, .pin = -1 });
        try claims.append(a, .{ .gap = d.gap, .lo = lo, .hi = d.hi, .height = d.depth, .kind = .detour_source, .end = .entry, .edges = edges });
    }
}

pub fn drawnByEligible(fans: []const fan_mod.Fan, eligible: []const bool, edge: sg.EdgeId, direction: fan_mod.Direction, discharged: []const pb.EdgeId) bool {
    for (fans, eligible) |f, ok| {
        if (!ok or f.direction != direction) continue;
        for (f.peers) |p| if (p.edge_id == edge and p.shared and !rail_closure.contains(discharged, edge)) return true;
    }
    return false;
}

/// The claims of every fan: one per run its drawing producer paints. A
/// per-peer run lands in the gap above its far end's sub-row; where its
/// descent would run through an earlier sub-row's box it jogs under the
/// pivot to a corridor beside that box — one jog row per fan, its run
/// starting at the corridor. A rail claim lists the members whose run it
/// is; a long member's runs lie in other gaps (`strokeClaims`).
pub fn fanClaims(
    comptime G: type,
    a: std.mem.Allocator,
    c: Census,
    geom: []const G,
    fans: []const fan_mod.Fan,
    eligible: []const bool,
    bundles: pb.RealizedBundles,
    claims: *std.ArrayListUnmanaged(Claim),
    per_peer: *std.AutoHashMapUnmanaged(sg.EdgeId, void),
    detours: *std.ArrayListUnmanaged(Detour),
) error{OutOfMemory}!void {
    for (fans, eligible, 0..) |f, ok, fi| {
        if (f.source_layer >= c.ngaps) continue;
        var groups: std.ArrayListUnmanaged(Group) = .empty;
        var dodges: std.ArrayListUnmanaged(Group) = .empty;
        for (f.peers) |p| {
            const e = edgeById(c.graph, p.edge_id) orelse continue;
            if (e.kind == .invisible or c.isPlacement(e) or rail_closure.contains(bundles.discharged, e.id)) continue;
            // The rail draws its shared members — unless a box stacked over
            // the member blocks the tap, which the stroke pass refuses and
            // hands to the per-peer path; every other member the router's
            // fan lookup hands to this fan is drawn per peer.
            const tap_col = if (p.long) centerOf(G, geom, p.peer_idx) else c.portCol(G, geom, e, if (f.direction == .out) .target_entry else .source_exit);
            const blocked = f.direction == .out and !p.long and c.sub.stackedObstacle(G, geom, c.lg, f.pivot_idx, p.peer_idx, tap_col) != null;
            const by_rail = ok and p.shared and !blocked;
            const drawn_here = by_rail or blk: {
                if (p.long) break :blk false;
                const other: fan_mod.Direction = if (f.direction == .out) .in else .out;
                if (drawnByEligible(fans, eligible, e.id, other, bundles.discharged)) break :blk false;
                const hit = fan_mod.lookup(fans, e.id) orelse break :blk false;
                break :blk hit.fan == &fans[fi];
            };
            if (!drawn_here) continue;
            if (!by_rail) try per_peer.put(a, e.id, {});
            const key = fan_mod.effectiveLane(f, p.lane);
            const pivot_end: pb.EndpointSide = if (f.direction == .out) .source_exit else .target_entry;
            const stem = c.portCol(G, geom, e, pivot_end);
            const tap = tap_col;
            // An unlabeled exact duplicate takes the outside detour, not the run.
            if (!by_rail and e.label == null) if (c.plan.forEdge(e.id)) |ep| if (ep.source_duplicate or ep.target_duplicate) {
                try noteDetour(a, detours, f.source_layer, @max(stem, tap), @max(ep.source_ordinal, ep.target_ordinal) + 2, e.id);
                continue;
            };
            const far_end = if (f.direction == .out) p.peer_idx else f.pivot_idx;
            const gap = if (by_rail) f.source_layer else c.sub.gapAbove(G, geom, far_end) orelse continue;
            // The jog lands in the gap above the box it dodges: the pivot's
            // gap for a box heading the peer's layer, the sub-gap under the
            // pivot for a box stacked beneath it.
            var run_lo = stem;
            if (!by_rail and f.direction == .out) if (c.sub.stackedObstacle(G, geom, c.lg, f.pivot_idx, p.peer_idx, stem)) |ob| {
                const corridor = c.sub.corridorColumn(G, geom, c.lg, f.pivot_idx, p.peer_idx, if (f.rows > 1) tap else stem, f.rows == 1);
                const dodge_gap = c.sub.gapAbove(G, geom, ob) orelse continue;
                const d: *Group = for (dodges.items) |*existing| {
                    if (existing.gap == dodge_gap) break existing;
                } else blk: {
                    try dodges.append(a, .{ .key = 0, .private = true, .gap = dodge_gap, .lo = stem, .hi = stem });
                    break :blk &dodges.items[dodges.items.len - 1];
                };
                d.lo = @min(d.lo, @min(stem, corridor));
                d.hi = @max(d.hi, @max(stem, corridor));
                if (e.arrow_from != .none) d.decorated_source = true;
                try d.edges.append(a, e.id);
                try d.stems.append(a, stem);
                try d.taps.append(a, corridor);
                run_lo = corridor;
            };
            const g: *Group = for (groups.items) |*existing| {
                if (existing.key == key and existing.private == !by_rail and existing.gap == gap) break existing;
            } else blk: {
                try groups.append(a, .{ .key = key, .private = !by_rail, .gap = gap, .comb = f.rows > 1 and gap != f.source_layer, .lo = run_lo, .hi = run_lo });
                break :blk &groups.items[groups.items.len - 1];
            };
            g.lo = @min(g.lo, @min(run_lo, tap));
            g.hi = @max(g.hi, @max(run_lo, tap));
            if (p.label_width != 0) g.labeled = true;
            if (e.arrow_from != .none) g.decorated_source = true;
            if (f.direction == .out) g.lift = @max(g.lift, rt.fanRailLift(c.graph, e.from, e.to));
            if (!p.long) try g.edges.append(a, e.id);
            try g.stems.append(a, run_lo);
            try g.taps.append(a, tap);
            try g.label_widths.append(a, p.label_width);
        }
        for (dodges.items) |*d| try claims.append(a, .{
            .gap = d.gap,
            .lo = d.lo,
            .hi = d.hi,
            .height = 1 + @as(u32, @intFromBool(d.decorated_source)),
            .kind = .grid_dodge,
            .end = .entry,
            .edges = try d.edges.toOwnedSlice(a),
            .stems = try d.stems.toOwnedSlice(a),
            .taps = try d.taps.toOwnedSlice(a),
        });
        for (groups.items) |*g| {
            // A run of verticals only needs no row — unless it carries a
            // label, whose band is the private descent's.
            if (g.lo == g.hi and !g.labeled) continue;
            // A rail answers `rowOfFan` and may fuse; a per-peer run is its
            // edges' alone. A lifted run is painted `lift` rows above its
            // row, and a decorated source keeps the row above straight:
            // both stay inside the band. A labeled fan-IN band is the rail
            // row plus `LABEL_RUN_EXTRA_ROWS` above it: the source's descent
            // is `│ label │` between its port and the rail. A labeled fan-OUT
            // band is `LABEL_RUN_EXTRA_ROWS` rows in all: the rail rises two
            // rows above its row (`fan_rail.build`, `fan_polyline`) and the
            // descent's third cell is the base cell the gap already holds.
            // When two of its labels cannot both stand on the label row —
            // one would touch a sibling's descent or label — the loser falls
            // to the side ladder, which needs one more row with blank
            // neighbours beside the stem. A grid comb keeps the one row the
            // grid reserved for it.
            // @guarded-by: junction_licence_test.zig "fan labels: feasible mixed, in-out, star-law-refused, clustered and BT renders lose none"
            const keys = try a.alloc(FanKey, 1);
            keys[0] = .{ .pivot_idx = f.pivot_idx, .direction = f.direction };
            const base: u32 = if (!g.labeled or g.comb) 1 else if (f.direction == .in) 1 + fan_mod.LABEL_RUN_EXTRA_ROWS else fan_mod.LABEL_RUN_EXTRA_ROWS + @intFromBool(labelsCollide(g.taps.items, g.label_widths.items));
            try claims.append(a, .{
                .gap = g.gap,
                .lo = g.lo,
                .hi = g.hi,
                .height = if (g.comb) 1 else base + g.lift + @intFromBool(g.decorated_source),
                .kind = if (g.comb) .grid_comb else if (f.direction == .in) .fan_in else .fan_out,
                .edges = try g.edges.toOwnedSlice(a),
                .fans = if (g.private) &.{} else keys,
                .stems = try g.stems.toOwnedSlice(a),
                .taps = try g.taps.toOwnedSlice(a),
                .fuse = if (!g.private and g.key == f.lane) f.lane else null,
                .pin = if (g.comb) -1 else null,
            });
        }
    }
}

/// True iff some label of the group cannot stand on the label row centred
/// on its own descent: it would come within the raster's one-cell margin
/// of a sibling's descent, or within two cells of a sibling's label
/// (`labels_ink.spanIsolated`; the same arithmetic as `fan.gateFanInSharedLabels`).
fn labelsCollide(taps: []const i32, widths: []const u32) bool {
    for (taps, widths, 0..) |cx, width, i| {
        if (width == 0) continue;
        const w: i32 = @intCast(width);
        const left = cx - @divTrunc(w - 1, 2);
        const right = cx + @divTrunc(w, 2);
        for (taps, widths, 0..) |qx, qwidth, j| {
            if (i == j) continue;
            if (qwidth != 0) {
                const qw: i32 = @intCast(qwidth);
                const q_left = qx - @divTrunc(qw - 1, 2);
                const q_right = qx + @divTrunc(qw, 2);
                if (!(right + 3 <= q_left or q_right + 3 <= left)) return true;
            } else if (left - 2 < qx and qx < right + 2) return true;
        }
    }
    return false;
}

/// The jogs of the member strokes an eligible rail's long members own.
pub fn strokeClaims(comptime G: type, a: std.mem.Allocator, c: Census, geom: []const G, fans: []const fan_mod.Fan, eligible: []const bool, bundles: pb.RealizedBundles, claims: *std.ArrayListUnmanaged(Claim)) error{OutOfMemory}!void {
    for (fans, eligible) |f, ok| {
        if (!ok) continue;
        for (f.peers) |p| {
            if (!p.long or !p.shared or rail_closure.contains(bundles.discharged, p.edge_id)) continue;
            const e = edgeById(c.graph, p.edge_id) orelse continue;
            if (c.isPlacement(e)) continue;
            const other: fan_mod.Direction = if (f.direction == .out) .in else .out;
            if (drawnByEligible(fans, eligible, e.id, other, bundles.discharged)) continue;
            const corridor = centerOf(G, geom, p.peer_idx);
            if (f.direction == .out) {
                const tl = c.layerOfNode(e.to) orelse continue;
                const col = c.portCol(G, geom, e, .target_entry);
                if (tl == 0 or tl - 1 >= c.ngaps or col == corridor) continue;
                try claims.append(a, try edgeClaim(a, tl - 1, corridor, col, .stroke_exit, .exit, e.arrow_to == .none, false, e.id));
            } else {
                const sl = c.layerOfNode(e.from) orelse continue;
                const col = c.portCol(G, geom, e, .source_exit);
                if (sl >= c.ngaps or col == corridor) continue;
                try claims.append(a, try edgeClaim(a, sl, col, corridor, .stroke_entry, .entry, e.arrow_from == .none, e.arrow_from != .none, e.id));
            }
        }
    }
}


//! Lever B — rank-grid reflow for `layout.zig`.
//!
//! Generalizes `fan_grid.zig`: reflows an over-wide Sugiyama layer (not
//! just one fan-OUT pivot's children) into a compact grid — `cols` nodes
//! per sub-row, stacked downward, lower layers pushed down to make room.
//! No rail synthesis: edges re-route from nodes' final geom in
//! `routing.buildEdges`. Pressure-gated to rungs > `natural` (TD-only,
//! no-op otherwise); conservative single-pass column calc, no fixpoint.
//! Fan coexistence decided by topology (`layerWrappedByFan`), not the fan list.
//!
//! Imports (layout/ zone): only `std` and `sugiyama.zig`.

const std = @import("std");
const sugiyama = @import("sugiyama.zig");

/// Reflow every over-wide layer of `lg` into a stacked grid. `geom` is
/// parallel to `lg.nodes`; `G` must expose `x: i32, y: i32, w: u32, h: u32`
/// fields (NodeGeom).
///
/// Mutates `geom` in place. Emits no rails: the repacked nodes' forward
/// edges re-route from their final positions in `routing.buildEdges`.
pub fn reflowWideRanks(
    comptime G: type,
    lg: sugiyama.LayeredGraph,
    geom: []G,
    budget: u32,
    h_spacing: u32,
    v_spacing: u32,
) void {
    // Walk layers top-to-bottom so later layers see already-shifted geom. // guarded-by: layout/rank_grid_test.zig "reflowWideRanks: a second wide layer's base_y reflects the first wide layer's shift, and a leaf further down cascades through both"
    for (lg.layers) |layer| {
        reflowOneLayer(G, lg, geom, budget, h_spacing, v_spacing, layer);
    }
}

fn reflowOneLayer(
    comptime G: type,
    lg: sugiyama.LayeredGraph,
    geom: []G,
    budget: u32,
    h_spacing: u32,
    v_spacing: u32,
    layer: []const u32,
) void {
    // Gather the REAL nodes of this layer, left-to-right by current x; virtuals carry no box and just ride the downward push. // guarded-by: layout/rank_grid_test.zig "reflowWideRanks: a same-layer virtual node's (oversized) width never enters the column/packing math and its position is untouched"
    var reals_buf: [256]u32 = undefined;
    var n_reals: usize = 0;
    for (layer) |idx| {
        switch (lg.nodes[idx]) {
            .real => {
                if (n_reals < reals_buf.len) {
                    reals_buf[n_reals] = idx;
                    n_reals += 1;
                }
            },
            .virtual => {},
        }
    }
    if (n_reals < 2) return;
    const reals = reals_buf[0..n_reals];
    if (layerWrappedByFan(lg, reals)) return;

    sortByX(G, reals, geom);

    // Actual rendered span (leftmost left edge → rightmost right edge) drives the overflow check, not tight packed width. // guarded-by: layout/rank_grid_test.zig "reflowWideRanks: nodes drifted far apart by centering are compacted even though their tight packed width already fits the budget"
    var span_min: i32 = std.math.maxInt(i32);
    var span_max: i32 = std.math.minInt(i32);
    // Tight single-row span = sum(node widths) + inter-node gaps.
    var single_row_w: u32 = 0;
    var max_w: u32 = 0;
    var max_h: u32 = 0;
    for (reals, 0..) |idx, i| {
        const g = geom[idx];
        single_row_w += g.w;
        if (i + 1 < reals.len) single_row_w += h_spacing;
        if (g.w > max_w) max_w = g.w;
        if (g.h > max_h) max_h = g.h;
        if (g.x < span_min) span_min = g.x;
        const right = g.x + @as(i32, @intCast(g.w));
        if (right > span_max) span_max = right;
    }
    const span: u32 = @intCast(@max(0, span_max - span_min));
    if (span <= budget) return; // already fits as positioned — leave it.

    const n: u32 = @intCast(reals.len);

    // Compaction floor keeps near-budget rows OUT of the compact path (no slack for centering/jogs) so they stack instead. // guarded-by: layout/rank_grid_test.zig "reflowWideRanks: a row exactly at the compact_floor boundary compacts to one row; one unit past it stacks into a grid"
    const compact_floor: u32 = budget - budget / 8;
    if (single_row_w <= compact_floor) {
        compactSingleRow(G, reals, geom, h_spacing);
        return;
    }

    // Otherwise stack into a grid: conservative widest-node-per-slot column count, forced to leave >=2 rows. // guarded-by: layout/rank_grid_test.zig "reflowWideRanks: the widest-node column formula still forces >=2 rows even when the naive per-node-count formula would leave one"
    const slot_w = max_w + h_spacing;
    var cols: u32 = if (slot_w == 0) 1 else (budget + h_spacing) / slot_w;
    if (cols == 0) cols = 1;
    if (cols >= n) cols = n - 1; // must split into ≥2 rows.
    const rows: u32 = (n + cols - 1) / cols;

    // Vertical step between grid sub-rows: tallest node + gap so sub-rows never touch and an edge can descend between them. // guarded-by: layout/rank_grid_test.zig "reflowWideRanks: row_step (max_h + v_spacing + 1) keeps a tall sub-row from touching the row below it"
    const row_step: i32 = @as(i32, @intCast(max_h)) +
        @as(i32, @intCast(v_spacing)) + 1;

    // Push every node strictly below base_y (real or virtual, incl. same-layer virtuals) down by added_h. guarded-by: layout/rank_grid_test.zig "rank-grid pushes only strictly-below nodes by added_h; same-layer and above nodes are untouched"
    const base_y: i32 = geom[reals[0]].y;
    const added_h: i32 = @as(i32, @intCast(rows - 1)) * row_step;
    for (geom) |*g| {
        if (g.y > base_y) g.y += added_h;
    }

    // Center the packed block on the layer's current horizontal center so the
    // grid sits under the same parents that fed the single row.
    const block_cx = layerCenterX(G, reals, geom);

    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const row_idx = i / cols;
        const col_start = row_idx * cols;
        const col_end = @min(col_start + cols, n);

        var rw: u32 = 0;
        var c: u32 = col_start;
        while (c < col_end) : (c += 1) {
            rw += geom[reals[c]].w;
            if (c + 1 < col_end) rw += h_spacing;
        }
        const row_left: i32 = block_cx - @divTrunc(@as(i32, @intCast(rw)), 2);

        var cursor: i32 = row_left;
        var k: u32 = col_start;
        while (k < col_end) : (k += 1) {
            geom[reals[k]].x = cursor;
            geom[reals[k]].y = base_y + @as(i32, @intCast(row_idx)) * row_step;
            cursor += @as(i32, @intCast(geom[reals[k]].w)) +
                @as(i32, @intCast(h_spacing));
        }
    }
}

/// True iff this layer is a single-pivot "fan rank" already governed by the
/// fan machinery / budget-ladder rotation, so rank-gridding it would fight
/// that machinery and change otherwise-fitting seeds. Two structural cases,
/// both keyed only on forward-edge topology (never on node identity):
///
///   (a) every real node converges to a SINGLE common forward CHILD — a pure
///       fan-IN rank; the budget ladder owns it (it rotates such a fan-IN to
///       fit). E.g. flowchart_fanin's source rank (4 roots → one Confirm).
///   (b) every real node shares a SINGLE common forward PARENT — a pure
///       single-pivot fan-OUT, which `wrapWideFanOut` already owns. E.g. the
///       spoke rank of flowchart_hub_and_spoke.
///
/// A genuine MULTI-pivot rank — whose nodes are fed by, or feed into, several
/// independent neighbours (multilayer_dag's mid/bottom ranks, frenzy's
/// rank-2, microservices' 4 disjoint service→DB chains) — fails both tests
/// and falls through to rank-grid. That is precisely the case
/// `wrapWideFanOut` cannot handle.
fn layerWrappedByFan(
    lg: sugiyama.LayeredGraph,
    reals: []const u32,
) bool {
    // Disconnected isolates (no forward edges at all) are exempt from rank-grid, left as a no-op to Lever A (component-packing). // guarded-by: layout/rank_grid_test.zig "reflowWideRanks: two edge-free sibling nodes (all-roots AND all-leaves) are left untouched"
    if (allRoots(lg, reals) and allLeaves(lg, reals)) return true;
    // (a) pure fan-IN source rank: ROOT + converges to a single common forward CHILD; the "all roots" qualifier is essential since a fed-from-above multi-layer rank is genuinely wide. // guarded-by: layout/rank_grid_test.zig "reflowWideRanks: a rank fed from above that ALSO converges to one child is not exempted as pure fan-IN — it still grids"
    if (allRoots(lg, reals) and sharedCommonNeighbour(lg, reals, .child)) return true;
    // (b) pure single-pivot fan-OUT: every node shares one common forward
    //     PARENT and is a LEAF below it (no outgoing forward edge), so the
    //     rank exists solely to diverge — `wrapWideFanOut` owns it. The "all
    //     leaves" qualifier mirrors (a): a rank that also feeds nodes below is
    //     genuinely wide and must still grid.
    if (allLeaves(lg, reals) and sharedCommonNeighbour(lg, reals, .parent)) return true;
    return false;
}

/// True iff no node in `reals` has an incoming forward (non-reversed) edge.
fn allRoots(lg: sugiyama.LayeredGraph, reals: []const u32) bool {
    for (reals) |idx| {
        for (lg.edges) |e| {
            if (e.reversed) continue;
            if (e.to == idx) return false;
        }
    }
    return true;
}

/// True iff no node in `reals` has an outgoing forward (non-reversed) edge.
fn allLeaves(lg: sugiyama.LayeredGraph, reals: []const u32) bool {
    for (reals) |idx| {
        for (lg.edges) |e| {
            if (e.reversed) continue;
            if (e.from == idx) return false;
        }
    }
    return true;
}

const Side = enum { parent, child };

/// True iff every node in `reals` has exactly one distinct forward neighbour
/// on `side` (parent = source of an incoming edge; child = target of an
/// outgoing edge) AND that neighbour is the SAME single node for all of them.
/// A node with zero or 2+ distinct such neighbours breaks the property.
fn sharedCommonNeighbour(lg: sugiyama.LayeredGraph, reals: []const u32, side: Side) bool {
    var common: ?u32 = null;
    for (reals) |idx| {
        const sole = soleForwardNeighbour(lg, idx, side) orelse return false;
        if (common) |c| {
            if (c != sole) return false;
        } else common = sole;
    }
    return common != null;
}

/// If `idx` has exactly one distinct forward neighbour on `side`, return it;
/// else null (zero, or 2+ distinct).
fn soleForwardNeighbour(lg: sugiyama.LayeredGraph, idx: u32, side: Side) ?u32 {
    var found: ?u32 = null;
    for (lg.edges) |e| {
        if (e.reversed) continue;
        const other: u32 = switch (side) {
            .parent => if (e.to == idx) e.from else continue,
            .child => if (e.from == idx) e.to else continue,
        };
        if (found) |f| {
            if (f != other) return null; // 2+ distinct neighbours.
        } else found = other;
    }
    return found;
}

/// Pack `reals` (already sorted L→R) into a single tight row, centered on the
/// span's current center. Used when a layer overflows by positional spread
/// rather than breadth: its boxes fit in one row, they were just drifted apart.
fn compactSingleRow(comptime G: type, reals: []const u32, geom: []G, h_spacing: u32) void {
    var rw: u32 = 0;
    for (reals, 0..) |idx, i| {
        rw += geom[idx].w;
        if (i + 1 < reals.len) rw += h_spacing;
    }
    const block_cx = layerCenterX(G, reals, geom);
    var cursor: i32 = block_cx - @divTrunc(@as(i32, @intCast(rw)), 2);
    for (reals) |idx| {
        geom[idx].x = cursor;
        cursor += @as(i32, @intCast(geom[idx].w)) + @as(i32, @intCast(h_spacing));
    }
}

fn sortByX(comptime G: type, idxs: []u32, geom: []const G) void {
    const Ctx = struct {
        g: []const G,
        fn lt(c: @This(), a: u32, b: u32) bool {
            if (c.g[a].x != c.g[b].x) return c.g[a].x < c.g[b].x;
            return a < b;
        }
    };
    std.mem.sort(u32, idxs, Ctx{ .g = geom }, Ctx.lt);
}

/// Center x of the span covered by `reals` (leftmost left edge → rightmost
/// right edge), in the same coordinate frame as `geom`.
fn layerCenterX(comptime G: type, reals: []const u32, geom: []const G) i32 {
    var min_x: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    for (reals) |idx| {
        const g = geom[idx];
        if (g.x < min_x) min_x = g.x;
        const right = g.x + @as(i32, @intCast(g.w));
        if (right > max_x) max_x = right;
    }
    return @divTrunc(min_x + max_x, 2);
}

test {
    _ = @import("rank_grid_test.zig");
}

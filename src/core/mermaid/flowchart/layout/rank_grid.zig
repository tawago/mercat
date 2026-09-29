const std = @import("std");
const sugiyama = @import("sugiyama.zig");
const fan_grid = @import("fan_grid.zig");

pub fn reflowWideRanks(
    comptime G: type,
    lg: sugiyama.LayeredGraph,
    geom: []G,
    budget: u32,
    h_spacing: u32,
    v_spacing: u32,
) void {
    // @guarded-by: layout/rank_grid_test.zig "reflowWideRanks: a second wide layer's base_y reflects the first wide layer's shift, and a leaf further down cascades through both"
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
    // @guarded-by: layout/rank_grid_test.zig "reflowWideRanks: a same-layer virtual node's (oversized) width never enters the column/packing math and its position is untouched"
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

    // @guarded-by: layout/rank_grid_test.zig "reflowWideRanks: nodes drifted far apart by centering are compacted even though their tight packed width already fits the budget"
    var span_min: i32 = std.math.maxInt(i32);
    var span_max: i32 = std.math.minInt(i32);
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
    if (span <= budget) return;

    const n: u32 = @intCast(reals.len);

    // @guarded-by: layout/rank_grid_test.zig "reflowWideRanks: a row exactly at the compact_floor boundary compacts to one row; one unit past it stacks into a grid"
    const compact_floor: u32 = budget - budget / 8;
    if (single_row_w <= compact_floor) {
        compactSingleRow(G, reals, geom, h_spacing);
        return;
    }

    // @guarded-by: layout/rank_grid_test.zig "reflowWideRanks: the widest-node column formula still forces >=2 rows even when the naive per-node-count formula would leave one"
    const slot_w = max_w + h_spacing;
    var cols: u32 = if (slot_w == 0) 1 else (budget + h_spacing) / slot_w;
    if (cols == 0) cols = 1;
    if (cols >= n) cols = n - 1;
    const rows: u32 = (n + cols - 1) / cols;

    // @guarded-by: layout/rank_grid_test.zig "reflowWideRanks: row_step (max_h + the grid gap) keeps a tall sub-row three rows clear of the row below it"
    const row_step = fan_grid.rowStep(max_h, v_spacing);

    // @guarded-by: layout/rank_grid_test.zig "rank-grid pushes only strictly-below nodes by added_h; same-layer and above nodes are untouched"
    var base_y: i32 = std.math.maxInt(i32);
    for (reals) |idx| base_y = @min(base_y, geom[idx].y);
    const added_h: i32 = @as(i32, @intCast(rows - 1)) * row_step;
    for (geom) |*g| {
        if (g.y > base_y) g.y += added_h;
    }

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

fn layerWrappedByFan(
    lg: sugiyama.LayeredGraph,
    reals: []const u32,
) bool {
    // @guarded-by: layout/rank_grid_test.zig "reflowWideRanks: two edge-free sibling nodes (all-roots AND all-leaves) are left untouched"
    if (allRoots(lg, reals) and allLeaves(lg, reals)) return true;
    // @guarded-by: layout/rank_grid_test.zig "reflowWideRanks: a rank fed from above that ALSO converges to one child is not exempted as pure fan-IN — it still grids"
    if (allRoots(lg, reals) and sharedCommonNeighbour(lg, reals, .child)) return true;
    if (allLeaves(lg, reals) and sharedCommonNeighbour(lg, reals, .parent)) return true;
    return false;
}

fn allRoots(lg: sugiyama.LayeredGraph, reals: []const u32) bool {
    for (reals) |idx| {
        for (lg.edges) |e| {
            if (e.reversed) continue;
            if (e.to == idx) return false;
        }
    }
    return true;
}

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

fn soleForwardNeighbour(lg: sugiyama.LayeredGraph, idx: u32, side: Side) ?u32 {
    var found: ?u32 = null;
    for (lg.edges) |e| {
        if (e.reversed) continue;
        const other: u32 = switch (side) {
            .parent => if (e.to == idx) e.from else continue,
            .child => if (e.from == idx) e.to else continue,
        };
        if (found) |f| {
            if (f != other) return null;
        } else found = other;
    }
    return found;
}

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

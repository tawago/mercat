//! gap_rows_grid.zig — the sub-rows a gridded layer stacks, as the row
//! ledger sees them.
//!
//! A wide fan-OUT or a wide rank is re-flowed into stacked sub-rows of one
//! layer (`fan_grid`, `rank_grid`). Between two sub-rows the grid reserves
//! a fixed band — the upper sub-row's departure row, a comb row, the lower
//! sub-row's arrival row — that no spacing grows. The ledger accounts each
//! band as a sub-gap: the row numbering of an inter-layer gap, its wall
//! the lower sub-row's top, its base the band's rows, and every run that
//! lands in it — a gridded fan's comb on the base row, an obstacle
//! corridor's entry on row 0 — packed there. When the census runs a node's
//! `y` is its offset inside its layer, so a stacked node is one with `y > 0`.
//!
//! Imports (layout zone): std + sugiyama.

const std = @import("std");
const sugiyama = @import("sugiyama.zig");

/// How far a corridor column search looks for a margined column before
/// settling for a merely box-free one (`sketch.clearLine`'s bound).
const MARGIN_BOUND: i32 = 24;

pub const SubGap = struct {
    /// The ledger's gap id: `real + i`.
    gap: u32,
    layer: u32,
    /// Offset of the lower sub-row's top inside the layer: the wall.
    top: i32,
    /// Offset of the first row under the upper sub-row's tallest box.
    far: i32,
    /// The band's rows, fixed by the grid.
    base: u32,
};

pub const SubRows = struct {
    layer_of: []const u32,
    gaps: []SubGap = &.{},
    /// Inter-layer gaps; sub-gaps are numbered after them.
    real: u32,

    /// The gap whose wall is `idx`'s top: the inter-layer gap above its
    /// layer when it heads the layer, else the sub-gap above its sub-row.
    pub fn gapAbove(self: SubRows, comptime G: type, geom: []const G, idx: u32) ?u32 {
        const layer = self.layer_of[idx];
        if (geom[idx].y == 0) return if (layer == 0) null else layer - 1;
        for (self.gaps) |s| if (s.layer == layer and s.top == geom[idx].y) return s.gap;
        return null;
    }

    /// The stacked box the column `col` runs through on its way from
    /// `from` (above) to `to` (below): a box under `from` in its layer, or
    /// above `to` in its; the highest such box.
    pub fn stackedObstacle(self: SubRows, comptime G: type, geom: []const G, lg: sugiyama.LayeredGraph, from: u32, to: u32, col: i32) ?u32 {
        var best: ?u32 = null;
        for (lg.layers[self.layer_of[from]]) |idx| {
            if (idx == from or lg.nodes[idx] != .real or geom[idx].y <= geom[from].y) continue;
            if (!coversColumn(G, geom[idx], col)) continue;
            if (best == null or geom[idx].y < geom[best.?].y) best = idx;
        }
        if (best != null) return best;
        for (lg.layers[self.layer_of[to]]) |idx| {
            if (idx == to or lg.nodes[idx] != .real or geom[idx].y >= geom[to].y) continue;
            if (!coversColumn(G, geom[idx], col)) continue;
            if (best == null or geom[idx].y < geom[best.?].y) best = idx;
        }
        return best;
    }

    /// The column a corridor takes past the boxes between `from` (above)
    /// and `to` (below) — those stacked under `from` in its layer and over
    /// `to` in its: the one nearest `want` that no such box covers, left
    /// first, and with `margin` one whose neighbours are box-free too, the
    /// way `sketch.clearLine` chooses it.
    pub fn corridorColumn(self: SubRows, comptime G: type, geom: []const G, lg: sugiyama.LayeredGraph, from: u32, to: u32, want: i32, margin: bool) i32 {
        var plain: ?i32 = null;
        var delta: i32 = 0;
        while (delta < 4096) : (delta += 1) {
            for ([2]i32{ want - delta, want + delta }) |c| {
                const center = self.columnFree(G, geom, lg, from, to, c);
                if (margin and delta < MARGIN_BOUND) {
                    if (center and self.columnFree(G, geom, lg, from, to, c - 1) and self.columnFree(G, geom, lg, from, to, c + 1)) return c;
                    if (center and plain == null) plain = c;
                } else if (center) return plain orelse c;
                if (delta == 0) break;
            }
        }
        return plain orelse want;
    }

    fn columnFree(self: SubRows, comptime G: type, geom: []const G, lg: sugiyama.LayeredGraph, from: u32, to: u32, col: i32) bool {
        for (lg.layers[self.layer_of[from]]) |idx| {
            if (idx == from or lg.nodes[idx] != .real or geom[idx].y <= geom[from].y) continue;
            if (coversColumn(G, geom[idx], col)) return false;
        }
        for (lg.layers[self.layer_of[to]]) |idx| {
            if (idx == to or lg.nodes[idx] != .real or geom[idx].y >= geom[to].y) continue;
            if (coversColumn(G, geom[idx], col)) return false;
        }
        return true;
    }
};

fn coversColumn(comptime G: type, g: G, col: i32) bool {
    return g.x <= col and col < g.x + @as(i32, @intCast(g.w));
}

/// Every sub-gap of the layered graph: one per pair of consecutive
/// sub-rows of a layer, numbered from `real`.
pub fn census(comptime G: type, a: std.mem.Allocator, lg: sugiyama.LayeredGraph, geom: []const G, real: u32) error{OutOfMemory}!SubRows {
    const layer_of = try a.alloc(u32, lg.nodes.len);
    @memset(layer_of, 0);
    var gaps: std.ArrayListUnmanaged(SubGap) = .empty;
    for (lg.layers, 0..) |row, li| {
        var tops: std.ArrayListUnmanaged(i32) = .empty;
        for (row) |idx| {
            layer_of[idx] = @intCast(li);
            if (lg.nodes[idx] != .real) continue;
            if (std.mem.indexOfScalar(i32, tops.items, geom[idx].y) == null) try tops.append(a, geom[idx].y);
        }
        std.mem.sort(i32, tops.items, {}, std.sort.asc(i32));
        for (tops.items[1..], 1..) |top, k| {
            var far: i32 = std.math.minInt(i32);
            for (row) |idx| {
                if (lg.nodes[idx] != .real or geom[idx].y != tops.items[k - 1]) continue;
                far = @max(far, geom[idx].y + @as(i32, @intCast(geom[idx].h)));
            }
            if (far >= top) continue;
            try gaps.append(a, .{ .gap = real + @as(u32, @intCast(gaps.items.len)), .layer = @intCast(li), .top = top, .far = far, .base = @intCast(top - far) });
        }
    }
    return .{ .layer_of = layer_of, .gaps = try gaps.toOwnedSlice(a), .real = real };
}

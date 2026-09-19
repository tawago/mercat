const std = @import("std");
const sugiyama = @import("sugiyama.zig");

const MARGIN_BOUND: i32 = 24;

pub const SubGap = struct {
    gap: u32,
    layer: u32,
    top: i32,
    far: i32,
    base: u32,
};

pub const SubRows = struct {
    layer_of: []const u32,
    gaps: []SubGap = &.{},
    real: u32,

    pub fn gapAbove(self: SubRows, comptime G: type, geom: []const G, idx: u32) ?u32 {
        const layer = self.layer_of[idx];
        if (geom[idx].y == 0) return if (layer == 0) null else layer - 1;
        for (self.gaps) |s| if (s.layer == layer and s.top == geom[idx].y) return s.gap;
        return null;
    }

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

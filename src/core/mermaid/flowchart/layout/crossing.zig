const std = @import("std");
const sugiyama = @import("sugiyama.zig");
const LayeredGraph = sugiyama.LayeredGraph;

const max_iterations = 24;
const convergence_window = 3;

pub fn reduceCrossings(allocator: std.mem.Allocator, lg: *LayeredGraph) error{OutOfMemory}!void {
    if (lg.layers.len < 2) return;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const order = try Order.init(a, lg.*);

    const best = try a.alloc([]u32, lg.layers.len);
    for (lg.layers, best) |row, *kept| kept.* = try a.dupe(u32, row);
    var best_crossings = order.crossings(lg.layers);
    var best_rail = order.railCost(lg.layers);

    var stagnation: u8 = 0;
    for (0..max_iterations) |_| {
        for (1..lg.layers.len) |i| order.reorder(lg.layers, i, i - 1);
        var i = lg.layers.len - 1;
        while (i > 0) : (i -= 1) order.reorder(lg.layers, i - 1, i);

        const crossings = order.crossings(lg.layers);
        const rail = order.railCost(lg.layers);
        if (crossings < best_crossings or (crossings == best_crossings and rail < best_rail)) {
            best_crossings = crossings;
            best_rail = rail;
            copyLayers(best, lg.layers);
            stagnation = 0;
        } else {
            copyLayers(lg.layers, best);
            stagnation += 1;
            if (stagnation >= convergence_window) break;
        }
        if (best_crossings == 0) break;
    }

    copyLayers(lg.layers, best);
}

/// One vertex in a barycenter sort: the exact fraction `sum / count` decides,
/// then a vertex off the back edges goes first, then the position it held.
pub const Key = struct {
    v: u32,
    sum: u64,
    count: u64,
    back: bool,
    prev: u32,

    pub fn less(_: void, a: Key, b: Key) bool {
        const left = a.sum * b.count;
        const right = b.sum * a.count;
        if (left != right) return left < right;
        if (a.back != b.back) return !a.back;
        return a.prev < b.prev;
    }
};

pub const Order = struct {
    edges: []const sugiyama.LayerEdge,
    back: []bool,
    forward_leaf: []bool,
    layer: []u32,
    pos: []u32,
    keys: []Key,

    pub fn init(a: std.mem.Allocator, lg: LayeredGraph) error{OutOfMemory}!Order {
        var widest: usize = 0;
        for (lg.layers) |row| widest = @max(widest, row.len);
        const order: Order = .{
            .edges = lg.edges,
            .back = try a.alloc(bool, lg.nodes.len),
            .forward_leaf = try a.alloc(bool, lg.nodes.len),
            .layer = try a.alloc(u32, lg.nodes.len),
            .pos = try a.alloc(u32, lg.nodes.len),
            .keys = try a.alloc(Key, widest),
        };
        @memset(order.back, false);
        @memset(order.forward_leaf, true);
        for (lg.layers, 0..) |row, li| for (row) |v| {
            order.layer[v] = @intCast(li);
        };
        for (lg.edges) |e| {
            if (e.reversed) {
                order.back[e.from] = true;
                order.back[e.to] = true;
            } else order.forward_leaf[e.from] = false;
        }
        return order;
    }

    pub fn crossings(order: Order, layers: []const []u32) u64 {
        for (layers) |row| for (row, 0..) |v, p| {
            order.pos[v] = @intCast(p);
        };
        var total: u64 = 0;
        for (order.edges, 0..) |a, k| {
            if (order.layer[a.to] != order.layer[a.from] + 1) continue;
            for (order.edges[k + 1 ..]) |b| {
                if (order.layer[b.from] != order.layer[a.from] or order.layer[b.to] != order.layer[a.to]) continue;
                const upper = std.math.order(order.pos[a.from], order.pos[b.from]);
                const lower = std.math.order(order.pos[a.to], order.pos[b.to]);
                if (upper != .eq and lower != .eq and upper != lower) total += 1;
            }
        }
        return total;
    }

    pub fn railCost(order: Order, layers: []const []u32) u64 {
        var total: u64 = 0;
        for (layers) |row| {
            if (row.len <= 1) continue;
            for (row, 0..) |v, p| {
                if (order.back[v] and order.forward_leaf[v]) total += row.len - 1 - p;
            }
        }
        return total;
    }

    fn reorder(order: Order, layers: []const []u32, li: usize, from: usize) void {
        const row = layers[li];
        if (row.len <= 1) return;
        for (layers[from], 0..) |v, p| order.pos[v] = @intCast(p);

        const keys = order.keys[0..row.len];
        for (row, keys, 0..) |v, *key, p| {
            key.* = .{ .v = v, .sum = 0, .count = 0, .back = order.back[v], .prev = @intCast(p) };
            for (order.edges) |e| {
                const other = if (from < li) (if (e.to == v) e.from else continue) else (if (e.from == v) e.to else continue);
                if (order.layer[other] != from) continue;
                key.sum += order.pos[other];
                key.count += 1;
            }
            if (key.count == 0) {
                key.sum = p;
                key.count = 1;
            }
        }
        std.mem.sort(Key, keys, {}, Key.less);
        for (row, keys) |*v, key| v.* = key.v;
    }
};

fn copyLayers(dst: []const []u32, src: []const []u32) void {
    for (dst, src) |to, from| @memcpy(to, from);
}

test {
    _ = @import("crossing_test.zig");
}

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const LayeredGraph = sugiyama.LayeredGraph;

pub const Sweep = enum { alternating, down_only, up_only };

pub const CrossingOptions = struct {
    max_iterations: u8 = 24,
    sweep: Sweep = .alternating,
    convergence_window: u8 = 3,
};

pub fn reduceCrossings(
    allocator: std.mem.Allocator,
    lg: *LayeredGraph,
    opts: CrossingOptions,
) !void {
    if (lg.layers.len < 2) return;

    var best = try cloneLayers(allocator, lg.layers);
    defer freeLayers(allocator, best);

    var best_crossings: u32 = try countCrossings(allocator, lg.*);
    var best_rail: u64 = railCost(lg.*);

    var stagnation: u8 = 0;
    var iter: u8 = 0;
    while (iter < opts.max_iterations) : (iter += 1) {
        switch (opts.sweep) {
            .alternating => {
                try sweepDown(allocator, lg);
                try sweepUp(allocator, lg);
            },
            .down_only => try sweepDown(allocator, lg),
            .up_only => try sweepUp(allocator, lg),
        }

        const cur = try countCrossings(allocator, lg.*);
        const cur_rail = railCost(lg.*);
        if (cur < best_crossings or
            (cur == best_crossings and cur_rail < best_rail))
        {
            best_crossings = cur;
            best_rail = cur_rail;
            freeLayers(allocator, best);
            best = try cloneLayers(allocator, lg.layers);
            stagnation = 0;
        } else {
            restoreLayers(lg.layers, best);
            stagnation += 1;
            if (opts.convergence_window != 0 and stagnation >= opts.convergence_window) {
                break;
            }
        }
        if (best_crossings == 0) break;
    }

    restoreLayers(lg.layers, best);
}

pub fn countCrossings(allocator: std.mem.Allocator, lg: LayeredGraph) !u32 {
    if (lg.layers.len < 2) return 0;

    var pos = try allocator.alloc(u32, lg.nodes.len);
    defer allocator.free(pos);
    @memset(pos, 0);

    var total: u32 = 0;
    var li: usize = 0;
    while (li + 1 < lg.layers.len) : (li += 1) {
        const upper = lg.layers[li];
        const lower = lg.layers[li + 1];
        for (upper, 0..) |idx, p| pos[idx] = @intCast(p);
        for (lower, 0..) |idx, p| pos[idx] = @intCast(p);

        var pair_edges: std.ArrayListUnmanaged(PairEdge) = .empty;
        defer pair_edges.deinit(allocator);
        for (lg.edges) |e| {
            if (containsIdx(upper, e.from) and containsIdx(lower, e.to)) {
                try pair_edges.append(allocator, .{
                    .u = pos[e.from],
                    .v = pos[e.to],
                });
            }
        }

        var i: usize = 0;
        while (i < pair_edges.items.len) : (i += 1) {
            const a = pair_edges.items[i];
            var j: usize = i + 1;
            while (j < pair_edges.items.len) : (j += 1) {
                const b = pair_edges.items[j];
                if ((a.u < b.u and a.v > b.v) or
                    (a.u > b.u and a.v < b.v))
                {
                    total += 1;
                }
            }
        }
    }
    return total;
}

const PairEdge = struct { u: u32, v: u32 };

pub const ScoredNode = struct {
    idx: u32,
    bary: f64,
    cur: u32,
    /// guarded-by: layout/crossing_test.zig "cmpScored places back-edge
    back: u8 = 0,
};

pub fn cmpScored(_: void, a: ScoredNode, b: ScoredNode) bool {
    if (a.bary != b.bary) return a.bary < b.bary;
    if (a.back != b.back) return a.back < b.back;
    return a.cur < b.cur;
}

test {
    _ = @import("crossing_test.zig");
}

fn sweepDown(allocator: std.mem.Allocator, lg: *LayeredGraph) !void {
    if (lg.layers.len < 2) return;
    var i: usize = 1;
    while (i < lg.layers.len) : (i += 1) {
        try reorderLayer(allocator, lg, i, .from_above);
    }
}

fn sweepUp(allocator: std.mem.Allocator, lg: *LayeredGraph) !void {
    if (lg.layers.len < 2) return;
    var i: usize = lg.layers.len - 1;
    while (i > 0) : (i -= 1) {
        try reorderLayer(allocator, lg, i - 1, .from_below);
    }
}

const Side = enum { from_above, from_below };

fn reorderLayer(
    allocator: std.mem.Allocator,
    lg: *LayeredGraph,
    layer_idx: usize,
    side: Side,
) !void {
    const row = lg.layers[layer_idx];
    if (row.len <= 1) return;

    const neighbour_layer = switch (side) {
        .from_above => lg.layers[layer_idx - 1],
        .from_below => lg.layers[layer_idx + 1],
    };

    var npos = try allocator.alloc(i64, lg.nodes.len);
    defer allocator.free(npos);
    @memset(npos, -1);
    for (neighbour_layer, 0..) |idx, p| npos[idx] = @intCast(p);

    const scored = try allocator.alloc(ScoredNode, row.len);
    defer allocator.free(scored);

    for (row, 0..) |idx, cur_pos| {
        var sum: f64 = 0;
        var n: u32 = 0;
        for (lg.edges) |e| {
            switch (side) {
                .from_above => {
                    if (e.to == idx) {
                        const p = npos[e.from];
                        if (p >= 0) {
                            sum += @floatFromInt(p);
                            n += 1;
                        }
                    }
                },
                .from_below => {
                    if (e.from == idx) {
                        const p = npos[e.to];
                        if (p >= 0) {
                            sum += @floatFromInt(p);
                            n += 1;
                        }
                    }
                },
            }
        }
        const bary: f64 = if (n == 0)
            @floatFromInt(cur_pos)
        else
            sum / @as(f64, @floatFromInt(n));

        scored[cur_pos] = .{
            .idx = idx,
            .bary = bary,
            .cur = @intCast(cur_pos),
            .back = if (isBackEndpoint(lg, idx)) 1 else 0,
        };
    }

    // guarded-by: layout/crossing_test.zig "cmpScored breaks barycenter ties by original position, independent of input order"
    std.mem.sort(ScoredNode, scored, {}, cmpScored);

    for (scored, 0..) |s, k| row[k] = s.idx;
}

fn cloneLayers(allocator: std.mem.Allocator, layers: [][]u32) ![][]u32 {
    const out = try allocator.alloc([]u32, layers.len);
    var i: usize = 0;
    errdefer {
        var k: usize = 0;
        while (k < i) : (k += 1) allocator.free(out[k]);
        allocator.free(out);
    }
    while (i < layers.len) : (i += 1) {
        out[i] = try allocator.dupe(u32, layers[i]);
    }
    return out;
}

fn freeLayers(allocator: std.mem.Allocator, layers: [][]u32) void {
    for (layers) |row| allocator.free(row);
    allocator.free(layers);
}

fn restoreLayers(dst: [][]u32, src: [][]u32) void {
    std.debug.assert(dst.len == src.len);
    for (dst, src) |d, s| {
        std.debug.assert(d.len == s.len);
        @memcpy(d, s);
    }
}

pub fn isBackEndpoint(lg: *const LayeredGraph, idx: u32) bool {
    for (lg.edges) |e| {
        if (e.reversed and (e.from == idx or e.to == idx)) return true;
    }
    return false;
}

/// guarded-by: layout/crossing_test.zig "reduceCrossings parks a back-edge
pub fn railCost(lg: LayeredGraph) u64 {
    var total: u64 = 0;
    for (lg.layers) |row| {
        if (row.len <= 1) continue;
        for (row, 0..) |idx, pos| {
            if (isBackEndpoint(&lg, idx) and isForwardLeaf(&lg, idx))
                total += @intCast(row.len - 1 - pos);
        }
    }
    return total;
}

fn isForwardLeaf(lg: *const LayeredGraph, idx: u32) bool {
    for (lg.edges) |e| {
        if (!e.reversed and e.from == idx) return false;
    }
    return true;
}

fn containsIdx(row: []const u32, idx: u32) bool {
    for (row) |x| {
        if (x == idx) return true;
    }
    return false;
}

const testing = std.testing;

fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{
        .id = id,
        .raw_id = raw,
        .label = raw,
        .shape = .rect,
        .classes = &.{},
        .cluster = null,
    };
}

fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
    };
}

test "linear chain has zero crossings before and after" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2) };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    const before = try countCrossings(testing.allocator, lg);
    try testing.expectEqual(@as(u32, 0), before);

    const snap = try cloneLayers(testing.allocator, lg.layers);
    defer freeLayers(testing.allocator, snap);

    try reduceCrossings(testing.allocator, &lg, .{});

    const after = try countCrossings(testing.allocator, lg);
    try testing.expectEqual(@as(u32, 0), after);

    try testing.expectEqual(snap.len, lg.layers.len);
    for (snap, lg.layers) |s, r| {
        try testing.expectEqualSlices(u32, s, r);
    }
}

test "two-layer X pattern reduces from 1 to 0" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "B"),
        mkNode(2, "C"),
        mkNode(3, "D"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 3),
        mkEdge(1, 1, 2),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), lg.layers.len);
    try testing.expectEqual(@as(usize, 2), lg.layers[0].len);
    try testing.expectEqual(@as(usize, 2), lg.layers[1].len);

    const before = try countCrossings(testing.allocator, lg);
    try testing.expectEqual(@as(u32, 1), before);

    const orig_lower = try testing.allocator.dupe(u32, lg.layers[1]);
    defer testing.allocator.free(orig_lower);

    try reduceCrossings(testing.allocator, &lg, .{});

    const after = try countCrossings(testing.allocator, lg);
    try testing.expectEqual(@as(u32, 0), after);

    const upper_swapped = lg.layers[0][0] != 0 or lg.layers[0][1] != 1;
    const lower_swapped =
        lg.layers[1][0] != orig_lower[0] or lg.layers[1][1] != orig_lower[1];
    try testing.expect(upper_swapped or lower_swapped);
}

test "convergence_window stops early when no improvement" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "B"),
        mkNode(2, "C"),
        mkNode(3, "D"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1),
        mkEdge(1, 2, 3),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    const before = try countCrossings(testing.allocator, lg);
    try testing.expectEqual(@as(u32, 0), before);

    try reduceCrossings(testing.allocator, &lg, .{ .convergence_window = 1 });

    const after = try countCrossings(testing.allocator, lg);
    try testing.expectEqual(@as(u32, 0), after);
}

test "best-of rollback never increases crossings" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "B"),
        mkNode(2, "C"),
        mkNode(3, "D"),
        mkNode(4, "E"),
        mkNode(5, "F"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 4),
        mkEdge(1, 0, 5),
        mkEdge(2, 1, 3),
        mkEdge(3, 1, 5),
        mkEdge(4, 2, 3),
        mkEdge(5, 2, 4),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    const before = try countCrossings(testing.allocator, lg);
    try reduceCrossings(testing.allocator, &lg, .{});
    const after = try countCrossings(testing.allocator, lg);
    try testing.expect(after <= before);
}

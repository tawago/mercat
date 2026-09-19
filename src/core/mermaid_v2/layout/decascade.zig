const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");

pub const NodeGeom = routing.NodeGeom;

const MIN_DRIFT: i32 = 4;

const COLLISION_GAP: i32 = 2;

pub const CorridorDrop = struct { gap: u32, rows: u32 };

pub fn deCascade(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    geom: []NodeGeom,
    lg: sugiyama.LayeredGraph,
) error{OutOfMemory}!?CorridorDrop {
    _ = graph;
    const nl = lg.layers.len;
    if (nl < 3) return null;

    var margin: i32 = std.math.maxInt(i32);
    for (lg.nodes, 0..) |ln, i| {
        if (ln == .real and geom[i].x < margin) margin = geom[i].x;
    }
    if (margin == std.math.maxInt(i32)) return null;

    // @guarded-by: decascade_test.zig "deCascade anchors on the most-drifted rail, not the first-drifted one"
    var seed_idx: ?u32 = null;
    var best_drift: i32 = MIN_DRIFT;
    {
        var li: usize = 0;
        while (li < nl) : (li += 1) {
            const sole = soleRealNode(lg, li) orelse continue;
            const drift = geom[sole].x - margin;
            if (drift > best_drift) {
                best_drift = drift;
                seed_idx = sole;
            }
        }
    }
    const seed = seed_idx orelse return null;

    // @guarded-by: decascade_test.zig "deCascade head climb stops exactly at a multi-node fork layer"
    var head = seed;
    while (true) {
        const p = soleForwardParent(lg, head) orelse break;
        if (geom[p].layer + 1 != geom[head].layer) break;
        if (soleRealNode(lg, geom[p].layer) == null) break;
        if (soleForwardChild(lg, p) == null) break;
        head = p;
    }
    // @guarded-by: decascade_test.zig "deCascade no-ops when the drifted rail head is a true source (no forward parent)"
    if (soleForwardParent(lg, head) == null) return null;
    const lo: usize = geom[head].layer;

    var hi = lo;
    var cur = head;
    while (true) {
        const next = soleForwardChild(lg, cur) orelse break;
        // @guarded-by: decascade_test.zig "deCascade rail walk stops at a branch instead of treating it as rail-straight"
        if (soleRealNode(lg, geom[next].layer) == null) break;
        if (geom[next].layer != geom[cur].layer + 1) break;
        hi = geom[next].layer;
        cur = next;
    }

    // @guarded-by: decascade_test.zig "deCascade does not fire for a lone drifted single-node layer (hi==lo)"
    if (hi <= lo) return null;

    const n = lg.nodes.len;
    const in_unit = try a.alloc(bool, n);
    defer a.free(in_unit);
    @memset(in_unit, false);

    var stack: std.ArrayListUnmanaged(u32) = .empty;
    defer stack.deinit(a);
    {
        var c = head;
        in_unit[c] = true;
        try stack.append(a, c);
        while (true) {
            const next = soleForwardChild(lg, c) orelse break;
            if (soleRealNode(lg, geom[next].layer) == null) break;
            if (geom[next].layer != geom[c].layer + 1) break;
            if (geom[next].layer > hi) break;
            in_unit[next] = true;
            try stack.append(a, next);
            c = next;
        }
    }
    // @guarded-by: decascade_test.zig "deCascade flood-forward never pulls a node above the run into the unit"
    while (stack.pop()) |node| {
        for (lg.edges) |e| {
            if (e.from != node) continue;
            if (e.reversed) continue;
            const t = e.to;
            if (in_unit[t]) continue;
            if (geom[t].layer < lo) continue;
            in_unit[t] = true;
            try stack.append(a, t);
        }
    }

    var unit_min: i32 = std.math.maxInt(i32);
    for (lg.nodes, 0..) |ln, i| {
        if (ln == .real and in_unit[i] and geom[i].x < unit_min) unit_min = geom[i].x;
    }
    if (unit_min == std.math.maxInt(i32)) return null;

    var delta = margin - unit_min;
    if (delta >= 0) return null;

    // @guarded-by: decascade_test.zig "deCascade collision floor clamps the slide short of a fixed sibling's right edge"
    var floor: i32 = std.math.minInt(i32);
    for (lg.nodes, 0..) |ln, i| {
        if (ln != .real or !in_unit[i]) continue;
        const layer = geom[i].layer;
        var rail: i32 = std.math.minInt(i32);
        for (lg.layers[layer]) |j| {
            if (lg.nodes[j] != .real or in_unit[j]) continue;
            if (geom[j].x >= geom[i].x) continue;
            const r = geom[j].x + @as(i32, @intCast(geom[j].w));
            if (r > rail) rail = r;
        }
        if (rail == std.math.minInt(i32)) continue;
        const node_floor = (rail + COLLISION_GAP) - geom[i].x;
        if (node_floor > floor) floor = node_floor;
    }
    if (floor != std.math.minInt(i32) and delta < floor) delta = floor;
    if (delta >= 0) return null;

    for (lg.nodes, 0..) |_, i| {
        if (in_unit[i]) geom[i].x += delta;
    }

    const head_port = geom[head].x + @divTrunc(@as(i32, @intCast(geom[head].w)), 2);
    var needs_corridor = false;
    var fork_layer_h: i32 = 0;
    if (lo > 0) {
        for (lg.layers[lo - 1]) |idx| {
            if (lg.nodes[idx] != .real or in_unit[idx]) continue;
            const r = geom[idx].x + @as(i32, @intCast(geom[idx].w));
            if (geom[idx].x <= head_port and head_port <= r) {
                needs_corridor = true;
            }
            const h: i32 = @intCast(geom[idx].h);
            if (h > fork_layer_h) fork_layer_h = h;
        }
    }
    // @guarded-by: decascade_test.zig "deCascade entry-corridor drop uses the tallest fork-layer sibling, not just the overlapping one"
    if (needs_corridor and fork_layer_h > 0) return .{ .gap = @intCast(lo - 1), .rows = @intCast(fork_layer_h) };
    return null;
}

fn soleRealNode(lg: sugiyama.LayeredGraph, li: usize) ?u32 {
    if (li >= lg.layers.len) return null;
    var found: ?u32 = null;
    for (lg.layers[li]) |idx| {
        if (lg.nodes[idx] != .real) continue;
        if (found != null) return null;
        found = idx;
    }
    return found;
}

fn soleForwardParent(lg: sugiyama.LayeredGraph, idx: u32) ?u32 {
    var found: ?u32 = null;
    for (lg.edges) |e| {
        if (e.to != idx) continue;
        if (e.reversed) continue;
        if (found != null) return null;
        found = e.from;
    }
    return found;
}

fn soleForwardChild(lg: sugiyama.LayeredGraph, idx: u32) ?u32 {
    var found: ?u32 = null;
    for (lg.edges) |e| {
        if (e.from != idx) continue;
        if (e.reversed) continue;
        if (found != null) return null;
        found = e.to;
    }
    return found;
}

test {
    _ = @import("decascade_test.zig");
}

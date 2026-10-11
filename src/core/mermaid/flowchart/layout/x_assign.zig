const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const fan_mod = @import("fan.zig");
const node_geom = @import("node_geom.zig");

const NodeGeom = node_geom.NodeGeom;

pub fn spread(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    geom: []NodeGeom,
    lg: sugiyama.LayeredGraph,
    h_spacing: u32,
    compact: bool,
) error{OutOfMemory}!void {
    assignInitialX(geom, lg.layers, h_spacing);
    try centerByBarycenter(a, graph, geom, lg, h_spacing, .down, compact);
    try centerByBarycenter(a, graph, geom, lg, h_spacing, .up, compact);
    normalizeX(geom);
    try centerByBarycenter(a, graph, geom, lg, h_spacing, .down, compact);
    normalizeX(geom);
}

pub fn assignInitialX(geom: []NodeGeom, layers: [][]u32, h_spacing: u32) void {
    for (layers) |row| {
        var cursor: i32 = 0;
        for (row) |idx| {
            geom[idx].x = cursor;
            cursor += @as(i32, @intCast(geom[idx].w)) + @as(i32, @intCast(h_spacing));
        }
    }
}

pub const SweepDir = enum { down, up };

pub fn centerByBarycenter(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    geom: []NodeGeom,
    lg: sugiyama.LayeredGraph,
    h_spacing: u32,
    dir: SweepDir,
    compact: bool,
) error{OutOfMemory}!void {
    if (lg.layers.len < 2) return;
    if (dir == .down) {
        var li: usize = 0;
        while (li < lg.layers.len) : (li += 1) {
            try centerLayer(a, graph, geom, lg, lg.layers[li], h_spacing, dir, compact);
        }
    } else {
        var li: usize = lg.layers.len;
        while (li > 0) {
            li -= 1;
            try centerLayer(a, graph, geom, lg, lg.layers[li], h_spacing, dir, compact);
        }
    }
}

fn centerLayer(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    geom: []NodeGeom,
    lg: sugiyama.LayeredGraph,
    row: []const u32,
    h_spacing: u32,
    dir: SweepDir,
    compact: bool,
) error{OutOfMemory}!void {
    if (row.len == 0) return;
    const desired = try a.alloc(i32, row.len);
    defer a.free(desired);

    for (row, 0..) |idx, k| {
        if (fan_mod.fanInCentroid(NodeGeom, geom, lg, idx)) |cx| {
            desired[k] = cx;
            continue;
        }
        var sum: i64 = 0;
        var n: u32 = 0;
        for (lg.edges) |e| {
            const want_above = dir == .down;
            if (want_above) {
                if (e.to == idx and geom[e.from].layer + 1 == geom[idx].layer) {
                    sum += geom[e.from].centerX();
                    n += 1;
                }
            } else {
                if (e.from == idx and geom[e.to].layer == geom[idx].layer + 1) {
                    sum += geom[e.to].centerX();
                    n += 1;
                }
            }
        }
        if (n == 0) {
            desired[k] = geom[idx].centerX();
        } else {
            desired[k] = @intCast(@divTrunc(sum, @as(i64, @intCast(n))));
        }
    }

    var cursor: i32 = std.math.minInt(i32) / 2;
    for (row, 0..) |idx, k| {
        const w_i: i32 = @intCast(geom[idx].w);
        const want_left = desired[k] - @divTrunc(w_i, 2);
        const left = if (want_left > cursor) want_left else cursor;
        geom[idx].x = left;
        cursor = left + w_i + @as(i32, @intCast(h_spacing));
    }

    if (!compact) return;

    if (!rowHasLabeledIncomingEdge(graph, geom, lg, row)) {
        centerRunOnDesired(geom, lg, row, desired);
    }
}

pub fn rowHasLabeledIncomingEdge(graph: sg.SemGraph, geom: []const NodeGeom, lg: sugiyama.LayeredGraph, row: []const u32) bool {
    for (row) |idx| {
        const tgt_layer = geom[idx].layer;
        if (tgt_layer == 0) continue;
        for (lg.edges) |e| {
            if (e.to != idx) continue;
            if (e.reversed) continue;
            if (geom[e.from].layer + 1 != tgt_layer) continue;
            if (edgeHasLabel(graph, e.edge)) return true;
        }
    }
    return false;
}

fn edgeHasLabel(graph: sg.SemGraph, edge_id: sg.EdgeId) bool {
    const edge = graph.edgeById(edge_id) orelse return false;
    return edge.labelText() != null;
}

fn centerRunOnDesired(geom: []NodeGeom, lg: sugiyama.LayeredGraph, row: []const u32, desired: []const i32) void {
    var sum_actual: i64 = 0;
    var sum_desired: i64 = 0;
    var n: i64 = 0;
    for (row, 0..) |idx, k| {
        switch (lg.nodes[idx]) {
            .real => {
                sum_actual += geom[idx].centerX();
                sum_desired += desired[k];
                n += 1;
            },
            .virtual => {},
        }
    }
    if (n == 0) return;
    var delta: i32 = @intCast(@divTrunc(sum_desired - sum_actual, n));
    if (delta == 0) return;

    var min_x: i32 = std.math.maxInt(i32);
    for (row) |idx| {
        if (geom[idx].x < min_x) min_x = geom[idx].x;
    }
    if (min_x + delta < 0) delta = -min_x;
    if (delta == 0) return;
    for (row) |idx| geom[idx].x += delta;
}

pub fn normalizeX(geom: []NodeGeom) void {
    if (geom.len == 0) return;
    var min_x: i32 = geom[0].x;
    for (geom) |g| {
        if (g.x < min_x) min_x = g.x;
    }
    if (min_x == 0) return;
    for (geom) |*g| g.x -= min_x;
}

pub fn centersX(a: std.mem.Allocator, geom: []const NodeGeom) error{OutOfMemory}![]i32 {
    const cx = try a.alloc(i32, geom.len);
    for (geom, 0..) |g, i| cx[i] = g.centerX();
    return cx;
}

test {
    _ = @import("x_assign_test.zig");
}

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const spacing = @import("spacing.zig");
const fan_mod = @import("fan.zig");
const routing = @import("routing.zig");

pub const NodeGeom = routing.NodeGeom;

pub fn assignInitialX(
    graph: sg.SemGraph,
    geom: []NodeGeom,
    nodes: []const sugiyama.LayerNode,
    layers: [][]u32,
    h_spacing: u32,
    spacing_scale: u8,
) void {
    for (layers) |row| {
        var cursor: i32 = 0;
        var prev: ?u32 = null;
        for (row) |idx| {
            if (prev) |p| {
                const extra = spacing.intraLayerExtra(graph, nodes[p], nodes[idx], spacing_scale);
                cursor += @as(i32, @intCast(extra));
            }
            geom[idx].x = cursor;
            cursor += @as(i32, @intCast(geom[idx].w)) + @as(i32, @intCast(h_spacing));
            prev = idx;
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
    spacing_scale: u8,
) error{OutOfMemory}!void {
    if (lg.layers.len < 2) return;
    if (dir == .down) {
        var li: usize = 0;
        while (li < lg.layers.len) : (li += 1) {
            try centerLayer(a, graph, geom, lg, lg.layers[li], h_spacing, dir, compact, spacing_scale);
        }
    } else {
        var li: usize = lg.layers.len;
        while (li > 0) {
            li -= 1;
            try centerLayer(a, graph, geom, lg, lg.layers[li], h_spacing, dir, compact, spacing_scale);
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
    spacing_scale: u8,
) error{OutOfMemory}!void {
    if (row.len == 0) return;
    const desired = try a.alloc(i32, row.len);
    defer a.free(desired);

    for (row, 0..) |idx, k| {
        // guarded-by: layout/x_assign_test.zig "centerLayer's fan-IN override centers on the real-source centroid, excluding a reversed back-edge source"
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
                    sum += centerX(geom[e.from]);
                    n += 1;
                }
            } else {
                if (e.from == idx and geom[e.to].layer == geom[idx].layer + 1) {
                    sum += centerX(geom[e.to]);
                    n += 1;
                }
            }
        }
        if (n == 0) {
            desired[k] = centerX(geom[idx]);
        } else {
            desired[k] = @intCast(@divTrunc(sum, @as(i64, @intCast(n))));
        }
    }

    // guarded-by: layout/x_assign_test.zig "monotonic packing's min_cursor floor drifts a shared-barycenter run right of its target, and compact=true corrects it"
    var cursor: i32 = std.math.minInt(i32) / 2;
    var prev_idx: ?u32 = null;
    for (row, 0..) |idx, k| {
        const w_i: i32 = @intCast(geom[idx].w);
        const extra: u32 = if (prev_idx) |p|
            spacing.intraLayerExtra(graph, lg.nodes[p], lg.nodes[idx], spacing_scale)
        else
            0;
        const min_cursor = cursor + @as(i32, @intCast(extra));
        const want_left = desired[k] - @divTrunc(w_i, 2);
        const left = if (want_left > min_cursor) want_left else min_cursor;
        geom[idx].x = left;
        cursor = left + w_i + @as(i32, @intCast(h_spacing));
        prev_idx = idx;
    }

    // guarded-by: layout/layout_test.zig "drift compaction fires on natural TD but is suppressed by is_direction_rotated, and never fires for LR"
    if (!compact) return;

    // guarded-by: layout/x_assign_test.zig "centerLayer skips re-centering a row that is both clustered and a labeled fork"
    if (!rowHasClusteredNode(graph, lg, row) and
        !rowHasLabeledIncomingEdge(graph, geom, lg, row))
    {
        centerRunOnDesired(geom, lg, row, desired);
    }
}

fn rowHasClusteredNode(graph: sg.SemGraph, lg: sugiyama.LayeredGraph, row: []const u32) bool {
    for (row) |idx| {
        switch (lg.nodes[idx]) {
            .real => |nid| {
                for (graph.nodes) |n| {
                    if (n.id == nid and n.cluster != null) return true;
                }
            },
            .virtual => {},
        }
    }
    return false;
}

fn rowHasLabeledIncomingEdge(graph: sg.SemGraph, geom: []const NodeGeom, lg: sugiyama.LayeredGraph, row: []const u32) bool {
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
    for (graph.edges) |ge| {
        if (ge.id != edge_id) continue;
        if (ge.label) |l| return l.len > 0;
        return false;
    }
    return false;
}

/// guarded-by: layout/x_assign_test.zig "centerRunOnDesired re-centers using only real nodes, keeping the real node's rail straight"
fn centerRunOnDesired(geom: []NodeGeom, lg: sugiyama.LayeredGraph, row: []const u32, desired: []const i32) void {
    var sum_actual: i64 = 0;
    var sum_desired: i64 = 0;
    var n: i64 = 0;
    for (row, 0..) |idx, k| {
        switch (lg.nodes[idx]) {
            .real => {
                sum_actual += centerX(geom[idx]);
                sum_desired += desired[k];
                n += 1;
            },
            .virtual => {},
        }
    }
    if (n == 0) return;
    var delta: i32 = @intCast(@divTrunc(sum_desired - sum_actual, n));
    if (delta == 0) return;

    // guarded-by: layout/x_assign_test.zig "centerRunOnDesired's width clamp keeps a recentered row from crossing x=0"
    var min_x: i32 = std.math.maxInt(i32);
    for (row) |idx| {
        if (geom[idx].x < min_x) min_x = geom[idx].x;
    }
    if (min_x + delta < 0) delta = -min_x;
    if (delta == 0) return;
    for (row) |idx| geom[idx].x += delta;
}

pub fn centerX(g: NodeGeom) i32 {
    return g.x + @divTrunc(@as(i32, @intCast(g.w)), 2);
}

pub fn flushLeftRows(graph: sg.SemGraph, geom: []NodeGeom, lg: sugiyama.LayeredGraph) void {
    var margin: i32 = std.math.maxInt(i32);
    for (lg.nodes, 0..) |ln, i| {
        switch (ln) {
            .real => if (geom[i].x < margin) {
                margin = geom[i].x;
            },
            .virtual => {},
        }
    }
    if (margin == std.math.maxInt(i32)) return;

    for (lg.layers) |row| {
        var real_count: u32 = 0;
        var row_min: i32 = std.math.maxInt(i32);
        for (row) |idx| {
            switch (lg.nodes[idx]) {
                .real => {
                    real_count += 1;
                    if (geom[idx].x < row_min) row_min = geom[idx].x;
                },
                .virtual => {},
            }
        }
        if (real_count < 2) continue;
        if (rowHasClusteredNode(graph, lg, row)) continue;
        if (rowHasLabeledIncomingEdge(graph, geom, lg, row)) continue;

        var delta = margin - row_min;
        if (delta >= 0) continue;

        // guarded-by: layout/x_assign_test.zig "flushLeftRows' connector-stretch floor stops short of the margin instead of stretching a connector"
        var floor_x: i32 = std.math.minInt(i32);
        for (row) |idx| {
            const nb = leftmostNeighbourX(geom, lg, idx) orelse continue;
            const node_floor = nb - geom[idx].x;
            if (node_floor > floor_x) floor_x = node_floor;
        }
        if (floor_x != std.math.minInt(i32) and delta < floor_x) delta = floor_x;
        if (delta >= 0) continue;
        for (row) |idx| geom[idx].x += delta;
    }
}

fn leftmostNeighbourX(geom: []const NodeGeom, lg: sugiyama.LayeredGraph, idx: u32) ?i32 {
    var min_cx: i32 = std.math.maxInt(i32);
    var found = false;
    for (lg.edges) |e| {
        const other: ?u32 = if (e.from == idx) e.to else if (e.to == idx) e.from else null;
        if (other) |o| {
            const cx = centerX(geom[o]);
            if (cx < min_cx) min_cx = cx;
            found = true;
        }
    }
    return if (found) min_cx else null;
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
    for (geom, 0..) |g, i| cx[i] = centerX(g);
    return cx;
}

test {
    _ = @import("x_assign_test.zig");
}

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const node_geom = @import("node_geom.zig");
const fan_mod = @import("fan.zig");
const options = @import("options.zig");
const x_assign = @import("x_assign.zig");
const components = @import("components.zig");
const rank_grid = @import("rank_grid.zig");
const decascade = @import("decascade.zig");

const NodeGeom = node_geom.NodeGeom;

pub fn run(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []NodeGeom,
    fans: []fan_mod.Fan,
    v_sp_per_gap: []u32,
    opts: options.LayoutOptions,
    compact_x: bool,
) error{OutOfMemory}!void {
    const under_pressure = opts.justify == .flush_left and compact_x;
    if (under_pressure) {
        flushLeftRows(graph, geom, lg);
        x_assign.normalizeX(geom);
        try components.packComponents(a, graph, geom, lg);
        x_assign.normalizeX(geom);
    }
    if (graph.direction == .TD and fans.len > 0) {
        fan_mod.wrapWideFanOut(NodeGeom, fans, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        if (under_pressure) fan_mod.wrapWideFanIn(NodeGeom, fans, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        x_assign.normalizeX(geom);
    }
    if (under_pressure) {
        rank_grid.reflowWideRanks(lg, geom, opts.max_width, opts.h_spacing, opts.v_spacing);
        x_assign.normalizeX(geom);
        if (try decascade.deCascade(a, geom, lg)) |drop| v_sp_per_gap[drop.gap] += drop.rows;
        x_assign.normalizeX(geom);
    }
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
        if (x_assign.rowHasLabeledIncomingEdge(graph, geom, lg, row)) continue;

        var delta = margin - row_min;
        if (delta >= 0) continue;

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
            const cx = geom[o].centerX();
            if (cx < min_cx) min_cx = cx;
            found = true;
        }
    }
    return if (found) min_cx else null;
}

test {
    _ = @import("pressure_test.zig");
}

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const node_geom = @import("node_geom.zig");
const gap_rows = @import("gap_rows.zig");

const NodeGeom = node_geom.NodeGeom;

pub fn heights(a: std.mem.Allocator, lg: sugiyama.LayeredGraph, geom: []const NodeGeom) error{OutOfMemory}![]u32 {
    const layer_h = try a.alloc(u32, lg.layers.len);
    @memset(layer_h, 0);
    for (lg.layers, layer_h) |row, *tallest| {
        for (row) |idx| tallest.* = @max(tallest.*, geom[idx].h);
    }
    return layer_h;
}

pub fn gaps(a: std.mem.Allocator, direction: sg.Direction, lg: sugiyama.LayeredGraph, v_spacing: u32) error{OutOfMemory}![]u32 {
    const base: u32 = switch (direction) {
        .TD => v_spacing,
        .BT => unreachable,
        .LR, .RL => 4,
    };
    if (lg.layers.len == 0) return try a.alloc(u32, 0);
    const out = try a.alloc(u32, lg.layers.len - 1);
    @memset(out, base);
    return out;
}

pub fn assignY(geom: []NodeGeom, layers: [][]u32, layer_h: []const u32, v_sp_per_gap: []const u32) void {
    var cursor: i32 = 0;
    for (layers, 0..) |row, li| {
        for (row) |idx| geom[idx].y += cursor;
        const gap: u32 = if (li < v_sp_per_gap.len) v_sp_per_gap[li] else 0;
        cursor += @as(i32, @intCast(layer_h[li])) + @as(i32, @intCast(gap));
    }
}

pub fn foldLayerOffsets(lg: sugiyama.LayeredGraph, geom: []NodeGeom, layer_h: []u32) void {
    for (lg.layers, 0..) |row, li| {
        var top: i32 = std.math.maxInt(i32);
        for (row) |idx| if (lg.nodes[idx] == .real) {
            top = @min(top, geom[idx].y);
        };
        if (top == std.math.maxInt(i32)) for (row) |idx| {
            top = @min(top, geom[idx].y);
        };
        var block: u32 = 0;
        for (row) |idx| {
            geom[idx].y = if (lg.nodes[idx] == .real) geom[idx].y - top else 0;
            block = @max(block, @as(u32, @intCast(geom[idx].y)) + geom[idx].h);
        }
        layer_h[li] = block;
    }
}

fn growSubGaps(lg: sugiyama.LayeredGraph, geom: []NodeGeom, layer_h: []u32, rows: gap_rows.Ledger) void {
    var i: usize = 0;
    while (i < rows.sub_gaps.len) : (i += 1) {
        const sgp = &rows.sub_gaps[i];
        const extra = rows.extraRows(sgp.gap);
        if (extra == 0) continue;
        const shift: i32 = @intCast(extra);
        for (lg.layers[sgp.layer]) |idx| if (lg.nodes[idx] == .real and geom[idx].y >= sgp.top) {
            geom[idx].y += shift;
        };
        for (rows.sub_gaps[i..]) |*later| if (later.layer == sgp.layer) {
            later.top += shift;
            if (later.far >= sgp.top) later.far += shift;
        };
        layer_h[sgp.layer] += extra;
    }
}

pub fn restack(lg: sugiyama.LayeredGraph, geom: []NodeGeom, layer_h: []u32, v_sp_per_gap: []u32, rows: gap_rows.Ledger) void {
    for (v_sp_per_gap, 0..) |*gap, i| gap.* += rows.extraRows(i);
    growSubGaps(lg, geom, layer_h, rows);
    assignY(geom, lg.layers, layer_h, v_sp_per_gap);
}

test {
    _ = @import("layer_axis_test.zig");
}

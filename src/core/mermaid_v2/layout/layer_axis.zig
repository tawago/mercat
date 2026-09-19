const std = @import("std");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const gap_rows = @import("gap_rows.zig");

const NodeGeom = routing.NodeGeom;

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

pub fn growSubGaps(lg: sugiyama.LayeredGraph, geom: []NodeGeom, layer_h: []u32, rows: gap_rows.Ledger) void {
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

pub fn layerTops(a: std.mem.Allocator, geom: []const NodeGeom, layers: [][]u32) error{OutOfMemory}![]const i32 {
    const tops = try a.alloc(i32, layers.len);
    for (layers, tops) |row, *top| {
        top.* = std.math.maxInt(i32);
        for (row) |idx| top.* = @min(top.*, geom[idx].y);
    }
    return tops;
}

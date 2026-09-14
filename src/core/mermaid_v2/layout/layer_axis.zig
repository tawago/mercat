//! layer_axis.zig — placing the layers down the layer axis for layout.zig.
//!
//! The levers that move nodes (flush-left, component packing, the grids,
//! the de-cascade) read and move `y`, so the layers are placed once at
//! base spacing for them; their result is then folded into each node's
//! offset inside its layer and the layers placed again with the row
//! ledger's spacing. A grid's sub-gaps grow here by what the ledger
//! packed into them.
//!
//! Imports (layout zone): std + sugiyama + routing (NodeGeom) + gap_rows.

const std = @import("std");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const gap_rows = @import("gap_rows.zig");

const NodeGeom = routing.NodeGeom;

/// Place the layers down the layer axis. On entry each node's `y` is its
/// offset inside its layer (zero until a grid stacks it); on return it is
/// absolute.
pub fn assignY(geom: []NodeGeom, layers: [][]u32, layer_h: []const u32, v_sp_per_gap: []const u32) void {
    var cursor: i32 = 0;
    for (layers, 0..) |row, li| {
        for (row) |idx| geom[idx].y += cursor;
        const gap: u32 = if (li < v_sp_per_gap.len) v_sp_per_gap[li] else 0;
        cursor += @as(i32, @intCast(layer_h[li])) + @as(i32, @intCast(gap));
    }
}

/// After the levers: each node's `y` becomes its offset inside its layer
/// and `layer_h` the height of the layer's stacked block, so the layers can
/// be placed again with the ledger's spacing without losing a grid's rows.
pub fn foldLayerOffsets(lg: sugiyama.LayeredGraph, geom: []NodeGeom, layer_h: []u32) void {
    for (lg.layers, 0..) |row, li| {
        // A virtual carries no box: it heads its layer wherever the levers left it.
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

/// A grid sub-gap holds the rows the grid reserved; where the packed
/// claims need more, the stacked sub-rows beneath it move down by the
/// difference and the layer's block grows with them — the ledger's
/// account of the band, like an inter-layer gap's. Sub-gaps are visited
/// in order, so a lower one carries the growth of those above it.
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

/// Each layer's top after placement: the least `y` among its nodes.
pub fn layerTops(a: std.mem.Allocator, geom: []const NodeGeom, layers: [][]u32) error{OutOfMemory}![]const i32 {
    const tops = try a.alloc(i32, layers.len);
    for (layers, tops) |row, *top| {
        top.* = std.math.maxInt(i32);
        for (row) |idx| top.* = @min(top.*, geom[idx].y);
    }
    return tops;
}


//! Back-edge (reversed-edge) routing for `layout/routing.zig`.
//! Builds the U-shape path for Sugiyama-reversed edges: TD/BT exit
//! source EAST to a rail column past the widest spanned node then enter
//! target EAST; LR/RL exit SOUTH to a rail row then enter target SOUTH.
//! `lanes.zig` packs back-edges into shared/stacked rails and finds the
//! obstacle-aware base; this module builds span demands and maps
//! resolved lanes to edge ids. Imports: std, sem_graph.zig, sketch.zig,
//! sugiyama.zig, routing.zig, lanes.zig only; must not reach raster/lattice/paint.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const lanes = @import("lanes.zig");

pub const BackEdgeRail = struct {
    edge_id: sg.EdgeId,
    /// Perpendicular distance from the node row to the rail line.
    /// TD/BT: x-column of the vertical rail. LR/RL: y-row of the
    /// horizontal rail.
    rail_pos: i32,
};

const RAIL_PAD: i32 = 1;
const RAIL_STACK_GAP: i32 = 1;

pub fn findRail(rails: []const BackEdgeRail, eid: sg.EdgeId) i32 {
    for (rails) |r| {
        if (r.edge_id == eid) return r.rail_pos;
    }
    return 0;
}

fn nodeGeomIndex(lg: sugiyama.LayeredGraph, nid: sg.NodeId) ?u32 {
    return lg.real_index.get(nid);
}

const Item = struct {
    eid: sg.EdgeId,
    from: sg.NodeId,
    to: sg.NodeId,
    lo: u32, // min layer of {source, target}
    hi: u32, // max layer
    span: u32,
    base: i32, // natural rail position (no stacking yet)
};

pub fn allocateBackEdgeRails(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const routing.NodeGeom,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]const BackEdgeRail {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    defer items.deinit(a);

    const horizontal = (graph.direction == .LR or graph.direction == .RL);

    for (graph.edges) |orig| {
        if (orig.from == orig.to) continue;
        if (!routing.isReversed(lg, orig.id)) continue;

        const src_geom_idx = nodeGeomIndex(lg, orig.from) orelse continue;
        const dst_geom_idx = nodeGeomIndex(lg, orig.to) orelse continue;
        // After applyDirection swaps axes for LR/RL, NodeGeom.layer is still the logical (pre-swap) layer, which is what "layers traversed" needs. // guarded-by: mirror_test.zig "mirror.applyDirection swaps x/y/w/h but leaves NodeGeom.layer untouched"
        const sl = geom[src_geom_idx].layer;
        const dl = geom[dst_geom_idx].layer;
        const lo = if (sl < dl) sl else dl;
        const hi = if (sl < dl) dl else sl;

        // Fallback base: max far-edge over every node in the spanned
        // layer range, padded out by RAIL_PAD. Used when an endpoint
        // placement can't be located.
        var max_extent: i32 = 0;
        for (placements) |p| {
            const pidx = nodeGeomIndex(lg, p.id) orelse continue;
            const player = geom[pidx].layer;
            if (player < lo or player > hi) continue;
            const ext: i32 = if (horizontal) p.rect.bottom() else p.rect.right();
            if (ext > max_extent) max_extent = ext;
        }
        const fallback_base = max_extent + RAIL_PAD;

        // Obstacle-aware base: parks the rail at the first clear cross position past the endpoints, byte-identical to fallback_base when unobstructed. guarded-by: lanes_test.zig "clearRunBase: vertical run parks just past endpoints when unobstructed"
        const base = lanes.clearRunBase(
            horizontal,
            placements,
            orig.from,
            orig.to,
            RAIL_PAD,
        ) orelse fallback_base;

        try items.append(a, .{
            .eid = orig.id,
            .from = orig.from,
            .to = orig.to,
            .lo = lo,
            .hi = hi,
            .span = hi - lo,
            .base = base,
        });
    }

    // Sort by span ascending: shortest back-edge claims the innermost lane first, biasing tightly-nested loops toward sharing. // guarded-by: back_edges_test.zig "allocateBackEdgeRails: span-ascending sort shares the innermost rail between disjoint short loops"
    const SortCtx = struct {
        pub fn lt(_: @This(), x: Item, y: Item) bool {
            return x.span < y.span;
        }
    };
    std.mem.sort(Item, items.items, SortCtx{}, SortCtx.lt);

    // Lane assignment: disjoint-span back-edges share a rail column; overlapping spans get distinct outer lanes. guarded-by: lanes_test.zig "assign: greedy 4-demand hand example with a tie"
    var demands = try a.alloc(lanes.Demand, items.items.len);
    defer a.free(demands);
    for (items.items, 0..) |it, i| {
        demands[i] = .{ .lo = it.lo, .hi = it.hi, .base = it.base };
    }

    var asg = try lanes.assign(a, demands, RAIL_STACK_GAP);
    defer asg.deinit(a);

    var rails = try a.alloc(BackEdgeRail, items.items.len);
    for (items.items, 0..) |it, i| {
        rails[i] = .{ .edge_id = it.eid, .rail_pos = asg.posOf(i) };
    }

    return rails;
}

pub fn backEdgePortFrom(dir: sg.Direction, p: sketch.NodePlacement) sketch.Port {
    return switch (dir) {
        .TD, .BT => .{ .node = p.id, .side = .east, .offset = @divTrunc(p.rect.h, 2) },
        .LR, .RL => .{ .node = p.id, .side = .south, .offset = @divTrunc(p.rect.w, 2) },
    };
}

pub fn backEdgePortTo(dir: sg.Direction, p: sketch.NodePlacement) sketch.Port {
    return switch (dir) {
        .TD, .BT => .{ .node = p.id, .side = .east, .offset = @divTrunc(p.rect.h, 2) },
        .LR, .RL => .{ .node = p.id, .side = .south, .offset = @divTrunc(p.rect.w, 2) },
    };
}

/// Build the U-shape polyline for one back edge. The rail leg is
/// obstacle-checked at allocation time (lanes.clearRunBase); each STUB
/// leg (endpoint mid-line out to the rail) also checks its straight run
/// with touch semantics (sketch.lineTouchesAny) and, when blocked, hops
/// one clear line sideways (toward the rail's far end first, via
/// sketch.clearLine/hopPos) to avoid slicing through a same-layer box.
///
/// Axis frame: TD/BT exit EAST (stub lines are rows, the rail is a
/// column); LR/RL exit SOUTH (stub lines are columns, the rail is a
/// row). `pt(along, line)` maps the axis-neutral pair back to a Point:
/// `along` runs along the stub (toward the rail), `line` is the stub's
/// cross position. The endpoints differ per axis by convention: TD/BT
/// ends one cell PAST the target's east border; LR/RL ends ON the south
/// border cell (the rasterizer skips it, landing the arrowhead on the
/// south-perimeter cell just below the box).
pub fn backEdgePolylineAt(
    a: std.mem.Allocator,
    dir: sg.Direction,
    src_p: sketch.NodePlacement,
    dst_p: sketch.NodePlacement,
    port_from: sketch.Port,
    port_to: sketch.Port,
    rail_pos: i32,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]sketch.Point {
    const sr = src_p.rect;
    const dr = dst_p.rect;
    const rows = (dir == .TD or dir == .BT); // stub lines are rows

    const src_line: i32 = if (rows) sr.y + @as(i32, @intCast(port_from.offset)) else sr.x + @as(i32, @intCast(port_from.offset));
    const dst_line: i32 = if (rows) dr.y + @as(i32, @intCast(port_to.offset)) else dr.x + @as(i32, @intCast(port_to.offset));
    const src_on: i32 = if (rows) sr.right() - 1 else sr.bottom() - 1; // ON the border cell
    const src_out: i32 = if (rows) sr.right() else sr.bottom(); // first cell outside
    const dst_out: i32 = if (rows) dr.right() else dr.bottom();
    const end_along: i32 = if (rows) dr.right() else dr.bottom() - 1;

    const pt = struct {
        fn f(r: bool, along: i32, line: i32) sketch.Point {
            return if (r) .{ .x = along, .y = line } else .{ .x = line, .y = along };
        }
    }.f;

    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(a, pt(rows, src_on, src_line));

    // Escape stub: source border -> rail, at the source's mid-line.
    var rail_start_line = src_line;
    if (sketch.lineTouchesAny(rows, src_line, src_out, rail_pos, placements, src_p.id, dst_p.id)) {
        const esc = sketch.clearLine(rows, src_line, src_out, rail_pos, placements, src_p.id, dst_p.id, .{ .toward = dst_line });
        if (esc != src_line) {
            if (sketch.hopPos(rows, src_line, src_out, @min(src_line, esc), @max(src_line, esc), placements, src_p.id, dst_p.id)) |hop| {
                try poly.append(a, pt(rows, hop, src_line));
                try poly.append(a, pt(rows, hop, esc));
                rail_start_line = esc;
            }
        }
    }
    try poly.append(a, pt(rows, rail_pos, rail_start_line));

    // Entry stub: rail -> target border, at the target's mid-line.
    if (sketch.lineTouchesAny(rows, dst_line, dst_out, rail_pos, placements, src_p.id, dst_p.id)) {
        const ent = sketch.clearLine(rows, dst_line, dst_out, rail_pos, placements, src_p.id, dst_p.id, .{ .toward = src_line });
        if (ent != dst_line) {
            if (sketch.hopPos(rows, dst_line, dst_out, @min(dst_line, ent), @max(dst_line, ent), placements, src_p.id, dst_p.id)) |hop| {
                try poly.append(a, pt(rows, rail_pos, ent));
                try poly.append(a, pt(rows, hop, ent));
                try poly.append(a, pt(rows, hop, dst_line));
                try poly.append(a, pt(rows, end_along, dst_line));
                return try poly.toOwnedSlice(a);
            }
        }
    }
    try poly.append(a, pt(rows, rail_pos, dst_line));
    try poly.append(a, pt(rows, end_along, dst_line));

    return try poly.toOwnedSlice(a);
}

pub fn backEdgePolyline(
    a: std.mem.Allocator,
    dir: sg.Direction,
    src_p: sketch.NodePlacement,
    dst_p: sketch.NodePlacement,
    rail_pos: i32,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]sketch.Point {
    return backEdgePolylineAt(a, dir, src_p, dst_p, backEdgePortFrom(dir, src_p), backEdgePortTo(dir, dst_p), rail_pos, placements);
}

test {
    _ = @import("back_edges_test.zig");
}

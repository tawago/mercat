const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const lanes = @import("lanes.zig");

pub const BackEdgeRail = struct {
    edge_id: sg.EdgeId,
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
    lo: u32,
    hi: u32,
    span: u32,
    base: i32,
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
        // @guarded-by: mirror_test.zig "mirror.applyDirection swaps x/y/w/h but leaves NodeGeom.layer untouched"
        const sl = geom[src_geom_idx].layer;
        const dl = geom[dst_geom_idx].layer;
        const lo = if (sl < dl) sl else dl;
        const hi = if (sl < dl) dl else sl;

        var max_extent: i32 = 0;
        for (placements) |p| {
            const pidx = nodeGeomIndex(lg, p.id) orelse continue;
            const player = geom[pidx].layer;
            if (player < lo or player > hi) continue;
            const ext: i32 = if (horizontal) p.rect.bottom() else p.rect.right();
            if (ext > max_extent) max_extent = ext;
        }
        const fallback_base = max_extent + RAIL_PAD;

        // @guarded-by: lanes_test.zig "clearRunBase: vertical run parks just past endpoints when unobstructed"
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

    // @guarded-by: back_edges_test.zig "allocateBackEdgeRails: span-ascending sort shares the innermost rail between disjoint short loops"
    const SortCtx = struct {
        pub fn lt(_: @This(), x: Item, y: Item) bool {
            return x.span < y.span;
        }
    };
    std.mem.sort(Item, items.items, SortCtx{}, SortCtx.lt);

    // @guarded-by: lanes_test.zig "assign: greedy 4-claim hand example with a tie"
    var demands = try a.alloc(lanes.LaneClaim, items.items.len);
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
    const rows = (dir == .TD or dir == .BT);

    const src_line: i32 = if (rows) sr.y + @as(i32, @intCast(port_from.offset)) else sr.x + @as(i32, @intCast(port_from.offset));
    const dst_line: i32 = if (rows) dr.y + @as(i32, @intCast(port_to.offset)) else dr.x + @as(i32, @intCast(port_to.offset));
    const src_on: i32 = if (rows) sr.right() - 1 else sr.bottom() - 1;
    const src_out: i32 = if (rows) sr.right() else sr.bottom();
    const dst_out: i32 = if (rows) dr.right() else dr.bottom();
    const end_along: i32 = if (rows) dr.right() else dr.bottom() - 1;

    const pt = struct {
        fn f(r: bool, along: i32, line: i32) sketch.Point {
            return if (r) .{ .x = along, .y = line } else .{ .x = line, .y = along };
        }
    }.f;

    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(a, pt(rows, src_on, src_line));

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

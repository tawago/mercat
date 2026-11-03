const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sketch_clearance = @import("../sketch_clearance.zig");
const sugiyama = @import("sugiyama.zig");
const node_geom = @import("node_geom.zig");
const rt = @import("routing_terminal.zig");
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
    geom: []const node_geom.NodeGeom,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]const BackEdgeRail {
    const lower = try allocateTrack(a, graph, lg, geom, placements, false);
    if (lg.upper_back_edges.len == 0) return lower;
    const upper = try allocateTrack(a, graph, lg, geom, try mirrorPlacements(a, graph.direction, placements), true);
    defer a.free(lower);
    defer a.free(upper);
    return std.mem.concat(a, BackEdgeRail, &.{ lower, upper });
}

fn allocateTrack(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const node_geom.NodeGeom,
    placements: []const sketch.NodePlacement,
    upper: bool,
) error{OutOfMemory}![]const BackEdgeRail {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    defer items.deinit(a);

    const horizontal = (graph.direction == .LR or graph.direction == .RL);

    for (graph.edges) |orig| {
        if (orig.from == orig.to) continue;
        if (!rt.isReversed(lg, orig.id)) continue;
        if (isUpper(lg, orig.id) != upper) continue;

        const src_geom_idx = nodeGeomIndex(lg, orig.from) orelse continue;
        const dst_geom_idx = nodeGeomIndex(lg, orig.to) orelse continue;
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

    const SortCtx = struct {
        pub fn lt(_: @This(), x: Item, y: Item) bool {
            return x.span < y.span;
        }
    };
    std.mem.sort(Item, items.items, SortCtx{}, SortCtx.lt);

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

pub fn isUpper(lg: sugiyama.LayeredGraph, eid: sg.EdgeId) bool {
    return std.mem.indexOfScalar(sg.EdgeId, lg.upper_back_edges, eid) != null;
}

pub fn splitTracks(a: std.mem.Allocator, graph: sg.SemGraph, lg: sugiyama.LayeredGraph) error{OutOfMemory}![]const sg.EdgeId {
    const layer_of = try a.alloc(u32, lg.nodes.len);
    defer a.free(layer_of);
    for (lg.layers, 0..) |row, li| for (row) |v| {
        layer_of[v] = @intCast(li);
    };
    var upper: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    const seen = try a.alloc(u32, lg.layers.len);
    defer a.free(seen);
    @memset(seen, 0);
    for (graph.edges) |e| {
        if (e.from == e.to or !rt.isReversed(lg, e.id)) continue;
        const v = lg.real_index.get(e.from) orelse continue;
        const li = layer_of[v];
        if (seen[li] % 2 == 0 and sharesLayer(graph, lg, layer_of, e.id, li)) try upper.append(a, e.id);
        seen[li] += 1;
    }
    return upper.toOwnedSlice(a);
}

fn sharesLayer(graph: sg.SemGraph, lg: sugiyama.LayeredGraph, layer_of: []const u32, eid: sg.EdgeId, li: u32) bool {
    for (graph.edges) |e| {
        if (e.id == eid or e.from == e.to or !rt.isReversed(lg, e.id)) continue;
        const v = lg.real_index.get(e.from) orelse continue;
        if (layer_of[v] == li) return true;
    }
    return false;
}

pub fn backEdgePortFrom(dir: sg.Direction, p: sketch.NodePlacement, upper: bool) sketch.Port {
    return switch (dir) {
        .TD, .BT => .{ .node = p.id, .side = if (upper) .west else .east, .offset = @divTrunc(p.rect.h, 2) },
        .LR, .RL => .{ .node = p.id, .side = if (upper) .north else .south, .offset = @divTrunc(p.rect.w, 2) },
    };
}

pub fn backEdgePortTo(dir: sg.Direction, p: sketch.NodePlacement, upper: bool) sketch.Port {
    return backEdgePortFrom(dir, p, upper);
}

fn mirrorRect(dir: sg.Direction, r: sketch.Rect) sketch.Rect {
    var out = r;
    switch (dir) {
        .TD, .BT => out.x = -(r.x + @as(i32, @intCast(r.w))),
        .LR, .RL => out.y = -(r.y + @as(i32, @intCast(r.h))),
    }
    return out;
}

fn mirrorPoint(dir: sg.Direction, p: sketch.Point) sketch.Point {
    return switch (dir) {
        .TD, .BT => .{ .x = -p.x - 1, .y = p.y },
        .LR, .RL => .{ .x = p.x, .y = -p.y - 1 },
    };
}

fn mirrorPlacement(dir: sg.Direction, p: sketch.NodePlacement) sketch.NodePlacement {
    var out = p;
    out.rect = mirrorRect(dir, p.rect);
    return out;
}

fn mirrorPlacements(a: std.mem.Allocator, dir: sg.Direction, placements: []const sketch.NodePlacement) error{OutOfMemory}![]const sketch.NodePlacement {
    const out = try a.alloc(sketch.NodePlacement, placements.len);
    for (placements, out) |p, *m| m.* = mirrorPlacement(dir, p);
    return out;
}

fn lowerSide(port: sketch.Port) sketch.Port {
    var out = port;
    out.side = switch (port.side) {
        .north => .south,
        .west => .east,
        else => port.side,
    };
    return out;
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
    upper: bool,
) error{OutOfMemory}![]sketch.Point {
    if (!upper) return lowerPolyline(a, dir, src_p, dst_p, port_from, port_to, rail_pos, placements);
    const poly = try lowerPolyline(a, dir, mirrorPlacement(dir, src_p), mirrorPlacement(dir, dst_p), lowerSide(port_from), lowerSide(port_to), rail_pos, try mirrorPlacements(a, dir, placements));
    for (poly) |*pt| pt.* = mirrorPoint(dir, pt.*);
    return poly;
}

fn lowerPolyline(
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
    if (sketch_clearance.lineTouchesAny(rows, src_line, src_out, rail_pos, placements, src_p.id, dst_p.id)) {
        const esc = sketch_clearance.clearLine(rows, src_line, src_out, rail_pos, placements, src_p.id, dst_p.id, .{ .toward = dst_line });
        if (esc != src_line) {
            if (sketch_clearance.hopPos(rows, src_line, src_out, @min(src_line, esc), @max(src_line, esc), placements, src_p.id, dst_p.id)) |hop| {
                try poly.append(a, pt(rows, hop, src_line));
                try poly.append(a, pt(rows, hop, esc));
                rail_start_line = esc;
            }
        }
    }
    try poly.append(a, pt(rows, rail_pos, rail_start_line));

    if (sketch_clearance.lineTouchesAny(rows, dst_line, dst_out, rail_pos, placements, src_p.id, dst_p.id)) {
        const ent = sketch_clearance.clearLine(rows, dst_line, dst_out, rail_pos, placements, src_p.id, dst_p.id, .{ .toward = src_line });
        if (ent != dst_line) {
            if (sketch_clearance.hopPos(rows, dst_line, dst_out, @min(dst_line, ent), @max(dst_line, ent), placements, src_p.id, dst_p.id)) |hop| {
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
    upper: bool,
) error{OutOfMemory}![]sketch.Point {
    return backEdgePolylineAt(a, dir, src_p, dst_p, backEdgePortFrom(dir, src_p, upper), backEdgePortTo(dir, dst_p, upper), rail_pos, placements, upper);
}

test {
    _ = @import("back_edges_test.zig");
}

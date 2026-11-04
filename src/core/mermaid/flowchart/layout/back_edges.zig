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

    var members: std.ArrayListUnmanaged(BackEdgeRail) = .empty;
    defer members.deinit(a);
    var k: usize = 0;
    while (k < items.items.len) {
        const it = items.items[k];
        const leader = groupLeader(graph, lg, it.eid) orelse {
            k += 1;
            continue;
        };
        if (leader == it.eid) {
            k += 1;
            continue;
        }
        for (items.items) |*l| if (l.eid == leader) {
            l.lo = @min(l.lo, it.lo);
            l.hi = @max(l.hi, it.hi);
            l.span = l.hi - l.lo;
            l.base = @max(l.base, it.base);
        };
        try members.append(a, .{ .edge_id = it.eid, .rail_pos = @intCast(leader) });
        _ = items.orderedRemove(k);
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

    var rails = try a.alloc(BackEdgeRail, items.items.len + members.items.len);
    for (items.items, 0..) |it, i| {
        rails[i] = .{ .edge_id = it.eid, .rail_pos = asg.posOf(i) };
    }
    for (members.items, items.items.len..) |m, i| {
        rails[i] = .{ .edge_id = m.edge_id, .rail_pos = findRail(rails[0..items.items.len], @intCast(m.rail_pos)) };
    }

    return rails;
}

pub fn groupLeader(graph: sg.SemGraph, lg: sugiyama.LayeredGraph, eid: sg.EdgeId) ?sg.EdgeId {
    const e = graph.edgeById(eid) orelse return null;
    if (!groupable(lg, e)) return null;
    const upper = isUpper(lg, eid);
    var leader: ?sg.Edge = null;
    var count: u32 = 0;
    for (graph.edges) |f| {
        if (f.from != e.from or !groupable(lg, f) or isUpper(lg, f.id) != upper or f.kind != e.kind) continue;
        for (graph.edges) |g| {
            if (g.id != f.id and g.from == e.from and g.to == f.to and groupable(lg, g) and isUpper(lg, g.id) == upper and g.kind == e.kind) return null;
        }
        count += 1;
        if (leader == null or nearer(graph, lg, f, leader.?)) leader = f;
    }
    if (count < 2) return null;
    return leader.?.id;
}

fn groupable(lg: sugiyama.LayeredGraph, e: sg.Edge) bool {
    return e.from != e.to and e.kind != .invisible and rt.isReversed(lg, e.id) and e.arrow_from == .none and e.arrow_to != .none;
}

fn nearer(graph: sg.SemGraph, lg: sugiyama.LayeredGraph, x: sg.Edge, y: sg.Edge) bool {
    const lx = layerOf(lg, x.to);
    const ly = layerOf(lg, y.to);
    if (lx != ly) return lx > ly;
    const nx = if (graph.nodeById(x.to)) |n| n.raw_id else "";
    const ny = if (graph.nodeById(y.to)) |n| n.raw_id else "";
    return std.mem.order(u8, nx, ny) == .lt;
}

fn layerOf(lg: sugiyama.LayeredGraph, id: sg.NodeId) u32 {
    const v = lg.real_index.get(id) orelse return 0;
    for (lg.layers, 0..) |row, li| for (row) |w| {
        if (w == v) return @intCast(li);
    };
    return 0;
}

pub fn isUpper(lg: sugiyama.LayeredGraph, eid: sg.EdgeId) bool {
    return std.mem.indexOfScalar(sg.EdgeId, lg.upper_back_edges, eid) != null;
}

pub fn splitTracks(a: std.mem.Allocator, graph: sg.SemGraph, lg: sugiyama.LayeredGraph, zigzag: bool) error{OutOfMemory}![]const sg.EdgeId {
    const layer_of = try a.alloc(u32, lg.nodes.len);
    defer a.free(layer_of);
    for (lg.layers, 0..) |row, li| for (row) |v| {
        layer_of[v] = @intCast(li);
    };
    var items: std.ArrayListUnmanaged(TrackItem) = .empty;
    defer items.deinit(a);
    for (graph.edges) |e| {
        if (e.from == e.to or !rt.isReversed(lg, e.id)) continue;
        const v = lg.real_index.get(e.from) orelse continue;
        const w = lg.real_index.get(e.to) orelse continue;
        const from = graph.nodeById(e.from) orelse continue;
        const to = graph.nodeById(e.to) orelse continue;
        try items.append(a, .{
            .edge = e.id,
            .layer = layer_of[v],
            .span = if (layer_of[v] > layer_of[w]) layer_of[v] - layer_of[w] else layer_of[w] - layer_of[v],
            .from = from.raw_id,
            .to = to.raw_id,
        });
    }
    std.mem.sort(TrackItem, items.items, {}, TrackItem.lessThan);
    var upper: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    var i: usize = 0;
    while (i < items.items.len) {
        var j = i + 1;
        while (j < items.items.len and items.items[j].layer == items.items[i].layer) j += 1;
        const n = j - i;
        if (n >= 2) for (items.items[i..j], 0..) |it, k| {
            if (if (zigzag) k % 2 == 0 else k < (n + 1) / 2) try upper.append(a, it.edge);
        };
        i = j;
    }
    return upper.toOwnedSlice(a);
}

const TrackItem = struct {
    edge: sg.EdgeId,
    layer: u32,
    span: u32,
    from: []const u8,
    to: []const u8,

    fn lessThan(_: void, x: TrackItem, y: TrackItem) bool {
        if (x.layer != y.layer) return x.layer < y.layer;
        if (x.span != y.span) return x.span < y.span;
        switch (std.mem.order(u8, x.from, y.from)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        switch (std.mem.order(u8, x.to, y.to)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        return x.edge < y.edge;
    }
};

pub fn backEdgePortFrom(dir: sg.Direction, p: sketch.NodePlacement, upper: bool) sketch.Port {
    return switch (dir) {
        .TD, .BT => .{ .node = p.id, .side = if (upper) .west else .east, .offset = @divTrunc(p.rect.h, 2) },
        .LR, .RL => .{ .node = p.id, .side = if (upper) .north else .south, .offset = @divTrunc(p.rect.w, 2) },
    };
}

pub fn backEdgePortTo(dir: sg.Direction, p: sketch.NodePlacement, upper: bool) sketch.Port {
    return backEdgePortFrom(dir, p, upper);
}

pub const EndPorts = struct {
    edge: sg.EdgeId,
    from: sketch.Port,
    to: sketch.Port,
};

const FaceEnd = struct {
    edge: sg.EdgeId,
    node: sg.NodeId,
    upper: bool,
    is_from: bool,
    other: i32,
    toward_low: bool,
    depth: i32,
    other_name: []const u8,

    fn lessThan(_: void, x: FaceEnd, y: FaceEnd) bool {
        if (x.node != y.node) return x.node < y.node;
        if (x.upper != y.upper) return !x.upper;
        if (x.toward_low != y.toward_low) return x.toward_low;
        if (x.other != y.other) return x.other > y.other;
        if (x.depth != y.depth) return if (x.toward_low) x.depth < y.depth else x.depth > y.depth;
        switch (std.mem.order(u8, x.other_name, y.other_name)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (x.is_from != y.is_from) return x.is_from;
        if (x.edge != y.edge) return x.edge < y.edge;
        return false;
    }
};

fn faceCenter(dir: sg.Direction, r: sketch.Rect) i32 {
    return switch (dir) {
        .TD, .BT => r.y + @divTrunc(@as(i32, @intCast(r.h)), 2),
        .LR, .RL => r.x + @divTrunc(@as(i32, @intCast(r.w)), 2),
    };
}

fn faceLength(dir: sg.Direction, r: sketch.Rect) i32 {
    return @intCast(switch (dir) {
        .TD, .BT => r.h,
        .LR, .RL => r.w,
    });
}

fn railDepth(dir: sg.Direction, p: sketch.NodePlacement, rail_pos: i32, upper: bool) i32 {
    const r = if (upper) mirrorRect(dir, p.rect) else p.rect;
    const face = switch (dir) {
        .TD, .BT => r.x + @as(i32, @intCast(r.w)),
        .LR, .RL => r.y + @as(i32, @intCast(r.h)),
    };
    return rail_pos - face;
}

pub fn spreadPorts(
    a: std.mem.Allocator,
    dir: sg.Direction,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    placements: []const sketch.NodePlacement,
    rails: []const BackEdgeRail,
) error{OutOfMemory}![]const EndPorts {
    var ends: std.ArrayListUnmanaged(FaceEnd) = .empty;
    defer ends.deinit(a);
    var out: std.ArrayListUnmanaged(EndPorts) = .empty;
    for (graph.edges) |e| {
        if (e.from == e.to or !rt.isReversed(lg, e.id)) continue;
        const sp = findPlacementIn(placements, e.from) orelse continue;
        const dp = findPlacementIn(placements, e.to) orelse continue;
        const upper = isUpper(lg, e.id);
        const rail = findRail(rails, e.id);
        const sc = faceCenter(dir, sp.rect);
        const dc = faceCenter(dir, dp.rect);
        const leader = groupLeader(graph, lg, e.id);
        if (leader == null or leader.? == e.id) try ends.append(a, .{ .edge = e.id, .node = e.from, .upper = upper, .is_from = true, .other = dc, .toward_low = dc < sc, .depth = railDepth(dir, sp, rail, upper), .other_name = if (graph.nodeById(e.to)) |n| n.raw_id else "" });
        try ends.append(a, .{ .edge = e.id, .node = e.to, .upper = upper, .is_from = false, .other = sc, .toward_low = sc < dc, .depth = railDepth(dir, dp, rail, upper), .other_name = if (graph.nodeById(e.from)) |n| n.raw_id else "" });
        try out.append(a, .{ .edge = e.id, .from = backEdgePortFrom(dir, sp, upper), .to = backEdgePortTo(dir, dp, upper) });
    }
    std.mem.sort(FaceEnd, ends.items, {}, FaceEnd.lessThan);
    var i: usize = 0;
    while (i < ends.items.len) {
        var j = i + 1;
        while (j < ends.items.len and ends.items[j].node == ends.items[i].node and ends.items[j].upper == ends.items[i].upper) j += 1;
        const p = findPlacementIn(placements, ends.items[i].node).?;
        const len = faceLength(dir, p.rect);
        const k: i32 = @intCast(j - i);
        for (ends.items[i..j], 0..) |end, n| {
            const offset: u32 = @intCast(1 + @divTrunc((2 * @as(i32, @intCast(n)) + 1) * (len - 2), 2 * k));
            for (out.items) |*ep| if (ep.edge == end.edge) {
                if (end.is_from) ep.from.offset = offset else ep.to.offset = offset;
            };
        }
        i = j;
    }
    for (out.items) |*ep| {
        const leader = groupLeader(graph, lg, ep.edge) orelse continue;
        if (leader == ep.edge) continue;
        if (endPortsOf(out.items, leader)) |l| ep.from = l.from;
    }
    return out.toOwnedSlice(a);
}

pub fn applyEndDemand(a: std.mem.Allocator, graph: sg.SemGraph, lg: sugiyama.LayeredGraph, geom: []node_geom.NodeGeom) error{OutOfMemory}!void {
    const lower = try a.alloc(u32, geom.len);
    defer a.free(lower);
    const upper = try a.alloc(u32, geom.len);
    defer a.free(upper);
    @memset(lower, 0);
    @memset(upper, 0);
    for (graph.edges) |e| {
        if (e.from == e.to or !rt.isReversed(lg, e.id)) continue;
        const counts = if (isUpper(lg, e.id)) upper else lower;
        const leader = groupLeader(graph, lg, e.id);
        if (leader == null or leader.? == e.id) if (lg.real_index.get(e.from)) |v| {
            counts[v] += 1;
        };
        if (lg.real_index.get(e.to)) |v| counts[v] += 1;
    }
    for (geom, lower, upper) |*g, lo, up| {
        const need = @max(lo, up) + 2;
        if (@max(lo, up) >= 2 and g.h < need) g.h = need;
    }
}

pub fn selfLoopFlips(graph: sg.SemGraph, lg: sugiyama.LayeredGraph, node: sg.NodeId) bool {
    var lower: u32 = 0;
    var upper: u32 = 0;
    for (graph.edges) |e| {
        if (e.from == e.to or !rt.isReversed(lg, e.id)) continue;
        if (e.from != node and e.to != node) continue;
        if (isUpper(lg, e.id)) upper += 1 else lower += 1;
    }
    return lower > 0 and upper == 0;
}

pub fn endPortsOf(ports: []const EndPorts, eid: sg.EdgeId) ?EndPorts {
    for (ports) |p| if (p.edge == eid) return p;
    return null;
}

fn findPlacementIn(placements: []const sketch.NodePlacement, id: sg.NodeId) ?sketch.NodePlacement {
    for (placements) |p| if (p.id == id) return p;
    return null;
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

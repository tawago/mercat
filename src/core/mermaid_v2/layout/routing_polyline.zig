const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const route_clearance = @import("route_clearance.zig");

pub fn insetPort(pt: sketch.Point, side: sketch.Dir4, pad: i32) sketch.Point {
    if (pad == 0) return pt;
    return switch (side) {
        .north => .{ .x = pt.x, .y = pt.y - pad },
        .south => .{ .x = pt.x, .y = pt.y + pad },
        .west => .{ .x = pt.x - pad, .y = pt.y },
        .east => .{ .x = pt.x + pad, .y = pt.y },
    };
}

pub const Straight = struct {
    from: bool = false,
    to: bool = false,

    pub fn forEdge(edge: sg.Edge) Straight {
        return .{ .from = edge.arrow_from != .none, .to = edge.arrow_to != .none };
    }
};

pub const Lanes = struct {
    entry: u32 = 0,
    exit: u32 = 0,
};

pub fn absDiff(x: i32, y: i32) i32 {
    return if (x > y) x - y else y - x;
}

pub fn portPoint(p: sketch.NodePlacement, port: sketch.Port) sketch.Point {
    return switch (port.side) {
        .north => .{ .x = p.rect.x + @as(i32, @intCast(port.offset)), .y = p.rect.y },
        .south => .{ .x = p.rect.x + @as(i32, @intCast(port.offset)), .y = p.rect.bottom() - 1 },
        .west => .{ .x = p.rect.x, .y = p.rect.y + @as(i32, @intCast(port.offset)) },
        .east => .{ .x = p.rect.right() - 1, .y = p.rect.y + @as(i32, @intCast(port.offset)) },
    };
}

fn oppositeSide(side: sketch.Dir4) sketch.Dir4 {
    return switch (side) {
        .north => .south,
        .south => .north,
        .east => .west,
        .west => .east,
    };
}

/// @guarded-by: routing_polyline_test.zig "final approach reconciles a below-approach opposite-side port to the entry-side terminal"
pub fn reconcileTerminalSide(
    poly: []sketch.Point,
    to_p: sketch.NodePlacement,
    port_to: sketch.Port,
) sketch.Port {
    if (poly.len < 2) return port_to;
    const end = poly[poly.len - 1];
    const prev = poly[poly.len - 2];
    if (prev.x == end.x and prev.y == end.y) return port_to;
    const entry_side: sketch.Dir4 = if (prev.x == end.x)
        (if (prev.y < end.y) .north else .south)
    else if (prev.y == end.y)
        (if (prev.x < end.x) .west else .east)
    else
        return port_to;
    if (oppositeSide(entry_side) != port_to.side) return port_to;
    const r = to_p.rect;
    const intrudes = switch (entry_side) {
        .north => prev.y < r.y,
        .south => prev.y > r.bottom() - 1,
        .west => prev.x < r.x,
        .east => prev.x > r.right() - 1,
    };
    if (!intrudes) return port_to;
    const flipped: sketch.Port = .{ .node = port_to.node, .side = entry_side, .offset = port_to.offset };
    poly[poly.len - 1] = portPoint(to_p, flipped);
    return flipped;
}

pub const CornerFed = struct { bi: usize, b: sketch.Point, p: sketch.Point, lx: i32, ly: i32 };

pub fn detectCornerFedTerminal(poly: []const sketch.Point) ?CornerFed {
    if (poly.len < 3) return null;
    const c = poly[poly.len - 1];
    var bi: usize = poly.len - 2;
    while (bi > 0 and poly[bi].x == c.x and poly[bi].y == c.y) : (bi -= 1) {}
    if (bi == 0) return null;
    const b = poly[bi];
    const p = poly[bi - 1];
    const lx = c.x - b.x;
    const ly = c.y - b.y;
    const dx = b.x - p.x;
    const dy = b.y - p.y;
    if (dx != 0 and dy != 0) return null;
    if (dx == 0 and dy == 0) return null;
    const perpendicular = (lx != 0 and dx == 0) or (ly != 0 and dy == 0);
    if (!perpendicular) return null;
    return .{ .bi = bi, .b = b, .p = p, .lx = lx, .ly = ly };
}

/// @guarded-by: routing_polyline_test.zig "ensureBaseStub shifts a turn-at-tip descent back one cell"
pub fn ensureBaseStub(
    poly: []sketch.Point,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
) bool {
    const fed = detectCornerFedTerminal(poly) orelse return false;
    const bi = fed.bi;
    const b = fed.b;
    const p = fed.p;
    const lx = fed.lx;
    const ly = fed.ly;
    if (@as(i32, @intCast(@abs(lx))) + @as(i32, @intCast(@abs(ly))) != 1) return false;
    const nb = sketch.Point{ .x = b.x - lx, .y = b.y - ly };
    const np = sketch.Point{ .x = p.x - lx, .y = p.y - ly };
    const descent_horizontal = (np.y == nb.y);
    const cross: i32 = if (descent_horizontal) np.y else np.x;
    const lo: i32 = if (descent_horizontal) @min(np.x, nb.x) else @min(np.y, nb.y);
    const hi: i32 = if (descent_horizontal) @max(np.x, nb.x) else @max(np.y, nb.y);
    if (sketch.lineTouchesAny(descent_horizontal, cross, lo, hi, placements, from_id, to_id)) return false;
    poly[bi] = nb;
    poly[bi - 1] = np;
    return true;
}

// @guarded-by: validate_test.zig "edge through node interior flagged"

pub fn columnIntrudesRect(x: i32, y_top: i32, y_bot: i32, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    const left = r.x;
    const right_inc = r.right() - 1;
    const top = r.y;
    const bottom_inc = r.bottom() - 1;
    if (x <= left or x >= right_inc) return false;
    return y_top < bottom_inc and y_bot > top;
}

pub fn rowIntrudesRect(y: i32, x_left: i32, x_right: i32, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    const top = r.y;
    const bottom_inc = r.bottom() - 1;
    const left = r.x;
    const right_inc = r.right() - 1;
    if (y <= top or y >= bottom_inc) return false;
    return x_left < right_inc and x_right > left;
}

/// @guarded-by: routing_polyline_test.zig "a one-layer route runs the corridor beside a box in its way instead of through it"
pub fn routePolyline(
    a: std.mem.Allocator,
    dir: sg.Direction,
    from_p: sketch.NodePlacement,
    to_p: sketch.NodePlacement,
    port_from: sketch.Port,
    port_to: sketch.Port,
    virtuals: []const u32,
    geom: anytype,
    placements: []const sketch.NodePlacement,
    inset_from: i32,
    inset_to: i32,
    lanes: Lanes,
    straight: Straight,
) error{OutOfMemory}![]sketch.Point {
    const raw_start = portPoint(from_p, port_from);
    const raw_end = portPoint(to_p, port_to);
    const start = insetPort(raw_start, port_from.side, inset_from);
    const end = insetPort(raw_end, port_to.side, inset_to);
    const horizontal = (dir == .LR or dir == .RL);
    const route_lane = lanes.exit;

    // @guarded-by: validate_test.zig "edge through node interior flagged"
    // @guarded-by: raster/edges_test.zig "edge cells colliding with node-owned cells are counted as lost"
    if (virtuals.len > 0) {
        const first = geom[virtuals[0]];
        if (!horizontal) {
            const want_x = first.x + @divTrunc(@as(i32, @intCast(first.w)), 2);
            return corridorRoute(a, false, start, end, want_x, first.y, lanes, straight, placements, from_p.id, to_p.id);
        }
        if (end.x > start.x) {
            const want_y = first.y + @divTrunc(@as(i32, @intCast(first.h)), 2);
            return corridorRoute(a, true, start, end, want_y, first.x, lanes, straight, placements, from_p.id, to_p.id);
        }
    }

    const plain = try plainRoute(a, horizontal, start, end, virtuals, geom, port_to.side, route_lane, straight);
    if (virtuals.len == 0) {
        if (obstacleBox(plain, placements, from_p.id, to_p.id)) |box| {
            if (!horizontal) return corridorRoute(a, false, start, end, end.x, box.y, lanes, straight, placements, from_p.id, to_p.id);
            if (end.x > start.x) return corridorRoute(a, true, start, end, end.y, box.x, lanes, straight, placements, from_p.id, to_p.id);
        }
    }
    return plain;
}

fn obstacleBox(poly: []const sketch.Point, placements: []const sketch.NodePlacement, from: sketch.NodeId, to: sketch.NodeId) ?sketch.Rect {
    for (placements) |p| {
        if (p.id == from or p.id == to) continue;
        const one = [_]sketch.NodePlacement{p};
        if (route_clearance.touchesForeignNode(poly, &one, from, to)) return p.rect;
    }
    return null;
}

fn corridorRoute(
    a: std.mem.Allocator,
    horizontal: bool,
    start: sketch.Point,
    end: sketch.Point,
    want: i32,
    top: i32,
    lanes: Lanes,
    straight: Straight,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
) error{OutOfMemory}![]sketch.Point {
    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(a, start);
    const lane: i32 = @intCast(lanes.exit);
    const entry: i32 = @intCast(lanes.entry);
    if (!horizontal) {
        // @guarded-by: routing_polyline_test.zig "the skip corridor enters on its entry lane above the intermediate layer and climbs with it"
        const enter_floor = start.y + (if (straight.from) @as(i32, 2) else 1);
        const enter_gap_y = @max(top - 2 - entry, enter_floor);
        // @guarded-by: routing_polyline_test.zig "TD skip-corridor final descent is a clean vertical approach (guards ▼)"
        // @guarded-by: routing_polyline_test.zig "a skip corridor past its lane budget keeps a decorated arrival straight"
        const align_y = if (end.y - 2 - lane > enter_gap_y) end.y - 2 - lane else if (straight.to) @max(end.y - 2, enter_gap_y) else end.y - 1;

        // @guarded-by: validate_test.zig "edge through node interior flagged";
        const run_top = @min(enter_gap_y, align_y);
        const run_bot = @max(enter_gap_y, align_y);
        const corridor_x = sketch.clearLine(false, want, run_top, run_bot, placements, from_id, to_id, .{ .margin = true });

        if (enter_gap_y != start.y) try poly.append(a, .{ .x = start.x, .y = enter_gap_y });
        if (corridor_x != start.x) try poly.append(a, .{ .x = corridor_x, .y = enter_gap_y });
        if (align_y != enter_gap_y) try poly.append(a, .{ .x = corridor_x, .y = align_y });
        if (end.x != corridor_x) try poly.append(a, .{ .x = end.x, .y = align_y });
    } else {
        const enter_floor = start.x + (if (straight.from) @as(i32, 2) else 1);
        const enter_gap_x = @max(top - 2 - entry, enter_floor);
        // @guarded-by: routing_polyline_test.zig "LR skip-corridor final approach is a clean horizontal approach (guards ▶)"
        const align_x = if (end.x - 2 - lane > enter_gap_x) end.x - 2 - lane else if (straight.to) @max(end.x - 2, enter_gap_x) else end.x - 1;
        const run_lo = @min(enter_gap_x, align_x);
        const run_hi = @max(enter_gap_x, align_x);
        const corridor_y = sketch.clearLine(true, want, run_lo, run_hi, placements, from_id, to_id, .{ .margin = true });

        if (enter_gap_x != start.x) try poly.append(a, .{ .x = enter_gap_x, .y = start.y });
        if (corridor_y != start.y) try poly.append(a, .{ .x = enter_gap_x, .y = corridor_y });
        if (align_x != enter_gap_x) try poly.append(a, .{ .x = align_x, .y = corridor_y });
        if (end.y != corridor_y) try poly.append(a, .{ .x = align_x, .y = end.y });
    }
    try poly.append(a, end);
    if (poly.items.len < 2) try poly.append(a, end);
    return try poly.toOwnedSlice(a);
}

fn plainRoute(
    a: std.mem.Allocator,
    horizontal: bool,
    start: sketch.Point,
    end: sketch.Point,
    virtuals: []const u32,
    geom: anytype,
    to_side: sketch.Dir4,
    route_lane: u32,
    straight: Straight,
) error{OutOfMemory}![]sketch.Point {
    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(a, start);
    var prev = start;
    for (virtuals) |idx| {
        const g = geom[idx];
        const cx = g.x + @divTrunc(@as(i32, @intCast(g.w)), 2);
        const cy = g.y + @divTrunc(@as(i32, @intCast(g.h)), 2);
        if (horizontal) {
            if (cx != prev.x) try poly.append(a, .{ .x = cx, .y = prev.y });
            if (cy != prev.y) try poly.append(a, .{ .x = cx, .y = cy });
        } else {
            if (cy != prev.y) try poly.append(a, .{ .x = prev.x, .y = cy });
            if (cx != prev.x) try poly.append(a, .{ .x = cx, .y = cy });
        }
        prev = .{ .x = cx, .y = cy };
    }

    // @guarded-by: validate_test.zig "edge through node interior flagged"
    if (virtuals.len == 0) {
        if (horizontal) {
            // @guarded-by: routing_polyline_test.zig "west/east port jog pad is never zero, near or far (guards clean </>)"
            if (end.y != prev.y) {
                // @guarded-by: routing_polyline_test.zig "the jog never lands on the source wall (span-2 gap and lane escalation clamp)"
                const span_x = absDiff(end.x, prev.x);
                const want_x_pad: i32 = (if (span_x >= 2) @as(i32, 2) else 1) + @as(i32, @intCast(route_lane));
                const pad = jogPad(want_x_pad, span_x, straight);
                const jog = insetPort(end, to_side, pad);
                try poly.append(a, .{ .x = jog.x, .y = prev.y });
                try poly.append(a, .{ .x = jog.x, .y = end.y });
            }
        } else {
            // @guarded-by: routing_polyline_test.zig "north/south port jog pad is never zero, near or far (guards clean ^/v)"
            if (end.x != prev.x) {
                // @guarded-by: routing_polyline_test.zig "the jog never lands on the source wall (span-2 gap and lane escalation clamp)"
                const span_y = absDiff(end.y, prev.y);
                const want_y_pad: i32 = (if (span_y >= 2) @as(i32, 2) else 1) + @as(i32, @intCast(route_lane));
                const pad = jogPad(want_y_pad, span_y, straight);
                const jog = insetPort(end, to_side, pad);
                try poly.append(a, .{ .x = prev.x, .y = jog.y });
                try poly.append(a, .{ .x = end.x, .y = jog.y });
            }
        }
    } else if (horizontal) {
        if (end.x != prev.x) try poly.append(a, .{ .x = end.x, .y = prev.y });
    } else {
        if (end.y != prev.y) try poly.append(a, .{ .x = prev.x, .y = end.y });
    }
    try poly.append(a, end);
    if (poly.items.len < 2) try poly.append(a, end);
    return try poly.toOwnedSlice(a);
}

/// @guarded-by: routing_polyline_test.zig "the jog never lands inside a decorated terminal cell"
pub fn jogPad(want: i32, span: i32, straight: Straight) i32 {
    const lo: i32 = if (straight.to) 2 else 1;
    const hi: i32 = span - (if (straight.from) @as(i32, 2) else 1);
    if (lo > hi) return @max(@min(want, span - 1), 1);
    return @max(@min(want, hi), lo);
}

test {
    _ = @import("routing_polyline_test.zig");
}

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");

pub const SelfLoop = struct {
    polyline: []sketch.Point,
    port_from: sketch.Port,
    port_to: sketch.Port,
};

// @guarded-by: routing_self_loops_test.zig "self-loop detour offsets match OFF_H=4 (east overshoot) / OFF_V=3 (vertical rise/drop) across TD/BT/LR/RL"
const OFF_H: i32 = 4;
const OFF_V: i32 = 3;

pub fn selfLoop(
    a: std.mem.Allocator,
    dir: sg.Direction,
    node_p: sketch.NodePlacement,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}!SelfLoop {
    switch (dir) {
        .TD, .BT => {
            if (!topLoopBlocked(node_p, placements)) return try topLoop(a, node_p);
            if (try belowEastLoop(a, node_p, placements)) |sl| return sl;
            return try topLoop(a, node_p);
        },
        .LR, .RL => return try southLoop(a, node_p),
    }
}

const LIFT_REACH: i32 = 4;
const OVERSHOOT_REACH: i32 = OFF_H + 2;

/// @guarded-by: routing_test.zig "a self loop lifts past foreign ink instead of lying along it"
pub fn loopCandidate(
    a: std.mem.Allocator,
    dir: sg.Direction,
    node_p: sketch.NodePlacement,
    port_from: sketch.Port,
    port_to: sketch.Port,
    step: u32,
) error{OutOfMemory}!?SelfLoop {
    const r = node_p.rect;
    const k: i32 = @intCast(step);
    if (dir == .TD or dir == .BT) {
        const per_lift = OVERSHOOT_REACH;
        if (k >= per_lift * (LIFT_REACH + 2)) return null;
        const rung = @divTrunc(k, per_lift);
        const lift = if (rung <= LIFT_REACH) OFF_V + rung else OFF_V - 1;
        const overshoot = 1 + @rem(k, per_lift);
        if (r.y < lift) return null;
        const east_y = r.y + @as(i32, @intCast(port_from.offset));
        const north_x = r.x + @as(i32, @intCast(port_to.offset));
        const loop_x = r.right() - 1 + overshoot;
        const loop_y = r.y - lift;
        const poly = try a.alloc(sketch.Point, 5);
        @memcpy(poly, &[_]sketch.Point{
            .{ .x = r.right() - 1, .y = east_y }, .{ .x = loop_x, .y = east_y },
            .{ .x = loop_x, .y = loop_y },        .{ .x = north_x, .y = loop_y },
            .{ .x = north_x, .y = r.y },
        });
        return .{ .polyline = poly, .port_from = port_from, .port_to = port_to };
    }
    if (k > LIFT_REACH) return null;
    const exit_x = r.x + @as(i32, @intCast(port_from.offset));
    const enter_x = r.x + @as(i32, @intCast(port_to.offset));
    const south_y = r.bottom() - 1;
    const loop_y = south_y + OFF_V + k;
    const poly = try a.alloc(sketch.Point, 4);
    @memcpy(poly, &[_]sketch.Point{
        .{ .x = exit_x, .y = south_y }, .{ .x = exit_x, .y = loop_y },
        .{ .x = enter_x, .y = loop_y }, .{ .x = enter_x, .y = south_y },
    });
    return .{ .polyline = poly, .port_from = port_from, .port_to = port_to };
}

const TopGeom = struct { east_x: i32, east_y: i32, north_x: i32, north_y: i32, loop_x: i32, loop_y: i32 };

fn topLoopGeom(r: sketch.Rect) TopGeom {
    const w_i: i32 = @intCast(r.w);
    const h_i: i32 = @intCast(r.h);
    return .{
        .east_x = r.right() - 1,
        .east_y = r.y + @divTrunc(h_i, 2),
        .north_x = r.x + @divTrunc(w_i, 2),
        .north_y = r.y,
        .loop_x = r.right() - 1 + OFF_H,
        .loop_y = r.y - OFF_V,
    };
}

fn topLoop(a: std.mem.Allocator, node_p: sketch.NodePlacement) error{OutOfMemory}!SelfLoop {
    const r = node_p.rect;
    const g = topLoopGeom(r);
    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(a, .{ .x = g.east_x, .y = g.east_y });
    try poly.append(a, .{ .x = g.loop_x, .y = g.east_y });
    try poly.append(a, .{ .x = g.loop_x, .y = g.loop_y });
    try poly.append(a, .{ .x = g.north_x, .y = g.loop_y });
    try poly.append(a, .{ .x = g.north_x, .y = g.north_y });
    return .{
        .polyline = try poly.toOwnedSlice(a),
        .port_from = .{ .node = node_p.id, .side = .east, .offset = @divTrunc(r.h, 2) },
        .port_to = .{ .node = node_p.id, .side = .north, .offset = @divTrunc(r.w, 2) },
    };
}

fn topLoopBlocked(node_p: sketch.NodePlacement, placements: []const sketch.NodePlacement) bool {
    const g = topLoopGeom(node_p.rect);
    const id = node_p.id;
    if (sketch.rowTouchesAny(g.east_y, g.east_x + 1, g.loop_x, placements, id, id)) return true;
    if (sketch.columnTouchesAny(g.loop_x, g.loop_y, g.east_y, placements, id, id)) return true;
    if (sketch.rowTouchesAny(g.loop_y, g.north_x, g.loop_x, placements, id, id)) return true;
    if (sketch.columnTouchesAny(g.north_x, g.loop_y, g.north_y - 1, placements, id, id)) return true;
    return false;
}

fn belowEastLoop(
    a: std.mem.Allocator,
    node_p: sketch.NodePlacement,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}!?SelfLoop {
    const r = node_p.rect;
    const w_i: i32 = @intCast(r.w);
    const h_i: i32 = @intCast(r.h);
    const id = node_p.id;
    const k = selfLoopHalfGap(r.w);
    const exit_x = r.x + @divTrunc(w_i, 2) + k;
    const south_y = r.bottom() - 1;
    const east_x = r.right() - 1;
    const east_y = r.y + @divTrunc(h_i, 2);

    var gap_y = south_y + 1;
    while (gap_y <= south_y + 3) : (gap_y += 1) {
        // @guarded-by: routing_self_loops_test.zig "belowEastLoop's south descent blocking is monotonic: an obstacle at the nearest candidate gap row sinks the whole fallback (no deeper gap_y recovers)"
        if (sketch.columnTouchesAny(exit_x, south_y + 1, gap_y, placements, id, id)) return null;
        // @guarded-by: routing_self_loops_test.zig "belowEastLoop lands the east re-entry with a straight base cell (◀─┐)"
        var arm_x = east_x + 3;
        while (arm_x <= east_x + OFF_H + 3) : (arm_x += 1) {
            if (sketch.rowTouchesAny(gap_y, exit_x, arm_x, placements, id, id)) continue;
            if (sketch.columnTouchesAny(arm_x, east_y, gap_y, placements, id, id)) continue;
            if (sketch.rowTouchesAny(east_y, east_x + 1, arm_x, placements, id, id)) continue;

            var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
            try poly.append(a, .{ .x = exit_x, .y = south_y });
            try poly.append(a, .{ .x = exit_x, .y = gap_y });
            try poly.append(a, .{ .x = arm_x, .y = gap_y });
            try poly.append(a, .{ .x = arm_x, .y = east_y });
            try poly.append(a, .{ .x = east_x, .y = east_y });
            return .{
                .polyline = try poly.toOwnedSlice(a),
                .port_from = .{ .node = id, .side = .south, .offset = @intCast(exit_x - r.x) },
                .port_to = .{ .node = id, .side = .east, .offset = @divTrunc(r.h, 2) },
            };
        }
    }
    return null;
}

/// @guarded-by: routing_self_loops_test.zig "self-loop detour never crosses back into the source node's own interior, across sizes and directions"
fn southLoop(a: std.mem.Allocator, node_p: sketch.NodePlacement) error{OutOfMemory}!SelfLoop {
    const r = node_p.rect;
    const w_i: i32 = @intCast(r.w);
    const k = selfLoopHalfGap(r.w);
    const exit_x = r.x + @divTrunc(w_i, 2) - k;
    const enter_x = r.x + @divTrunc(w_i, 2) + k;
    const south_y = r.bottom() - 1;
    const loop_y = south_y + OFF_V;
    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(a, .{ .x = exit_x, .y = south_y });
    try poly.append(a, .{ .x = exit_x, .y = loop_y });
    try poly.append(a, .{ .x = enter_x, .y = loop_y });
    // @guarded-by: routing_self_loops_test.zig "southLoop's final segment rises north (dy<0), the geometry paint.zig's arrowGlyph maps to the up-arrow ▲"
    try poly.append(a, .{ .x = enter_x, .y = south_y });
    return .{
        .polyline = try poly.toOwnedSlice(a),
        .port_from = .{ .node = node_p.id, .side = .south, .offset = @intCast(exit_x - r.x) },
        .port_to = .{ .node = node_p.id, .side = .south, .offset = @intCast(enter_x - r.x) },
    };
}

pub fn selfLoopHalfGap(w: u32) i32 {
    const w_i: i32 = @intCast(w);
    const half = @divTrunc(w_i, 2);
    // @guarded-by: routing_self_loops_test.zig "selfLoopHalfGap keeps both south ports strictly inside [1, w-2] for every non-degenerate width"
    const max_k = @min(half - 1, w_i - 2 - half);
    if (max_k < 1) return 1;
    const want = @divTrunc(w_i, 4);
    return std.math.clamp(want, 1, max_k);
}

test {
    _ = @import("routing_self_loops_test.zig");
}

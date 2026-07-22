//! Self-loop "lollipop" detour geometry: builds a 4-corner orthogonal path
//! for `X --> X` edges (span=0 would collapse to a point), exiting one
//! perimeter side, looping outside the node, and re-entering another side.
//! TD/BT: the classic loop goes over the top; if a node sits above that
//! would block it, the loop goes below and re-enters east instead. Keyed
//! only on placed rects.
//! Imports: `std`, `../sem_graph.zig`, `../sketch.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");

/// A routed self-loop: polyline plus the two perimeter ports it uses.
/// Geometry and ports are decided together because the obstacle-aware
/// variant selection changes both.
pub const SelfLoop = struct {
    polyline: []sketch.Point,
    port_from: sketch.Port,
    port_to: sketch.Port,
};

// Detour offsets for the classic TD loop (corner+dash east, corner+verticals+arrowhead north). // guarded-by: routing_self_loops_test.zig "self-loop detour offsets match OFF_H=4 (east overshoot) / OFF_V=3 (vertical rise/drop) across TD/BT/LR/RL"
const OFF_H: i32 = 4;
const OFF_V: i32 = 3;

/// Build the self-loop for `X --> X`.
///
/// TD/BT: exit east-mid, loop over the top, enter north-mid — unless the
///   top loop would touch another box, in which case loop below the node
///   and re-enter east-mid (see module doc). If neither is clear, keep
///   the classic shape (status quo: the validator still reports it).
/// LR/RL: exit south-left, loop under the node, enter south-right
///   (both ports on south to stay clear of the east forward flow).
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

/// Port-allocated production entry. Singleton offsets reproduce `selfLoop`.
pub fn selfLoopAt(
    a: std.mem.Allocator,
    dir: sg.Direction,
    node_p: sketch.NodePlacement,
    placements: []const sketch.NodePlacement,
    port_from: sketch.Port,
    port_to: sketch.Port,
) error{OutOfMemory}!SelfLoop {
    const r = node_p.rect;
    if (dir == .TD or dir == .BT) {
        const east_y = r.y + @as(i32, @intCast(port_from.offset));
        const north_x = r.x + @as(i32, @intCast(port_to.offset));
        const east_x = r.right() - 1;
        // Base-side law: lift the top run OFF_V rows (matching the clean
        // `topLoop`) so the final descent carries a straight `│` before the
        // `▼`. But the taller loop can foul a neighbour in a dense layout, so
        // PREFER the lifted geometry and fall back to the tight (-1) shape when
        // no overshoot column clears the lifted arms — never fabricate an
        // adjacency to gain a base cell. Also clamps the lift away from a
        // canvas underflow (top < OFF_V rows). // guarded-by: routing_self_loops_test.zig "selfLoopAt TD lifts the top run OFF_V so the north re-entry has a straight base cell"
        const lifted_y = if (r.y >= OFF_V) r.y - OFF_V else r.y - 1;
        const loop_y, const loop_x = choose: {
            if (r.y >= OFF_V) {
                if (clearLoopX(node_p.id, east_x, east_y, north_x, lifted_y, r.y, placements)) |lx|
                    break :choose .{ lifted_y, lx };
            }
            const tight_y = r.y - 1;
            const tx = clearLoopX(node_p.id, east_x, east_y, north_x, tight_y, r.y, placements) orelse (east_x + OFF_H);
            break :choose .{ tight_y, tx };
        };
        const poly = try a.alloc(sketch.Point, 5);
        @memcpy(poly, &[_]sketch.Point{
            .{ .x = r.right() - 1, .y = east_y }, .{ .x = loop_x, .y = east_y },
            .{ .x = loop_x, .y = loop_y },        .{ .x = north_x, .y = loop_y },
            .{ .x = north_x, .y = r.y },
        });
        return .{ .polyline = poly, .port_from = port_from, .port_to = port_to };
    }
    const exit_x = r.x + @as(i32, @intCast(port_from.offset));
    const enter_x = r.x + @as(i32, @intCast(port_to.offset));
    const south_y = r.bottom() - 1;
    const loop_y = south_y + OFF_V;
    const poly = try a.alloc(sketch.Point, 4);
    @memcpy(poly, &[_]sketch.Point{
        .{ .x = exit_x, .y = south_y }, .{ .x = exit_x, .y = loop_y },
        .{ .x = enter_x, .y = loop_y }, .{ .x = enter_x, .y = south_y },
    });
    return .{ .polyline = poly, .port_from = port_from, .port_to = port_to };
}

/// Nearest overshoot column east of the node whose lifted top-arm geometry
/// (east arm, vertical rise, top run, north descent) clears every foreign box,
/// or null when none within `OFF_H` is clear.
fn clearLoopX(id: sketch.NodeId, east_x: i32, east_y: i32, north_x: i32, loop_y: i32, north_y: i32, placements: []const sketch.NodePlacement) ?i32 {
    var loop_x = east_x + 1;
    while (loop_x < east_x + OFF_H) : (loop_x += 1) {
        if (!allocatedTopArmBlocked(id, east_x, east_y, north_x, loop_x, loop_y, north_y, placements)) return loop_x;
    }
    return null;
}

fn allocatedTopArmBlocked(id: sketch.NodeId, east_x: i32, east_y: i32, north_x: i32, loop_x: i32, loop_y: i32, north_y: i32, placements: []const sketch.NodePlacement) bool {
    if (sketch.rowTouchesAny(east_y, east_x + 1, loop_x, placements, id, id)) return true;
    if (sketch.columnTouchesAny(loop_x, loop_y, east_y, placements, id, id)) return true;
    if (sketch.rowTouchesAny(loop_y, north_x, loop_x, placements, id, id)) return true;
    return sketch.columnTouchesAny(north_x, loop_y, north_y - 1, placements, id, id);
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

/// Classic TD/BT loop: exit east-mid, over the top, enter north-mid.
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

/// True iff any run of the classic top loop would touch a FOREIGN box
/// (touch semantics: even border contact makes the raster delete cells).
fn topLoopBlocked(node_p: sketch.NodePlacement, placements: []const sketch.NodePlacement) bool {
    const g = topLoopGeom(node_p.rect);
    const id = node_p.id;
    if (sketch.rowTouchesAny(g.east_y, g.east_x + 1, g.loop_x, placements, id, id)) return true;
    if (sketch.columnTouchesAny(g.loop_x, g.loop_y, g.east_y, placements, id, id)) return true;
    if (sketch.rowTouchesAny(g.loop_y, g.north_x, g.loop_x, placements, id, id)) return true;
    if (sketch.columnTouchesAny(g.north_x, g.loop_y, g.north_y - 1, placements, id, id)) return true;
    return false;
}

/// Fallback TD/BT loop: exit SOUTH right of center (clear of the forward
/// out-edge on the center column), drop into a clear gap row, run right
/// past the east border, rise beside the node, and enter EAST-mid with a
/// horizontal ◀ arrowhead (which needs only a ≥2-cell approach run, not
/// headroom above the node). Candidate gap rows / arm columns are
/// searched nearest-first; returns null when nothing within reach is
/// clear (caller keeps the classic shape — status quo).
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
        // The south descent only lengthens with gap_y; once blocked, no deeper row can work either. // guarded-by: routing_self_loops_test.zig "belowEastLoop's south descent blocking is monotonic: an obstacle at the nearest candidate gap row sinks the whole fallback (no deeper gap_y recovers)"
        if (sketch.columnTouchesAny(exit_x, south_y + 1, gap_y, placements, id, id)) return null;
        // Base-side law: land the east re-entry with a straight `─` before the
        // `◀` (arm one cell further east → `◀─┐`, never `◀┐`). // guarded-by: routing_self_loops_test.zig "belowEastLoop lands the east re-entry with a straight base cell (◀─┐)"
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

/// LR/RL loop, self-contained BELOW the node (both ports on SOUTH) so the detour never crosses back into the node's own body, and stays clear of the east forward out-edge (re-entering east would collide the return ◀ with the forward ▶, reading as a spurious ◀──▶). // guarded-by: routing_self_loops_test.zig "self-loop detour never crosses back into the source node's own interior, across sizes and directions"
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
    // Final segment rises NORTH into the south border so the rasterizer derives a ▲ arrowhead anchored on the bottom wall. // guarded-by: routing_self_loops_test.zig "southLoop's final segment rises north (dy<0), the geometry paint.zig's arrowGlyph maps to the up-arrow ▲"
    try poly.append(a, .{ .x = enter_x, .y = south_y });
    return .{
        .polyline = try poly.toOwnedSlice(a),
        .port_from = .{ .node = node_p.id, .side = .south, .offset = @intCast(exit_x - r.x) },
        .port_to = .{ .node = node_p.id, .side = .south, .offset = @intCast(enter_x - r.x) },
    };
}

/// Half-gap `k` between the two SOUTH ports of an LR/RL self-loop.
/// The exit sits at `w/2 - k`, the re-entry at `w/2 + k`, so the two
/// ports never coincide and both stay strictly inside the bottom border.
/// Clamped so that `[w/2 - k, w/2 + k] ⊂ [1, w-2]` for any node width
/// (degenerate narrow nodes fall back to k=1, the minimum distinct gap).
pub fn selfLoopHalfGap(w: u32) i32 {
    const w_i: i32 = @intCast(w);
    const half = @divTrunc(w_i, 2);
    // Largest k keeping both ports in [1, w-2]: k <= half-1 (left bound) and k <= w-2-half (right bound); prefer ~quarter width, clamp to the structural maximum, floor at 1. // guarded-by: routing_self_loops_test.zig "selfLoopHalfGap keeps both south ports strictly inside [1, w-2] for every non-degenerate width"
    const max_k = @min(half - 1, w_i - 2 - half);
    if (max_k < 1) return 1;
    const want = @divTrunc(w_i, 4);
    return std.math.clamp(want, 1, max_k);
}

test {
    _ = @import("routing_self_loops_test.zig");
}

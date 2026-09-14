//! The detour builders a lane loop falls to when no gap lane clears: the
//! outside detour around the placed diagram, the invisible-link dogleg
//! search, the interior-run shift, and the widening bound. Split from
//! route_clearance.zig (500-line cap); the clearance gates stay there.
//! Imports (layout zone): std, sem_graph, sketch, base/ledger, siblings.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const route_clearance = @import("route_clearance.zig");
const Straight = @import("routing_polyline.zig").Straight;

const portPoint = route_clearance.portPoint;
const blocked = route_clearance.blocked;

/// How far the outside-detour search may widen before it gives up.
///
/// Each step pushes the detour one cell further outside every placement, and
/// the canvas bbox grows with it, so a search that never clears is billed for
/// every step it took. What it dodges is the paths already routed: with
/// `routed` of them and two sides to alternate between, `2 * routed + 2`
/// tracks exhaust every distinct answer widening can give — past that the
/// walk is only buying frame. The absolute ceiling stays 64 so a pathological
/// graph cannot make it quadratic.
///
/// This bound is why one unroutable edge in a complete undirected mesh no
/// longer drags ~60 empty rows of frame around the whole diagram.
/// @guarded-by: route_clearance_test.zig "the detour search widens once per already-routed path, never past the ceiling"
pub fn detourLimit(routed: usize) u32 {
    const want = 2 * @as(u64, routed) + 2;
    return @intCast(@min(want, 64));
}

/// A clear line for a detour's port-adjacent run. No box is exempt — the
/// route's OWN boxes terminate it too (box termination: a box is a terminus, never a
/// corridor); the only legal own-box footprint is the port cell itself,
/// which sits one cell before `want` and off the searched line. The result
/// is also confined to the port's outward half-plane, so the perpendicular
/// leg from the port can never run back through the box; when nothing on
/// that side is clear, `want` (the first off-box line) stands.
/// @guarded-by: route_clearance_test.zig "a detour's port run never crosses the route's own box"
fn offSideClearLine(horizontal: bool, want: i32, lo: i32, hi: i32, placements: []const sk.NodePlacement, outward: i32) i32 {
    const none = std.math.maxInt(pb.NodeId);
    const found = sk.clearLine(horizontal, want, lo, hi, placements, none, none, .{});
    return if ((found - want) * outward >= 0) found else want;
}

/// How many rows (TD) or columns (LR) beyond its minimum a detour's
/// port-adjacent run may be pushed into the gap when the nearer line is
/// taken by foreign ink: the widening ladder tries every pair of
/// source/target offsets up to this reach at each distance.
pub const ROW_REACH: u32 = 2;

/// The offsets of one detour candidate's two port-adjacent runs beyond
/// their minimum distance from the port (see `outsideDetour`).
pub const Rows = struct { source_extra: u32 = 0, target_extra: u32 = 0 };

/// Route around the outside of the placed diagram when all local gap lanes
/// are occupied. The first and last legs remain perpendicular to the ports,
/// and a decorated end's leg is two cells long so its head cell holds no
/// corner (`straight`, the straight-through rule of routing_terminal.zig).
/// `rows` pushes either port-adjacent run further out — a foreign jog on
/// the nearest gap row leaves the next one free — and a pushed run that
/// would touch a box (or whose leg would) is null: the builder clears its
/// own boxes, since the plan-blind clearance gates read only ink.
/// @guarded-by: route_clearance_test.zig "an outside detour bends two cells out from a decorated end and one from a plain end"
/// @guarded-by: route_clearance_test.zig "a pushed detour run takes the next gap row and is null where the push meets a box"
pub fn outsideDetour(
    a: std.mem.Allocator,
    direction: sg.Direction,
    from: sk.NodePlacement,
    to: sk.NodePlacement,
    port_from: sk.Port,
    port_to: sk.Port,
    placements: []const sk.NodePlacement,
    distance: u32,
    straight: Straight,
    rows: Rows,
) error{OutOfMemory}!?[]sk.Point {
    const out_from: i32 = (if (straight.from) @as(i32, 2) else 1) + @as(i32, @intCast(rows.source_extra));
    const out_to: i32 = (if (straight.to) @as(i32, 2) else 1) + @as(i32, @intCast(rows.target_extra));
    const start = portPoint(from, port_from);
    const end = portPoint(to, port_to);
    var min_x = @min(start.x, end.x);
    var min_y = @min(start.y, end.y);
    var max_x = @max(start.x, end.x);
    var max_y = @max(start.y, end.y);
    for (placements) |placement| {
        min_x = @min(min_x, placement.rect.x);
        min_y = @min(min_y, placement.rect.y);
        max_x = @max(max_x, placement.rect.right() - 1);
        max_y = @max(max_y, placement.rect.bottom() - 1);
    }
    const offset: i32 = @intCast(distance + 2);
    const points = try a.alloc(sk.Point, 6);
    if (direction == .TD or direction == .BT) {
        const outside_x = if (distance % 2 == 0) min_x - offset else max_x + offset;
        const src_out: i32 = if (port_from.side == .south) 1 else -1;
        const tgt_out: i32 = if (port_to.side == .north) -1 else 1;
        const source_y = offSideClearLine(true, start.y + src_out * out_from, @min(outside_x, start.x), @max(outside_x, start.x), placements, src_out);
        const target_y = offSideClearLine(true, end.y + tgt_out * out_to, @min(outside_x, end.x), @max(outside_x, end.x), placements, tgt_out);
        if (rows.source_extra != 0 and !pushedRunClear(true, start, src_out, source_y, outside_x, placements)) return null;
        if (rows.target_extra != 0 and !pushedRunClear(true, end, tgt_out, target_y, outside_x, placements)) return null;
        @memcpy(points, &[_]sk.Point{
            start,
            .{ .x = start.x, .y = source_y },
            .{ .x = outside_x, .y = source_y },
            .{ .x = outside_x, .y = target_y },
            .{ .x = end.x, .y = target_y },
            end,
        });
    } else {
        const outside_y = if (distance % 2 == 0) min_y - offset else max_y + offset;
        const src_out: i32 = if (port_from.side == .east) 1 else -1;
        const tgt_out: i32 = if (port_to.side == .west) -1 else 1;
        const source_x = offSideClearLine(false, start.x + src_out * out_from, @min(outside_y, start.y), @max(outside_y, start.y), placements, src_out);
        const target_x = offSideClearLine(false, end.x + tgt_out * out_to, @min(outside_y, end.y), @max(outside_y, end.y), placements, tgt_out);
        if (rows.source_extra != 0 and !pushedRunClear(false, start, src_out, source_x, outside_y, placements)) return null;
        if (rows.target_extra != 0 and !pushedRunClear(false, end, tgt_out, target_x, outside_y, placements)) return null;
        @memcpy(points, &[_]sk.Point{
            start,
            .{ .x = source_x, .y = start.y },
            .{ .x = source_x, .y = outside_y },
            .{ .x = target_x, .y = outside_y },
            .{ .x = target_x, .y = end.y },
            end,
        });
    }
    return points;
}

/// True iff a pushed port-adjacent run — the line `line` (a row when
/// `horizontal`) from the port's cross coordinate out to `outside` — and
/// the leg from the port to it touch no box. The leg starts one cell off
/// the port so the route's own box, which the port sits on, is not read.
fn pushedRunClear(horizontal: bool, port: sk.Point, outward: i32, line: i32, outside: i32, placements: []const sk.NodePlacement) bool {
    const none = std.math.maxInt(pb.NodeId);
    const along = if (horizontal) port.x else port.y;
    const cross = if (horizontal) port.y else port.x;
    if (sk.lineTouchesAny(horizontal, line, @min(outside, along), @max(outside, along), placements, none, none)) return false;
    const leg_lo = @min(cross + outward, line);
    const leg_hi = @max(cross + outward, line);
    return !sk.lineTouchesAny(!horizontal, along, leg_lo, leg_hi, placements, none, none);
}

pub fn dogleg(
    a: std.mem.Allocator,
    from: sk.NodePlacement,
    to: sk.NodePlacement,
    port_from: sk.Port,
    port_to: sk.Port,
    via: i32,
    vertical_middle: bool,
) error{OutOfMemory}![]sk.Point {
    const start = portPoint(from, port_from);
    const end = portPoint(to, port_to);
    const points = try a.alloc(sk.Point, 4);
    points[0] = start;
    points[3] = end;
    if (vertical_middle) {
        points[1] = .{ .x = via, .y = start.y };
        points[2] = .{ .x = via, .y = end.y };
    } else {
        points[1] = .{ .x = start.x, .y = via };
        points[2] = .{ .x = end.x, .y = via };
    }
    return points;
}

pub fn shiftInteriorRun(a: std.mem.Allocator, polyline: []const sk.Point, direction: sg.Direction, distance: u32) error{OutOfMemory}![]sk.Point {
    const shifted = try a.dupe(sk.Point, polyline);
    if (shifted.len < 4) return shifted;
    const delta: i32 = @intCast(distance);
    for (1..shifted.len - 2) |i| {
        const horizontal = shifted[i].y == shifted[i + 1].y;
        if ((direction == .TD or direction == .BT) != horizontal) continue;
        if (horizontal) {
            const dy = if (direction == .TD) delta else -delta;
            shifted[i].y += dy;
            shifted[i + 1].y += dy;
        } else {
            const dx = if (direction == .LR) delta else -delta;
            shifted[i].x += dx;
            shifted[i + 1].x += dx;
        }
        break;
    }
    return shifted;
}

pub fn clearInvisiblePath(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    from: sk.NodePlacement,
    to: sk.NodePlacement,
    port_from: sk.Port,
    port_to: sk.Port,
    placements: []const sk.NodePlacement,
    existing: []const sk.EdgePath,
    bundles: pb.RealizedBundles,
) error{OutOfMemory}![]sk.Point {
    var min_x = placements[0].rect.x;
    var max_x = placements[0].rect.right() - 1;
    var min_y = placements[0].rect.y;
    var max_y = placements[0].rect.bottom() - 1;
    for (placements[1..]) |placement| {
        min_x = @min(min_x, placement.rect.x);
        max_x = @max(max_x, placement.rect.right() - 1);
        min_y = @min(min_y, placement.rect.y);
        max_y = @max(max_y, placement.rect.bottom() - 1);
    }
    var x = min_x;
    while (x <= max_x) : (x += 1) {
        const poly = try dogleg(a, from, to, port_from, port_to, x, true);
        if (!try blocked(a, edge, poly, existing, bundles, placements, from.id, to.id)) return poly;
    }
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const poly = try dogleg(a, from, to, port_from, port_to, y, false);
        if (!try blocked(a, edge, poly, existing, bundles, placements, from.id, to.id)) return poly;
    }
    return a.alloc(sk.Point, 0);
}

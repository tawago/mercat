//! Orthogonal polyline routing helpers, split from `routing.zig`.
//!
//! Contains `routePolyline` (the main forward-edge routing function) and
//! the supporting helpers `insetPort`, `absDiff`, `portPoint`, plus the
//! strict-interior intrusion predicates. Touch-semantics clearance (used
//! when CHOOSING an edge run's line) lives in `sketch.zig`; the per-gap
//! extra-row reservations (`skipCorridorExtraRows`,
//! `terminalApproachExtraRows`) in `routing_terminal.zig`.
//! Imports: only `std`, `../sem_graph.zig`, `../sketch.zig`,
//! `route_clearance.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const route_clearance = @import("route_clearance.zig");

/// Move a perimeter port outward by `pad` cells along the side normal.
/// Used to introduce a 1-cell whitespace gap between a node border and
/// the first dash of an edge, matching the cluster-internal goldens.
pub fn insetPort(pt: sketch.Point, side: sketch.Dir4, pad: i32) sketch.Point {
    if (pad == 0) return pt;
    return switch (side) {
        .north => .{ .x = pt.x, .y = pt.y - pad },
        .south => .{ .x = pt.x, .y = pt.y + pad },
        .west => .{ .x = pt.x - pad, .y = pt.y },
        .east => .{ .x = pt.x + pad, .y = pt.y },
    };
}

/// Which of a route's two terminal cells must be run straight through.
/// A decorated end's departure or arrival cell is that end's decoration
/// cell: a turn inside it puts a corner where the head must sit, so the
/// producer bends one cell further out instead. An undecorated end holds
/// a plain run and may bend in its terminal cell.
pub const Straight = struct {
    from: bool = false,
    to: bool = false,

    pub fn forEdge(edge: sg.Edge) Straight {
        return .{ .from = edge.arrow_from != .none, .to = edge.arrow_to != .none };
    }
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

/// Reconcile a terminal port with the side the polyline's final leg
/// actually approaches from. A route's last segment must enter the target
/// wall perpendicular, landing ON the allocated port's border. When an
/// obstacle-dodging shift (see `route_detour.shiftInteriorRun`) drives
/// the approach run to the side of the target OPPOSITE its allocated port,
/// the recorded endpoint sits on the far border and the final leg crosses
/// the whole box interior to reach it — the rasterizer then drops those
/// intruded-through cells (arrowhead included). Nothing upstream enforces
/// that the final-approach side equals the terminal-port side, so this closes
/// the gap at the router's exit: if the final leg enters from the port's
/// exact opposite side (with `prev` strictly outside the box), flip the port
/// to the entry side and move the endpoint onto that border. The cross-axis
/// offset is preserved (north<->south share the x-offset, east<->west the
/// y-offset), so the approach column/row is unchanged — only the border the
/// arrowhead lands on moves. No-op when the approach already agrees with the
/// port (the common case) or disagrees only perpendicularly.
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

/// Neutral facts about a corner-fed terminal: the final port-entry leg (b->c,
/// delta lx/ly) at index `bi` and its perpendicular predecessor `p`.
pub const CornerFed = struct { bi: usize, b: sketch.Point, p: sketch.Point, lx: i32, ly: i32 };

/// Shared corner-detection HEAD for `ensureBaseStub` (below) and
/// routing_terminal.zig's `satisfyApproach`: locates the final leg
/// `b->c` and confirms its predecessor `p->b` is an orthogonal run PERPENDICULAR
/// to it (the "corner-fed terminal" both passes act on); null otherwise.
/// Deliberately NEUTRAL — it checks neither final-leg LENGTH (stub wants 1,
/// lengthen wants 2) nor predecessor DEPTH (lengthen needs bi>=2); each caller
/// applies its own. All gates are pure, so hoisting the shared ones ahead of the
/// caller-specific ones does not change which polylines fire.
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

/// Ensure the arrowhead at the polyline's TERMINAL is fed on its BASE side
/// (owner arrow-base rule, 2026-07-18): a "turn-at-tip" final approach — a
/// perpendicular descent leg that turns into the 1-cell port-entry leg IN the
/// arrowhead's own row/column — leaves the base cell (behind the tip) blank,
/// so the ink appears to arrive from the flank. Shift the descent leg one cell
/// back along the port-leg axis so the turn happens one cell early: the corner
/// then lands on the base cell (a `└`/`┘`/`┌`/`┐` welded into the run) and the
/// final leg spans two cells with the arrowhead one cell in from the wall.
///
/// Length-preserving: moves the two points that form the descent leg, never
/// inserts. No-op unless the final leg is exactly 1 cell AND its predecessor is
/// perpendicular to it (the tell of a turn-at-tip). Accept-fallback: leaves the
/// polyline untouched when the shifted descent would touch a foreign box (no
/// room) — the report-only validator keeps counting that residual.
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

// Strict-interior intrusion predicates: border contact allowed. Use them
// ONLY to ask "would the validator flag this?" (mirrors
// `validate.segmentCrossesInterior`).
// @guarded-by: validate_test.zig "edge through node interior flagged"

/// True iff a vertical segment at column `x` spanning rows
/// `[y_top, y_bot]` would pass through the strict open interior of `r`.
pub fn columnIntrudesRect(x: i32, y_top: i32, y_bot: i32, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    const left = r.x;
    const right_inc = r.right() - 1;
    const top = r.y;
    const bottom_inc = r.bottom() - 1;
    if (x <= left or x >= right_inc) return false;
    return y_top < bottom_inc and y_bot > top;
}

/// Row analogue of `columnIntrudesRect`.
pub fn rowIntrudesRect(y: i32, x_left: i32, x_right: i32, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    const top = r.y;
    const bottom_inc = r.bottom() - 1;
    const left = r.x;
    const right_inc = r.right() - 1;
    if (y <= top or y >= bottom_inc) return false;
    return x_left < right_inc and x_right > left;
}

/// NodeGeom is passed by the caller (routing.zig); we reference it as a
/// slice parameter rather than importing routing.zig (which would create
/// a circular import). The type must match `routing.NodeGeom` exactly:
/// { x: i32, y: i32, w: u32, h: u32, layer: u32 }.
///
/// A route spanning two or more layers runs a corridor beside its
/// intermediate layers (`corridorRoute`); a one-layer route is a plain jog
/// (`plainRoute`) — unless that jog would run through a foreign box (a
/// rank grid's lower sub-row stacks a box between the two ports), in which
/// case it too takes the corridor, beside that box: a box is a terminus,
/// never a corridor.
/// @guarded-by: routing_polyline_test.zig "a one-layer route runs the corridor beside a box in its way instead of through it"
pub fn routePolyline(
    a: std.mem.Allocator,
    dir: sg.Direction,
    from_p: sketch.NodePlacement,
    to_p: sketch.NodePlacement,
    port_from: sketch.Port,
    port_to: sketch.Port,
    virtuals: []const u32,
    /// Slice of NodeGeom (from routing.zig); uses anytype to avoid
    /// circular import — caller passes the routing.NodeGeom slice.
    geom: anytype,
    placements: []const sketch.NodePlacement,
    inset_from: i32,
    inset_to: i32,
    route_lane: u32,
    straight: Straight,
) error{OutOfMemory}![]sketch.Point {
    const raw_start = portPoint(from_p, port_from);
    const raw_end = portPoint(to_p, port_to);
    const start = insetPort(raw_start, port_from.side, inset_from);
    const end = insetPort(raw_end, port_to.side, inset_to);
    const horizontal = (dir == .LR or dir == .RL);

    // Skip-corridor routing: an edge spanning ≥2 layers carries ≥1 virtual
    // node. Bending the polyline at each virtual's box row would intrude
    // into the intermediate boxes; instead route it as a corridor beside
    // them, aimed at the first virtual's centre line. The horizontal mirror
    // is gated on eastward flow (post-transpose LR invariant); anything
    // else keeps the legacy virtual-follower path.
    // @guarded-by: validate_test.zig "edge through node interior flagged"
    // @guarded-by: raster/edges_test.zig "edge cells colliding with node-owned cells are counted as lost"
    if (virtuals.len > 0) {
        const first = geom[virtuals[0]];
        if (!horizontal) {
            const want_x = first.x + @divTrunc(@as(i32, @intCast(first.w)), 2);
            return corridorRoute(a, false, start, end, want_x, first.y, route_lane, straight, placements, from_p.id, to_p.id);
        }
        if (end.x > start.x) {
            const want_y = first.y + @divTrunc(@as(i32, @intCast(first.h)), 2);
            return corridorRoute(a, true, start, end, want_y, first.x, route_lane, straight, placements, from_p.id, to_p.id);
        }
    }

    const plain = try plainRoute(a, horizontal, start, end, virtuals, geom, port_to.side, route_lane, straight);
    if (virtuals.len == 0) {
        if (obstacleBox(plain, placements, from_p.id, to_p.id)) |box| {
            if (!horizontal) return corridorRoute(a, false, start, end, end.x, box.y, route_lane, straight, placements, from_p.id, to_p.id);
            if (end.x > start.x) return corridorRoute(a, true, start, end, end.y, box.x, route_lane, straight, placements, from_p.id, to_p.id);
        }
    }
    return plain;
}

/// The foreign box a plain route runs through, when one does: the first
/// placement other than the route's own two that a segment of `poly`
/// touches. Null for a box-free route.
fn obstacleBox(poly: []const sketch.Point, placements: []const sketch.NodePlacement, from: sketch.NodeId, to: sketch.NodeId) ?sketch.Rect {
    for (placements) |p| {
        if (p.id == from or p.id == to) continue;
        const one = [_]sketch.NodePlacement{p};
        if (route_clearance.touchesForeignNode(poly, &one, from, to)) return p.rect;
    }
    return null;
}

/// A corridor route: descend into the gap before `top` (the first line of
/// the intermediate layer or obstacle box), jog once to the corridor line
/// nearest `want` that touches no foreign box, run straight past the
/// obstacle, then jog into the target's line and enter its port. `top` and
/// `want` are a row and a column for a vertical (TD) route and a column
/// and a row for a horizontal (LR) one.
fn corridorRoute(
    a: std.mem.Allocator,
    horizontal: bool,
    start: sketch.Point,
    end: sketch.Point,
    want: i32,
    top: i32,
    route_lane: u32,
    straight: Straight,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
) error{OutOfMemory}![]sketch.Point {
    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(a, start);
    const lane: i32 = @intCast(route_lane);
    if (!horizontal) {
        // enter_gap_y: the entry run's row, three rows above the first
        // intermediate layer and one higher per lane. The row directly
        // above that layer is its arrival row — every decorated arrival
        // cell there is reserved against a foreign through-run — and the
        // row above that holds those heads' base cells, where a crossing
        // leaves a head unfed (the raster paints one stroke per cell); an
        // entry run on either is refused or priced at every lane. The
        // floor keeps the run off the source wall and, for a decorated
        // source, out of the departure cell.
        // @guarded-by: routing_polyline_test.zig "the skip corridor enters three rows above the intermediate layer and climbs with the lane"
        const enter_floor = start.y + (if (straight.from) @as(i32, 2) else 1);
        const enter_gap_y = @max(top - 3 - lane, enter_floor);
        // align_y: gap ABOVE the target, leaving ≥1 row for a vertical descent (falls back to end.y-1 if skipCorridorExtraRows headroom is absent). @guarded-by: routing_polyline_test.zig "TD skip-corridor final descent is a clean vertical approach (guards ▼)"
        // A decorated arrival never takes the end.y-1 fallback — that is a
        // turn in the arrival cell — it holds the corridor row instead.
        // @guarded-by: routing_polyline_test.zig "a skip corridor past its lane budget keeps a decorated arrival straight"
        const align_y = if (end.y - 2 - lane > enter_gap_y) end.y - 2 - lane else if (straight.to) @max(end.y - 2, enter_gap_y) else end.y - 1;

        // The wanted column is NOT guaranteed clear: a real node may have
        // drifted onto the virtuals' barycenter, and an obstacle box sits on
        // the target's own column by definition; slide the corridor to the
        // nearest column whose run touches NO foreign box cell (touch
        // semantics, not strict-interior intrusion — a corridor on a foreign
        // border column rasterizes as swallowed edge cells even where the
        // interior validator stays silent). Generic — keyed only on the
        // placed rects, never on identities.
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
        const enter_gap_x = @max(top - 3 - lane, enter_floor);
        // align_x: gap column just before the target, leaving ≥1 cell of straight horizontal approach. @guarded-by: routing_polyline_test.zig "LR skip-corridor final approach is a clean horizontal approach (guards ▶)"
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

/// The plain route: follow the virtuals' centres (legacy path), then the
/// final approach jog into the target port.
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

    // Final approach: the edge must enter the target wall perpendicular,
    // landing on the port, and must not run along the SOURCE wall on its
    // way out. Bend in the inter-layer gap one cell OUTSIDE the target wall:
    // run perpendicular out of the source to that gap line, jog across to
    // the port's cross-axis (clear of both boxes), then run the final cell
    // straight into the port. Bending at the wall coordinate itself would
    // lay the final/exit segment ALONG a box wall, piercing its border/corner.
    // @guarded-by: validate_test.zig "edge through node interior flagged"
    if (virtuals.len == 0) {
        if (horizontal) {
            // West/east port: straight run if already on the port row; otherwise jog out 2 cells (1 if the gap is tight) so the final horizontal approach is never zero-length. @guarded-by: routing_polyline_test.zig "west/east port jog pad is never zero, near or far (guards clean </>)"
            if (end.y != prev.y) {
                // Clamp the jog to at most span-1 (floor 1): a jog ON the
                // source wall column lays the cross run along the wall — the
                // raster refuses those cells and the head ships unfed.
                // @guarded-by: routing_polyline_test.zig "the jog never lands on the source wall (span-2 gap and lane escalation clamp)"
                const span_x = absDiff(end.x, prev.x);
                const want_x_pad: i32 = (if (span_x >= 2) @as(i32, 2) else 1) + @as(i32, @intCast(route_lane));
                const pad = jogPad(want_x_pad, span_x, straight);
                const jog = insetPort(end, to_side, pad);
                try poly.append(a, .{ .x = jog.x, .y = prev.y });
                try poly.append(a, .{ .x = jog.x, .y = end.y });
            }
        } else {
            // North/south port: straight run if already on the port column; otherwise jog out 2 rows (1 if the gap is tight) so the final vertical approach is never zero-length. @guarded-by: routing_polyline_test.zig "north/south port jog pad is never zero, near or far (guards clean ^/v)"
            if (end.x != prev.x) {
                // Same clamp as the horizontal arm: the jog row must stay
                // strictly off the source wall row.
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

/// The jog's distance from the target wall. A decorated arrival keeps the
/// jog two cells out (the arrival cell stays straight), a decorated source
/// keeps it two cells short of the source wall (the departure cell stays
/// straight); a plain end may bend in its terminal cell. A gap too tight
/// for both keeps the pre-rule clamp and leaves the refusal to the
/// straight-through gate, which degrades the route instead of shipping a
/// corner where a head sits.
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

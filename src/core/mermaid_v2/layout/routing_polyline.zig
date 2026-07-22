//! Orthogonal polyline routing helpers, split from `routing.zig`.
//!
//! Contains `routePolyline` (the main forward-edge routing function),
//! `skipCorridorExtraRows` (per-gap extra row allocation for skip edges),
//! and the supporting helpers `placementAxis`, `insetPort`, `absDiff`,
//! `portPoint`, plus the strict-interior "pierce" predicates. Touch-semantics
//! clearance (used when CHOOSING an edge run's line) lives in `sketch.zig`.
//! Imports: only `std`, `../sem_graph.zig`, `../sketch.zig`, `sugiyama.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");

/// Per-gap extra rows needed for skip-edge corridors (TD/BT). Entry i is
/// the extra row count in the gap between layer i and layer i+1. A layer
/// that receives a ≥2-layer-spanning edge (i.e. an edge whose final
/// segment arrives from a VIRTUAL node) needs one extra row in the gap
/// directly above it so the corridor can make a clean vertical descent
/// into the target port. Generic: keyed purely on virtual→real arrivals,
/// not on any node identity.
pub fn skipCorridorExtraRows(
    a: std.mem.Allocator,
    lg: sugiyama.LayeredGraph,
) error{OutOfMemory}![]u32 {
    if (lg.layers.len < 2) return try a.alloc(u32, 0);
    const out = try a.alloc(u32, lg.layers.len - 1);
    @memset(out, 0);

    var node_layer = try a.alloc(u32, lg.nodes.len);
    defer a.free(node_layer);
    @memset(node_layer, 0);
    for (lg.layers, 0..) |row, li| {
        for (row) |idx| node_layer[idx] = @intCast(li);
    }

    for (lg.edges) |le| {
        // The corridor's final descent lands on a real target reached
        // from a virtual predecessor — that is the tell of a skip edge.
        const from_is_virtual = switch (lg.nodes[le.from]) {
            .virtual => true,
            .real => false,
        };
        const to_is_real = switch (lg.nodes[le.to]) {
            .real => true,
            .virtual => false,
        };
        if (from_is_virtual and to_is_real) {
            const tgt_layer = node_layer[le.to];
            if (tgt_layer > 0) {
                const gap = tgt_layer - 1;
                if (gap < out.len) out[gap] = 1;
            }
        }
    }
    return out;
}

/// Effective routing axis for a same-cluster edge, read from the two
/// endpoints' actual relative placement. Returns a horizontal direction
/// (LR/RL) when the boxes sit side-by-side (y-ranges overlap, x disjoint)
/// and a vertical one (TD/BT) when they are stacked. Picks the polarity
/// (LR vs RL, TD vs BT) from which endpoint leads so the source exits
/// toward the target. Falls back to `fallback` when the relationship is
/// ambiguous (overlap on both axes, or neither). Used to keep a
/// direction-transposed subgraph's internal edges flowing between the
/// member boxes instead of looping over the cluster frame border.
pub fn placementAxis(
    from_p: sketch.NodePlacement,
    to_p: sketch.NodePlacement,
    fallback: sg.Direction,
) sg.Direction {
    const f = from_p.rect;
    const t = to_p.rect;
    const x_overlap = f.x < t.right() and t.x < f.right();
    const y_overlap = f.y < t.bottom() and t.y < f.bottom();
    if (y_overlap and !x_overlap) {
        return if (t.x >= f.right()) .LR else .RL;
    }
    if (x_overlap and !y_overlap) {
        return if (t.y >= f.bottom()) .TD else .BT;
    }
    return fallback;
}

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

pub fn absDiff(x: i32, y: i32) i32 {
    return if (x > y) x - y else y - x;
}

pub fn portPoint(p: sketch.NodePlacement, port: sketch.Port) sketch.Point {
    // Endpoints land ON the perimeter border cell (inclusive), not one
    // cell outside it. The edge rasterizer skips the polyline's source
    // and target cells when walking, so an OR-merge on the source border
    // (and the target arrowhead's preceding cell) yields the correct
    // junction glyph.
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
/// obstacle-dodging shift (see `route_clearance.shiftInteriorRun`) drives
/// the approach run to the side of the target OPPOSITE its allocated port,
/// the recorded endpoint sits on the far border and the final leg crosses
/// the whole box interior to reach it — the rasterizer then drops those
/// pierced cells (arrowhead included). Nothing upstream enforces that the
/// final-approach side equals the terminal-port side, so this closes the
/// gap at the router's exit: if the final leg enters from the port's exact
/// opposite side (with `prev` strictly outside the box), flip the port to
/// the entry side and move the endpoint onto that border. The cross-axis
/// offset is preserved (north<->south share the x-offset, east<->west the
/// y-offset), so the approach column/row is unchanged — only the border the
/// arrowhead lands on moves. No-op when the approach already agrees with the
/// port (the common case) or disagrees only perpendicularly.
/// guarded-by: routing_polyline_test.zig "final approach reconciles a below-approach opposite-side port to the entry-side terminal"
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
        return port_to; // non-orthogonal final leg — leave untouched
    if (oppositeSide(entry_side) != port_to.side) return port_to; // agrees, or perpendicular
    const r = to_p.rect;
    // Require `prev` strictly OUTSIDE the box on the entry side, so the leg
    // genuinely crosses the interior (a pierce), not merely a short stub.
    const pierces = switch (entry_side) {
        .north => prev.y < r.y,
        .south => prev.y > r.bottom() - 1,
        .west => prev.x < r.x,
        .east => prev.x > r.right() - 1,
    };
    if (!pierces) return port_to;
    const flipped: sketch.Port = .{ .node = port_to.node, .side = entry_side, .offset = port_to.offset };
    poly[poly.len - 1] = portPoint(to_p, flipped);
    return flipped;
}

/// Neutral facts about a corner-fed terminal: the final port-entry leg (b->c,
/// delta lx/ly) at index `bi` and its perpendicular predecessor `p`.
pub const CornerFed = struct { bi: usize, b: sketch.Point, p: sketch.Point, lx: i32, ly: i32 };

/// Shared corner-detection HEAD for `ensureBaseStub` (below) and
/// routing_terminal.zig's `ensureBaseApproachLengthen`: locates the final leg
/// `b->c` and confirms its predecessor `p->b` is an orthogonal run PERPENDICULAR
/// to it (the "corner-fed terminal" both passes act on); null otherwise.
/// Deliberately NEUTRAL — it checks neither final-leg LENGTH (stub wants 1,
/// lengthen wants 2) nor predecessor DEPTH (lengthen needs bi>=2); each caller
/// applies its own. All gates are pure, so hoisting the shared ones ahead of the
/// caller-specific ones does not change which polylines fire.
pub fn detectCornerFedTerminal(poly: []const sketch.Point) ?CornerFed {
    if (poly.len < 3) return null;
    const c = poly[poly.len - 1]; // terminal: the port border cell (raster skips it)
    // Collapse any trailing duplicate so `b` is the last real vertex.
    var bi: usize = poly.len - 2;
    while (bi > 0 and poly[bi].x == c.x and poly[bi].y == c.y) : (bi -= 1) {}
    if (bi == 0) return null;
    const b = poly[bi];
    const p = poly[bi - 1];
    const lx = c.x - b.x;
    const ly = c.y - b.y;
    // Predecessor leg (p -> b): orthogonal AND perpendicular to the final leg.
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
/// guarded-by: routing_polyline_test.zig "ensureBaseStub shifts a turn-at-tip descent back one cell"
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
    // Port-entry leg (b -> c): a single orthogonal step, else not a tip turn.
    if (@as(i32, @intCast(@abs(lx))) + @as(i32, @intCast(@abs(ly))) != 1) return false;
    // Shift the descent leg one cell back along -unit(b->c).
    const nb = sketch.Point{ .x = b.x - lx, .y = b.y - ly };
    const np = sketch.Point{ .x = p.x - lx, .y = p.y - ly };
    // The shifted descent runs along the p->b axis at its new cross position.
    const descent_horizontal = (np.y == nb.y);
    const cross: i32 = if (descent_horizontal) np.y else np.x;
    const lo: i32 = if (descent_horizontal) @min(np.x, nb.x) else @min(np.y, nb.y);
    const hi: i32 = if (descent_horizontal) @max(np.x, nb.x) else @max(np.y, nb.y);
    if (sketch.lineTouchesAny(descent_horizontal, cross, lo, hi, placements, from_id, to_id)) return false;
    poly[bi] = nb;
    poly[bi - 1] = np;
    return true;
}

// Strict-interior "pierce" predicates: border contact allowed. Use them
// ONLY to ask "would the validator flag this?" (mirrors
// `validate.segmentCrossesInterior`).
// guarded-by: validate_test.zig "edge through node interior flagged"
// When CHOOSING the row/column an edge run occupies, use the TOUCH-semantics
// helpers in `sketch.zig` (`sketch.clearLine` / `sketch.lineTouchesAny`)
// instead — raster cell ownership includes borders.

/// True iff a vertical segment at column `x` spanning rows
/// `[y_top, y_bot]` would pass through the strict open interior of `r`.
pub fn columnPiercesRect(x: i32, y_top: i32, y_bot: i32, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    const left = r.x;
    const right_inc = r.right() - 1;
    const top = r.y;
    const bottom_inc = r.bottom() - 1;
    if (x <= left or x >= right_inc) return false;
    return y_top < bottom_inc and y_bot > top;
}

/// Row analogue of `columnPiercesRect`.
pub fn rowPiercesRect(y: i32, x_left: i32, x_right: i32, r: sketch.Rect) bool {
    if (r.w < 3 or r.h < 3) return false;
    const top = r.y;
    const bottom_inc = r.bottom() - 1;
    const left = r.x;
    const right_inc = r.right() - 1;
    if (y <= top or y >= bottom_inc) return false;
    return x_left < right_inc and x_right > left;
}

fn rowClear(
    y: i32,
    x_left: i32,
    x_right: i32,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
) bool {
    for (placements) |p| {
        if (p.id == from_id or p.id == to_id) continue;
        if (rowPiercesRect(y, x_left, x_right, p.rect)) return false;
    }
    return true;
}

/// Pick a gap row for a serpentine band-return run from `want_y` outward
/// (nearest first), skipping any row whose horizontal span `[x_left,x_right]`
/// would pierce a node interior. A clear row always exists (bands are
/// separated by `BAND_CROSS_GAP` lanes).
fn clearRow(
    want_y: i32,
    x_left: i32,
    x_right: i32,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
) i32 {
    if (rowClear(want_y, x_left, x_right, placements, from_id, to_id)) return want_y;
    var delta: i32 = 1;
    while (delta < 4096) : (delta += 1) {
        const up = want_y - delta;
        if (rowClear(up, x_left, x_right, placements, from_id, to_id)) return up;
        const down = want_y + delta;
        if (rowClear(down, x_left, x_right, placements, from_id, to_id)) return down;
    }
    return want_y;
}

/// NodeGeom is passed by the caller (routing.zig); we reference it as a
/// slice parameter rather than importing routing.zig (which would create
/// a circular import). The type must match `routing.NodeGeom` exactly:
/// { x: i32, y: i32, w: u32, h: u32, layer: u32 }.
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
    /// True only on the chain_wrap rung — enables the serpentine band-return
    /// route. Off elsewhere so a normal RL/LR left-going edge keeps its plain
    /// elbow (it is not a carriage return).
    chain_wrap: bool,
) error{OutOfMemory}![]sketch.Point {
    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    const raw_start = portPoint(from_p, port_from);
    const raw_end = portPoint(to_p, port_to);
    const start = insetPort(raw_start, port_from.side, inset_from);
    const end = insetPort(raw_end, port_to.side, inset_to);
    try poly.append(a, start);

    const horizontal = (dir == .LR or dir == .RL);

    // Skip-corridor routing (TD/BT): an edge spanning ≥2 layers carries ≥1
    // virtual node. Bending the polyline at each virtual's box row would
    // pierce the intermediate boxes; instead route it as a vertical channel
    // beside those boxes — descend into the gap above the first
    // intermediate layer, jog once to the virtuals' corridor column, run
    // straight down past every intermediate layer, then jog into the
    // target's column and descend into its port.
    // guarded-by: validate_test.zig "edge through node interior flagged"
    if (!horizontal and virtuals.len > 0) {
        // Corridor column = the virtuals' center x. They are barycenter-
        // placed into a single near-vertical channel beside the chain.
        const first = geom[virtuals[0]];
        const want_x = first.x + @divTrunc(@as(i32, @intCast(first.w)), 2);
        // Gap row immediately above the first intermediate box-top — one
        // row up sits in the inter-layer gap, never on a border.
        const enter_gap_y = first.y - 1;
        // align_y: gap ABOVE the target, leaving ≥1 row for a vertical descent (falls back to end.y-1 if skipCorridorExtraRows headroom is absent). guarded-by: routing_polyline_test.zig "TD skip-corridor final descent is a clean vertical approach (guards ▼)"
        const lane: i32 = @intCast(route_lane);
        const align_y = if (end.y - 2 - lane > enter_gap_y) end.y - 2 - lane else end.y - 1;

        // The virtuals' barycenter column is NOT guaranteed clear: a real
        // node may have drifted onto it, so slide the corridor to the
        // nearest column whose run touches NO foreign box cell (touch
        // semantics, not strict-interior pierce — a corridor on a foreign
        // border column rasterizes as swallowed edge cells even where the
        // interior validator stays silent). Generic — keyed only on the
        // placed rects, never on identities.
        // guarded-by: validate_test.zig "edge through node interior flagged";
        //   raster/edges_test.zig "edge cells colliding with node-owned cells are counted as lost"
        const run_top = @min(enter_gap_y, align_y);
        const run_bot = @max(enter_gap_y, align_y);
        const corridor_x = sketch.clearLine(false, want_x, run_top, run_bot, placements, from_p.id, to_p.id, .{ .margin = true });

        if (enter_gap_y != start.y) try poly.append(a, .{ .x = start.x, .y = enter_gap_y });
        if (corridor_x != start.x) try poly.append(a, .{ .x = corridor_x, .y = enter_gap_y });
        if (align_y != enter_gap_y) try poly.append(a, .{ .x = corridor_x, .y = align_y });
        if (end.x != corridor_x) try poly.append(a, .{ .x = end.x, .y = align_y });
        try poly.append(a, end);
        if (poly.items.len < 2) try poly.append(a, end);
        return try poly.toOwnedSlice(a);
    }

    // Horizontal (LR) mirror of the TD skip-corridor above. Without it,
    // horizontal edges with virtuals fall through the virtual-follower loop
    // below with no obstacle check, and can swallow raster cells on a
    // foreign border. Gated on eastward flow (post-transpose LR invariant);
    // anything else keeps the legacy path.
    // guarded-by: raster/edges_test.zig "edge cells colliding with node-owned cells are counted as lost"
    if (horizontal and virtuals.len > 0 and end.x > start.x) {
        const first = geom[virtuals[0]];
        const want_y = first.y + @divTrunc(@as(i32, @intCast(first.h)), 2);
        // Gap column just before the first intermediate layer's band.
        const enter_gap_x = first.x - 1;
        // align_x: gap column just before the target, leaving ≥1 cell of straight horizontal approach. guarded-by: routing_polyline_test.zig "LR skip-corridor final approach is a clean horizontal approach (guards ▶)"
        const lane: i32 = @intCast(route_lane);
        const align_x = if (end.x - 2 - lane > enter_gap_x) end.x - 2 - lane else end.x - 1;
        const run_lo = @min(enter_gap_x, align_x);
        const run_hi = @max(enter_gap_x, align_x);
        const corridor_y = sketch.clearLine(true, want_y, run_lo, run_hi, placements, from_p.id, to_p.id, .{ .margin = true });

        if (enter_gap_x != start.x) try poly.append(a, .{ .x = enter_gap_x, .y = start.y });
        if (corridor_y != start.y) try poly.append(a, .{ .x = enter_gap_x, .y = corridor_y });
        if (align_x != enter_gap_x) try poly.append(a, .{ .x = align_x, .y = corridor_y });
        if (end.y != corridor_y) try poly.append(a, .{ .x = align_x, .y = end.y });
        try poly.append(a, end);
        if (poly.items.len < 2) try poly.append(a, end);
        return try poly.toOwnedSlice(a);
    }

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
    // guarded-by: validate_test.zig "edge through node interior flagged"
    //
    // Applies only to direct (virtual-free) adjacent-layer edges: edges
    // carrying virtuals already thread mid-segment bends and keep the
    // original final bend (TD skip edges are handled by the corridor branch
    // above); forcing the gap-bend on them would disconnect the trailing stub.
    if (virtuals.len == 0) {
        if (chain_wrap and horizontal and end.x < prev.x and end.y != prev.y) {
            // Serpentine band-return (Lever C): target sits left of and on a
            // different row than the source — a chain-wrap carriage-return
            // edge. A plain east-exit + left-jog would slice every box across
            // the source band; instead exit one cell past the source wall,
            // drop into a clear inter-band gap row, run left to the target
            // column, then descend/ascend into the port. Generic — keyed only
            // on the placed rects, never on identity.
            // guarded-by: validate_test.zig "edge through node interior flagged"
            const exit_x = prev.x + 1; // one cell east of the source port.
            const x_lo = @min(exit_x, end.x);
            const x_hi = @max(exit_x, prev.x);
            const want_y = @divTrunc(prev.y + end.y, 2);
            const gap_y = clearRow(want_y, x_lo, x_hi, placements, from_p.id, to_p.id);
            try poly.append(a, .{ .x = exit_x, .y = prev.y });
            try poly.append(a, .{ .x = exit_x, .y = gap_y });
            // Land in the target's approach column (one cell west of its west
            // port) along the gap row, then run the final cell(s) into the port.
            const approach_x = end.x - 1;
            try poly.append(a, .{ .x = approach_x, .y = gap_y });
            try poly.append(a, .{ .x = approach_x, .y = end.y });
        } else if (horizontal) {
            // West/east port: straight run if already on the port row; otherwise jog out 2 cells (1 if the gap is tight) so the final horizontal approach is never zero-length. guarded-by: routing_polyline_test.zig "west/east port jog pad is never zero, near or far (guards clean </>)"
            if (end.y != prev.y) {
                const pad: i32 = (if (absDiff(end.x, prev.x) >= 2) @as(i32, 2) else 1) + @as(i32, @intCast(route_lane));
                const jog = insetPort(end, port_to.side, pad);
                try poly.append(a, .{ .x = jog.x, .y = prev.y });
                try poly.append(a, .{ .x = jog.x, .y = end.y });
            }
        } else {
            // North/south port: straight run if already on the port column; otherwise jog out 2 rows (1 if the gap is tight) so the final vertical approach is never zero-length. guarded-by: routing_polyline_test.zig "north/south port jog pad is never zero, near or far (guards clean ^/v)"
            if (end.x != prev.x) {
                const pad: i32 = (if (absDiff(end.y, prev.y) >= 2) @as(i32, 2) else 1) + @as(i32, @intCast(route_lane));
                const jog = insetPort(end, port_to.side, pad);
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

test {
    _ = @import("routing_polyline_test.zig");
}

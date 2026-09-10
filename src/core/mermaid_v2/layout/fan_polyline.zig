//! Fan peer-edge polyline construction + port helpers, split from
//! `fan.zig` (500-line cap). `buildPolyline` routes one fan member edge
//! via grid combs (rows > 1) or the single-row rail path, dodging via
//! sketch.zig's touch-semantics helpers whenever a foreign box would
//! otherwise block a run.
//!
//! Imports (layout zone): std + sem_graph + sketch + fan.zig (types) +
//! routing_polyline.zig (the `Straight` terminal rule).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const fan_mod = @import("fan.zig");
const Straight = @import("routing_polyline.zig").Straight;
const Fan = fan_mod.Fan;
const ChildRole = fan_mod.ChildRole;

/// Emit the dodged-descent point sequence shared by the grid fan-OUT comb
/// and the single-row source drop: jog sideways in the gap line just past
/// the source, descend the corridor column, rejoin the rail.
fn emitDodgedDescent(
    a: std.mem.Allocator,
    pts: *std.ArrayListUnmanaged(sketch.Point),
    sx: i32,
    tx: i32,
    jog_y: i32,
    rail_y: i32,
    corridor: i32,
) error{OutOfMemory}!void {
    try pts.append(a, .{ .x = sx, .y = jog_y });
    if (corridor != sx) try pts.append(a, .{ .x = corridor, .y = jog_y });
    if (rail_y != jog_y) try pts.append(a, .{ .x = corridor, .y = rail_y });
    if (tx != corridor) try pts.append(a, .{ .x = tx, .y = rail_y });
}

/// Move the end of the rail run — the last point, at the target column on
/// row `rail_y` — to `corridor`. When the run already travels along
/// `rail_y`, the last waypoint is replaced (or dropped, when the run's
/// earlier point already sits at the corridor column); when the route
/// reached `rail_y` by a vertical drop at the target column, the run to the
/// corridor is a new horizontal leg. Either way the route never revisits a
/// cell and never takes a diagonal step.
fn endRailRunAt(
    a: std.mem.Allocator,
    pts: *std.ArrayListUnmanaged(sketch.Point),
    corridor: i32,
    rail_y: i32,
) error{OutOfMemory}!void {
    const n = pts.items.len;
    const prev = pts.items[n - 2];
    if (prev.y != rail_y) {
        try pts.append(a, .{ .x = corridor, .y = rail_y });
    } else if (prev.x == corridor) {
        _ = pts.pop();
    } else {
        pts.items[n - 1] = .{ .x = corridor, .y = rail_y };
    }
}

/// Build the polyline for a single fan peer edge. `dir` must be `.TD` or
/// `.BT` (LR/RL fans unsupported). For fan-OUT the polyline runs
/// pivot→peer; for fan-IN it runs peer→pivot. In both cases the polyline
/// goes from the actual edge's source perimeter to its target perimeter.
pub fn buildPolylineAt(
    a: std.mem.Allocator,
    dir: sg.Direction,
    fan: Fan,
    pivot_p: sketch.NodePlacement,
    peer_p: sketch.NodePlacement,
    source_port: sketch.Port,
    target_port: sketch.Port,
    role: ChildRole,
    member_lane: u32,
    rail_lift: u32,
    /// The row of the jog a dodge under the source takes (the ledger's);
    /// null jogs in the first row under the source.
    dodge_y: ?i32,
    placements: []const sketch.NodePlacement,
    straight: Straight,
) error{OutOfMemory}![]sketch.Point {
    // A decorated source keeps its departure cell straight (the head sits
    // there), so every source-side jog or clamp lands one row further out.
    // @guarded-by: fan_polyline_test.zig "a decorated source's lane clamp and dodge jog stay out of the departure cell"
    const off_source: i32 = if (straight.from) 2 else 1;
    const source_p = if (fan.direction == .out) pivot_p else peer_p;
    const target_p = if (fan.direction == .out) peer_p else pivot_p;
    const south_flow = (dir == .TD);
    const source_point = portPoint(source_p, source_port);
    const target_point = portPoint(target_p, target_port);
    const sx = source_point.x;
    const tx = target_point.x;
    // `member_lane` is the ledger's row plus one: lane 0 is the base row,
    // lane k the rail row k-1 — the row `fan_rail.build` paints for row k-1.
    const lane: i32 = @intCast(member_lane);

    if (fan.direction == .out and fan.rows > 1 and south_flow) {
        const child_top = peer_p.rect.y;
        const src_bot = source_point.y;
        // Rail sits two rows above the child top so the descent renders a clean ▼ (`wrapWideFanOut`'s row_step reserves the headroom); a first-row peer's rail rises with the row the ledger gave it in the pivot's gap, never past the pivot. @guarded-by: fan_polyline_test.zig "grid fan-OUT rail sits exactly 2 rows above the child top (clean descent, not a corner-collision)"
        const rail = @max(child_top - 2 - lane, src_bot + off_source);
        var gpts: std.ArrayListUnmanaged(sketch.Point) = .empty;
        try gpts.append(a, .{ .x = sx, .y = src_bot });
        // Pivot-column descent for a row-≥2 child may pass through an earlier row's sibling box; dodge to a touch-free column. @guarded-by: fan_polyline_test.zig "grid fan-OUT rail dodges a sibling box stacked in an earlier grid row"
        if (sketch.columnTouchesAny(sx, src_bot + 1, rail, placements, source_p.id, target_p.id)) {
            const jog_y = @max(dodge_y orelse src_bot + off_source, src_bot + off_source);
            const corridor = sketch.clearLine(false, tx, jog_y, rail, placements, source_p.id, target_p.id, .{});
            try emitDodgedDescent(a, &gpts, sx, tx, jog_y, rail, corridor);
        } else {
            try gpts.append(a, .{ .x = sx, .y = rail });
            if (tx != sx) try gpts.append(a, .{ .x = tx, .y = rail });
        }
        try gpts.append(a, .{ .x = tx, .y = child_top });
        return try gpts.toOwnedSlice(a);
    }

    if (fan.direction == .in and fan.rows > 1 and south_flow) {
        const source_bottom = source_point.y;
        const rail = source_bottom + 2;
        const target_top = target_point.y;
        var gpts: std.ArrayListUnmanaged(sketch.Point) = .empty;
        try gpts.append(a, .{ .x = sx, .y = source_bottom });
        try gpts.append(a, .{ .x = sx, .y = rail });
        // Mirror of the fan-OUT grid dodge: dodges the rail through a source box stacked in a LOWER grid row via a touch-free column. @guarded-by: fan_polyline_test.zig "grid fan-IN rail dodges a source stacked in a lower grid row at the shared target column"
        if (sketch.columnTouchesAny(tx, rail, target_top - 1, placements, source_p.id, target_p.id)) {
            const land_y = target_top - 2;
            const corridor = sketch.clearLine(false, tx, rail, land_y, placements, source_p.id, target_p.id, .{});
            if (corridor != sx) try gpts.append(a, .{ .x = corridor, .y = rail });
            if (land_y != rail) try gpts.append(a, .{ .x = corridor, .y = land_y });
            if (tx != corridor) try gpts.append(a, .{ .x = tx, .y = land_y });
        } else {
            if (tx != sx) try gpts.append(a, .{ .x = tx, .y = rail });
        }
        try gpts.append(a, .{ .x = tx, .y = target_top });
        return try gpts.toOwnedSlice(a);
    }
    const s_peri = source_point.y;
    const t_peri = target_point.y;
    // Rail row: two cells "inside" the gap from the target perimeter at lane
    // 0, one more per lane. At lane 1 in a three-row gap the rail sits one
    // row below the source (t_peri-3 == s_peri+1); a lane-0 run bends on
    // the base cell and feeds its head from a corner.
    // `rail_lift` pulls the rail further toward the source perimeter so it doesn't fuse with a cluster's frame-border row when the descent crosses into a cluster. @guarded-by: fan_polyline_test.zig "rail_lift moves the single-row rail away from the cluster frame-border row instead of fusing with it"
    const lift: i32 = @intCast(rail_lift);
    var rail_y: i32 = if (south_flow) t_peri - 2 - lift - lane else t_peri + 2 + lift + lane;
    // A rail belongs to the GAP it crosses. `routing.zig` walks the lane up
    // until the polyline clears, and a gap holds only so many lanes: past that
    // the raw arithmetic keeps marching over the source perimeter, through the
    // source's own box and off the top of the canvas — where nothing is drawn,
    // so the clearance test happily accepts it and the rasterizer then clips
    // the run into severed ink with a dead-end terminal. Clamping to the
    // innermost row still inside the gap makes every over-budget lane say the
    // same unclearable thing, so the escalation reaches the designed
    // outside-detour fallback instead of inventing a path above the diagram.
    // @guarded-by: fan_polyline_test.zig "a lane past the gap's capacity clamps to the innermost in-gap row instead of climbing over the source"
    rail_y = if (south_flow) @max(rail_y, s_peri + off_source) else @min(rail_y, s_peri - off_source);
    // Labeled fan-OUT: raise the rail to the top of the label band the row
    // ledger claimed for it — the same row `fan_rail.build` paints — so each
    // member's PRIVATE final descent is 4 cells long — flank, on-run label
    // row, flank, arrowhead — the DECORATED sandwich raster/labels_onrun.zig
    // interrupts (FLANKED-RESUMPTION RULE refuses an arrowhead as a flank, so
    // the head needs its own cell). The band replaces the one base cell, so
    // the rise is two rows. Applied only when the raised rail still clears
    // the source perimeter, so a tighter-than-claimed gap keeps the classic
    // geometry and the label falls back to the ordinary ladder. Fan-IN needs
    // no rail move: its private ink is the source-side descent, which the
    // widened gap stretches by itself.
    // @guarded-by: fan_polyline_test.zig "labeled fan-OUT rail rises to the rail's labeled row for a 4-cell private descent; unlabeled stays put"
    if (fan.direction == .out and fan.labeled and south_flow) {
        const raised = rail_y - @as(i32, @intCast(fan_mod.LABEL_RUN_EXTRA_ROWS - 1));
        if (raised > s_peri) rail_y = raised;
    }

    var pts: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try pts.append(a, .{ .x = sx, .y = s_peri });
    switch (role) {
        .center => {},
        .leftmost, .rightmost, .middle => {
            // A fan whose peers sit 2+ layers away needs this dodge (same discipline as the grid combs above) since a direct column drop would slice an intermediate box. (Only TD reaches fan routing: BT is canonicalized to TD before layout, and LR/RL fans are not detected — no direction gate needed.) @guarded-by: fan_polyline_test.zig "single-row fan spanning 2+ layers dodges an intermediate box instead of slicing it"
            if (sketch.columnTouchesAny(sx, s_peri + 1, rail_y, placements, source_p.id, target_p.id)) {
                const jog_y = @max(dodge_y orelse s_peri + off_source, s_peri + off_source);
                const corridor = sketch.clearLine(false, sx, jog_y, rail_y, placements, source_p.id, target_p.id, .{ .margin = true });
                try emitDodgedDescent(a, &pts, sx, tx, jog_y, rail_y, corridor);
            } else {
                try pts.append(a, .{ .x = sx, .y = rail_y });
                if (tx != sx) {
                    try pts.append(a, .{ .x = tx, .y = rail_y });
                }
            }
            const land_y = t_peri - 2;
            if (land_y > rail_y and
                sketch.columnTouchesAny(tx, rail_y + 1, t_peri - 1, placements, source_p.id, target_p.id))
            {
                const corridor = sketch.clearLine(false, tx, rail_y, land_y, placements, source_p.id, target_p.id, .{ .margin = true });
                if (corridor != tx) {
                    // The rail run ENDS at the corridor column: the waypoint
                    // at the target column is retracted, not extended past.
                    // Appending the corridor after it sent the run to the
                    // target column and back, and a route that visits a
                    // cell twice ships a tee no second edge joins and a
                    // stub that stops in open space.
                    // @guarded-by: fan_polyline_test.zig "the target-side corridor ends the rail run at the corridor column; the route visits each cell once"
                    try endRailRunAt(a, &pts, corridor, rail_y);
                    try pts.append(a, .{ .x = corridor, .y = land_y });
                    try pts.append(a, .{ .x = tx, .y = land_y });
                }
            }
        },
    }
    try pts.append(a, .{ .x = tx, .y = t_peri });
    return try pts.toOwnedSlice(a);
}

pub fn portPoint(p: sketch.NodePlacement, port: sketch.Port) sketch.Point {
    const offset: i32 = @intCast(port.offset);
    return switch (port.side) {
        .north => .{ .x = p.rect.x + offset, .y = p.rect.y },
        .south => .{ .x = p.rect.x + offset, .y = p.rect.bottom() - 1 },
        .west => .{ .x = p.rect.x, .y = p.rect.y + offset },
        .east => .{ .x = p.rect.right() - 1, .y = p.rect.y + offset },
    };
}

/// Center column of a placement (shared with fan_rail.zig).
pub fn midX(p: sketch.NodePlacement) i32 {
    return p.rect.x + @divTrunc(@as(i32, @intCast(p.rect.w)), 2);
}

pub fn portFromSource(dir: sg.Direction, source_p: sketch.NodePlacement) sketch.Port {
    const side: sketch.Dir4 = switch (dir) {
        .TD => .south,
        .BT => .north,
        .LR => .east,
        .RL => .west,
    };
    const offset: u32 = switch (side) {
        .north, .south => @divTrunc(source_p.rect.w, 2),
        .east, .west => @divTrunc(source_p.rect.h, 2),
    };
    return .{ .node = source_p.id, .side = side, .offset = offset };
}

pub fn portToTarget(dir: sg.Direction, target_p: sketch.NodePlacement) sketch.Port {
    const side: sketch.Dir4 = switch (dir) {
        .TD => .north,
        .BT => .south,
        .LR => .west,
        .RL => .east,
    };
    const offset: u32 = switch (side) {
        .north, .south => @divTrunc(target_p.rect.w, 2),
        .east, .west => @divTrunc(target_p.rect.h, 2),
    };
    return .{ .node = target_p.id, .side = side, .offset = offset };
}

//! Fan peer-edge polyline construction + port helpers, split from
//! `fan.zig` (500-line cap). `buildPolyline` routes one fan member edge
//! via grid combs (rows > 1) or the single-row rail path, dodging via
//! sketch.zig's touch-semantics helpers whenever a foreign box would
//! otherwise block a run.
//!
//! Imports (layout zone): std + sem_graph + sketch + fan.zig (types).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const fan_mod = @import("fan.zig");
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
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]sketch.Point {
    const source_p = if (fan.direction == .out) pivot_p else peer_p;
    const target_p = if (fan.direction == .out) peer_p else pivot_p;
    const south_flow = (dir == .TD);
    const source_point = portPoint(source_p, source_port);
    const target_point = portPoint(target_p, target_port);
    const sx = source_point.x;
    const tx = target_point.x;

    // Grid fan-OUT (wrapped wide fan): the children are stacked across
    // multiple rows. Route each child off a shared vertical trunk that
    // descends the pivot column: down to the gap row directly above the
    // child's row, then across to the child column, then into the child
    // top. Overlapping trunk segments merge in the rasterizer, so this
    // yields a clean comb with one horizontal rail per grid row.
    if (fan.direction == .out and fan.rows > 1 and south_flow) {
        const child_top = peer_p.rect.y;
        // Rail sits two rows above the child top so the descent renders a clean ▼ (`wrapWideFanOut`'s row_step reserves the headroom). guarded-by: fan_polyline_test.zig "grid fan-OUT rail sits exactly 2 rows above the child top (clean descent, not a corner-collision)"
        const rail = child_top - 2;
        const src_bot = source_point.y;
        var gpts: std.ArrayListUnmanaged(sketch.Point) = .empty;
        try gpts.append(a, .{ .x = sx, .y = src_bot });
        // Pivot-column descent for a row-≥2 child may pass through an earlier row's sibling box; dodge to a touch-free column. guarded-by: fan_polyline_test.zig "grid fan-OUT trunk dodges a sibling box stacked in an earlier grid row"
        if (sketch.columnTouchesAny(sx, src_bot + 1, rail, placements, source_p.id, target_p.id)) {
            const jog_y = src_bot + 1;
            const corridor = sketch.clearLine(false, tx, jog_y, rail, placements, source_p.id, target_p.id, .{});
            try emitDodgedDescent(a, &gpts, sx, tx, jog_y, rail, corridor);
        } else {
            try gpts.append(a, .{ .x = sx, .y = rail });
            if (tx != sx) try gpts.append(a, .{ .x = tx, .y = rail });
        }
        try gpts.append(a, .{ .x = tx, .y = child_top });
        return try gpts.toOwnedSlice(a);
    }

    // Grid fan-IN (wrapped wide fan): the SOURCES are stacked across multiple
    // rows above the shared target. Mirror of the fan-OUT grid comb: each
    // source drops from its bottom to a short horizontal rail two rows below
    // its own row, then runs across to the TARGET column, then descends a
    // shared trunk into the target top. The trunk segments at the target
    // column (one per source row) merge in the rasterizer into a single
    // descending trunk — a clean reverse comb that keeps every source feeding
    // the one target without re-attaching to a sibling source.
    if (fan.direction == .in and fan.rows > 1 and south_flow) {
        const source_bottom = source_point.y;
        const rail = source_bottom + 2;
        const target_top = target_point.y;
        var gpts: std.ArrayListUnmanaged(sketch.Point) = .empty;
        try gpts.append(a, .{ .x = sx, .y = source_bottom });
        try gpts.append(a, .{ .x = sx, .y = rail });
        // Mirror of the fan-OUT grid dodge: dodges the trunk through a source box stacked in a LOWER grid row via a touch-free column. guarded-by: fan_polyline_test.zig "grid fan-IN trunk dodges a source stacked in a lower grid row at the shared target column"
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
    // Rail row: two cells "inside" the gap from the target perimeter.
    // For fan-OUT this places the rail one row below the source (because
    // the gap is exactly 2 wide + 1 reserved = 3, and t_peri-2 == s_peri+1).
    // For fan-IN it stays one row above the target perimeter.
    // `rail_lift` pulls the rail further toward the source perimeter so it doesn't fuse with a cluster's frame-border row when the descent crosses into a cluster. guarded-by: fan_polyline_test.zig "rail_lift moves the single-row rail away from the cluster frame-border row instead of fusing with it"
    const lift: i32 = @intCast(rail_lift);
    // Lane separation (fan_lanes): an incomplete-bipartite fan is lifted to its
    // own rail row so its rail no longer fuses with a neighbour's into a
    // fabricating bus. lane 0 == the classic shared row (byte-identical).
    const lane: i32 = @intCast(@max(fan.lane, member_lane));
    const rail_y: i32 = if (south_flow) t_peri - 2 - lift - lane else t_peri + 2 + lift + lane;

    var pts: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try pts.append(a, .{ .x = sx, .y = s_peri });
    switch (role) {
        .center => {
            // Straight descent: source column == target column.
        },
        .leftmost, .rightmost, .middle => {
            // A fan whose peers sit 2+ layers away needs this dodge (same discipline as the grid combs above) since a direct column drop would slice an intermediate box. (Only TD reaches fan routing: BT is canonicalized to TD before layout, and LR/RL fans are not detected — no direction gate needed.) guarded-by: fan_polyline_test.zig "single-row fan spanning 2+ layers dodges an intermediate box instead of slicing it"
            if (sketch.columnTouchesAny(sx, s_peri + 1, rail_y, placements, source_p.id, target_p.id)) {
                const jog_y = s_peri + 1;
                const corridor = sketch.clearLine(false, sx, jog_y, rail_y, placements, source_p.id, target_p.id, .{ .margin = true });
                try emitDodgedDescent(a, &pts, sx, tx, jog_y, rail_y, corridor);
            } else {
                try pts.append(a, .{ .x = sx, .y = rail_y });
                if (tx != sx) {
                    try pts.append(a, .{ .x = tx, .y = rail_y });
                }
            }
            const land_y = t_peri - 2; // >= 1 row of straight final descent
            if (land_y > rail_y and
                sketch.columnTouchesAny(tx, rail_y + 1, t_peri - 1, placements, source_p.id, target_p.id))
            {
                const corridor = sketch.clearLine(false, tx, rail_y, land_y, placements, source_p.id, target_p.id, .{ .margin = true });
                if (corridor != tx) {
                    try pts.append(a, .{ .x = corridor, .y = rail_y });
                    try pts.append(a, .{ .x = corridor, .y = land_y });
                    try pts.append(a, .{ .x = tx, .y = land_y });
                }
            }
        },
    }
    try pts.append(a, .{ .x = tx, .y = t_peri });
    return try pts.toOwnedSlice(a);
}

pub fn buildPolyline(
    a: std.mem.Allocator,
    dir: sg.Direction,
    fan: Fan,
    pivot_p: sketch.NodePlacement,
    peer_p: sketch.NodePlacement,
    role: ChildRole,
    rail_lift: u32,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]sketch.Point {
    const source = if (fan.direction == .out) pivot_p else peer_p;
    const target = if (fan.direction == .out) peer_p else pivot_p;
    return buildPolylineAt(a, dir, fan, pivot_p, peer_p, portFromSource(dir, source), portToTarget(dir, target), role, 0, rail_lift, placements);
}

fn portPoint(p: sketch.NodePlacement, port: sketch.Port) sketch.Point {
    const offset: i32 = @intCast(port.offset);
    return switch (port.side) {
        .north => .{ .x = p.rect.x + offset, .y = p.rect.y },
        .south => .{ .x = p.rect.x + offset, .y = p.rect.bottom() - 1 },
        .west => .{ .x = p.rect.x, .y = p.rect.y + offset },
        .east => .{ .x = p.rect.right() - 1, .y = p.rect.y + offset },
    };
}

/// Center column of a placement (shared with fan_busbar.zig).
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

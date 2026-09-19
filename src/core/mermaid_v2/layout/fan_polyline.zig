const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const fan_mod = @import("fan.zig");
const Straight = @import("routing_polyline.zig").Straight;
const Fan = fan_mod.Fan;
const ChildRole = fan_mod.ChildRole;

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
    dodge_y: ?i32,
    placements: []const sketch.NodePlacement,
    straight: Straight,
) error{OutOfMemory}![]sketch.Point {
    // @guarded-by: fan_polyline_test.zig "a decorated source's lane clamp and dodge jog stay out of the departure cell"
    const off_source: i32 = if (straight.from) 2 else 1;
    const source_p = if (fan.direction == .out) pivot_p else peer_p;
    const target_p = if (fan.direction == .out) peer_p else pivot_p;
    const south_flow = (dir == .TD);
    const source_point = portPoint(source_p, source_port);
    const target_point = portPoint(target_p, target_port);
    const sx = source_point.x;
    const tx = target_point.x;
    const lane: i32 = @intCast(member_lane);

    if (fan.direction == .out and fan.rows > 1 and south_flow) {
        const child_top = peer_p.rect.y;
        const src_bot = source_point.y;
        // @guarded-by: fan_polyline_test.zig "grid fan-OUT rail sits exactly 2 rows above the child top (clean descent, not a corner-collision)"
        const rail = @max(child_top - 2 - lane, src_bot + off_source);
        var gpts: std.ArrayListUnmanaged(sketch.Point) = .empty;
        try gpts.append(a, .{ .x = sx, .y = src_bot });
        // @guarded-by: fan_polyline_test.zig "grid fan-OUT rail dodges a sibling box stacked in an earlier grid row"
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
        // @guarded-by: fan_polyline_test.zig "grid fan-IN rail dodges a source stacked in a lower grid row at the shared target column"
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
    // @guarded-by: fan_polyline_test.zig "rail_lift moves the single-row rail away from the cluster frame-border row instead of fusing with it"
    const lift: i32 = @intCast(rail_lift);
    var rail_y: i32 = if (south_flow) t_peri - 2 - lift - lane else t_peri + 2 + lift + lane;
    // @guarded-by: fan_polyline_test.zig "a lane past the gap's capacity clamps to the innermost in-gap row instead of climbing over the source"
    rail_y = if (south_flow) @max(rail_y, s_peri + off_source) else @min(rail_y, s_peri - off_source);
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
            // @guarded-by: fan_polyline_test.zig "single-row fan spanning 2+ layers dodges an intermediate box instead of slicing it"
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

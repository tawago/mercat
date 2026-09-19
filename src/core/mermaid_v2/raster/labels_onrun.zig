const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const lw = @import("labels_write.zig");
const aux = @import("aux.zig");
const ink = @import("labels_ink.zig");
const onrun_h = @import("labels_onrun_h.zig");

/// @guarded-by: labels_onrun_h_test.zig "tie order: the longer qualifying stretch is tried first, ties go vertical"
pub fn tryOnRunEdge(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    ep: sketch.EdgePath,
    run: lw.Run,
    sink: aux.Sink,
) bool {
    if (ep.polyline.len < 2) return false;
    const h_len = onrun_h.longestHorizontalInterior(ep.polyline);
    const v_len = longestVerticalInterior(ep.polyline);
    if (h_len > v_len) {
        if (onrun_h.tryOnRunEdgeH(lat, s, ep, run, sink)) return true;
        return tryVerticalEdge(lat, s, ep, run, sink);
    }
    if (tryVerticalEdge(lat, s, ep, run, sink)) return true;
    return onrun_h.tryOnRunEdgeH(lat, s, ep, run, sink);
}

fn longestVerticalInterior(polyline: []const sketch.Point) u32 {
    if (polyline.len < 2) return 0;
    var best: u32 = 0;
    for (polyline[0 .. polyline.len - 1], 0..) |p, i| {
        const q = polyline[i + 1];
        if (p.x != q.x or p.y == q.y) continue;
        const span: u32 = @intCast(@max(p.y, q.y) - @min(p.y, q.y));
        if (span >= 1 and span - 1 > best) best = span - 1;
    }
    return best;
}

fn tryVerticalEdge(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    ep: sketch.EdgePath,
    run: lw.Run,
    sink: aux.Sink,
) bool {
    for (ep.polyline[0 .. ep.polyline.len - 1], 0..) |p, i| {
        const q = ep.polyline[i + 1];
        if (p.x != q.x or p.y == q.y) continue;
        const owner: ink.Owner = .{ .edge_id = ep.id, .polyline = ep.polyline, .seg_a = p, .seg_b = q };
        if (tryRun(lat, s, ep.id, p.x, @min(p.y, q.y) + 1, @max(p.y, q.y) - 1, run, owner, sink)) return true;
    }
    return false;
}

pub fn tryOnRunTap(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    tap: sketch.Tap,
    run: lw.Run,
    sink: aux.Sink,
) bool {
    if (tap.at.x != tap.landing.x or tap.at.y == tap.landing.y) return false;
    const owner: ink.Owner = .{ .edge_id = tap.edge, .polyline = &.{}, .seg_a = tap.at, .seg_b = tap.landing };
    return tryRun(lat, s, tap.edge, tap.at.x, @min(tap.at.y, tap.landing.y) + 1, @max(tap.at.y, tap.landing.y) - 1, run, owner, sink);
}

fn tryRun(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    x: i32,
    y_lo: i32,
    y_hi: i32,
    run: lw.Run,
    owner: ink.Owner,
    sink: aux.Sink,
) bool {
    if (y_lo > y_hi) return false;
    if (run.cell_count == 0) return false;
    const mid: i32 = @divTrunc(y_lo + y_hi, 2);
    var d: i32 = 0;
    while (mid - d >= y_lo or mid + d <= y_hi) : (d += 1) {
        if (mid - d >= y_lo and tryAt(lat, s, edge_id, x, mid - d, run, owner, sink)) return true;
        if (d > 0 and mid + d <= y_hi and tryAt(lat, s, edge_id, x, mid + d, run, owner, sink)) return true;
    }
    return false;
}

fn tryAt(
    lat: *lattice.Lattice,
    s: sketch.Sketch,
    edge_id: u32,
    x: i32,
    row: i32,
    run: lw.Run,
    owner: ink.Owner,
    sink: aux.Sink,
) bool {
    const cell_count = run.cell_count;
    // @guarded-by: labels_onrun_test.zig "OWN-INK RULE: a rail/crossbar cell is never interrupted"
    if (!privateDropperCell(lat, edge_id, x, row)) return false;
    // @guarded-by: labels_onrun_test.zig "OWN-INK RULE: a cell another tap's drop covers is refused"
    if (coveredByOther(s, edge_id, x, row)) return false;
    // @guarded-by: labels_onrun_test.zig "FLANKED-RESUMPTION RULE: an arrowhead is not a flank, so the head-adjacent row is refused"
    if (!runFlankCell(lat, edge_id, x, row - 1)) return false;
    if (!runFlankCell(lat, edge_id, x, row + 1)) return false;

    const cc: i32 = @intCast(cell_count);
    const start_x: i32 = x - @divTrunc(cc - 1, 2);
    if (row < 0 or @as(i64, row) >= lat.height) return false;
    if (start_x < 0) return false;
    const sx: u32 = @intCast(start_x);
    const urow: u32 = @intCast(row);
    if (sx + cell_count > lat.width) return false;

    var i: u32 = 0;
    while (i < cell_count) : (i += 1) {
        const cx: i32 = start_x + @as(i32, @intCast(i));
        if (cx == x) continue;
        switch (lat.atConst(@intCast(cx), urow).occupant) {
            .empty => {},
            else => return false,
        }
    }

    // @guarded-by: labels_onrun_test.zig "foreign ink beside the span still refuses the on-run candidate"
    if (!ink.spanIsolated(lat, owner, start_x, row, cell_count, false)) return false;

    std.debug.assert(privateDropperCell(lat, edge_id, x, row));

    lw.writeRun(lat, sx, urow, run, .{ .kind = .edge, .id = edge_id }, sink);

    return true;
}

fn privateDropperCell(lat: *const lattice.Lattice, edge_id: u32, x: i32, y: i32) bool {
    if (x < 0 or y < 0) return false;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return false;
    const cell = lat.atConst(ux, uy);
    switch (cell.occupant) {
        .edge_segment => |seg| {
            if (seg.edge != edge_id) return false;
            switch (seg.role) {
                .fan_out_dropper, .fan_in_dropper => {},
                else => return false,
            }
        },
        else => return false,
    }
    const n = cell.neighbours;
    return n.n and n.s and !n.e and !n.w;
}

fn runFlankCell(lat: *const lattice.Lattice, edge_id: u32, x: i32, y: i32) bool {
    if (x < 0 or y < 0) return false;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return false;
    const cell = lat.atConst(ux, uy);
    switch (cell.occupant) {
        .edge_segment => |seg| {
            if (seg.edge != edge_id) return false;
            switch (seg.role) {
                .fan_out_rail, .fan_in_rail => return false,
                else => {},
            }
        },
        else => return false,
    }
    const n = cell.neighbours;
    return n.n and n.s and !n.e and !n.w;
}

pub fn coveredByOther(s: sketch.Sketch, edge_id: u32, x: i32, y: i32) bool {
    for (s.edges) |other| {
        if (other.id == edge_id) continue;
        if (other.polyline.len < 2) continue;
        for (other.polyline[0 .. other.polyline.len - 1], 0..) |p, i| {
            if (onSeg(p, other.polyline[i + 1], x, y)) return true;
        }
    }
    for (s.rails) |rail| {
        for (rail.stem[0 .. rail.stem.len - 1], 0..) |p, i| {
            if (onSeg(p, rail.stem[i + 1], x, y)) return true;
        }
        if (onSeg(rail.crossbar[0], rail.crossbar[1], x, y)) return true;
        for (rail.taps) |tap| {
            if (tap.edge == edge_id) continue;
            if (onSeg(tap.at, tap.landing, x, y)) return true;
        }
    }
    return false;
}

fn onSeg(a: sketch.Point, b: sketch.Point, x: i32, y: i32) bool {
    if (a.x != b.x and a.y != b.y) return false;
    return x >= @min(a.x, b.x) and x <= @max(a.x, b.x) and
        y >= @min(a.y, b.y) and y <= @max(a.y, b.y);
}

test {
    _ = @import("labels_onrun_test.zig");
}

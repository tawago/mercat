const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const rp = @import("routing_polyline.zig");
const lanes = @import("../base/lanes.zig");

pub const LaneClaim = lanes.LaneClaim;
pub const assign = lanes.assign;

fn inflateCross(horizontal: bool, r: sketch.Rect, pad: i32) sketch.Rect {
    const pad2: i32 = 2 * (pad + 1);
    if (horizontal) {
        const h_i: i32 = @as(i32, @intCast(r.h)) + pad2;
        return .{
            .x = r.x,
            .y = r.y - (pad + 1),
            .w = r.w,
            .h = @intCast(h_i),
        };
    } else {
        const w_i: i32 = @as(i32, @intCast(r.w)) + pad2;
        return .{
            .x = r.x - (pad + 1),
            .y = r.y,
            .w = @intCast(w_i),
            .h = r.h,
        };
    }
}

pub fn runClear(
    horizontal: bool,
    c: i32,
    lo: i32,
    hi: i32,
    placements: []const sketch.NodePlacement,
    from_id: sg.NodeId,
    to_id: sg.NodeId,
    pad: i32,
) bool {
    for (placements) |p| {
        if (p.id == from_id or p.id == to_id) continue;
        const inflated = inflateCross(horizontal, p.rect, pad);
        const intrudes = if (horizontal)
            rp.rowIntrudesRect(c, lo, hi, inflated)
        else
            rp.columnIntrudesRect(c, lo, hi, inflated);
        if (intrudes) return false;
    }
    return true;
}

pub fn clearRunBase(
    horizontal: bool,
    placements: []const sketch.NodePlacement,
    from_id: sg.NodeId,
    to_id: sg.NodeId,
    pad: i32,
) ?i32 {
    var src: ?sketch.NodePlacement = null;
    var dst: ?sketch.NodePlacement = null;
    for (placements) |p| {
        if (p.id == from_id) src = p;
        if (p.id == to_id) dst = p;
    }
    const s = src orelse return null;
    const d = dst orelse return null;

    const sr = s.rect;
    const dr = d.rect;
    const sw_i: i32 = @intCast(sr.w);
    const sh_i: i32 = @intCast(sr.h);
    const dw_i: i32 = @intCast(dr.w);
    const dh_i: i32 = @intCast(dr.h);

    const lo: i32 = if (horizontal)
        @min(sr.x + @divTrunc(sw_i, 2), dr.x + @divTrunc(dw_i, 2))
    else
        @min(sr.y + @divTrunc(sh_i, 2), dr.y + @divTrunc(dh_i, 2));
    const hi: i32 = if (horizontal)
        @max(sr.x + @divTrunc(sw_i, 2), dr.x + @divTrunc(dw_i, 2))
    else
        @max(sr.y + @divTrunc(sh_i, 2), dr.y + @divTrunc(dh_i, 2));

    const start: i32 = if (horizontal)
        @max(sr.bottom(), dr.bottom()) + pad
    else
        @max(sr.right(), dr.right()) + pad;

    var delta: i32 = 0;
    while (delta < 4096) : (delta += 1) {
        const c = start + delta;
        if (runClear(horizontal, c, lo, hi, placements, from_id, to_id, pad)) {
            return c;
        }
    }
    return start;
}

test {
    _ = @import("lanes_test.zig");
}

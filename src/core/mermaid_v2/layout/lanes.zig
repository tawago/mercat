//! Lane-packing primitives for fitting several parallel runs (e.g. back-edge
//! rails, bridge tracks) into a shared cross-axis "gutter". Re-exports the
//! pure interval-packer core (`Demand`, `assign`, `Gutter`, `gutter`) from
//! `../lanes.zig`, so cluster/ can use it too (the linter forbids
//! cluster/ → layout/ imports); adds the placement-aware obstacle search
//! (`runClear`, `clearRunBase`), which needs sketch geometry and so stays
//! here. Axis-parameterized via `horizontal`; makes no post-`applyDirection`
//! assumptions, so usable both pre- and post-direction-transform.
//!
//! Imports (layout/ zone): `std`, `../lanes.zig`, `../sem_graph.zig`,
//! `../sketch.zig`, `routing_polyline.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const rp = @import("routing_polyline.zig");
const lanes = @import("../base/lanes.zig");

pub const Demand = lanes.Demand;
pub const Assignment = lanes.Assignment;
pub const assign = lanes.assign;
pub const Gutter = lanes.Gutter;
pub const gutter = lanes.gutter;

/// Inflate `r` by `pad + 1` on the CROSS axis only (the axis the run's
/// position lives on), leaving the flow axis untouched. With the inflation,
/// the first cross position a run can occupy clear of `r` equals
/// `r.far_edge + pad`.
///
/// `horizontal` true  → run is a y-row; cross axis = y (inflate .y/.h).
/// `horizontal` false → run is an x-column; cross axis = x (inflate .x/.w).
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

/// True iff a straight run at cross position `c` over the flow interval
/// `[lo, hi]` pierces the interior of any node box — EXCLUDING the two
/// endpoint boxes — after cross-axis inflation by `pad + 1`.
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
        const pierces = if (horizontal)
            rp.rowPiercesRect(c, lo, hi, inflated)
        else
            rp.columnPiercesRect(c, lo, hi, inflated);
        if (pierces) return false;
    }
    return true;
}

/// Search outward (increasing cross coordinate) from just past the two
/// endpoints' own far edge for the first clear run cross-position. The run's
/// flow interval spans the two endpoints' centre lines. Returns null if
/// either endpoint placement is missing (caller falls back to its own
/// conservative base).
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

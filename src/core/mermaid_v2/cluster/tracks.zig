//! cluster/tracks.zig — track discipline for cross-border bridge jogs.
//!
//! BORDER CLEARANCE: a jog must never run along a drawn cluster-frame
//! border (the corner glyph would fuse into it); an offending coordinate
//! is displaced outward on a bounded search (at most 4096 steps). An
//! expired search SURRENDERS: the last coordinate is returned even though
//! it may still sit on a border, and each surrender is counted through the
//! caller's `expired` out-counter (surfaced as the Sketch diagnostic
//! `track_clearance_expired`), so a surrendered coordinate is always
//! distinguishable from a cleared one. Synthetic frames never constrain.
//! TRACK SEPARATION: same-side bridges whose jog spans overlap pack into
//! distinct tracks (lanes.assign, stack_gap 1); untangled requests
//! keep their preferred, border-cleared coordinate. PURE DATA: rects/coords
//! in, resolved coords out; imports std, lanes, sketch.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lanes = @import("../base/lanes.zig");

/// One jog request within a same-side group: the cross-axis interval the jog
/// segment spans (inclusive; x-range for a row jog, y-range for a column
/// jog) and the preferred jog coordinate the plain elbow formula produced.
pub const Req = struct {
    span_lo: i32,
    span_hi: i32,
    pref: i32,
};

/// Direction that moves a jog AWAY from the box being entered: entering a
/// north port ⇒ the jog sits above the box ⇒ outward is -y; and so on.
pub fn outwardSign(entry: sketch.Dir4) i32 {
    return switch (entry) {
        .north, .west => -1,
        .south, .east => 1,
    };
}

/// A north/south entry jogs along a ROW (the coordinate is a y); an
/// east/west entry jogs along a COLUMN (the coordinate is an x).
fn isRowJog(entry: sketch.Dir4) bool {
    return entry == .north or entry == .south;
}

/// True iff a jog at `coord` spanning `[lo, hi]` on the cross axis runs
/// ALONG the border row/column of any drawn (non-synthetic) cluster frame.
/// Crossing a PERPENDICULAR border is fine — the raster makes a clean
/// T-junction; only coincident-parallel runs fuse.
pub fn onFrameBorder(
    row_jog: bool,
    coord: i32,
    lo: i32,
    hi: i32,
    clusters: []const sketch.ClusterFrame,
) bool {
    for (clusters) |c| {
        if (c.synthetic) continue;
        if (c.rect.w == 0 or c.rect.h == 0) continue;
        if (row_jog) {
            const top = c.rect.y;
            const bot = c.rect.bottom() - 1;
            if ((coord == top or coord == bot) and lo < c.rect.right() and hi >= c.rect.x) return true;
        } else {
            const left = c.rect.x;
            const rgt = c.rect.right() - 1;
            if ((coord == left or coord == rgt) and lo < c.rect.bottom() and hi >= c.rect.y) return true;
        }
    }
    return false;
}

/// Rail-ink obstacles for jog placement: `heads` are arrowhead CELLS
/// (foreign ink there is an ink-attribution transit violation, perpendicular crossing
/// included); `runs` are the rail's straight strokes (crossbar, stem,
/// droppers), which — like frame borders — forbid only COLLINEAR jog runs;
/// a perpendicular crossing rasterizes as a legal crossing.
pub const Obstacles = struct {
    heads: []const sketch.Point = &.{},
    runs: []const [2]sketch.Point = &.{},

    pub fn blocks(o: Obstacles, row_jog: bool, coord: i32, lo: i32, hi: i32) bool {
        for (o.heads) |h| {
            if (row_jog) {
                if (h.y == coord and h.x >= lo and h.x <= hi) return true;
            } else {
                if (h.x == coord and h.y >= lo and h.y <= hi) return true;
            }
        }
        for (o.runs) |s| {
            const horizontal = s[0].y == s[1].y;
            if (row_jog and horizontal) {
                if (s[0].y == coord and @min(s[0].x, s[1].x) <= hi and @max(s[0].x, s[1].x) >= lo) return true;
            } else if (!row_jog and !horizontal) {
                if (s[0].x == coord and @min(s[0].y, s[1].y) <= hi and @max(s[0].y, s[1].y) >= lo) return true;
            }
        }
        return false;
    }

    /// True iff `p` lies on a head cell or any run stroke.
    pub fn covers(o: Obstacles, p: sketch.Point) bool {
        for (o.heads) |h| {
            if (h.x == p.x and h.y == p.y) return true;
        }
        for (o.runs) |s| {
            if (@min(s[0].x, s[1].x) <= p.x and p.x <= @max(s[0].x, s[1].x) and
                @min(s[0].y, s[1].y) <= p.y and p.y <= @max(s[0].y, s[1].y)) return true;
        }
        return false;
    }
};

/// Displace `coord` outward (per `entry`) until the jog segment no longer
/// runs along a drawn frame border or through rail-ink obstacles.
/// On guard expiry the last coordinate is surrendered (possibly still on a
/// border) and `expired`, when given, is incremented once.
pub fn clearOfBorders(
    entry: sketch.Dir4,
    coord: i32,
    lo: i32,
    hi: i32,
    clusters: []const sketch.ClusterFrame,
    obstacles: Obstacles,
    expired: ?*u32,
) i32 {
    const sign = outwardSign(entry);
    const row = isRowJog(entry);
    var c = coord;
    var guard: u32 = 0;
    while (onFrameBorder(row, c, lo, hi, clusters) or obstacles.blocks(row, c, lo, hi)) {
        if (guard == 4096) {
            if (expired) |e| e.* += 1;
            break;
        }
        guard += 1;
        c += sign;
    }
    return c;
}

const SortCtx = struct {
    reqs: []const Req,
    sign: i32,

    fn lessThan(ctx: @This(), a: usize, b: usize) bool {
        return ctx.sign * ctx.reqs[a].pref < ctx.sign * ctx.reqs[b].pref;
    }
};

/// Resolve one same-side group of jog requests to final jog coordinates
/// (parallel to `reqs`, arena-owned). Overlapping-span requests are packed
/// into distinct tracks innermost-first; every resolved coordinate is
/// displaced off drawn frame borders, cascading so tracks stay distinct.
pub fn resolve(
    arena: std.mem.Allocator,
    reqs: []const Req,
    entry: sketch.Dir4,
    clusters: []const sketch.ClusterFrame,
    obstacles: Obstacles,
    expired: ?*u32,
) error{OutOfMemory}![]i32 {
    const out = try arena.alloc(i32, reqs.len);
    const sign = outwardSign(entry);
    const row = isRowJog(entry);

    const part = try arena.alloc(bool, reqs.len);
    @memset(part, false);
    for (reqs, 0..) |ra, i| {
        for (reqs[i + 1 ..], i + 1..) |rb, j| {
            if (ra.span_lo <= rb.span_hi and rb.span_lo <= ra.span_hi) {
                part[i] = true;
                part[j] = true;
            }
        }
    }

    // Requests with no overlapping partner keep their preferred jog line; they only
    // need displacing off any drawn frame border (no track separation to negotiate).
    // guarded-by: bridges_test.zig "vertical bridge jogs when x-misaligned, final segment vertical"
    for (reqs, 0..) |r, i| {
        if (!part[i]) out[i] = clearOfBorders(entry, r.pref, r.span_lo, r.span_hi, clusters, obstacles, expired);
    }

    // Entangled requests: sort innermost-preference first (assign packs in
    // the given order), build outward-unit demands, pack with stack_gap 1.
    var order: std.ArrayListUnmanaged(usize) = .empty;
    for (part, 0..) |p, i| {
        if (p) try order.append(arena, i);
    }
    if (order.items.len == 0) return out;
    std.mem.sort(usize, order.items, SortCtx{ .reqs = reqs, .sign = sign }, SortCtx.lessThan);

    const demands = try arena.alloc(lanes.LaneClaim, order.items.len);
    for (order.items, 0..) |ri, k| {
        const r = reqs[ri];
        demands[k] = .{
            .lo = @intCast(@max(0, r.span_lo)),
            .hi = @intCast(@max(0, r.span_hi)),
            .base = sign * r.pref, // outward units: larger = further from target
        };
    }
    const asg = try lanes.assign(arena, demands, 1);

    const nlanes = asg.lane_pos.len;
    const lane_lo = try arena.alloc(i32, nlanes);
    const lane_hi = try arena.alloc(i32, nlanes);
    @memset(lane_lo, std.math.maxInt(i32));
    @memset(lane_hi, std.math.minInt(i32));
    for (order.items, 0..) |ri, k| {
        const li = asg.lane_of[k];
        lane_lo[li] = @min(lane_lo[li], reqs[ri].span_lo);
        lane_hi[li] = @max(lane_hi[li], reqs[ri].span_hi);
    }

    // guarded-by: bridges_test.zig "two same-side bridges with overlapping spans get distinct tracks"
    var prev: i32 = std.math.minInt(i32);
    for (asg.lane_pos, 0..) |*pos, li| {
        var v = pos.*;
        if (prev != std.math.minInt(i32) and v <= prev) v = prev + 1;
        var guard: u32 = 0;
        while (onFrameBorder(row, sign * v, lane_lo[li], lane_hi[li], clusters) or obstacles.blocks(row, sign * v, lane_lo[li], lane_hi[li])) {
            if (guard == 4096) {
                if (expired) |e| e.* += 1;
                break;
            }
            guard += 1;
            v += 1;
        }
        pos.* = v;
        prev = v;
    }

    for (order.items, 0..) |ri, k| out[ri] = sign * asg.lane_pos[asg.lane_of[k]];
    return out;
}

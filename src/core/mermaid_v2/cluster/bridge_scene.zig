//! cluster/bridge_scene.zig — the merged scene's ink, derived for the
//! bridge router (cap-forced split of bridges.zig). Heads and runs follow
//! the three-relation rule recorded in tracks.Obstacles: heads block any
//! transit, runs block only collinear runs, licensed shares block nothing.

const std = @import("std");
const sketch = @import("../sketch.zig");
const tracks = @import("tracks.zig");
const corridors = @import("corridors.zig");

const Pt = sketch.Point;

/// Sketch-space ink already in the merged scene. Rail heads: the pivot head
/// one step out from `stem[0]` along the stem, each decorated tap's head one
/// step back from its landing — cell-twin of raster/rails.zig
/// pivotHead/tapHead, which stamp exactly these cells. Edge heads sit one
/// step back from a decorated port along the end segment. Runs: crossbars,
/// stem legs, tap droppers, and every polyline leg.
// @guarded-by: bridges_test.zig "sceneObstacles derives the pivot and tap head cells the raster stamps"
pub fn sceneObstacles(
    arena: std.mem.Allocator,
    rails: []const sketch.Rail,
    edge_paths: []const sketch.EdgePath,
) error{OutOfMemory}!tracks.Obstacles {
    var heads: std.ArrayListUnmanaged(Pt) = .empty;
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    for (edge_paths) |e| {
        const n = e.polyline.len;
        if (n >= 2) {
            if (e.arrow_to != .none) {
                if (stepDir(e.polyline[n - 1], e.polyline[n - 2])) |d| try heads.append(arena, stepPt(e.polyline[n - 1], d));
            }
            if (e.arrow_from != .none) {
                if (stepDir(e.polyline[0], e.polyline[1])) |d| try heads.append(arena, stepPt(e.polyline[0], d));
            }
        }
    }
    for (rails) |r| {
        try runs.append(arena, r.crossbar);
        var si: usize = 0;
        while (si + 1 < r.stem.len) : (si += 1) {
            try runs.append(arena, .{ r.stem[si], r.stem[si + 1] });
        }
        if (r.pivot_arrow != .none and r.stem.len >= 2) {
            si = 0;
            while (si + 1 < r.stem.len) : (si += 1) {
                if (stepDir(r.stem[si], r.stem[si + 1])) |d| {
                    try heads.append(arena, stepPt(r.stem[0], d));
                    break;
                }
            }
        }
        for (r.taps) |tap| {
            try runs.append(arena, .{ tap.at, tap.landing });
            if (tap.arrow == .none) continue;
            const d = stepDir(tap.at, tap.landing) orelse continue;
            const first = stepPt(tap.at, d);
            if (first.x == tap.landing.x and first.y == tap.landing.y) continue;
            try heads.append(arena, stepPt(tap.landing, .{ .x = -d.x, .y = -d.y }));
        }
    }
    return .{ .heads = try heads.toOwnedSlice(arena), .runs = try runs.toOwnedSlice(arena) };
}

/// File a routed polyline's ink into a growing scene: every segment as a
/// run, plus the head cell one step back from each decorated end — the same
/// derivation `sceneObstacles` uses for edge paths.
pub fn commitPoly(
    arena: std.mem.Allocator,
    heads: *std.ArrayListUnmanaged(Pt),
    runs: *std.ArrayListUnmanaged([2]Pt),
    poly: []const Pt,
    arrow_from: bool,
    arrow_to: bool,
) error{OutOfMemory}!void {
    const n = poly.len;
    if (n < 2) return;
    var i: usize = 0;
    while (i + 1 < n) : (i += 1) {
        try runs.append(arena, .{ poly[i], poly[i + 1] });
    }
    if (arrow_to) {
        if (stepDir(poly[n - 1], poly[n - 2])) |d| try heads.append(arena, stepPt(poly[n - 1], d));
    }
    if (arrow_from) {
        if (stepDir(poly[0], poly[1])) |d| try heads.append(arena, stepPt(poly[0], d));
    }
}

/// File a pending bridge's TENTATIVE elbow (its current jog, already
/// clamped) into a growing scene, so an earlier bridge's dodge sees the
/// paths its successors are about to draw. A jogless unaligned pending
/// (a re-route this layer cannot model) files nothing.
pub fn tentInk(
    arena: std.mem.Allocator,
    heads: *std.ArrayListUnmanaged(Pt),
    runs: *std.ArrayListUnmanaged([2]Pt),
    start: Pt,
    end: Pt,
    vertical: bool,
    jog: ?i32,
    arrow_from: bool,
    arrow_to: bool,
) error{OutOfMemory}!void {
    var buf: [4]Pt = undefined;
    var n: usize = 0;
    buf[n] = start;
    n += 1;
    if (jog) |c| {
        if (vertical) {
            buf[n] = .{ .x = start.x, .y = c };
            buf[n + 1] = .{ .x = end.x, .y = c };
        } else {
            buf[n] = .{ .x = c, .y = start.y };
            buf[n + 1] = .{ .x = c, .y = end.y };
        }
        n += 2;
    } else if (if (vertical) start.x != end.x else start.y != end.y) {
        return;
    }
    buf[n] = end;
    n += 1;
    try commitPoly(arena, heads, runs, buf[0..n], arrow_from, arrow_to);
}

/// Conflict count of the elbow through jog `c` against `aug` (committed +
/// tentative scene ink), per the three-relation rule: heads conflict with
/// any transit, runs only with collinear runs and with corner cells landing
/// on them; perpendicular crossings are free. A jog line along a drawn
/// frame border or through a foreign node box is never placeable (large
/// score). Zero means clear.
pub fn jogScore(
    start: Pt,
    end: Pt,
    c: i32,
    vertical: bool,
    placements: []const sketch.NodePlacement,
    gf: sketch.NodeId,
    gt: sketch.NodeId,
    clusters: []const sketch.ClusterFrame,
    aug: tracks.Obstacles,
) u32 {
    const lo = if (vertical) @min(start.x, end.x) else @min(start.y, end.y);
    const hi = if (vertical) @max(start.x, end.x) else @max(start.y, end.y);
    if (tracks.onFrameBorder(vertical, c, lo, hi, clusters)) return 1000;
    for (placements) |p| {
        if (p.id == gf or p.id == gt) continue;
        const r = p.rect;
        const in_band = if (vertical) c >= r.y and c < r.bottom() else c >= r.x and c < r.right();
        const overlaps = if (vertical) lo < r.right() and hi >= r.x else lo < r.bottom() and hi >= r.y;
        if (in_band and overlaps) return 1000;
    }
    var score: u32 = 0;
    if (aug.blocks(vertical, c, lo, hi)) score += 1;
    if (vertical) {
        if (aug.blocks(false, start.x, @min(start.y, c), @max(start.y, c))) score += 1;
        if (aug.blocks(false, end.x, @min(c, end.y), @max(c, end.y))) score += 1;
    } else {
        if (aug.blocks(true, start.y, @min(start.x, c), @max(start.x, c))) score += 1;
        if (aug.blocks(true, end.y, @min(end.x, c), @max(end.x, c))) score += 1;
    }
    const corners = if (vertical)
        [2]Pt{ .{ .x = start.x, .y = c }, .{ .x = end.x, .y = c } }
    else
        [2]Pt{ .{ .x = c, .y = start.y }, .{ .x = c, .y = end.y } };
    for (corners) |corner| {
        if (aug.covers(corner)) score += 1;
    }
    for (aug.heads) |h| {
        if (vertical) {
            if (h.x == start.x and between(h.y, start.y, c)) score += 1;
            if (h.x == end.x and between(h.y, c, end.y)) score += 1;
        } else {
            if (h.y == start.y and between(h.x, start.x, c)) score += 1;
            if (h.y == end.y and between(h.x, c, end.x)) score += 1;
        }
    }
    return score;
}

/// Conflict count of one routed polyline against boxed ink the run/head
/// scene cannot see: a segment running through a foreign node rect (touch
/// semantics) or collinear along a drawn frame border row/column, counted
/// per CELL — the raster's violation counters are per-cell, and a
/// comparison metric must weigh a long fusion by its length.
pub fn boxScore(
    poly: []const Pt,
    gf: sketch.NodeId,
    gt: sketch.NodeId,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
) u64 {
    var score: u64 = 0;
    if (poly.len < 2) return 0;
    var i: usize = 0;
    while (i + 1 < poly.len) : (i += 1) {
        const a = poly[i];
        const b = poly[i + 1];
        const horizontal = a.y == b.y;
        const lo = if (horizontal) @min(a.x, b.x) else @min(a.y, b.y);
        const hi = if (horizontal) @max(a.x, b.x) else @max(a.y, b.y);
        const c = if (horizontal) a.y else a.x;
        for (placements) |p| {
            if (p.id == gf or p.id == gt) continue;
            const r = p.rect;
            const in_band = if (horizontal) c >= r.y and c < r.bottom() else c >= r.x and c < r.right();
            const o = if (horizontal)
                @min(hi, r.right() - 1) - @max(lo, r.x)
            else
                @min(hi, r.bottom() - 1) - @max(lo, r.y);
            if (in_band and o >= 0) score += 2 * @as(u64, @intCast(o + 1));
        }
        if (tracks.onFrameBorder(horizontal, c, lo, hi, clusters)) score += 2 * @as(u64, @intCast(hi - lo + 1));
    }
    return score;
}

/// Conflict count of one routed polyline against the scene, per the
/// three-relation rule: a segment collinear-overlapping a scene run (counted
/// per overlapping CELL), an interior corner landing on scene ink, or any
/// cell covering a scene head each count; perpendicular crossings are free.
/// Comparison metric for whole-set routing attempts — licensed shared-start
/// overlap counts equally in every attempt and cancels.
pub fn polyScore(poly: []const Pt, dyn: tracks.Obstacles) u64 {
    var score: u64 = 0;
    if (poly.len < 2) return 0;
    var i: usize = 0;
    while (i + 1 < poly.len) : (i += 1) {
        const a = poly[i];
        const b = poly[i + 1];
        const horizontal = a.y == b.y;
        for (dyn.runs) |r| {
            const rh = r[0].y == r[1].y;
            if (horizontal and rh and a.y == r[0].y) {
                const o = @min(@max(a.x, b.x), @max(r[0].x, r[1].x)) - @max(@min(a.x, b.x), @min(r[0].x, r[1].x));
                if (o >= 0) score += @as(u64, @intCast(o + 1));
            } else if (!horizontal and !rh and a.x == r[0].x) {
                const o = @min(@max(a.y, b.y), @max(r[0].y, r[1].y)) - @max(@min(a.y, b.y), @min(r[0].y, r[1].y));
                if (o >= 0) score += @as(u64, @intCast(o + 1));
            }
        }
        for (dyn.heads) |h| {
            if (between(h.x, a.x, b.x) and between(h.y, a.y, b.y)) score += 1;
        }
    }
    for (poly[1 .. poly.len - 1]) |corner| {
        if (dyn.covers(corner)) score += 1;
    }
    return score;
}

pub const Step = struct { x: i32, y: i32 };

pub fn stepDir(a: Pt, b: Pt) ?Step {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if ((dx == 0) == (dy == 0)) return null;
    return .{ .x = std.math.sign(dx), .y = std.math.sign(dy) };
}

pub fn stepPt(p: Pt, d: Step) Pt {
    return .{ .x = p.x + d.x, .y = p.y + d.y };
}

/// True iff `p` is one of `cells`.
pub fn cellIn(cells: []const Pt, p: Pt) bool {
    for (cells) |c| {
        if (c.x == p.x and c.y == p.y) return true;
    }
    return false;
}

/// Inclusive-interval membership, order-free endpoints.
pub fn between(v: i32, a: i32, b: i32) bool {
    return v >= @min(a, b) and v <= @max(a, b);
}

/// Obstacle-aware vertical route. Exits the source into the gap immediately
/// below/above it (above its intra-cluster child), jogs to a column clear of
/// every node over the run span, descends/ascends, then jogs to the target's
/// column in the gap outside the target box and runs into the port. Degenerate
/// (zero-length) segments collapse to the simple elbow.
pub fn verticalCorridor(
    arena: std.mem.Allocator,
    start: sketch.Point,
    end: sketch.Point,
    to_box: sketch.Rect,
    exit: sketch.Dir4,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
    expired: ?*u32,
) error{OutOfMemory}![]sketch.Point {
    const descending = (exit == .south);
    // Gap row just past the source node — collision-free above its child. // @guarded-by: bridges_test.zig "verticalCorridor: the source-side jog row (one past the source) is collision-free above the pierced child"
    const src_jog_y = if (descending) start.y + 1 else start.y - 1;
    const entry: sketch.Dir4 = if (descending) .north else .south;
    const tgt_want = tracks.clearOfBorders(
        entry,
        if (descending) @min(to_box.y - 1, end.y - 2) else @max(to_box.bottom(), end.y + 2),
        @min(start.x, end.x),
        @max(start.x, end.x),
        clusters,
        obstacles,
        expired,
    );
    const tgt_jog_y = if (descending)
        clampBetween(start.y, end.y, tgt_want)
    else
        clampBetween(end.y, start.y, tgt_want);

    const lo = @min(src_jog_y, tgt_jog_y);
    const hi = @max(src_jog_y, tgt_jog_y);
    // Prefer descending straight into the target column, sliding outward only
    // if blocked; margined over merely touch-free (flush `││` reads as
    // crowding) — sketch.clearLine is the shared clearance core (cluster/ may
    // import sketch, not layout/). // @guarded-by: sketch.zig "clearLine prefers a margined line over a closer touch-free-only line"
    const run_col = corridors.descentColumn(end.x, lo, hi, placements, from_id, to_id, clusters);

    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    var prev = start;
    try poly.append(arena, prev);
    const pts = [_]sketch.Point{
        .{ .x = start.x, .y = src_jog_y },
        .{ .x = run_col, .y = src_jog_y },
        .{ .x = run_col, .y = tgt_jog_y },
        .{ .x = end.x, .y = tgt_jog_y },
        end,
    };
    for (pts) |p| {
        if (p.x == prev.x and p.y == prev.y) continue;
        try poly.append(arena, p);
        prev = p;
    }
    return try poly.toOwnedSlice(arena);
}

/// True iff any straight vertical segment of `poly` touches a node box
/// (excluding the edge's own endpoints). Touch semantics — borders count —
/// because the raster owns border cells: a bridge leg running along a
/// foreign border column rasterizes as swallowed edge cells even though
/// the strict-interior validator stays silent.
pub fn polyIntrudes(
    poly: []const sketch.Point,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
) bool {
    if (poly.len < 2) return false;
    var i: usize = 0;
    while (i + 1 < poly.len) : (i += 1) {
        const a = poly[i];
        const b = poly[i + 1];
        if (a.x == b.x) {
            const y0 = @min(a.y, b.y);
            const y1 = @max(a.y, b.y);
            if (sketch.columnTouchesAny(a.x, y0, y1, placements, from_id, to_id)) return true;
        }
    }
    return false;
}

/// Clamp `want` into the open interval (lo, hi). Keeps the jog coordinate
/// strictly between the two ports even when the preferred gap line would land
/// on or past a port (tight box spacing).
pub fn clampBetween(lo: i32, hi: i32, want: i32) i32 {
    if (hi - lo < 2) return lo + 1;
    if (want <= lo) return lo + 1;
    if (want >= hi) return hi - 1;
    return want;
}

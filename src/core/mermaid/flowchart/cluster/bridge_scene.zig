const std = @import("std");
const sketch = @import("../sketch.zig");
const sketch_clearance = @import("../sketch_clearance.zig");
const tracks = @import("tracks.zig");
const corridors = @import("corridors.zig");
const types = @import("bridge_types.zig");

const Pt = sketch.Point;

pub fn sceneObstacles(
    arena: std.mem.Allocator,
    rails: []const sketch.Rail,
    edge_paths: []const sketch.EdgePath,
) error{OutOfMemory}!tracks.Obstacles {
    var heads: std.ArrayListUnmanaged(Pt) = .empty;
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    for (edge_paths) |e| try appendHeads(arena, &heads, e.polyline, e.arrow_from != .none, e.arrow_to != .none);
    for (rails) |r| {
        try runs.append(arena, r.crossbar);
        try appendRuns(arena, &runs, r.stem);
        if (r.pivot_arrow != .none and r.stem.len >= 2) {
            for (r.stem[0 .. r.stem.len - 1], r.stem[1..]) |a, b| {
                if (stepDir(a, b)) |d| {
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

pub fn appendRuns(arena: std.mem.Allocator, runs: *std.ArrayListUnmanaged([2]Pt), poly: []const Pt) error{OutOfMemory}!void {
    if (poly.len < 2) return;
    for (poly[0 .. poly.len - 1], poly[1..]) |a, b| try runs.append(arena, .{ a, b });
}

fn appendHeads(
    arena: std.mem.Allocator,
    heads: *std.ArrayListUnmanaged(Pt),
    poly: []const Pt,
    arrow_from: bool,
    arrow_to: bool,
) error{OutOfMemory}!void {
    const n = poly.len;
    if (n < 2) return;
    if (arrow_to) {
        if (stepDir(poly[n - 1], poly[n - 2])) |d| try heads.append(arena, stepPt(poly[n - 1], d));
    }
    if (arrow_from) {
        if (stepDir(poly[0], poly[1])) |d| try heads.append(arena, stepPt(poly[0], d));
    }
}

pub fn commitPoly(
    arena: std.mem.Allocator,
    heads: *std.ArrayListUnmanaged(Pt),
    runs: *std.ArrayListUnmanaged([2]Pt),
    poly: []const Pt,
    arrow_from: bool,
    arrow_to: bool,
) error{OutOfMemory}!void {
    try appendRuns(arena, runs, poly);
    try appendHeads(arena, heads, poly, arrow_from, arrow_to);
}

pub fn tentInk(
    arena: std.mem.Allocator,
    heads: *std.ArrayListUnmanaged(Pt),
    runs: *std.ArrayListUnmanaged([2]Pt),
    p: types.Pending,
) error{OutOfMemory}!void {
    if (p.jog == null and (if (p.vertical()) p.start.x != p.end.x else p.start.y != p.end.y)) return;
    const e = p.elbow();
    try commitPoly(arena, heads, runs, e.slice(), p.cross.arrow_from != .none, p.cross.arrow_to != .none);
}

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

pub fn cellIn(cells: []const Pt, p: Pt) bool {
    for (cells) |c| {
        if (c.x == p.x and c.y == p.y) return true;
    }
    return false;
}

pub fn between(v: i32, a: i32, b: i32) bool {
    return v >= @min(a, b) and v <= @max(a, b);
}

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
) error{OutOfMemory}![]sketch.Point {
    const descending = (exit == .south);
    const src_jog_y = if (descending) start.y + 1 else start.y - 1;
    const entry: sketch.Dir4 = if (descending) .north else .south;
    const tgt_want = tracks.clearOfBorders(
        entry,
        if (descending) @min(to_box.y - 1, end.y - 2) else @max(to_box.bottom(), end.y + 2),
        @min(start.x, end.x),
        @max(start.x, end.x),
        clusters,
        obstacles,
    );
    const tgt_jog_y = if (descending)
        types.clampBetween(start.y, end.y, tgt_want)
    else
        types.clampBetween(end.y, start.y, tgt_want);

    const lo = @min(src_jog_y, tgt_jog_y);
    const hi = @max(src_jog_y, tgt_jog_y);
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
            if (sketch_clearance.columnTouchesAny(a.x, y0, y1, placements, from_id, to_id)) return true;
        }
    }
    return false;
}

pub fn rerouted(p: types.Pending, placements: []const sketch.NodePlacement) bool {
    if (!p.vertical()) return false;
    const e = p.elbow();
    return polyIntrudes(e.slice(), placements, p.gf, p.gt);
}

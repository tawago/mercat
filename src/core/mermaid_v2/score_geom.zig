//! score_geom.zig — pure geometric T2 legibility measurements for score.zig.
//! No weights live here: score.zig owns every fitted constant; this file
//! only MEASURES a Sketch (dead space, edge stretch, bends, crossings,
//! forced label wraps).
//!
//! Pure: no floats, no RNG, no I/O. The dead-space coverage bitmap comes
//! from the caller's arena.
//!
//! Allowed imports (lint): std, prim, sketch.

const std = @import("std");
const sketch = @import("sketch.zig");

/// bbox area minus covered area, via a coverage bitmap (cells relative to
/// the bbox origin). Coverage marks every cell of every cluster frame rect,
/// every node rect, and every edge-polyline cell. The bitmap makes
/// double-marking free, so cluster frames vs member nodes are NOT
/// double-counted (`clusters.computeBbox` keeps the bbox tight, so a fully
/// covered diagram scores 0).
///
/// NOTE: SYNTHETIC packing frames (ClusterFrame.synthetic) are counted as
/// covered here even though they paint nothing — their rect is exactly the
/// packed content's bbox, so a packed candidate's INTERNAL dead space is
/// invisible to this term. If packed candidates start winning suspiciously
/// on t2, exclude synthetic frames from this loop and re-audit.
pub fn deadSpace(allocator: std.mem.Allocator, s: sketch.Sketch) !u64 {
    const w: u64 = s.bbox.w;
    const h: u64 = s.bbox.h;
    const area = w * h;
    if (area == 0) return 0;

    var covered = try std.DynamicBitSet.initEmpty(allocator, area);
    defer covered.deinit();

    for (s.clusters) |c| markRect(&covered, s.bbox, c.rect);
    for (s.nodes) |n| markRect(&covered, s.bbox, n.rect);
    for (s.edges) |e| {
        if (e.polyline.len < 2) continue;
        var i: usize = 0;
        while (i + 1 < e.polyline.len) : (i += 1) {
            markSegment(&covered, s.bbox, e.polyline[i], e.polyline[i + 1]);
        }
    }
    for (s.busbars) |bb| {
        var i: usize = 0;
        while (i + 1 < bb.stem.len) : (i += 1) {
            markSegment(&covered, s.bbox, bb.stem[i], bb.stem[i + 1]);
        }
        markSegment(&covered, s.bbox, bb.rail[0], bb.rail[1]);
        for (bb.taps) |tap| markSegment(&covered, s.bbox, tap.at, tap.landing);
    }
    return area - covered.count();
}

/// Mark every cell of `r` (clipped to `bbox`) in the coverage bitmap.
fn markRect(covered: *std.DynamicBitSet, bbox: sketch.Rect, r: sketch.Rect) void {
    if (r.w == 0 or r.h == 0) return;
    const x0 = @max(r.x, bbox.x);
    const y0 = @max(r.y, bbox.y);
    const x1 = @min(r.right(), bbox.right());
    const y1 = @min(r.bottom(), bbox.bottom());
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) markCell(covered, bbox, x, y);
    }
}

/// Mark every cell along the segment a→b (inclusive; orthogonal walks are
/// exact, diagonal segments — a safety net, polylines are orthogonal —
/// step both axes toward the target).
fn markSegment(covered: *std.DynamicBitSet, bbox: sketch.Rect, a: sketch.Point, b: sketch.Point) void {
    var x = a.x;
    var y = a.y;
    while (true) {
        markCell(covered, bbox, x, y);
        if (x == b.x and y == b.y) break;
        if (x != b.x) x += if (b.x > x) @as(i32, 1) else -1;
        if (y != b.y) y += if (b.y > y) @as(i32, 1) else -1;
    }
}

fn markCell(covered: *std.DynamicBitSet, bbox: sketch.Rect, x: i32, y: i32) void {
    if (x < bbox.x or y < bbox.y or x >= bbox.right() or y >= bbox.bottom()) return;
    const col: u64 = @intCast(x - bbox.x);
    const row: u64 = @intCast(y - bbox.y);
    covered.set(row * @as(u64, bbox.w) + col);
}

/// Σ over edges of (manhattan polyline length − manhattan endpoint span):
/// how much farther every edge travels than a straight L-route would.
///
/// Bus-bars: the TRUNK is counted ONCE — only the stem's own detour (0 for
/// a straight stem). The rail is NOT detour: it exists exactly to reach the
/// taps, and each tap's direct route covers its own share of it. Tap drops
/// are straight (walked == direct), contributing nothing.
pub fn edgeStretch(s: sketch.Sketch) u64 {
    var total: u64 = 0;
    for (s.edges) |e| {
        if (e.polyline.len < 2) continue;
        var walked: u64 = 0;
        var i: usize = 0;
        while (i + 1 < e.polyline.len) : (i += 1) {
            walked += manhattan(e.polyline[i], e.polyline[i + 1]);
        }
        const direct = manhattan(e.polyline[0], e.polyline[e.polyline.len - 1]);
        total += walked -| direct;
    }
    for (s.busbars) |bb| {
        var walked: u64 = 0;
        var i: usize = 0;
        while (i + 1 < bb.stem.len) : (i += 1) {
            walked += manhattan(bb.stem[i], bb.stem[i + 1]);
        }
        total += walked -| manhattan(bb.stem[0], bb.stem[bb.stem.len - 1]);
    }
    return total;
}

fn manhattan(a: sketch.Point, b: sketch.Point) u64 {
    return @abs(a.x - b.x) + @abs(a.y - b.y);
}

/// Interior axis flips summed over all edge polylines. Zero-length
/// segments are skipped; a segment is vertical when dx == 0, else
/// horizontal (polylines are orthogonal by construction).
pub fn bends(s: sketch.Sketch) u64 {
    var total: u64 = 0;
    for (s.edges) |e| total += polylineBends(e.polyline);
    // Bus-bar trunk corners counted once (stem flips + stem→rail turn) plus one turn per off-column tap. // guarded-by: score_test.zig "bus-bar bends: trunk junction counted once, one turn per off-column tap"
    for (s.busbars) |bb| {
        total += polylineBends(bb.stem);
        const junction = bb.stem[bb.stem.len - 1];
        if (bb.rail[0].x != bb.rail[1].x) total += 1;
        for (bb.taps) |tap| {
            if (tap.at.x != junction.x) total += 1;
        }
    }
    return total;
}

fn polylineBends(poly: []const sketch.Point) u64 {
    var total: u64 = 0;
    var prev_vertical: ?bool = null;
    var i: usize = 0;
    while (i + 1 < poly.len) : (i += 1) {
        const a = poly[i];
        const b = poly[i + 1];
        if (a.x == b.x and a.y == b.y) continue; // zero-length
        const vertical = a.x == b.x;
        if (prev_vertical) |pv| {
            if (pv != vertical) total += 1;
        }
        prev_vertical = vertical;
    }
    return total;
}

/// Edge crossings by pairwise polyline segment intersection between
/// DIFFERENT edges. (`sketch.Diagnostic.crossing_count` is declared but
/// never emitted anywhere — do not trust it.) Counts a crossing when a
/// horizontal and a vertical segment intersect STRICTLY inside both
/// segments' interiors; endpoint touches / T-junctions / collinear
/// overlaps are not counted (deterministic, and avoids false positives
/// where two edges share a node port).
pub fn countCrossings(s: sketch.Sketch) u64 {
    var total: u64 = 0;
    for (s.edges, 0..) |ea, ai| {
        for (s.edges[ai + 1 ..]) |eb| {
            total += crossingsBetween(ea.polyline, eb.polyline);
        }
    }
    // Bus-bars cross edges/other bus-bars; a bus-bar never crosses itself. // guarded-by: score_test.zig "bus-bar crossings: shared trunk registers once, never crosses itself"
    for (s.busbars, 0..) |ba, bi| {
        for (s.edges) |e| total += busbarEdgeCrossings(ba, e.polyline);
        for (s.busbars[bi + 1 ..]) |bb| total += busbarBusbarCrossings(ba, bb);
    }
    return total;
}

/// Iterate a bus-bar's segments: stem segments, the rail, one drop per
/// tap. Index-addressed so crossing loops stay allocation-free.
fn busbarSegCount(bb: sketch.BusBar) usize {
    return (bb.stem.len - 1) + 1 + bb.taps.len;
}

fn busbarSeg(bb: sketch.BusBar, i: usize) [2]sketch.Point {
    const stem_segs = bb.stem.len - 1;
    if (i < stem_segs) return .{ bb.stem[i], bb.stem[i + 1] };
    if (i == stem_segs) return .{ bb.rail[0], bb.rail[1] };
    const tap = bb.taps[i - stem_segs - 1];
    return .{ tap.at, tap.landing };
}

fn busbarEdgeCrossings(bb: sketch.BusBar, poly: []const sketch.Point) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i < busbarSegCount(bb)) : (i += 1) {
        const sa = busbarSeg(bb, i);
        var j: usize = 0;
        while (j + 1 < poly.len) : (j += 1) {
            if (segmentsCross(sa[0], sa[1], poly[j], poly[j + 1])) total += 1;
        }
    }
    return total;
}

fn busbarBusbarCrossings(ba: sketch.BusBar, bb: sketch.BusBar) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i < busbarSegCount(ba)) : (i += 1) {
        const sa = busbarSeg(ba, i);
        var j: usize = 0;
        while (j < busbarSegCount(bb)) : (j += 1) {
            const sb = busbarSeg(bb, j);
            if (segmentsCross(sa[0], sa[1], sb[0], sb[1])) total += 1;
        }
    }
    return total;
}

fn crossingsBetween(pa: []const sketch.Point, pb: []const sketch.Point) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i + 1 < pa.len) : (i += 1) {
        var j: usize = 0;
        while (j + 1 < pb.len) : (j += 1) {
            if (segmentsCross(pa[i], pa[i + 1], pb[j], pb[j + 1])) total += 1;
        }
    }
    return total;
}

/// Strict interior crossing of one horizontal and one vertical segment.
fn segmentsCross(a0: sketch.Point, a1: sketch.Point, b0: sketch.Point, b1: sketch.Point) bool {
    const a_vert = a0.x == a1.x;
    const a_horiz = a0.y == a1.y;
    const b_vert = b0.x == b1.x;
    const b_horiz = b0.y == b1.y;
    if (a_horiz and !a_vert and b_vert and !b_horiz) {
        return strictCross(a0, a1, b0, b1);
    }
    if (a_vert and !a_horiz and b_horiz and !b_vert) {
        return strictCross(b0, b1, a0, a1);
    }
    return false;
}

/// `h0→h1` horizontal, `v0→v1` vertical: cross iff the vertical's x is
/// strictly inside the horizontal's x-span AND the horizontal's y is
/// strictly inside the vertical's y-span.
fn strictCross(h0: sketch.Point, h1: sketch.Point, v0: sketch.Point, v1: sketch.Point) bool {
    const hx0 = @min(h0.x, h1.x);
    const hx1 = @max(h0.x, h1.x);
    const vy0 = @min(v0.y, v1.y);
    const vy1 = @max(v0.y, v1.y);
    return v0.x > hx0 and v0.x < hx1 and h0.y > vy0 and h0.y < vy1;
}

/// Count of `.forced_label_wrap` diagnostics.
pub fn labelWraps(s: sketch.Sketch) u64 {
    var n: u64 = 0;
    for (s.diagnostics) |d| switch (d) {
        .forced_label_wrap => n += 1,
        else => {},
    };
    return n;
}

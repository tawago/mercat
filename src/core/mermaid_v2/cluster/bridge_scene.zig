//! cluster/bridge_scene.zig — the merged scene's ink, derived for the
//! bridge router (cap-forced split of bridges.zig). Heads and runs follow
//! the three-relation rule recorded in tracks.Obstacles: heads block any
//! transit, runs block only collinear runs, licensed shares block nothing.

const std = @import("std");
const sketch = @import("../sketch.zig");
const tracks = @import("tracks.zig");

const Pt = sketch.Point;

/// Sketch-space ink already in the merged scene. Rail heads: the pivot head
/// one step out from `stem[0]` along the stem, each decorated tap's head one
/// step back from its landing — cell-twin of raster/busbars.zig
/// pivotHead/tapHead, which stamp exactly these cells. Edge heads sit one
/// step back from a decorated port along the end segment. Runs: crossbars,
/// stem legs, tap droppers, and every polyline leg.
// guarded-by: bridges_test.zig "sceneObstacles derives the pivot and tap head cells the raster stamps"
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


pub const Step = struct { x: i32, y: i32 };

pub fn stepDir(a: Pt, b: Pt) ?Step {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if ((dx == 0) == (dy == 0)) return null; // zero-length or diagonal
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

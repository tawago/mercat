const std = @import("std");
const sketch = @import("../sketch.zig");
const rail_star = @import("../base/rail_star.zig");
const bridge_fans = @import("bridge_fans.zig");
const types = @import("bridge_types.zig");
const requests = @import("bridge_requests.zig");
const scene = @import("bridge_scene.zig");
const tracks = @import("tracks.zig");

const Pt = sketch.Point;

pub fn overrideJogs(
    arena: std.mem.Allocator,
    pends: []types.Pending,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
) error{OutOfMemory}!void {
    const crossings = try arena.alloc(types.Crossing, pends.len);
    for (pends, crossings) |p, *c| c.* = p.cross;
    for ([2]rail_star.Endpoint{ .source, .target }) |end| {
        for (try bridge_fans.groups(arena, crossings, end)) |members| {
            if (!try bridge_fans.licensed(arena, crossings, members, end)) continue;
            if (!railable(pends, members, placements, end)) continue;
            if (try chooseJog(arena, pends, members, placements, clusters, obstacles, end)) |c| {
                for (members) |mi| pends[mi].jog = c;
            }
        }
    }
}

fn railEnd(end: rail_star.Endpoint) requests.RailEnd {
    return if (end == .source) .start else .end;
}

fn railable(
    pends: []const types.Pending,
    members: []const usize,
    placements: []const sketch.NodePlacement,
    end: rail_star.Endpoint,
) bool {
    const re = railEnd(end);
    const p0 = pends[members[0]];
    for (members) |mi| {
        const m = pends[mi];
        if (m.jog == null) return false;
        if (requests.railSide(m, re) != requests.railSide(p0, re)) return false;
        if (!requests.samePt(requests.railPort(m, re), requests.railPort(p0, re))) return false;
        if (scene.rerouted(m, placements)) return false;
        if (requests.railedAtOtherEnd(pends, mi, re)) return false;
    }
    return true;
}

fn chooseJog(
    arena: std.mem.Allocator,
    pends: []const types.Pending,
    members: []const usize,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
    end: rail_star.Endpoint,
) error{OutOfMemory}!?i32 {
    const p0 = pends[members[0]];
    const vertical = p0.vertical();
    var lo: i32 = std.math.minInt(i32);
    var hi: i32 = std.math.maxInt(i32);
    for (members) |mi| {
        const b = pends[mi].bounds();
        lo = @max(lo, b[0]);
        hi = @min(hi, b[1]);
    }
    if (hi - lo < 2) return null;
    const jc = types.clampBetween(lo, hi, p0.jog.?);

    var heads: std.ArrayListUnmanaged(Pt) = .empty;
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try heads.appendSlice(arena, obstacles.heads);
    try runs.appendSlice(arena, obstacles.runs);
    const port = requests.railPort(p0, railEnd(end));
    for (pends, 0..) |q, qi| {
        if (std.mem.indexOfScalar(usize, members, qi) != null) continue;
        if (requests.samePt(requests.railPort(q, railEnd(end)), port)) continue;
        try scene.tentInk(arena, &heads, &runs, q);
    }
    const aug = tracks.Obstacles{ .heads = heads.items, .runs = runs.items };

    const cur = groupScore(pends, members, jc, vertical, placements, clusters, aug);
    if (cur == 0) return null;
    var best: ?i32 = null;
    var best_score = cur;
    var d: i32 = 1;
    while (d <= hi - lo) : (d += 1) {
        for ([2]i32{ jc + d, jc - d }) |c| {
            if (c <= lo or c >= hi) continue;
            const s = groupScore(pends, members, c, vertical, placements, clusters, aug);
            if (s < best_score) {
                best_score = s;
                best = c;
                if (s == 0) return best;
            }
        }
    }
    return best;
}

fn groupScore(
    pends: []const types.Pending,
    members: []const usize,
    c: i32,
    vertical: bool,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    aug: tracks.Obstacles,
) u64 {
    var sum: u64 = 0;
    for (members) |mi| {
        const m = pends[mi];
        sum += scene.jogScore(m.start, m.end, c, vertical, placements, m.gf, m.gt, clusters, aug);
        const poly = if (vertical)
            [4]Pt{ m.start, .{ .x = m.start.x, .y = c }, .{ .x = m.end.x, .y = c }, m.end }
        else
            [4]Pt{ m.start, .{ .x = c, .y = m.start.y }, .{ .x = c, .y = m.end.y }, m.end };
        sum += scene.polyScore(&poly, aug) + scene.boxScore(&poly, m.gf, m.gt, placements, clusters);
    }
    return sum;
}

pub fn withStaticRuns(
    arena: std.mem.Allocator,
    base: tracks.Obstacles,
    edge_paths: []const sketch.EdgePath,
) error{OutOfMemory}!tracks.Obstacles {
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try runs.appendSlice(arena, base.runs);
    for (edge_paths) |e| try scene.appendRuns(arena, &runs, e.polyline);
    return .{ .heads = base.heads, .runs = try runs.toOwnedSlice(arena) };
}

pub fn realizedRail(
    arena: std.mem.Allocator,
    paths: []const sketch.EdgePath,
    end: rail_star.Endpoint,
) error{OutOfMemory}!bool {
    if (paths.len < 2) return false;
    const polys = try arena.alloc([]const Pt, paths.len);
    for (paths, polys) |p, *poly| {
        if (p.polyline.len == 0) return false;
        poly.* = try cellsOf(arena, p.polyline, end);
    }
    const first = polys[0][0];
    for (polys[1..]) |poly| {
        if (!requests.samePt(poly[0], first)) return false;
    }
    for (polys, 0..) |a, i| {
        for (polys[i + 1 ..]) |b| {
            if (!cleanSplit(a, b)) return false;
        }
    }
    return true;
}

fn cleanSplit(ca: []const Pt, cb: []const Pt) bool {
    var k: usize = 0;
    while (k < ca.len and k < cb.len and requests.samePt(ca[k], cb[k])) : (k += 1) {}
    for (ca[k..]) |p| {
        if (scene.cellIn(cb[k..], p)) return false;
    }
    return true;
}

fn cellsOf(arena: std.mem.Allocator, poly: []const Pt, end: rail_star.Endpoint) error{OutOfMemory}![]const Pt {
    var out: std.ArrayListUnmanaged(Pt) = .empty;
    if (poly.len == 0) return &.{};
    try out.append(arena, poly[0]);
    for (poly[0 .. poly.len - 1], poly[1..]) |a, b| {
        var p = a;
        const d = scene.stepDir(a, b) orelse continue;
        while (p.x != b.x or p.y != b.y) {
            p = scene.stepPt(p, d);
            try out.append(arena, p);
        }
    }
    if (end == .target) std.mem.reverse(Pt, out.items);
    return out.toOwnedSlice(arena);
}

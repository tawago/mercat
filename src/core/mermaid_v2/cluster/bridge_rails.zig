//! cluster/bridge_rails.zig — selective realization of cross-border bundles.
//!
//! A LICENSED group of crossings sharing one original endpoint (same licence
//! tier as a piece fan — base/rail_star.checkLicence) whose pends meet at one
//! port of that convergent node is already ONE rail in geometry; what it
//! lacks is a clean rail row. `overrideJogs` moves the group's shared jog
//! jointly to the least-conflicted coordinate, judged exactly like the gated
//! dodge (committed scene + tentative non-member ink; a shared port is a
//! licensed rail, never an obstacle) — at the source end and at the target
//! end alike (realization across a boundary). Whether the railed build SHIPS
//! is not decided here or by any sketch-side proxy: the railed variant is
//! laid out as a candidate and the selection stage's composite score against
//! the real raster picks (confluence selection note).
//!
//! `realizedRail` is the plan tier's witness over FINAL geometry: a group
//! realized a rail iff every routed member leaves one shared point at the
//! convergent end and the members never touch again past the shared prefix —
//! the shape on which a structural sanction is inert away from the rail (the
//! always-on failure mode was sanctioning member-vs-member contact AWAY from
//! the approach). The shape reads the same from either end.
//!
//! PURE DATA: pends/paths in, jog mutations + one predicate out. Imports the
//! cluster-internal bridges.zig / bridge_requests.zig / bridge_scene.zig /
//! tracks.zig plus sketch, sem_graph, base/ledger.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const bridges = @import("bridges.zig");
const requests = @import("bridge_requests.zig");
const scene = @import("bridge_scene.zig");
const tracks = @import("tracks.zig");

const Pt = sketch.Point;

/// Jointly re-place the shared jog of every licensed group, convergent at
/// the source end first, then at the target end. Mutates `pends`; returns
/// true iff any jog moved (so the caller knows a rebuild can differ at all).
/// @guarded-by: bridges_test.zig "a licensed shared-target fan moves its whole rail off a static run the scene models as no obstacle"
pub fn overrideJogs(
    arena: std.mem.Allocator,
    pends: []bridges.Pending,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
) error{OutOfMemory}!bool {
    var changed = false;
    for ([2]ledger.Endpoint{ .source, .target }) |end| {
        const done = try arena.alloc(bool, pends.len);
        @memset(done, false);
        for (pends, 0..) |p0, i| {
            if (done[i] or p0.cross.from == p0.cross.to or p0.cross.kind == .invisible) continue;
            var members: std.ArrayListUnmanaged(usize) = .empty;
            for (pends[i..], i..) |q, j| {
                if (pivotOf(q, end) != pivotOf(p0, end) or q.cross.from == q.cross.to or q.cross.kind == .invisible) continue;
                done[j] = true;
                try members.append(arena, j);
            }
            if (members.items.len < 2) continue;
            if (!try licensed(arena, pends, members.items, end)) continue;
            if (!try railable(arena, pends, members.items, placements, end)) continue;
            if (try chooseJog(arena, pends, members.items, placements, clusters, obstacles, end)) |c| {
                for (members.items) |mi| pends[mi].jog = c;
                changed = true;
            }
        }
    }
    return changed;
}

fn pivotOf(p: bridges.Pending, end: ledger.Endpoint) sg.NodeId {
    return if (end == .source) p.cross.from else p.cross.to;
}

fn railEnd(end: ledger.Endpoint) requests.RailEnd {
    return if (end == .source) .start else .end;
}

/// The licence over the group at its convergent end — the same geometry-free
/// tier a piece fan answers, members keyed by root edge ids.
fn licensed(
    arena: std.mem.Allocator,
    pends: []const bridges.Pending,
    members: []const usize,
    end: ledger.Endpoint,
) error{OutOfMemory}!bool {
    const rows = try arena.alloc(ledger.RailLicenceMember, members.len);
    for (members, rows) |mi, *row| {
        const c = pends[mi].cross;
        row.* = .{
            .edge = if (c.origin == sg.SENTINEL) c.id else c.origin,
            .endpoints = .{ c.from, c.to },
            .arrows = .{ c.arrow_from, c.arrow_to },
            .stands_for = .arrow_free,
            .kind = c.kind,
            .pivot_end = end,
        };
    }
    return ledger.checkRailLicence(.{
        .id = 1,
        .polarity = if (end == .source) .out else .in,
        .pivot = pivotOf(pends[members[0]], end),
        .members = rows,
    }).isValid();
}

/// A group is rail-shaped at `end` only when every member meets ONE port on
/// one side there, each carries a jog to move, none was re-routed as a
/// corridor (whose descent column this layer never chose), and none rides a
/// rail keyed at its other end (one jog serves one rail).
fn railable(
    arena: std.mem.Allocator,
    pends: []const bridges.Pending,
    members: []const usize,
    placements: []const sketch.NodePlacement,
    end: ledger.Endpoint,
) error{OutOfMemory}!bool {
    const re = railEnd(end);
    const p0 = pends[members[0]];
    for (members) |mi| {
        const m = pends[mi];
        if (m.jog == null) return false;
        if (requests.railSide(m, re) != requests.railSide(p0, re)) return false;
        if (!requests.samePt(requests.railPort(m, re), requests.railPort(p0, re))) return false;
        if (try bridges.rerouted(arena, m, placements)) return false;
        if (requests.railedAtOtherEnd(pends, mi, re)) return false;
    }
    return true;
}

/// The least-conflicted shared jog coordinate for the group, judged member by
/// member with `scene.jogScore` against the static scene plus the tentative
/// elbows of every non-member (the dodge's own metric, applied jointly).
/// Null when the assigned coordinate is already clear or nothing strictly
/// improves on it.
fn chooseJog(
    arena: std.mem.Allocator,
    pends: []const bridges.Pending,
    members: []const usize,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
    end: ledger.Endpoint,
) error{OutOfMemory}!?i32 {
    const p0 = pends[members[0]];
    const vertical = (p0.sides.exit == .north or p0.sides.exit == .south);
    var lo: i32 = std.math.minInt(i32);
    var hi: i32 = std.math.maxInt(i32);
    for (members) |mi| {
        const b = boundsOf(pends[mi]);
        lo = @max(lo, b[0]);
        hi = @min(hi, b[1]);
    }
    if (hi - lo < 2) return null;
    const jc = scene.clampBetween(lo, hi, p0.jog.?);

    var heads: std.ArrayListUnmanaged(Pt) = .empty;
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try heads.appendSlice(arena, obstacles.heads);
    try runs.appendSlice(arena, obstacles.runs);
    const port = requests.railPort(p0, railEnd(end));
    for (pends, 0..) |q, qi| {
        if (inGroup(members, qi)) continue;
        if (requests.samePt(requests.railPort(q, railEnd(end)), port)) continue;
        const qv = (q.sides.exit == .north or q.sides.exit == .south);
        const qb = boundsOf(q);
        const qj: ?i32 = if (q.jog) |qq| scene.clampBetween(qb[0], qb[1], qq) else null;
        try scene.tentInk(arena, &heads, &runs, q.start, q.end, qv, qj, q.cross.arrow_from != .none, q.cross.arrow_to != .none);
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

/// Joint conflict at shared jog `c`: the dodge's own band metric PLUS each
/// member's full elbow scored the way the whole-scene gate scores it
/// (polyScore sees a head mid-rail, which the band metric cannot).
fn groupScore(
    pends: []const bridges.Pending,
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

/// The member's legal jog interval (jog strictly between these), per exit.
fn boundsOf(p: bridges.Pending) [2]i32 {
    return switch (p.sides.exit) {
        .south => .{ p.start.y, p.end.y },
        .north => .{ p.end.y, p.start.y },
        .east => .{ p.start.x, p.end.x },
        .west => .{ p.end.x, p.start.x },
    };
}

/// `base` widened with every static edge path's segments as run obstacles.
/// The bridge scene deliberately models static edges as heads only; the
/// rail choice and its gate use this fuller picture LOCALLY, so a rail can
/// step off a piece edge's run without changing any other routing decision.
pub fn withStaticRuns(
    arena: std.mem.Allocator,
    base: tracks.Obstacles,
    edge_paths: []const sketch.EdgePath,
) error{OutOfMemory}!tracks.Obstacles {
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try runs.appendSlice(arena, base.runs);
    for (edge_paths) |e| {
        if (e.polyline.len < 2) continue;
        for (e.polyline[0 .. e.polyline.len - 1], e.polyline[1..]) |a, b| {
            try runs.append(arena, .{ a, b });
        }
    }
    return .{ .heads = base.heads, .runs = try runs.toOwnedSlice(arena) };
}

fn inGroup(members: []const usize, i: usize) bool {
    for (members) |m| {
        if (m == i) return true;
    }
    return false;
}

/// True iff the routed members ARE one rail at `end`: every path, traced
/// outward from that end, leaves one shared point and, past the pairwise
/// shared prefix, no two members touch again.
pub fn realizedRail(
    arena: std.mem.Allocator,
    paths: []const sketch.EdgePath,
    end: ledger.Endpoint,
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

/// Two member cell traces share a prefix from the convergent port and then
/// stay apart.
fn cleanSplit(ca: []const Pt, cb: []const Pt) bool {
    var k: usize = 0;
    while (k < ca.len and k < cb.len and requests.samePt(ca[k], cb[k])) : (k += 1) {}
    for (ca[k..]) |p| {
        if (scene.cellIn(cb[k..], p)) return false;
    }
    return true;
}

/// The polyline expanded to unit-step cells, endpoints included, in trace
/// order from `end`: as drawn from the source, reversed from the target.
fn cellsOf(arena: std.mem.Allocator, poly: []const Pt, end: ledger.Endpoint) error{OutOfMemory}![]const Pt {
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

test "realizedRail accepts a shared stem with disjoint tails and refuses re-contact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem_west = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 2, .y = 4 }, .{ .x = 2, .y = 9 } };
    const stem_east = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 16, .y = 4 }, .{ .x = 16, .y = 9 } };
    var pa = path(&stem_west);
    var pb = path(&stem_east);
    try std.testing.expect(try realizedRail(a, &.{ pa, pb }, .source));
    try std.testing.expect(!try realizedRail(a, &.{ pa, pb }, .target));

    const other = [_]Pt{ .{ .x = 11, .y = 0 }, .{ .x = 11, .y = 9 } };
    pb = path(&other);
    try std.testing.expect(!try realizedRail(a, &.{ pa, pb }, .source));

    const recross = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 16, .y = 4 }, .{ .x = 16, .y = 6 }, .{ .x = 2, .y = 6 }, .{ .x = 2, .y = 8 } };
    pa = path(&stem_west);
    pb = path(&recross);
    try std.testing.expect(!try realizedRail(a, &.{ pa, pb }, .source));
}

test "realizedRail read from the target end accepts a fan-in rail, a straight member included, and refuses re-contact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const from_west = [_]Pt{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const from_east = [_]Pt{ .{ .x = 16, .y = 0 }, .{ .x = 16, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const straight = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 9 } };
    const pw = path(&from_west);
    const pe = path(&from_east);
    const ps = path(&straight);
    try std.testing.expect(try realizedRail(a, &.{ pw, pe, ps }, .target));
    try std.testing.expect(!try realizedRail(a, &.{ pw, pe, ps }, .source));

    const retouch = [_]Pt{ .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 3 }, .{ .x = 16, .y = 3 }, .{ .x = 16, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const pr = path(&retouch);
    try std.testing.expect(!try realizedRail(a, &.{ pw, pr }, .target));
}

fn path(poly: []const Pt) sketch.EdgePath {
    return .{
        .id = 0,
        .from = 0,
        .to = 1,
        .polyline = poly,
        .port_from = .{ .node = 0, .side = .south, .offset = 0 },
        .port_to = .{ .node = 1, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    };
}

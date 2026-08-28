//! cluster/bridge_trunks.zig — selective realization of cross-border bundles.
//!
//! A LICENSED shared-source group of crossings (same original endpoint, same
//! licence tier as a piece fan — base/rail_star.checkLicence) whose pends
//! left one exit port is already ONE rail in geometry; what it lacks is a
//! clean rail row. `overrideJogs` moves the group's shared jog jointly to the
//! least-conflicted coordinate, judged exactly like the gated dodge
//! (committed scene + tentative non-member ink; a shared port is a licensed
//! rail, never an obstacle). The caller re-builds the whole set and ships the
//! trunk ONLY on a strict whole-scene win — realization is a measured choice,
//! never a global switch.
//!
//! `realizedTrunk` is the plan tier's witness over FINAL geometry: a group
//! realized a trunk iff every routed member leaves one shared point and the
//! members never touch again past the shared prefix — the shape on which a
//! structural sanction is inert away from the trunk (the always-on failure
//! mode was sanctioning member-vs-member contact AWAY from the approach).
//!
//! PURE DATA: pends/paths in, jog mutations + one predicate out. Imports the
//! cluster-internal bridges.zig / bridge_scene.zig / tracks.zig plus sketch,
//! sem_graph, base/ledger.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const bridges = @import("bridges.zig");
const scene = @import("bridge_scene.zig");
const tracks = @import("tracks.zig");

const Pt = sketch.Point;

/// Jointly re-place the shared jog of every licensed shared-source group.
/// Mutates `pends`; returns true iff any jog moved (so the caller knows a
/// rebuild can differ at all).
pub fn overrideJogs(
    arena: std.mem.Allocator,
    pends: []bridges.Pending,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
) error{OutOfMemory}!bool {
    var changed = false;
    const done = try arena.alloc(bool, pends.len);
    @memset(done, false);
    for (pends, 0..) |p0, i| {
        if (done[i] or p0.cross.from == p0.cross.to or p0.cross.kind == .invisible) continue;
        var members: std.ArrayListUnmanaged(usize) = .empty;
        for (pends[i..], i..) |q, j| {
            if (q.cross.from != p0.cross.from or q.cross.from == q.cross.to or q.cross.kind == .invisible) continue;
            done[j] = true;
            try members.append(arena, j);
        }
        if (members.items.len < 2) continue;
        if (!try licensedOut(arena, pends, members.items)) continue;
        if (!try trunkable(arena, pends, members.items, placements)) continue;
        if (try chooseJog(arena, pends, members.items, placements, clusters, obstacles)) |c| {
            for (members.items) |mi| pends[mi].jog = c;
            changed = true;
        }
    }
    return changed;
}

/// The exit-side licence over the group — the same geometry-free tier a
/// piece fan answers, members keyed by root edge ids.
fn licensedOut(
    arena: std.mem.Allocator,
    pends: []const bridges.Pending,
    members: []const usize,
) error{OutOfMemory}!bool {
    const rows = try arena.alloc(ledger.RailLicenceMember, members.len);
    for (members, rows) |mi, *row| {
        const c = pends[mi].cross;
        row.* = .{
            .edge = if (c.origin == sg.SENTINEL) c.id else c.origin,
            .endpoints = .{ c.from, c.to },
            .arrows = .{ c.arrow_from, c.arrow_to },
            .kind = c.kind,
            .pivot_end = .source,
        };
    }
    return ledger.checkRailLicence(.{
        .id = 1,
        .polarity = .out,
        .pivot = pends[members[0]].cross.from,
        .members = rows,
    }).isValid();
}

/// A group is trunk-shaped only when every member left ONE exit port on one
/// side, each carries a jog to move, and none was re-routed as a corridor
/// (whose descent column this layer never chose).
fn trunkable(
    arena: std.mem.Allocator,
    pends: []const bridges.Pending,
    members: []const usize,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}!bool {
    const p0 = pends[members[0]];
    for (members) |mi| {
        const m = pends[mi];
        if (m.jog == null) return false;
        if (m.sides.exit != p0.sides.exit) return false;
        if (m.start.x != p0.start.x or m.start.y != p0.start.y) return false;
        if (try bridges.rerouted(arena, m, placements)) return false;
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
    for (pends, 0..) |q, qi| {
        if (inGroup(members, qi)) continue;
        if (q.start.x == p0.start.x and q.start.y == p0.start.y) continue;
        const qv = (q.sides.exit == .north or q.sides.exit == .south);
        const qb = boundsOf(q);
        const qj: ?i32 = if (q.jog) |qq| scene.clampBetween(qb[0], qb[1], qq) else null;
        try scene.tentInk(arena, &heads, &runs, q.start, q.end, qv, qj, q.cross.arrow_from != .none, q.cross.arrow_to != .none);
    }
    const aug = tracks.Obstacles{ .heads = heads.items, .runs = runs.items };

    // A group already conflict-free keeps its coordinate; otherwise the
    // NEAREST strictly-better coordinate wins (the dodge's own search
    // shape), and the whole-scene gate still arbitrates the ship.
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
/// trunk choice and its gate use this fuller picture LOCALLY, so a rail can
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

/// One whole-set conflict total for finished paths against `base`, each path
/// also scored against the ink of the paths before it — the comparison the
/// trunk gate runs on both the incumbent and the trunked set.
pub fn sceneScore(
    arena: std.mem.Allocator,
    paths: []const sketch.EdgePath,
    base: tracks.Obstacles,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
) error{OutOfMemory}!u64 {
    var heads: std.ArrayListUnmanaged(Pt) = .empty;
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try heads.appendSlice(arena, base.heads);
    try runs.appendSlice(arena, base.runs);
    var total: u64 = 0;
    for (paths) |p| {
        const dyn = tracks.Obstacles{ .heads = heads.items, .runs = runs.items };
        total += scene.polyScore(p.polyline, dyn) + scene.boxScore(p.polyline, p.from, p.to, placements, clusters);
        try scene.commitPoly(arena, &heads, &runs, p.polyline, p.arrow_from != .none, p.arrow_to != .none);
    }
    return total;
}

fn inGroup(members: []const usize, i: usize) bool {
    for (members) |m| {
        if (m == i) return true;
    }
    return false;
}

/// True iff the routed members ARE one trunk: every path leaves one shared
/// point and, past the pairwise shared prefix, no two members touch again.
pub fn realizedTrunk(
    arena: std.mem.Allocator,
    paths: []const sketch.EdgePath,
) error{OutOfMemory}!bool {
    if (paths.len < 2) return false;
    for (paths) |p| {
        if (p.polyline.len == 0) return false;
    }
    const first = paths[0].polyline[0];
    for (paths[1..]) |p| {
        if (p.polyline[0].x != first.x or p.polyline[0].y != first.y) return false;
    }
    for (paths, 0..) |a, i| {
        for (paths[i + 1 ..]) |b| {
            if (!try cleanSplit(arena, a.polyline, b.polyline)) return false;
        }
    }
    return true;
}

/// Two member polylines share a prefix from the pivot and then stay apart.
fn cleanSplit(arena: std.mem.Allocator, pa: []const Pt, pb: []const Pt) error{OutOfMemory}!bool {
    const ca = try cellsOf(arena, pa);
    const cb = try cellsOf(arena, pb);
    var k: usize = 0;
    while (k < ca.len and k < cb.len and ca[k].x == cb[k].x and ca[k].y == cb[k].y) : (k += 1) {}
    for (ca[k..]) |p| {
        if (scene.cellIn(cb[k..], p)) return false;
    }
    return true;
}

/// The polyline expanded to unit-step cells, endpoints included.
fn cellsOf(arena: std.mem.Allocator, poly: []const Pt) error{OutOfMemory}![]const Pt {
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
    return out.toOwnedSlice(arena);
}

test "realizedTrunk accepts a shared stem with disjoint tails and refuses re-contact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stem_west = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 2, .y = 4 }, .{ .x = 2, .y = 9 } };
    const stem_east = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 16, .y = 4 }, .{ .x = 16, .y = 9 } };
    var pa = path(&stem_west);
    var pb = path(&stem_east);
    try std.testing.expect(try realizedTrunk(a, &.{ pa, pb }));

    // Split starts: not one trunk.
    const other = [_]Pt{ .{ .x = 11, .y = 0 }, .{ .x = 11, .y = 9 } };
    pb = path(&other);
    try std.testing.expect(!try realizedTrunk(a, &.{ pa, pb }));

    // Re-contact past the split: the tail of one member crosses back onto
    // the other's tail cell — refused.
    const recross = [_]Pt{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 4 }, .{ .x = 16, .y = 4 }, .{ .x = 16, .y = 6 }, .{ .x = 2, .y = 6 }, .{ .x = 2, .y = 8 } };
    pa = path(&stem_west);
    pb = path(&recross);
    try std.testing.expect(!try realizedTrunk(a, &.{ pa, pb }));
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

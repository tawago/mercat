const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const tracks = @import("tracks.zig");
const scene = @import("bridge_scene.zig");
const corridors = @import("corridors.zig");
const requests = @import("bridge_requests.zig");
const bridge_rails = @import("bridge_rails.zig");
const types = @import("bridge_types.zig");

pub const Crossing = types.Crossing;
const Pending = types.Pending;
const Sides = types.Sides;

pub fn route(
    arena: std.mem.Allocator,
    crossings: []const Crossing,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    rails: []const sketch.Rail,
    edge_paths: []const sketch.EdgePath,
    dir: sketch.Direction,
    orig_to_merged: []const sketch.NodeId,
    build: prim.BridgeBuild,
) error{OutOfMemory}![]sketch.EdgePath {
    const obstacles = try sceneObstacles(arena, rails, edge_paths);
    var pends: std.ArrayListUnmanaged(Pending) = .empty;
    for (crossings) |c| {
        if (c.from >= orig_to_merged.len or c.to >= orig_to_merged.len) continue;
        const gf = orig_to_merged[c.from];
        const gt = orig_to_merged[c.to];
        if (gf == sg.SENTINEL or gt == sg.SENTINEL) continue;
        const from_p = sketch.placementById(placements, gf) orelse continue;
        const to_p = sketch.placementById(placements, gt) orelse continue;

        const from_box = boxOf(clusters, from_p) orelse from_p.rect;
        const to_box = boxOf(clusters, to_p) orelse to_p.rect;
        const sides = relSides(from_box, to_box, dir);
        const start = portPoint(from_p.rect, sides.exit);
        const end = portPoint(to_p.rect, sides.entry);

        try pends.append(arena, .{
            .cross = c,
            .gf = gf,
            .gt = gt,
            .from_rect = from_p.rect,
            .to_rect = to_p.rect,
            .to_box = to_box,
            .sides = sides,
            .start = start,
            .end = end,
            .off_from = corridors.sideOffset(from_p.rect, sides.exit),
            .off_to = corridors.sideOffset(to_p.rect, sides.entry),
            .from_frame = corridors.drawnFrame(clusters, from_p),
            .to_frame = corridors.drawnFrame(clusters, to_p),
            .pref = null,
        });
    }

    for (pends.items) |*p| p.resetJog();
    try requests.assignJogs(arena, pends.items, clusters, obstacles);

    const pairs = try arena.alloc(corridors.Pair, pends.items.len);
    for (pends.items, pairs) |p, *q| {
        const exit_frame: ?sketch.ClusterId = if (scene.rerouted(p, placements)) null else p.from_frame;
        q.* = .{
            .from = .{ .node = p.gf, .rect = p.from_rect, .side = p.sides.exit, .frame = exit_frame },
            .to = .{ .node = p.gt, .rect = p.to_rect, .side = p.sides.entry, .frame = p.to_frame },
        };
    }
    for (pends.items, try corridors.discipline(arena, pairs, clusters, placements)) |*p, r| {
        corridors.slide(&p.start, p.sides.exit, r.from_coord);
        corridors.slide(&p.end, p.sides.entry, r.to_coord);
        p.off_from = r.from_off;
        p.off_to = r.to_off;
        p.resetJog();
    }

    for (pends.items, 0..) |*p, pi| {
        const shared_start = p.start;
        if (slideOffHeads(&p.start, p.sides.exit, p.gf, p.from_rect, obstacles, pends.items, pi)) {
            p.off_from = corridors.portOffset(p.from_rect, p.sides.exit, faceCoord(p.start, p.sides.exit));
            p.resetJog();
            for (pends.items[pi + 1 ..]) |*q| {
                if (q.start.x != shared_start.x or q.start.y != shared_start.y) continue;
                q.start = p.start;
                q.off_from = p.off_from;
                q.resetJog();
            }
        }
    }

    try requests.assignJogs(arena, pends.items, clusters, obstacles);

    if (build == .railed) {
        const full = try bridge_rails.withStaticRuns(arena, obstacles, edge_paths);
        try bridge_rails.overrideJogs(arena, pends.items, placements, clusters, full);
    }
    return buildPaths(arena, pends.items, placements, clusters, obstacles, build == .dodged);
}

fn buildPaths(
    arena: std.mem.Allocator,
    pends_src: []const Pending,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
    enable_dodge: bool,
) error{OutOfMemory}![]sketch.EdgePath {
    const pends = try arena.dupe(Pending, pends_src);
    var dyn_heads: std.ArrayListUnmanaged(Pt) = .empty;
    var dyn_runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try dyn_heads.appendSlice(arena, obstacles.heads);
    try dyn_runs.appendSlice(arena, obstacles.runs);
    var out: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
    for (pends, 0..) |*p, pi| {
        const dyn = tracks.Obstacles{ .heads = dyn_heads.items, .runs = dyn_runs.items };
        const reroute = scene.rerouted(p.*, placements);
        if (enable_dodge) {
            if (requests.leaderJog(pends[0..pi], p.*)) |j| {
                p.jog = j;
            } else if (p.jog != null and !reroute) {
                p.jog = try dodgeJog(arena, p.*, pi, pends, placements, clusters, dyn);
            }
        }
        const poly = if (reroute)
            try scene.verticalCorridor(arena, p.start, p.end, p.to_box, p.sides.exit, placements, p.gf, p.gt, clusters, if (enable_dodge) dyn else obstacles)
        else
            try p.elbow().dupe(arena);
        try scene.commitPoly(arena, &dyn_heads, &dyn_runs, poly, p.cross.arrow_from != .none, p.cross.arrow_to != .none);

        try out.append(arena, .{
            .id = p.cross.id,
            .from = p.gf,
            .to = p.gt,
            .polyline = poly,
            .port_from = .{ .node = p.gf, .side = p.sides.exit, .offset = p.off_from },
            .port_to = .{ .node = p.gt, .side = p.sides.entry, .offset = p.off_to },
            .arrow_from = p.cross.arrow_from,
            .arrow_to = p.cross.arrow_to,
            .label = p.cross.label,
            .kind = p.cross.kind,
            .role = .forward,
        });
    }
    return out.toOwnedSlice(arena);
}

fn dodgeJog(
    arena: std.mem.Allocator,
    p: Pending,
    pi: usize,
    pends: []const Pending,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    dyn: tracks.Obstacles,
) error{OutOfMemory}!?i32 {
    const j = p.jog orelse return null;
    const vertical = p.vertical();
    const bound_lo, const bound_hi = p.bounds();
    const jc = types.clampBetween(bound_lo, bound_hi, j);

    var heads: std.ArrayListUnmanaged(Pt) = .empty;
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try heads.appendSlice(arena, dyn.heads);
    try runs.appendSlice(arena, dyn.runs);
    for (pends[pi + 1 ..]) |q| {
        if (requests.sharesPort(q, p)) continue;
        try scene.tentInk(arena, &heads, &runs, q);
    }
    const aug = tracks.Obstacles{ .heads = heads.items, .runs = runs.items };

    const cur = scene.jogScore(p.start, p.end, jc, vertical, placements, p.gf, p.gt, clusters, aug);
    if (cur == 0) return j;
    const sign = tracks.outwardSign(p.sides.entry);
    const width = bound_hi - bound_lo;
    var best: ?i32 = null;
    var best_score = cur;
    var d: i32 = 1;
    while (d <= width) : (d += 1) {
        for ([2]i32{ jc + sign * d, jc - sign * d }) |c| {
            if (c <= bound_lo or c >= bound_hi) continue;
            const s = scene.jogScore(p.start, p.end, c, vertical, placements, p.gf, p.gt, clusters, aug);
            if (s == 0) return c;
            if (s < best_score) {
                best_score = s;
                best = c;
            }
        }
    }
    return best orelse j;
}

pub const sceneObstacles = scene.sceneObstacles;

fn faceCoord(p: Pt, side: sketch.Dir4) i32 {
    return switch (side) {
        .north, .south => p.x,
        .east, .west => p.y,
    };
}

fn outwardCell(rect: sketch.Rect, side: sketch.Dir4, c: i32) Pt {
    return switch (side) {
        .north => .{ .x = c, .y = rect.y - 1 },
        .south => .{ .x = c, .y = rect.bottom() },
        .west => .{ .x = rect.x - 1, .y = c },
        .east => .{ .x = rect.right(), .y = c },
    };
}

const cellIn = scene.cellIn;

fn slideOffHeads(
    port: *Pt,
    side: sketch.Dir4,
    node: sketch.NodeId,
    rect: sketch.Rect,
    obstacles: tracks.Obstacles,
    pends: []const Pending,
    self: usize,
) bool {
    if (obstacles.heads.len == 0) return false;
    const c0 = faceCoord(port.*, side);
    if (!cellIn(obstacles.heads, outwardCell(rect, side, c0))) return false;
    const rng = corridors.faceRange(rect, side);
    var d: i32 = 1;
    while (d <= rng.hi - rng.lo) : (d += 1) {
        for ([2]i32{ c0 + d, c0 - d }) |c| {
            if (c < rng.lo or c > rng.hi) continue;
            if (obstacles.covers(outwardCell(rect, side, c))) continue;
            if (faceTaken(pends, self, node, side, c)) continue;
            corridors.slide(port, side, c);
            return true;
        }
    }
    return false;
}

fn faceTaken(pends: []const Pending, self: usize, node: sketch.NodeId, side: sketch.Dir4, c: i32) bool {
    for (pends, 0..) |q, qi| {
        if (qi == self) continue;
        if (q.gf == node and q.sides.exit == side and faceCoord(q.start, side) == c) return true;
        if (q.gt == node and q.sides.entry == side and faceCoord(q.end, side) == c) return true;
    }
    return false;
}

fn boxOf(clusters: []const sketch.ClusterFrame, p: sketch.NodePlacement) ?sketch.Rect {
    return corridors.rectOf(clusters, p.cluster_id orelse return null);
}

fn relSides(f: sketch.Rect, t: sketch.Rect, dir: sketch.Direction) Sides {
    const x_overlap = f.x < t.right() and t.x < f.right();
    const y_overlap = f.y < t.bottom() and t.y < f.bottom();
    const fc = center(f);
    const tc = center(t);
    const dx = tc.x - fc.x;
    const dy = tc.y - fc.y;
    const flow_vertical = (dir == .TD or dir == .BT);

    const vertical = if (!y_overlap and !x_overlap)
        flow_vertical
    else
        !y_overlap;

    if (vertical) {
        return if (dy >= 0) .{ .exit = .south, .entry = .north } else .{ .exit = .north, .entry = .south };
    }
    return if (dx >= 0) .{ .exit = .east, .entry = .west } else .{ .exit = .west, .entry = .east };
}

const Pt = sketch.Point;
fn center(r: sketch.Rect) Pt {
    return .{ .x = r.x + @divTrunc(@as(i32, @intCast(r.w)), 2), .y = r.y + @divTrunc(@as(i32, @intCast(r.h)), 2) };
}

fn portPoint(r: sketch.Rect, side: sketch.Dir4) Pt {
    const off: i32 = @intCast(corridors.sideOffset(r, side));
    return switch (side) {
        .north => .{ .x = r.x + off, .y = r.y },
        .south => .{ .x = r.x + off, .y = r.bottom() - 1 },
        .west => .{ .x = r.x, .y = r.y + off },
        .east => .{ .x = r.right() - 1, .y = r.y + off },
    };
}

test {
    _ = @import("bridges_test.zig");
}

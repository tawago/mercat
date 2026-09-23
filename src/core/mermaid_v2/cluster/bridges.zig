const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const tracks = @import("tracks.zig");
const scene = @import("bridge_scene.zig");
const corridors = @import("corridors.zig");
const requests = @import("bridge_requests.zig");
const bridge_rails = @import("bridge_rails.zig");

pub const Crossing = struct {
    id: sketch.EdgeId,
    from: sg.NodeId,
    to: sg.NodeId,
    kind: sketch.EdgeKind,
    arrow_from: sketch.ArrowKind,
    arrow_to: sketch.ArrowKind,
    label: ?[]const u8,
    origin: sg.EdgeId = sg.SENTINEL,
    proxy: sg.EdgeId = sg.SENTINEL,
};

pub fn route(
    arena: std.mem.Allocator,
    crossings: []const Crossing,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    rails: []const sketch.Rail,
    edge_paths: []const sketch.EdgePath,
    dir: sketch.Direction,
    orig_to_merged: []const sketch.NodeId,
    expired: ?*u32,
    build: prim.BridgeBuild,
) error{OutOfMemory}![]sketch.EdgePath {
    const obstacles = try sceneObstacles(arena, rails, edge_paths);
    var pends: std.ArrayListUnmanaged(Pending) = .empty;
    for (crossings) |c| {
        if (c.from >= orig_to_merged.len or c.to >= orig_to_merged.len) continue;
        const gf = orig_to_merged[c.from];
        const gt = orig_to_merged[c.to];
        if (gf == sg.SENTINEL or gt == sg.SENTINEL) continue;
        const from_p = placementById(placements, gf) orelse continue;
        const to_p = placementById(placements, gt) orelse continue;

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
            .off_from = sideOffset(from_p.rect, sides.exit),
            .off_to = sideOffset(to_p.rect, sides.entry),
            .from_frame = corridors.drawnFrame(clusters, from_p),
            .to_frame = corridors.drawnFrame(clusters, to_p),
            .pref = null,
            .anchor = anchorOf(clusters, to_p, gt),
        });
    }

    // @guarded-by: bridges_test.zig "a re-routed corridor raises no crossing demand on the frame it leaves"
    for (pends.items) |*p| p.pref = jogPref(p.start, p.end, p.sides.exit, p.to_box);
    try requests.assignJogs(arena, pends.items, clusters, obstacles, null);

    const pairs = try arena.alloc(corridors.Pair, pends.items.len);
    for (pends.items, pairs) |p, *q| {
        const exit_frame: ?sketch.ClusterId = if (try rerouted(arena, p, placements)) null else p.from_frame;
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
        p.pref = jogPref(p.start, p.end, p.sides.exit, p.to_box);
        p.jog = null;
    }

    for (pends.items, 0..) |*p, pi| {
        const shared_start = p.start;
        if (slideOffHeads(&p.start, p.sides.exit, p.gf, p.from_rect, obstacles, pends.items, pi)) {
            p.off_from = corridors.portOffset(p.from_rect, p.sides.exit, faceCoord(p.start, p.sides.exit));
            p.pref = jogPref(p.start, p.end, p.sides.exit, p.to_box);
            p.jog = null;
            for (pends.items[pi + 1 ..]) |*q| {
                if (q.start.x != shared_start.x or q.start.y != shared_start.y) continue;
                q.start = p.start;
                q.off_from = p.off_from;
                q.pref = jogPref(q.start, q.end, q.sides.exit, q.to_box);
                q.jog = null;
            }
        }
    }

    var jog_expired: u32 = 0;
    try requests.assignJogs(arena, pends.items, clusters, obstacles, &jog_expired);

    if (build == .railed) {
        const full = try bridge_rails.withStaticRuns(arena, obstacles, edge_paths);
        _ = try bridge_rails.overrideJogs(arena, pends.items, placements, clusters, full);
    }
    const built = try buildPaths(arena, pends.items, placements, clusters, obstacles, build == .dodged);
    if (expired) |e| e.* += jog_expired + built.expired;
    return built.paths;
}

const Built = struct { paths: []sketch.EdgePath, expired: u32 };

fn buildPaths(
    arena: std.mem.Allocator,
    pends_src: []const Pending,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
    enable_dodge: bool,
) error{OutOfMemory}!Built {
    const pends = try arena.dupe(Pending, pends_src);
    var dyn_heads: std.ArrayListUnmanaged(Pt) = .empty;
    var dyn_runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try dyn_heads.appendSlice(arena, obstacles.heads);
    try dyn_runs.appendSlice(arena, obstacles.runs);
    var out: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
    var expired: u32 = 0;
    for (pends, 0..) |*p, pi| {
        const dyn = tracks.Obstacles{ .heads = dyn_heads.items, .runs = dyn_runs.items };
        const reroute = try rerouted(arena, p.*, placements);
        if (enable_dodge) {
            if (requests.leaderJog(pends[0..pi], p.*)) |j| {
                p.jog = j;
            } else if (p.jog != null and !reroute) {
                p.jog = try dodgeJog(arena, p.*, pi, pends, placements, clusters, dyn);
            }
        }
        var poly = try buildElbow(arena, p.*);
        if (reroute) {
            poly = try verticalCorridor(arena, p.start, p.end, p.to_box, p.sides.exit, placements, p.gf, p.gt, clusters, if (enable_dodge) dyn else obstacles, &expired);
        }
        try commitScene(arena, &dyn_heads, &dyn_runs, poly, p.cross);

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
    return .{ .paths = try out.toOwnedSlice(arena), .expired = expired };
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
    const vertical = (p.sides.exit == .north or p.sides.exit == .south);
    const bound_lo: i32, const bound_hi: i32 = switch (p.sides.exit) {
        .south => .{ p.start.y, p.end.y },
        .north => .{ p.end.y, p.start.y },
        .east => .{ p.start.x, p.end.x },
        .west => .{ p.end.x, p.start.x },
    };
    const jc = clampBetween(bound_lo, bound_hi, j);

    var heads: std.ArrayListUnmanaged(Pt) = .empty;
    var runs: std.ArrayListUnmanaged([2]Pt) = .empty;
    try heads.appendSlice(arena, dyn.heads);
    try runs.appendSlice(arena, dyn.runs);
    for (pends[pi + 1 ..]) |q| {
        if (requests.sharesPort(q, p)) continue;
        const qv = (q.sides.exit == .north or q.sides.exit == .south);
        const qj: ?i32 = if (q.jog) |qq| switch (q.sides.exit) {
            .south => clampBetween(q.start.y, q.end.y, qq),
            .north => clampBetween(q.end.y, q.start.y, qq),
            .east => clampBetween(q.start.x, q.end.x, qq),
            .west => clampBetween(q.end.x, q.start.x, qq),
        } else null;
        try scene.tentInk(arena, &heads, &runs, q.start, q.end, qv, qj, q.cross.arrow_from != .none, q.cross.arrow_to != .none);
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

fn commitScene(
    arena: std.mem.Allocator,
    heads: *std.ArrayListUnmanaged(Pt),
    runs: *std.ArrayListUnmanaged([2]Pt),
    poly: []const sketch.Point,
    cross: Crossing,
) error{OutOfMemory}!void {
    try scene.commitPoly(arena, heads, runs, poly, cross.arrow_from != .none, cross.arrow_to != .none);
}

pub fn rerouted(
    arena: std.mem.Allocator,
    p: Pending,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}!bool {
    if (p.sides.exit != .north and p.sides.exit != .south) return false;
    return polyIntrudes(try buildElbow(arena, p), placements, p.gf, p.gt);
}

pub const Pending = struct {
    cross: Crossing,
    gf: sketch.NodeId,
    gt: sketch.NodeId,
    from_rect: sketch.Rect,
    to_rect: sketch.Rect,
    to_box: sketch.Rect,
    sides: Sides,
    start: Pt,
    end: Pt,
    off_from: u32,
    off_to: u32,
    from_frame: ?sketch.ClusterId,
    to_frame: ?sketch.ClusterId,
    pref: ?i32,
    anchor: Anchor,
    jog: ?i32 = null,
    rail_end: requests.RailEnd = .start,
};

const Anchor = struct { frame: bool, id: u32 };

fn anchorOf(clusters: []const sketch.ClusterFrame, p: sketch.NodePlacement, merged_id: sketch.NodeId) Anchor {
    var cid = p.cluster_id;
    var guard: u32 = 0;
    while (cid) |id| : (guard += 1) {
        if (guard > 64) break;
        const f = frameById(clusters, id) orelse break;
        if (!f.synthetic) return .{ .frame = true, .id = id };
        cid = f.parent_id;
    }
    return .{ .frame = false, .id = merged_id };
}

fn frameById(clusters: []const sketch.ClusterFrame, id: sketch.ClusterId) ?sketch.ClusterFrame {
    for (clusters) |c| {
        if (c.id == id) return c;
    }
    return null;
}

fn jogPref(start: Pt, end: Pt, exit: sketch.Dir4, to_box: sketch.Rect) ?i32 {
    return switch (exit) {
        .south => if (start.x == end.x) null else @min(to_box.y - 1, end.y - 2),
        .north => if (start.x == end.x) null else @max(to_box.bottom(), end.y + 2),
        .east => if (start.y == end.y) null else @min(to_box.x - 1, end.x - 2),
        .west => if (start.y == end.y) null else @max(to_box.right(), end.x + 2),
    };
}

pub const sceneObstacles = scene.sceneObstacles;
const stepDir = scene.stepDir;
const stepPt = scene.stepPt;

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
    const cid = p.cluster_id orelse return null;
    for (clusters) |c| {
        if (c.id == cid) return c.rect;
    }
    return null;
}

const Sides = struct { exit: sketch.Dir4, entry: sketch.Dir4 };

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

fn buildElbow(arena: std.mem.Allocator, p: Pending) error{OutOfMemory}![]sketch.Point {
    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(arena, p.start);
    if (p.jog) |j| {
        const jc = switch (p.sides.exit) {
            .south => clampBetween(p.start.y, p.end.y, j),
            .north => clampBetween(p.end.y, p.start.y, j),
            .east => clampBetween(p.start.x, p.end.x, j),
            .west => clampBetween(p.end.x, p.start.x, j),
        };
        const vertical = (p.sides.exit == .north or p.sides.exit == .south);
        if (vertical) {
            try poly.append(arena, .{ .x = p.start.x, .y = jc });
            try poly.append(arena, .{ .x = p.end.x, .y = jc });
        } else {
            try poly.append(arena, .{ .x = jc, .y = p.start.y });
            try poly.append(arena, .{ .x = jc, .y = p.end.y });
        }
    }
    try poly.append(arena, p.end);
    return try poly.toOwnedSlice(arena);
}

const verticalCorridor = scene.verticalCorridor;
const polyIntrudes = scene.polyIntrudes;
const clampBetween = scene.clampBetween;

const Pt = sketch.Point;
fn center(r: sketch.Rect) Pt {
    return .{ .x = r.x + @divTrunc(@as(i32, @intCast(r.w)), 2), .y = r.y + @divTrunc(@as(i32, @intCast(r.h)), 2) };
}

fn sideOffset(r: sketch.Rect, side: sketch.Dir4) u32 {
    return corridors.sideOffset(r, side);
}

fn portPoint(r: sketch.Rect, side: sketch.Dir4) Pt {
    const off: i32 = @intCast(sideOffset(r, side));
    return switch (side) {
        .north => .{ .x = r.x + off, .y = r.y },
        .south => .{ .x = r.x + off, .y = r.bottom() - 1 },
        .west => .{ .x = r.x, .y = r.y + off },
        .east => .{ .x = r.right() - 1, .y = r.y + off },
    };
}

fn placementById(placements: []const sketch.NodePlacement, id: sketch.NodeId) ?sketch.NodePlacement {
    for (placements) |p| {
        if (p.id == id) return p;
    }
    return null;
}

test {
    _ = @import("bridges_test.zig");
}

//! cluster/bridges.zig — routes cross-border edges (an edge whose endpoints
//! `split` placed in different pieces) in the merged Sketch, after `stitch`
//! has given both endpoints final coordinates. Lays a plain orthogonal elbow
//! between perimeters — no new layout router needed. Raster turns crossed
//! borders into clean T-junctions and skips node-interior collisions.
//!
//! Track discipline (tracks.zig): jogs are displaced off drawn cluster-frame
//! borders; overlapping same-side bridges get distinct stacked tracks, but
//! bridges sharing one port — source or target — share a track (fan rail;
//! bridge_requests.zig keys the requests).
//!
//! Corridor discipline (corridors.zig): each border a bridge crosses carries
//! at most ONE corridor per display column, and never one on a frame corner;
//! an offending port slides along its own node face until both hold.
//!
//! Routing VARIANTS (plain / dodged / railed) are a caller decision
//! (`prim.BridgeBuild`, from LayoutOptions): this router constructs exactly
//! the variant it is told to and never picks between them — the variants
//! are laid out as candidates and the selection stage's composite score
//! against the real raster decides (confluence selection note).
//!
//! PURE DATA: Sketch geometry in, Sketch edges out. Imports only std, prim,
//! sem_graph, sketch, and the cluster-internal tracks.zig / corridors.zig /
//! bridge_scene.zig / bridge_requests.zig / bridge_rails.zig (licensed
//! shared-port rail realization).

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const tracks = @import("tracks.zig");
const scene = @import("bridge_scene.zig");
const corridors = @import("corridors.zig");
const requests = @import("bridge_requests.zig");
const bridge_rails = @import("bridge_rails.zig");

/// One original edge that crosses a piece boundary. Endpoints are ORIGINAL
/// SemGraph node ids (resolved to merged placements via `orig_to_merged`).
pub const Crossing = struct {
    id: sketch.EdgeId,
    from: sg.NodeId,
    to: sg.NodeId,
    kind: sketch.EdgeKind,
    arrow_from: sketch.ArrowKind,
    arrow_to: sketch.ArrowKind,
    label: ?[]const u8,
    /// Root-graph EdgeId of the declared edge this crossing renders
    /// (SENTINEL only for hand-built test crossings). Same identity rule as
    /// `sem_graph.Edge.origin`.
    origin: sg.EdgeId = sg.SENTINEL,
    /// The outer piece's placement edge that stands for this crossing
    /// (SENTINEL for hand-built test crossings): the gap rows the outer
    /// ledger claimed for the bridge are filed under it.
    proxy: sg.EdgeId = sg.SENTINEL,
};

/// Route every crossing into an orthogonal `EdgePath` between its endpoints'
/// merged placements. `orig_to_merged[orig_id]` gives the merged node id, or
/// `sg.SENTINEL` if the endpoint was dropped (defensive — skipped). `clusters`
/// supplies each subgraph's box so the connector can jog in the open gap
/// BETWEEN boxes rather than along a box's inner inset row.
pub fn route(
    arena: std.mem.Allocator,
    crossings: []const Crossing,
    placements: []const sketch.NodePlacement,
    clusters: []const sketch.ClusterFrame,
    rails: []const sketch.Rail,
    edge_paths: []const sketch.EdgePath,
    dir: sketch.Direction,
    orig_to_merged: []const sketch.NodeId,
    /// Counts border-clearance searches that expired on SHIPPED coordinates
    /// (tracks.zig surrender); tentative or unshipped attempts never count.
    expired: ?*u32,
    /// Which routing variant to construct (see the module doc). `.railed`
    /// with no licensed group (or no jog moved) builds the plain geometry.
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

    // Pass 2: per-column crossing discipline (corridors.zig). Each corridor
    // meets its frames at one border cell each; two corridors may not meet
    // the same one and none may meet a corner. The fix is a sideways slide
    // of the offending PORT along its own node face, so the corridor stays
    // orthogonal and its final run stays perpendicular.
    //
    // The slide only MOVES a crossing where the port coordinate IS the
    // crossing coordinate. An entry always qualifies: its jog sits outside
    // the target's frame, so the final perpendicular leg is what meets the
    // border. An exit qualifies unless pass 3 re-routes it as an
    // obstacle-aware `verticalCorridor`, which jogs one row off the source —
    // INSIDE the frame — and then meets the border at its descent column,
    // a coordinate this layer never chose. Sliding such a port de-centres
    // the arrow foot and resolves nothing, so that end raises no demand.
    // Deciding it needs the tentative jogs, which need only the centred
    // ports the re-route itself will keep.
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

/// One whole-set routing attempt. If a vertical elbow would run straight
/// through a node interior, re-route as a corridor that jogs into a clear
/// column before descending; gating on an actual intrusion keeps every
/// non-intruding seed byte-identical.
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

/// Displace `p`'s jog inside its clamp interval to the least-conflicted
/// coordinate, judged against the committed scene PLUS the tentative elbows
/// of the bridges still to route (shared-port peers excepted — a shared port
/// is a licensed rail, never an obstacle). The assigned coordinate is kept
/// when it is clear and kept when nothing strictly improves on it.
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

/// File a routed bridge's ink into the growing scene (bridge_scene.zig owns
/// the derivation).
fn commitScene(
    arena: std.mem.Allocator,
    heads: *std.ArrayListUnmanaged(Pt),
    runs: *std.ArrayListUnmanaged([2]Pt),
    poly: []const sketch.Point,
    cross: Crossing,
) error{OutOfMemory}!void {
    try scene.commitPoly(arena, heads, runs, poly, cross.arrow_from != .none, cross.arrow_to != .none);
}

/// True iff the plain elbow for `p` would run straight through a node
/// interior, so pass 3 replaces it with the obstacle-aware
/// `verticalCorridor`. Pass 2 asks this to know whether a slide of the exit
/// port could move that end's border crossing at all — the re-route meets
/// the source frame at its own descent column instead.
pub fn rerouted(
    arena: std.mem.Allocator,
    p: Pending,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}!bool {
    if (p.sides.exit != .north and p.sides.exit != .south) return false;
    return polyIntrudes(try buildElbow(arena, p), placements, p.gf, p.gt);
}

/// One crossing after endpoint/side resolution, before polyline build.
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
    /// Port offsets on the two node faces. They start centred and only move
    /// when the corridor discipline slides one off a taken border column or
    /// a frame corner.
    off_from: u32,
    off_to: u32,
    /// The drawn (non-synthetic) frame each endpoint sits in, or null when
    /// the endpoint is top-level — the frame whose border this corridor
    /// crosses on that side.
    from_frame: ?sketch.ClusterId,
    to_frame: ?sketch.ClusterId,
    /// Preferred jog coordinate (row y for a vertical bridge, column x for a
    /// horizontal one); null when the ports already line up (straight run).
    pref: ?i32,
    /// Same-side grouping key for track assignment.
    anchor: Anchor,
    /// Track-resolved jog coordinate (clamped at polyline build).
    jog: ?i32 = null,
    /// The end whose port keys this pend's jog request (bridge_requests.zig).
    rail_end: requests.RailEnd = .start,
};

/// Grouping anchor: the drawn (non-synthetic) frame the target sits in, or
/// the target node itself when top-level. Synthetic packing frames are
/// walked THROUGH so branches of one packed cluster group together.
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

/// The plain elbow's preferred jog coordinate: in the open gap just outside
/// the target box (one cell past its entry border), but always ≥2 cells back
/// from the port so the final perpendicular run has an interior cell —
/// otherwise the arrowhead inherits the jog's direction. Null = straight.
fn jogPref(start: Pt, end: Pt, exit: sketch.Dir4, to_box: sketch.Rect) ?i32 {
    return switch (exit) {
        .south => if (start.x == end.x) null else @min(to_box.y - 1, end.y - 2),
        .north => if (start.x == end.x) null else @max(to_box.bottom(), end.y + 2),
        .east => if (start.y == end.y) null else @min(to_box.x - 1, end.x - 2),
        .west => if (start.y == end.y) null else @max(to_box.right(), end.x + 2),
    };
}

/// Scene-ink derivation lives in bridge_scene.zig (cap-forced split);
/// re-exported so callers and the derivation test keep one name.
pub const sceneObstacles = scene.sceneObstacles;
const stepDir = scene.stepDir;
const stepPt = scene.stepPt;

/// The port's coordinate along its face (x on a horizontal face, y on a
/// vertical one).
fn faceCoord(p: Pt, side: sketch.Dir4) i32 {
    return switch (side) {
        .north, .south => p.x,
        .east, .west => p.y,
    };
}

/// The cell one step outward from a port at face coordinate `c`.
fn outwardCell(rect: sketch.Rect, side: sketch.Dir4, c: i32) Pt {
    return switch (side) {
        .north => .{ .x = c, .y = rect.y - 1 },
        .south => .{ .x = c, .y = rect.bottom() },
        .west => .{ .x = rect.x - 1, .y = c },
        .east => .{ .x = rect.right(), .y = c },
    };
}

const cellIn = scene.cellIn;

/// If `port`'s outward step lands on a head cell, slide it along its face —
/// nearest interior coordinate first — to one whose outward step touches no
/// scene ink at all (a head repels; landing on a stem or dropper column
/// would only trade the transit for a fused junction) and which no other
/// bridge's port on this face holds. Returns true iff the port moved; an
/// all-blocked face keeps the centre.
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

/// True iff another bridge already holds face coordinate `c` on this node
/// face (either of its ends).
fn faceTaken(pends: []const Pending, self: usize, node: sketch.NodeId, side: sketch.Dir4, c: i32) bool {
    for (pends, 0..) |q, qi| {
        if (qi == self) continue;
        if (q.gf == node and q.sides.exit == side and faceCoord(q.start, side) == c) return true;
        if (q.gt == node and q.sides.entry == side and faceCoord(q.end, side) == c) return true;
    }
    return false;
}

/// The subgraph frame containing `p`, or null if `p` is top-level.
fn boxOf(clusters: []const sketch.ClusterFrame, p: sketch.NodePlacement) ?sketch.Rect {
    const cid = p.cluster_id orelse return null;
    for (clusters) |c| {
        if (c.id == cid) return c.rect;
    }
    return null;
}

const Sides = struct { exit: sketch.Dir4, entry: sketch.Dir4 };

/// Pick which side of each box the line leaves / enters, from the boxes'
/// relative placement and the overall flow direction. Disjoint boxes are
/// separated on at least one axis. When BOTH axes are disjoint (e.g. a
/// top-level node fanning out to subgraphs spread to its left/right), prefer
/// the FLOW axis — a TD/BT graph enters the target's top/bottom and drops in
/// vertically (a clean ▼ through the box border, like a fan rail) rather than
/// poking sideways into the box wall; an LR/RL graph prefers the horizontal.
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

/// Build the orthogonal polyline. A straight run when the ports already line
/// up on the cross-axis; otherwise a single jog at the track-resolved
/// coordinate (see assignJogs), clamped to sit strictly between the two
/// ports, so the final segment crosses the box border and enters the port
/// perpendicular — a clean arrowhead, never a sideways run along a box inset
/// row.
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

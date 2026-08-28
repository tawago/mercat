//! cluster/bridges.zig — routes cross-border edges (an edge whose endpoints
//! `split` placed in different pieces) in the merged Sketch, after `stitch`
//! has given both endpoints final coordinates. Lays a plain orthogonal elbow
//! between perimeters — no new layout router needed. Raster turns crossed
//! borders into clean T-junctions and skips node-interior collisions.
//!
//! Track discipline (tracks.zig): jogs are displaced off drawn cluster-frame
//! borders; overlapping same-side bridges get distinct stacked tracks, but
//! bridges sharing one source port share a track (fan rail).
//!
//! Corridor discipline (corridors.zig): each border a bridge crosses carries
//! at most ONE corridor per display column, and never one on a frame corner;
//! an offending port slides along its own node face until both hold.
//!
//! PURE DATA: Sketch geometry in, Sketch edges out. Imports only std, prim,
//! sem_graph, sketch, and the cluster-internal tracks.zig / corridors.zig /
//! bridge_scene.zig / bridge_trunks.zig (licensed shared-source trunk
//! realization, gated on a strict full-scene win).

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const tracks = @import("tracks.zig");
const scene = @import("bridge_scene.zig");
const corridors = @import("corridors.zig");
const trunks = @import("bridge_trunks.zig");

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
) error{OutOfMemory}![]sketch.EdgePath {
    // Bridges are routed LAST, into a fully-inked scene, so existing ink
    // constrains them: an arrowhead cell refuses any foreign transit, and a
    // collinear run along a trunk or edge stroke fuses into a foreign
    // junction. Heads also repel ports whose outward step would land on
    // them (slideOffHeads).
    const obstacles = try sceneObstacles(arena, rails, edge_paths);
    // Pass 1: resolve endpoints, sides and centred ports. The jog
    // preference waits for pass 2, which may still move a port.
    var pends: std.ArrayListUnmanaged(Pending) = .empty;
    for (crossings) |c| {
        if (c.from >= orig_to_merged.len or c.to >= orig_to_merged.len) continue;
        const gf = orig_to_merged[c.from];
        const gt = orig_to_merged[c.to];
        if (gf == sg.SENTINEL or gt == sg.SENTINEL) continue;
        const from_p = placementById(placements, gf) orelse continue;
        const to_p = placementById(placements, gt) orelse continue;

        // Each endpoint's "box": its containing subgraph frame, or its own
        // rect when top-level. Sides are chosen from how the BOXES face each
        // other (so the line leaves/enters on the correct edge), but the
        // ports sit on the actual NODE perimeters.
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
    // guarded-by: bridges_test.zig "a re-routed corridor raises no crossing demand on the frame it leaves"
    for (pends.items) |*p| p.pref = jogPref(p.start, p.end, p.sides.exit, p.to_box);
    try assignJogs(arena, pends.items, clusters, obstacles);

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

    // An EXIT port whose first outward step is an arrowhead cell shares its
    // face column with a trunk stem or tap: every route out of it transits
    // the head (the rerouted corridor's first leg included, which no jog or
    // corridor demand can move). Slide it to the nearest interior
    // coordinate whose step touches no scene ink and which no other
    // bridge's port on the same face holds. Entry ports stay put — their
    // final leg is corridor-disciplined, and sliding them against a
    // neighbour's head only trades the transit for a fused junction.
    // Bridges sharing one start point are ONE corridor (a shared-port fan)
    // and must slide together or not at all — a split start breaks the
    // port-share the raster licenses.
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

    try assignJogs(arena, pends.items, clusters, obstacles);

    // Pass 3, two attempts: the plain build (every jog exactly as pass 2
    // assigned it) and the dodging build (each bridge routes SEQUENTIALLY
    // into a scene holding the bridges before it, its jog displaced off
    // committed and tentative ink; bridges sharing one start stay ONE rail —
    // the leader's dodged jog is copied, never re-dodged). The dodged set
    // must EARN shipping: at least a halving of measured conflict. The
    // metric is a sketch-side proxy for the raster's per-cell verdicts,
    // faithful for gross fusion but blind to classification subtleties, so
    // a marginal win is treated as noise and the plain build (the incumbent
    // geometry) ships — a contact-free scene routes byte-identically, and a
    // dodge can never make the whole diagram worse than not dodging.
    const plain = try buildPaths(arena, pends.items, placements, clusters, obstacles, false);
    const dodged = try buildPaths(arena, pends.items, placements, clusters, obstacles, true);
    const incumbent = if (dodged.score * 2 <= plain.score) dodged else plain;

    // Trunk attempt (bridge_trunks.zig): each licensed shared-source group
    // jointly moves its shared jog to the least-conflicted rail coordinate,
    // judged against the scene WITH static edge runs (which the base scene
    // models as heads only). The trunk set ships only on a STRICT win of the
    // same full-scene comparison run over both sets — realization stays a
    // measured choice, never a default.
    const full = try trunks.withStaticRuns(arena, obstacles, edge_paths);
    if (try trunks.overrideJogs(arena, pends.items, placements, clusters, full)) {
        const trunked = try buildPaths(arena, pends.items, placements, clusters, obstacles, false);
        const t = try trunks.sceneScore(arena, trunked.paths, full, placements, clusters);
        const inc = try trunks.sceneScore(arena, incumbent.paths, full, placements, clusters);
        if (t < inc) return trunked.paths;
    }
    return incumbent.paths;
}

const Built = struct { paths: []sketch.EdgePath, score: u64 };

/// One whole-set routing attempt. In both attempts each finished polyline
/// is scored against the scene so far (static ink + earlier bridges), so
/// the two attempts' totals are comparable conflict counts. If a vertical
/// elbow would run straight through a node interior, re-route as a corridor
/// that jogs into a clear column before descending; gating on an actual
/// intrusion keeps every non-intruding seed byte-identical.
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
    var score: u64 = 0;
    for (pends, 0..) |*p, pi| {
        const dyn = tracks.Obstacles{ .heads = dyn_heads.items, .runs = dyn_runs.items };
        const reroute = try rerouted(arena, p.*, placements);
        if (enable_dodge) {
            if (leaderJog(pends[0..pi], p.*)) |j| {
                p.jog = j;
            } else if (p.jog != null and !reroute) {
                p.jog = try dodgeJog(arena, p.*, pi, pends, placements, clusters, dyn);
            }
        }
        var poly = try buildElbow(arena, p.*);
        if (reroute) {
            poly = try verticalCorridor(arena, p.start, p.end, p.to_box, p.sides.exit, placements, p.gf, p.gt, clusters, if (enable_dodge) dyn else obstacles);
        }
        score += scene.polyScore(poly, dyn) + scene.boxScore(poly, p.gf, p.gt, placements, clusters);
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
    return .{ .paths = try out.toOwnedSlice(arena), .score = score };
}

/// The jog an earlier same-start, same-exit bridge committed: a follower on
/// a shared rail keeps the leader's coordinate so the rail never splits.
fn leaderJog(earlier: []const Pending, p: Pending) ?i32 {
    for (earlier) |q| {
        if (q.sides.exit != p.sides.exit) continue;
        if (q.start.x != p.start.x or q.start.y != p.start.y) continue;
        return q.jog;
    }
    return null;
}

/// Displace `p`'s jog inside its clamp interval to the least-conflicted
/// coordinate, judged against the committed scene PLUS the tentative elbows
/// of the bridges still to route (same-start peers excepted — a shared port
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
        if (q.start.x == p.start.x and q.start.y == p.start.y) continue;
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

/// Group jogging bridges by (entry side, target anchor) and resolve each
/// group's tracks (tracks.resolve: overlap packing + border clearance).
/// Bridges sharing one start point (the same source port) merge into ONE
/// request — a shared-port fan reads as a single rail with several drops.
fn assignJogs(
    arena: std.mem.Allocator,
    pends: []Pending,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
) error{OutOfMemory}!void {
    const done = try arena.alloc(bool, pends.len);
    @memset(done, false);

    for (0..pends.len) |i| {
        if (done[i] or pends[i].pref == null) continue;
        const p0 = pends[i];
        const row_jog = (p0.sides.entry == .north or p0.sides.entry == .south);
        const sign = tracks.outwardSign(p0.sides.entry);

        // Collect the group and fold same-start members into shared requests.
        var members: std.ArrayListUnmanaged(usize) = .empty;
        var req_of: std.ArrayListUnmanaged(usize) = .empty;
        var starts: std.ArrayListUnmanaged(Pt) = .empty;
        var reqs: std.ArrayListUnmanaged(tracks.Req) = .empty;
        for (i..pends.len) |j| {
            if (done[j] or pends[j].pref == null) continue;
            const m = pends[j];
            if (m.sides.entry != p0.sides.entry) continue;
            if (m.anchor.frame != p0.anchor.frame or m.anchor.id != p0.anchor.id) continue;
            done[j] = true;
            try members.append(arena, j);

            const lo = if (row_jog) @min(m.start.x, m.end.x) else @min(m.start.y, m.end.y);
            const hi = if (row_jog) @max(m.start.x, m.end.x) else @max(m.start.y, m.end.y);
            var found: ?usize = null;
            for (starts.items, 0..) |s, si| {
                if (s.x == m.start.x and s.y == m.start.y) {
                    found = si;
                    break;
                }
            }
            if (found) |si| {
                const r = &reqs.items[si];
                r.span_lo = @min(r.span_lo, lo);
                r.span_hi = @max(r.span_hi, hi);
                // Innermost (closest-to-target) preference wins for the rail. // guarded-by: bridges_test.zig "assignJogs: shared-request merge across different cluster depths picks the closest-to-target preference"
                if (sign * m.pref.? < sign * r.pref) r.pref = m.pref.?;
                try req_of.append(arena, si);
            } else {
                try req_of.append(arena, reqs.items.len);
                try starts.append(arena, m.start);
                try reqs.append(arena, .{ .span_lo = lo, .span_hi = hi, .pref = m.pref.? });
            }
        }

        const coords = try tracks.resolve(arena, reqs.items, p0.sides.entry, clusters, obstacles);
        for (members.items, req_of.items) |mi, ri| pends[mi].jog = coords[ri];
    }
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
        flow_vertical // both axes free: follow the flow axis
    else
        !y_overlap; // only one axis disjoint: must use it

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

// Obstacle-aware corridor geometry, intrusion test and jog clamping live in
// bridge_scene.zig (cap-forced split); aliased so this router reads as one
// vocabulary.
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

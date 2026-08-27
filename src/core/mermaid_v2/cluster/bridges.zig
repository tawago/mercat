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
//! sem_graph, sketch, and the cluster-internal tracks.zig / corridors.zig.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const tracks = @import("tracks.zig");
const corridors = @import("corridors.zig");

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

    // Pass 3: build polylines. If a vertical elbow would run straight
    // through a node interior (a cross-border edge whose source has an
    // intra-cluster child sitting directly below it), re-route as a
    // corridor that jogs into a clear column before descending. Gating on
    // an actual intrusion keeps every non-intruding seed byte-identical.
    var out: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
    for (pends.items) |p| {
        var poly = try buildElbow(arena, p);
        if (try rerouted(arena, p, placements)) {
            poly = try verticalCorridor(arena, p.start, p.end, p.to_box, p.sides.exit, placements, p.gf, p.gt, clusters, obstacles);
        }

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
    return try out.toOwnedSlice(arena);
}

/// True iff the plain elbow for `p` would run straight through a node
/// interior, so pass 3 replaces it with the obstacle-aware
/// `verticalCorridor`. Pass 2 asks this to know whether a slide of the exit
/// port could move that end's border crossing at all — the re-route meets
/// the source frame at its own descent column instead.
fn rerouted(
    arena: std.mem.Allocator,
    p: Pending,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}!bool {
    if (p.sides.exit != .north and p.sides.exit != .south) return false;
    return polyIntrudes(try buildElbow(arena, p), placements, p.gf, p.gt);
}

/// One crossing after endpoint/side resolution, before polyline build.
const Pending = struct {
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

fn cellIn(cells: []const Pt, p: Pt) bool {
    for (cells) |c| {
        if (c.x == p.x and c.y == p.y) return true;
    }
    return false;
}

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

const Step = struct { x: i32, y: i32 };

fn stepDir(a: Pt, b: Pt) ?Step {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if ((dx == 0) == (dy == 0)) return null; // zero-length or diagonal
    return .{ .x = std.math.sign(dx), .y = std.math.sign(dy) };
}

fn stepPt(p: Pt, d: Step) Pt {
    return .{ .x = p.x + d.x, .y = p.y + d.y };
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

/// Obstacle-aware vertical route. Exits the source into the gap immediately
/// below/above it (above its intra-cluster child), jogs to a column clear of
/// every node over the run span, descends/ascends, then jogs to the target's
/// column in the gap outside the target box and runs into the port. Degenerate
/// (zero-length) segments collapse to the simple elbow.
fn verticalCorridor(
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
    // Gap row just past the source node — collision-free above its child. // guarded-by: bridges_test.zig "verticalCorridor: the source-side jog row (one past the source) is collision-free above the pierced child"
    const src_jog_y = if (descending) start.y + 1 else start.y - 1;
    // Gap row just outside the target box, ≥2 back from the port — displaced
    // off any drawn frame border row (same discipline as the plain elbow).
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
        clampBetween(start.y, end.y, tgt_want)
    else
        clampBetween(end.y, start.y, tgt_want);

    const lo = @min(src_jog_y, tgt_jog_y);
    const hi = @max(src_jog_y, tgt_jog_y);
    // Prefer descending straight into the target column, sliding outward only
    // if blocked; margined over merely touch-free (flush `││` reads as
    // crowding) — sketch.clearLine is the shared clearance core (cluster/ may
    // import sketch, not layout/). // guarded-by: sketch.zig "clearLine prefers a margined line over a closer touch-free-only line"
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
        if (p.x == prev.x and p.y == prev.y) continue; // skip zero-length
        try poly.append(arena, p);
        prev = p;
    }
    return try poly.toOwnedSlice(arena);
}

/// True iff any straight vertical segment of `poly` touches a node box
/// (excluding the edge's own endpoints). Touch semantics — borders count —
/// because the raster owns border cells: a bridge leg running along a
/// foreign border column rasterizes as swallowed edge cells even though
/// the strict-interior validator stays silent.
fn polyIntrudes(
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
            if (sketch.columnTouchesAny(a.x, y0, y1, placements, from_id, to_id)) return true;
        }
    }
    return false;
}

/// Clamp `want` into the open interval (lo, hi). Keeps the jog coordinate
/// strictly between the two ports even when the preferred gap line would land
/// on or past a port (tight box spacing).
fn clampBetween(lo: i32, hi: i32, want: i32) i32 {
    if (hi - lo < 2) return lo + 1; // degenerate: no room, sit just past lo
    if (want <= lo) return lo + 1;
    if (want >= hi) return hi - 1;
    return want;
}

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

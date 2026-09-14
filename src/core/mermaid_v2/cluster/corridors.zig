//! cluster/corridors.zig — per-column crossing discipline for cluster frames.
//!
//! A cross-border edge meets a drawn subgraph frame at ONE cell, and the
//! frame-solid ruling leaves that cell pristine (`raster/edges.zig` files an
//! `.intrusion` record and the border glyph survives). Two facts follow, and
//! neither is recoverable from the grid afterwards, so both have to hold by
//! construction here:
//!
//!   PER-COLUMN UNIQUENESS — a display column of a horizontal frame side
//!   (row of a vertical side) may carry AT MOST ONE crossing corridor. Two
//!   corridors bridging one border cell are indistinguishable from one.
//!   Corridors that genuinely converge BEFORE the border (several edges into
//!   one port) are one corridor and share their coordinate: that is what
//!   `group` says.
//!
//!   CORNER EXCLUSION — no corridor may cross a frame CORNER cell. A corner
//!   glyph already spends both of its arms on the frame; a crossing there
//!   has nowhere to resume from.
//!
//! The resolution is a sideways shift along the frame side, inside the
//! crossing node's own face — the corridor stays orthogonal and the final
//! run stays perpendicular into the port, only the port offset moves.
//!
//! SCOPE, stated plainly because the resolution is a PORT slide: this layer
//! binds a crossing only where the port coordinate IS the crossing
//! coordinate. An entry always qualifies — its jog sits outside the target's
//! frame, so the final perpendicular leg is what meets the border. An exit
//! qualifies unless `bridges.zig` re-routes it as an obstacle-aware vertical
//! corridor, which jogs one row off the source (inside the frame) and meets
//! the border at its descent column instead; `bridges.route` withholds that
//! end's demand, since sliding the port would de-centre the arrow foot and
//! move nothing. Two such descent columns can still coincide, and nothing
//! here can separate them — only a router that owns the descent could.
//!
//!   NODE CLEARANCE — a shift takes the whole perpendicular APPROACH run
//!   (border cell to port) with it, so the column it lands on must also be
//!   clear of every other node box over that run. Without this term the
//!   discipline separates two corridors by driving one straight through an
//!   intervening box: the stroke is swallowed for the box's whole height and
//!   re-emerges as a second foot on its far border, reading as an edge out of
//!   a node that has none. Two corridors sharing a border cell LOSE an edge;
//!   a pierced box INVENTS one, which is strictly worse — so when no clear
//!   column exists the corridor keeps `want` and the merge stands.
//!
//! PURE DATA: rects/coords in, resolved coords out; imports std and sketch.

const std = @import("std");
const sketch = @import("../sketch.zig");
const tracks = @import("tracks.zig");

/// One end of a bridge: the node face the corridor leaves from or arrives
/// on, plus the drawn frame (if any) whose border it therefore crosses.
pub const Endpoint = struct {
    node: sketch.NodeId,
    rect: sketch.Rect,
    side: sketch.Dir4,
    frame: ?sketch.ClusterId,
};

/// One bridge's two ends.
pub const Pair = struct { from: Endpoint, to: Endpoint };

/// Where a bridge's two ports ended up: the coordinate along each face and
/// the matching `sketch.Port.offset`. Unmoved ends come back centred.
pub const Resolved = struct {
    from_coord: i32,
    to_coord: i32,
    from_off: u32,
    to_off: u32,
};

/// The nearest DRAWN frame containing `p` — synthetic packing frames are
/// walked through because they paint no border to cross. Null at top level.
pub fn drawnFrame(clusters: []const sketch.ClusterFrame, p: sketch.NodePlacement) ?sketch.ClusterId {
    var cid = p.cluster_id;
    var guard: u32 = 0;
    while (cid) |id| : (guard += 1) {
        if (guard > 64) break;
        const f = frameById(clusters, id) orelse break;
        if (!f.synthetic) return id;
        cid = f.parent_id;
    }
    return null;
}

/// Slide a port point along its face to `coord` (an x on a north/south
/// face, a y on an east/west one). The axis that says WHICH face the port
/// sits on never moves, so the corridor stays orthogonal.
pub fn slide(p: *sketch.Point, side: sketch.Dir4, coord: i32) void {
    switch (side) {
        .north, .south => p.x = coord,
        .east, .west => p.y = coord,
    }
}

/// Enforce both laws over a whole set of bridges. Each bridge raises at
/// most two demands — where it LEAVES its source's frame and where it
/// ENTERS its target's. An endpoint at top level raises none (no border is
/// met), and neither does a bridge whose two endpoints share one drawn
/// frame. Demands are honoured in bridge order, source end before target
/// end.
/// @guarded-by: corridors_test.zig "two bridges entering one frame at one column: the later port slides along its face"
pub fn discipline(
    arena: std.mem.Allocator,
    pairs: []const Pair,
    clusters: []const sketch.ClusterFrame,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]Resolved {
    const out = try arena.alloc(Resolved, pairs.len);
    for (pairs, out) |p, *o| o.* = .{
        .from_coord = centre(p.from.rect, p.from.side),
        .to_coord = centre(p.to.rect, p.to.side),
        .from_off = sideOffset(p.from.rect, p.from.side),
        .to_off = sideOffset(p.to.rect, p.to.side),
    };

    var reqs: std.ArrayListUnmanaged(Req) = .empty;
    var owner: std.ArrayListUnmanaged(struct { idx: usize, exit: bool }) = .empty;
    for (pairs, 0..) |p, i| {
        if (p.from.frame != null and p.to.frame != null and p.from.frame.? == p.to.frame.?) continue;
        for ([2]bool{ true, false }) |exit| {
            const e = if (exit) p.from else p.to;
            const f = e.frame orelse continue;
            const rng = faceRange(e.rect, e.side);
            const run: Span = if (rectOf(clusters, f)) |fr|
                approachRun(fr, e.rect, e.side)
            else
                .{ .lo = 0, .hi = -1 };
            try reqs.append(arena, .{
                .frame = f,
                .side = e.side,
                .want = centre(e.rect, e.side),
                .lo = rng.lo,
                .hi = rng.hi,
                .group = groupKey(e.node, e.side),
                .run_lo = run.lo,
                .run_hi = run.hi,
                .skip_a = p.from.node,
                .skip_b = p.to.node,
            });
            try owner.append(arena, .{ .idx = i, .exit = exit });
        }
    }
    if (reqs.items.len == 0) return out;

    for (owner.items, try resolve(arena, reqs.items, clusters, placements)) |o, coord| {
        const p = pairs[o.idx];
        if (o.exit) {
            out[o.idx].from_coord = coord;
            out[o.idx].from_off = portOffset(p.from.rect, p.from.side, coord);
        } else {
            out[o.idx].to_coord = coord;
            out[o.idx].to_off = portOffset(p.to.rect, p.to.side, coord);
        }
    }
    return out;
}

/// The centred port offset a face gets before any discipline runs. THE
/// formula — `bridges.zig` builds its port points from this one too, so
/// "what the corridor wants" and "where the port is" cannot drift apart.
pub fn sideOffset(r: sketch.Rect, side: sketch.Dir4) u32 {
    return switch (side) {
        .north, .south => @divTrunc(r.w, 2),
        .east, .west => @divTrunc(r.h, 2),
    };
}

fn centre(r: sketch.Rect, side: sketch.Dir4) i32 {
    const off: i32 = @intCast(sideOffset(r, side));
    return switch (side) {
        .north, .south => r.x + off,
        .east, .west => r.y + off,
    };
}

fn frameById(clusters: []const sketch.ClusterFrame, id: sketch.ClusterId) ?sketch.ClusterFrame {
    for (clusters) |c| {
        if (c.id == id) return c;
    }
    return null;
}

/// One corridor's demand on a frame side.
pub const Req = struct {
    /// The drawn frame whose border this corridor crosses.
    frame: sketch.ClusterId,
    /// Which side of that frame — north/south are horizontal sides whose
    /// coordinate is an x, east/west are vertical sides keyed by y.
    side: sketch.Dir4,
    /// Preferred crossing coordinate (the port's own column/row).
    want: i32,
    /// Inclusive range the crossing may be shifted into: the strict
    /// interior of the crossing node's face, so a shifted port never lands
    /// on the node's own corner.
    lo: i32,
    hi: i32,
    /// Corridor identity. Requests sharing a group are ONE corridor (the
    /// same port, reached by several edges) and resolve to one coordinate
    /// without conflicting; distinct groups on one frame side may not
    /// share a coordinate.
    group: u64,
    /// Span of the perpendicular approach run a SHIFTED crossing would lay
    /// down — rows between the frame border and the port on a north/south
    /// face, columns on an east/west one. Empty (`run_hi < run_lo`) disables
    /// the node-clearance term, which is what a caller with no placements to
    /// consult wants.
    run_lo: i32 = 0,
    run_hi: i32 = -1,
    /// The corridor's own two nodes, exempt from node clearance: the run is
    /// allowed to touch the boxes it starts and ends on.
    skip_a: sketch.NodeId = std.math.maxInt(sketch.NodeId),
    skip_b: sketch.NodeId = std.math.maxInt(sketch.NodeId),
};

/// An inclusive coordinate span; empty when `hi < lo`.
pub const Span = struct { lo: i32, hi: i32 };

/// How far the descent search walks before settling for its node-clear
/// preference. Generous — a real graph never needs a fraction of it.
const DESCENT_REACH: i32 = 512;

/// Column for a vertical corridor's long descent over rows `[lo, hi]`:
/// node-clear (the shared `sketch.clearLine` core), off every drawn frame's
/// border column, and out of the strict INTERIOR of every drawn frame that
/// holds neither endpoint.
///
/// The border term alone is not enough. Escaping a wall by marching in one
/// fixed direction steps INWARD as often as outward, and a descent laid
/// inside a frame it has no business in crosses that frame's two borders and
/// is drawn down through its title and its members — two crossings nobody
/// counts, in a subgraph the edge never touches. So the search is
/// nearest-first in BOTH directions from the node-clear preference, ties
/// broken toward the target column (the shorter final jog), and it never
/// leaves the canvas.
/// @guarded-by: corridors_test.zig "a descent escaping a frame wall leaves the frame instead of stepping inside it"
pub fn descentColumn(
    want: i32,
    lo: i32,
    hi: i32,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
    clusters: []const sketch.ClusterFrame,
) i32 {
    const first = sketch.clearLine(false, want, lo, hi, placements, from_id, to_id, .{ .margin = true });
    if (!frameBlocked(first, lo, hi, placements, from_id, to_id, clusters)) return first;

    const dirn: i32 = if (want < first) -1 else 1;
    var d: i32 = 1;
    while (d <= DESCENT_REACH) : (d += 1) {
        for ([2]i32{ first + dirn * d, first - dirn * d }) |c| {
            if (c < 0) continue;
            if (frameBlocked(c, lo, hi, placements, from_id, to_id, clusters)) continue;
            if (sketch.lineTouchesAny(false, c, lo, hi, placements, from_id, to_id)) continue;
            return c;
        }
    }
    return first;
}

/// True iff a descent at `col` would run along a drawn frame's wall or down
/// the inside of a frame that holds neither of the corridor's endpoints.
fn frameBlocked(
    col: i32,
    lo: i32,
    hi: i32,
    placements: []const sketch.NodePlacement,
    from_id: sketch.NodeId,
    to_id: sketch.NodeId,
    clusters: []const sketch.ClusterFrame,
) bool {
    if (tracks.onFrameBorder(false, col, lo, hi, clusters)) return true;
    for (clusters) |c| {
        if (c.synthetic or c.rect.w == 0 or c.rect.h == 0) continue;
        if (col <= c.rect.x or col >= c.rect.right() - 1) continue;
        if (lo >= c.rect.bottom() or hi < c.rect.y) continue;
        if (frameHolds(c.rect, placements, from_id) or frameHolds(c.rect, placements, to_id)) continue;
        return true;
    }
    return false;
}

fn frameHolds(frame: sketch.Rect, placements: []const sketch.NodePlacement, id: sketch.NodeId) bool {
    for (placements) |p| {
        if (p.id != id) continue;
        return p.rect.x >= frame.x and p.rect.right() <= frame.right() and
            p.rect.y >= frame.y and p.rect.bottom() <= frame.bottom();
    }
    return false;
}

/// The approach run a crossing on `side` lays down between `frame`'s border
/// and `rect`'s face: rows for a horizontal side, columns for a vertical one.
/// This is the span a sideways shift drags across other node boxes.
pub fn approachRun(frame: sketch.Rect, rect: sketch.Rect, side: sketch.Dir4) Span {
    const a: i32, const b: i32 = switch (side) {
        .north => .{ frame.y, rect.y },
        .south => .{ rect.bottom() - 1, frame.bottom() - 1 },
        .west => .{ frame.x, rect.x },
        .east => .{ rect.right() - 1, frame.right() - 1 },
    };
    return .{ .lo = @min(a, b), .hi = @max(a, b) };
}

/// True iff `coord` names a CORNER cell of `side` on `frame`.
pub fn onCorner(frame: sketch.Rect, side: sketch.Dir4, coord: i32) bool {
    if (frame.w == 0 or frame.h == 0) return false;
    return switch (side) {
        .north, .south => coord == frame.x or coord == frame.right() - 1,
        .east, .west => coord == frame.y or coord == frame.bottom() - 1,
    };
}

/// The strict interior of `rect`'s `side` face: the range a port may be
/// shifted into without landing on the node's OWN corner. Empty (hi < lo)
/// for a face too narrow to hold an interior cell, which reads downstream
/// as "this corridor cannot move".
pub fn faceRange(rect: sketch.Rect, side: sketch.Dir4) struct { lo: i32, hi: i32 } {
    return switch (side) {
        .north, .south => .{ .lo = rect.x + 1, .hi = rect.right() - 2 },
        .east, .west => .{ .lo = rect.y + 1, .hi = rect.bottom() - 2 },
    };
}

/// Corridor identity of a port: edges reaching the SAME node face converge
/// before the border and are one corridor, however many of them there are.
pub fn groupKey(node: sketch.NodeId, side: sketch.Dir4) u64 {
    return (@as(u64, node) << 2) | @intFromEnum(side);
}

/// Offset of a resolved crossing coordinate within `rect`, in the units
/// `sketch.Port.offset` uses (columns from the left for a horizontal side,
/// rows from the top for a vertical one).
pub fn portOffset(rect: sketch.Rect, side: sketch.Dir4, coord: i32) u32 {
    const base = switch (side) {
        .north, .south => rect.x,
        .east, .west => rect.y,
    };
    return @intCast(@max(0, coord - base));
}

/// One coordinate already spoken for on a frame side.
const Claim = struct { frame: sketch.ClusterId, side: sketch.Dir4, coord: i32 };

/// The coordinate a corridor group settled on.
const Grp = struct { frame: sketch.ClusterId, side: sketch.Dir4, group: u64, coord: i32 };

/// Resolve every request to a crossing coordinate obeying both laws
/// (parallel to `reqs`, arena-owned). Requests are honoured in index order,
/// so the FIRST demand on a coordinate keeps it and later ones move —
/// deterministic, and it keeps the common single-crossing frame byte-identical.
/// A request with no legal coordinate in `[lo, hi]` keeps `want` (a shift
/// that cannot land is worse than the collision it was meant to fix).
pub fn resolve(
    arena: std.mem.Allocator,
    reqs: []const Req,
    clusters: []const sketch.ClusterFrame,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]i32 {
    const out = try arena.alloc(i32, reqs.len);
    for (reqs, 0..) |r, i| out[i] = r.want;

    var claims: std.ArrayListUnmanaged(Claim) = .empty;
    var groups: std.ArrayListUnmanaged(Grp) = .empty;

    for (reqs, 0..) |r, i| {
        const rect = rectOf(clusters, r.frame) orelse continue;

        // A corridor already resolved for this group is the SAME corridor:
        // it reuses the coordinate and files no second claim.
        // @guarded-by: corridors_test.zig "two edges into one port are one corridor and keep one column"
        if (findGroup(groups.items, r)) |c| {
            out[i] = c;
            continue;
        }

        var pick = r.want;
        if (!legal(rect, r, pick, claims.items)) {
            pick = search(rect, r, claims.items, placements) orelse r.want;
        }
        out[i] = pick;
        try claims.append(arena, .{ .frame = r.frame, .side = r.side, .coord = pick });
        try groups.append(arena, .{ .frame = r.frame, .side = r.side, .group = r.group, .coord = pick });
    }
    return out;
}

fn findGroup(groups: []const Grp, r: Req) ?i32 {
    for (groups) |g| {
        if (g.frame == r.frame and g.side == r.side and g.group == r.group) return g.coord;
    }
    return null;
}

/// Nearest legal coordinate to `want`, searched outward and preferring the
/// larger side on a tie so the walk is a total order. A candidate must clear
/// intervening node boxes as well — `want` itself is exempt, so a corridor
/// that never moves stays byte-identical.
/// @guarded-by: corridors_test.zig "a slide that would drive the approach run through a node box is refused"
fn search(rect: sketch.Rect, r: Req, claims: []const Claim, placements: []const sketch.NodePlacement) ?i32 {
    if (r.hi < r.lo) return null;
    const reach: i32 = @max(r.want - r.lo, r.hi - r.want);
    var d: i32 = 1;
    while (d <= reach) : (d += 1) {
        for ([2]i32{ r.want + d, r.want - d }) |c| {
            if (c < r.lo or c > r.hi) continue;
            if (legal(rect, r, c, claims) and runClear(r, c, placements)) return c;
        }
    }
    return null;
}

/// True iff the approach run a crossing at `coord` would lay down touches no
/// node box but its own two. Vacuously true when the caller filed no run span.
fn runClear(r: Req, coord: i32, placements: []const sketch.NodePlacement) bool {
    if (r.run_hi < r.run_lo) return true;
    const horizontal = (r.side == .east or r.side == .west);
    return !sketch.lineTouchesAny(horizontal, coord, r.run_lo, r.run_hi, placements, r.skip_a, r.skip_b);
}

fn legal(rect: sketch.Rect, r: Req, coord: i32, claims: []const Claim) bool {
    if (onCorner(rect, r.side, coord)) return false;
    for (claims) |c| {
        if (c.frame == r.frame and c.side == r.side and c.coord == coord) return false;
    }
    return true;
}

fn rectOf(clusters: []const sketch.ClusterFrame, id: sketch.ClusterId) ?sketch.Rect {
    for (clusters) |c| {
        if (c.id == id) return c.rect;
    }
    return null;
}

test {
    _ = @import("corridors_test.zig");
}

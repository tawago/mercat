const std = @import("std");
const sketch = @import("../sketch.zig");
const tracks = @import("tracks.zig");

pub const Endpoint = struct {
    node: sketch.NodeId,
    rect: sketch.Rect,
    side: sketch.Dir4,
    frame: ?sketch.ClusterId,
};

pub const Pair = struct { from: Endpoint, to: Endpoint };

pub const Resolved = struct {
    from_coord: i32,
    to_coord: i32,
    from_off: u32,
    to_off: u32,
};

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

pub fn slide(p: *sketch.Point, side: sketch.Dir4, coord: i32) void {
    switch (side) {
        .north, .south => p.x = coord,
        .east, .west => p.y = coord,
    }
}

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

pub const Req = struct {
    frame: sketch.ClusterId,
    side: sketch.Dir4,
    want: i32,
    lo: i32,
    hi: i32,
    group: u64,
    run_lo: i32 = 0,
    run_hi: i32 = -1,
    skip_a: sketch.NodeId = std.math.maxInt(sketch.NodeId),
    skip_b: sketch.NodeId = std.math.maxInt(sketch.NodeId),
};

pub const Span = struct { lo: i32, hi: i32 };

const DESCENT_REACH: i32 = 512;

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

pub fn approachRun(frame: sketch.Rect, rect: sketch.Rect, side: sketch.Dir4) Span {
    const a: i32, const b: i32 = switch (side) {
        .north => .{ frame.y, rect.y },
        .south => .{ rect.bottom() - 1, frame.bottom() - 1 },
        .west => .{ frame.x, rect.x },
        .east => .{ rect.right() - 1, frame.right() - 1 },
    };
    return .{ .lo = @min(a, b), .hi = @max(a, b) };
}

pub fn onCorner(frame: sketch.Rect, side: sketch.Dir4, coord: i32) bool {
    if (frame.w == 0 or frame.h == 0) return false;
    return switch (side) {
        .north, .south => coord == frame.x or coord == frame.right() - 1,
        .east, .west => coord == frame.y or coord == frame.bottom() - 1,
    };
}

pub fn faceRange(rect: sketch.Rect, side: sketch.Dir4) struct { lo: i32, hi: i32 } {
    return switch (side) {
        .north, .south => .{ .lo = rect.x + 1, .hi = rect.right() - 2 },
        .east, .west => .{ .lo = rect.y + 1, .hi = rect.bottom() - 2 },
    };
}

pub fn groupKey(node: sketch.NodeId, side: sketch.Dir4) u64 {
    return (@as(u64, node) << 2) | @intFromEnum(side);
}

pub fn portOffset(rect: sketch.Rect, side: sketch.Dir4, coord: i32) u32 {
    const base = switch (side) {
        .north, .south => rect.x,
        .east, .west => rect.y,
    };
    return @intCast(@max(0, coord - base));
}

const Claim = struct { frame: sketch.ClusterId, side: sketch.Dir4, coord: i32 };

const Grp = struct { frame: sketch.ClusterId, side: sketch.Dir4, group: u64, coord: i32 };

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

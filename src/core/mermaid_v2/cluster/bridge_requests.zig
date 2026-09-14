//! cluster/bridge_requests.zig — the jog request merge: which pends take ONE
//! jog coordinate. Pends that meet at one port of a convergent node are one
//! rail in geometry and file one track request: a shared START (the source
//! port of a fan-out) exactly as a shared END (the target port of a fan-in).
//! The packer (tracks.zig) then stacks distinct requests on distinct tracks.
//!
//! An edge may be a rail member at each end, but a one-jog elbow carries one
//! coordinate, so each pend keys its request at exactly one end: the start
//! when another pend of its group shares that start, the end otherwise.
//! Source first mirrors the raw-first tie rule of selection; the shape a
//! member gives up at its other end is judged by the plan, never fabricated.
//!
//! PURE DATA: pends in, jog assignments out. Imports std, sketch, and the
//! cluster-internal bridges.zig / tracks.zig.

const std = @import("std");
const sketch = @import("../sketch.zig");
const bridges = @import("bridges.zig");
const tracks = @import("tracks.zig");

const Pt = sketch.Point;
const Pending = bridges.Pending;

/// The end of a pend whose port keys its jog request.
pub const RailEnd = enum { start, end };

/// The port point at `end`.
pub fn railPort(p: Pending, end: RailEnd) Pt {
    return switch (end) {
        .start => p.start,
        .end => p.end,
    };
}

/// The side of the node face at `end`.
pub fn railSide(p: Pending, end: RailEnd) sketch.Dir4 {
    return switch (end) {
        .start => p.sides.exit,
        .end => p.sides.entry,
    };
}

pub fn samePt(a: Pt, b: Pt) bool {
    return a.x == b.x and a.y == b.y;
}

/// True iff the two pends meet at one port at either end — a shared port is
/// a licensed rail, never an obstacle to its own members.
pub fn sharesPort(a: Pending, b: Pending) bool {
    return samePt(a.start, b.start) or samePt(a.end, b.end);
}

/// True iff `pends[i]` keys its request at the end OTHER than `end` and
/// another pend rides that request: the rail it belongs to is the other
/// end's, so a rail at `end` may not move it.
/// @guarded-by: bridges_test.zig "a bridge sharing a start with one peer and an end with another keys its request at the start"
pub fn railedAtOtherEnd(pends: []const Pending, i: usize, end: RailEnd) bool {
    const p = pends[i];
    if (p.rail_end == end) return false;
    for (pends, 0..) |q, qi| {
        if (qi == i or q.rail_end != p.rail_end or q.jog == null) continue;
        if (samePt(railPort(q, p.rail_end), railPort(p, p.rail_end))) return true;
    }
    return false;
}

/// Group jogging bridges by (entry side, target anchor) and resolve each
/// group's tracks (tracks.resolve: overlap packing + border clearance).
/// Bridges keyed at one shared port merge into ONE request — a fan reads as
/// a single rail with several drops from either end.
/// @guarded-by: bridges_test.zig "bridges sharing one source port share a single rail track"
/// @guarded-by: bridges_test.zig "bridges sharing one target port share a single rail track"
pub fn assignJogs(
    arena: std.mem.Allocator,
    pends: []Pending,
    clusters: []const sketch.ClusterFrame,
    obstacles: tracks.Obstacles,
    expired: ?*u32,
) error{OutOfMemory}!void {
    const done = try arena.alloc(bool, pends.len);
    @memset(done, false);

    for (0..pends.len) |i| {
        if (done[i] or pends[i].pref == null) continue;
        const p0 = pends[i];
        const row_jog = (p0.sides.entry == .north or p0.sides.entry == .south);
        const sign = tracks.outwardSign(p0.sides.entry);

        var members: std.ArrayListUnmanaged(usize) = .empty;
        for (i..pends.len) |j| {
            if (done[j] or pends[j].pref == null) continue;
            const m = pends[j];
            if (m.sides.entry != p0.sides.entry) continue;
            if (m.anchor.frame != p0.anchor.frame or m.anchor.id != p0.anchor.id) continue;
            done[j] = true;
            try members.append(arena, j);
        }
        for (members.items) |mi| {
            pends[mi].rail_end = if (startShared(pends, members.items, mi)) .start else .end;
        }

        var keys: std.ArrayListUnmanaged(Key) = .empty;
        var reqs: std.ArrayListUnmanaged(tracks.Req) = .empty;
        const req_of = try arena.alloc(usize, members.items.len);
        for (members.items, req_of) |mi, *ri| {
            const m = pends[mi];
            const lo = if (row_jog) @min(m.start.x, m.end.x) else @min(m.start.y, m.end.y);
            const hi = if (row_jog) @max(m.start.x, m.end.x) else @max(m.start.y, m.end.y);
            const key = Key{ .end = m.rail_end, .port = railPort(m, m.rail_end) };
            if (indexOf(keys.items, key)) |si| {
                const r = &reqs.items[si];
                r.span_lo = @min(r.span_lo, lo);
                r.span_hi = @max(r.span_hi, hi);
                // Innermost (closest-to-target) preference wins for the rail. // @guarded-by: bridges_test.zig "assignJogs: shared-request merge across different cluster depths picks the closest-to-target preference"
                if (sign * m.pref.? < sign * r.pref) r.pref = m.pref.?;
                ri.* = si;
            } else {
                ri.* = reqs.items.len;
                try keys.append(arena, key);
                try reqs.append(arena, .{ .span_lo = lo, .span_hi = hi, .pref = m.pref.? });
            }
        }

        const coords = try tracks.resolve(arena, reqs.items, p0.sides.entry, clusters, obstacles, expired);
        for (members.items, req_of) |mi, ri| pends[mi].jog = coords[ri];
    }
}

const Key = struct { end: RailEnd, port: Pt };

fn indexOf(keys: []const Key, key: Key) ?usize {
    for (keys, 0..) |k, i| {
        if (k.end == key.end and samePt(k.port, key.port)) return i;
    }
    return null;
}

fn startShared(pends: []const Pending, members: []const usize, mi: usize) bool {
    for (members) |mj| {
        if (mj != mi and samePt(pends[mj].start, pends[mi].start)) return true;
    }
    return false;
}

/// The jog an earlier bridge on the same rail committed: a follower keeps
/// the leader's coordinate so the rail never splits. A same-start leader is
/// followed at any keying; a same-end leader only by an end-keyed pend.
pub fn leaderJog(earlier: []const Pending, p: Pending) ?i32 {
    for (earlier) |q| {
        if (q.sides.exit != p.sides.exit) continue;
        if (!samePt(q.start, p.start)) continue;
        return q.jog;
    }
    if (p.rail_end == .end) for (earlier) |q| {
        if (q.rail_end != .end or q.sides.entry != p.sides.entry) continue;
        if (!samePt(q.end, p.end)) continue;
        return q.jog;
    };
    return null;
}

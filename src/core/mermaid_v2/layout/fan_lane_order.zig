//! fan_lane_order.zig — stem-corner clearance ordering for the lane-separated
//! trunks of one inter-layer gap.
//!
//! `fan_lanes.zig` decides HOW MANY rail rows a gap needs and which trunk is
//! entitled to one; it does not decide WHICH row each trunk takes, and for a
//! star decomposition that choice is load-bearing.
//!
//! A trunk's stem meets its crossbar at one cell — the stem column on the rail
//! row. Every OTHER trunk in the gap runs its taps as verticals from the peer
//! side down to its own rail row. When a foreign tap shares the stem's column
//! and its rail row lies BEYOND the stem's junction, that tap passes straight
//! through the junction cell: a four-armed glyph whose vertical belongs to one
//! trunk and whose corner belongs to another. Neither run can be traced through
//! it, and the reach oracle reports it (`reach_unknown_continuation`).
//!
//! The conflict is one of ORDER, not of position. A fan-IN trunk's taps occupy
//! the rows between the sources and its own rail; a trunk whose stem column is
//! one of them only has to sit BELOW that rail for its junction to fall outside
//! the tap's span. So this pass reads the placed columns of every trunk in a
//! gap, derives that precedence, and topologically re-orders the lane indices
//! the packer handed out. It is a PERMUTATION: the row count, and therefore
//! every reserved row, is untouched. When the precedence has a cycle no order
//! clears every junction and the packer's order stands.
//!
//! Allowed imports (layout zone): std + layout siblings.

const std = @import("std");
const fan_rail = @import("fan_rail.zig");

/// One rail-producing trunk as this pass sees it: the gap it crosses, the lane
/// the packer gave it, and the placed columns of its stem junction and taps.
pub const Trunk = struct {
    gap: u32,
    lane: u32,
    fan_in: bool,
    stem_x: i32,
    tap_xs: []const i32,
};

/// The stem column of a resolved trunk — the same expression `fan_rail.build`
/// uses, so the two can never drift.
pub fn stemX(resolved: fan_rail.Resolved) i32 {
    const offset = if (resolved.pivot_port) |port| port.offset else resolved.pivot.rect.w / 2;
    return resolved.pivot.rect.x + @as(i32, @intCast(offset));
}

/// The tap columns of a resolved trunk, in peer order (`fan_rail.build`'s).
pub fn tapXs(a: std.mem.Allocator, resolved: fan_rail.Resolved) error{OutOfMemory}![]const i32 {
    const out = try a.alloc(i32, resolved.peers.len);
    for (resolved.peers, out) |p, *slot| {
        const offset = if (p.port) |port| port.offset else p.placement.rect.w / 2;
        slot.* = p.placement.rect.x + @as(i32, @intCast(offset));
    }
    return out;
}

/// Re-order `trunks`' lane indices, per gap, so that no trunk's stem junction
/// falls inside a foreign trunk's tap column-run. Mutates `trunks[i].lane` in
/// place and returns nothing: a gap whose precedence cannot be satisfied keeps
/// the lanes it came in with.
/// guarded-by: fan_lane_order_test.zig "a stem crossed by a foreign tap is ordered below it"
pub fn reorder(a: std.mem.Allocator, trunks: []Trunk) error{OutOfMemory}!void {
    if (trunks.len < 2) return;
    var gap_seen: std.ArrayListUnmanaged(u32) = .empty;
    defer gap_seen.deinit(a);
    for (trunks) |t| {
        var known = false;
        for (gap_seen.items) |g| {
            if (g == t.gap) known = true;
        }
        if (!known) try gap_seen.append(a, t.gap);
    }
    for (gap_seen.items) |gap| try reorderGap(a, trunks, gap);
}

fn reorderGap(a: std.mem.Allocator, trunks: []Trunk, gap: u32) error{OutOfMemory}!void {
    var idx: std.ArrayListUnmanaged(usize) = .empty;
    defer idx.deinit(a);
    for (trunks, 0..) |t, i| {
        if (t.gap == gap) try idx.append(a, i);
    }
    const n = idx.items.len;
    if (n < 2) return;

    // Only a PERMUTATION of the rows the packer already handed out is on
    // offer: this pass moves trunks between existing rail rows, it never asks
    // for another one. Two trunks sharing a row are the packer saying they do
    // not fuse, so there is nothing here to re-order.
    const lanes = try a.alloc(u32, n);
    defer a.free(lanes);
    for (idx.items, lanes) |i, *slot| slot.* = trunks[i].lane;
    if (!allDistinct(lanes)) return;
    const sorted = try a.dupe(u32, lanes);
    defer a.free(sorted);
    std.mem.sort(u32, sorted, {}, std.sort.asc(u32));

    // One direction per gap: the precedence's sign is the direction's (a
    // fan-IN's taps lie above its rail, a fan-OUT's below), so a mixed gap has
    // no single order to solve for.
    const fan_in = trunks[idx.items[0]].fan_in;
    for (idx.items) |i| {
        if (trunks[i].fan_in != fan_in) return;
    }

    // `before[k][j]` — trunk k's rail must sit on the peer-side FAR row
    // relative to trunk j's, because j's taps cross k's stem junction.
    const before = try a.alloc(bool, n * n);
    defer a.free(before);
    @memset(before, false);
    var any = false;
    for (0..n) |k| {
        for (0..n) |j| {
            if (k == j) continue;
            if (!contains(trunks[idx.items[j]].tap_xs, trunks[idx.items[k]].stem_x)) continue;
            before[k * n + j] = true;
            any = true;
        }
    }
    if (!any) return;

    // Kahn's algorithm over `before`, ties broken by the packer's own lane so
    // the result is deterministic and stays as close to it as the constraints
    // allow. `order[p]` is the trunk that takes rank p.
    const indeg = try a.alloc(u32, n);
    defer a.free(indeg);
    @memset(indeg, 0);
    for (0..n) |k| {
        for (0..n) |j| {
            if (before[k * n + j]) indeg[j] += 1;
        }
    }
    const done = try a.alloc(bool, n);
    defer a.free(done);
    @memset(done, false);
    const order = try a.alloc(usize, n);
    defer a.free(order);
    var placed: usize = 0;
    while (placed < n) {
        var pick: ?usize = null;
        for (0..n) |k| {
            if (done[k] or indeg[k] != 0) continue;
            if (pick == null or lanes[k] < lanes[pick.?]) pick = k;
        }
        const k = pick orelse return; // cycle: the packer's order stands
        done[k] = true;
        order[placed] = k;
        placed += 1;
        for (0..n) |j| {
            if (before[k * n + j]) indeg[j] -= 1;
        }
    }

    // Rank 0 takes the row nearest the pivot (lane 0) for a fan-IN, since a
    // constrained trunk must clear the taps that cross it; a fan-OUT's taps
    // run the other way, so its ranks fill from the far row down.
    for (order, 0..) |k, rank| {
        trunks[idx.items[k]].lane = if (fan_in) sorted[rank] else sorted[n - 1 - rank];
    }
}

fn allDistinct(lanes: []const u32) bool {
    for (lanes, 0..) |x, i| {
        for (lanes[i + 1 ..]) |y| if (x == y) return false;
    }
    return true;
}

fn contains(xs: []const i32, v: i32) bool {
    for (xs) |x| if (x == v) return true;
    return false;
}

test {
    _ = @import("fan_lane_order_test.zig");
}

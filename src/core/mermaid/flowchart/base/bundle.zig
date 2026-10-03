const std = @import("std");

const EdgeId = u32;

pub const BundleOrigin = enum {
    selected_bundle,
    fan_rail,
    port_share,
};

pub const Bundle = struct {
    origin: BundleOrigin,
    members: []const EdgeId,
    cells: ?[]const BundleCell = null,
    pairwise: ?[]const PairCells = null,
};

pub const PairCells = struct {
    a: EdgeId,
    b: EdgeId,
    cells: []const BundleCell,
};

pub const BundleCell = struct {
    x: i32,
    y: i32,
};

pub fn concatBundles(
    allocator: std.mem.Allocator,
    head: []const Bundle,
    tail: []const Bundle,
) error{OutOfMemory}![]const Bundle {
    if (tail.len == 0) return head;
    if (head.len == 0) return tail;
    const out = try allocator.alloc(Bundle, head.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], tail);
    return out;
}

pub fn bundleMembersAt(sets: []const Bundle, first: EdgeId, second: EdgeId, at: ?BundleCell) bool {
    for (sets) |set| {
        var saw_first = false;
        var saw_second = false;
        for (set.members) |m| {
            if (m == first) saw_first = true;
            if (m == second) saw_second = true;
        }
        if (!saw_first or !saw_second) continue;
        if (!licensesPair(set, first, second, at)) continue;
        return true;
    }
    return false;
}

fn licenses(set: Bundle, at: ?BundleCell) bool {
    const cells = set.cells orelse return true;
    const here = at orelse return true;
    for (cells) |c| {
        if (c.x == here.x and c.y == here.y) return true;
    }
    return false;
}

fn pairEntry(set: Bundle, a: EdgeId, b: EdgeId) ?[]const BundleCell {
    const list = set.pairwise orelse return null;
    for (list) |p| {
        if ((p.a == a and p.b == b) or (p.a == b and p.b == a)) return p.cells;
    }
    return &.{};
}

fn licensesPair(set: Bundle, first: EdgeId, second: EdgeId, at: ?BundleCell) bool {
    if (set.pairwise == null) return licenses(set, at);
    const here = at orelse return true;
    const cells = pairEntry(set, first, second) orelse return true;
    for (cells) |c| {
        if (c.x == here.x and c.y == here.y) return true;
    }
    return false;
}

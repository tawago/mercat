const std = @import("std");

const EdgeId = u32;

pub const BundleOrigin = enum {
    selected_bundle,
    fan_rail,
    port_share,
};

pub const BundleId = u32;

pub const no_bundle: BundleId = 0;

pub const Bundle = struct {
    origin: BundleOrigin,
    bundle: BundleId = no_bundle,
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

pub fn memberOfBundleAt(sets: []const Bundle, bundle: BundleId, edge: EdgeId, at: ?BundleCell) bool {
    if (bundle == no_bundle) return false;
    for (sets) |set| {
        if (set.bundle != bundle) continue;
        if (hasMember(set.members, edge) and licensesMember(set, edge, at)) return true;
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

fn licensesMember(set: Bundle, edge: EdgeId, at: ?BundleCell) bool {
    const list = set.pairwise orelse return licenses(set, at);
    const here = at orelse return true;
    for (list) |p| {
        if (p.a != edge and p.b != edge) continue;
        for (p.cells) |c| {
            if (c.x == here.x and c.y == here.y) return true;
        }
    }
    return false;
}

pub const StructuralBundleResolution = union(enum) {
    absent,
    unique: usize,
    multiple,
};

pub fn resolveStructuralBundle(sets: []const Bundle, edge: EdgeId) StructuralBundleResolution {
    var found: ?usize = null;
    for (sets, 0..) |set, i| {
        if (!structuralUnscoped(set) or !hasMember(set.members, edge)) continue;
        if (found != null) return .multiple;
        found = i;
    }
    return if (found) |i| .{ .unique = i } else .absent;
}

pub fn structuralUnscoped(set: Bundle) bool {
    if (set.cells != null or set.pairwise != null) return false;
    return switch (set.origin) {
        .selected_bundle, .fan_rail => true,
        .port_share => false,
    };
}

fn hasMember(members: []const EdgeId, edge: EdgeId) bool {
    for (members) |member| {
        if (member == edge) return true;
    }
    return false;
}

pub fn numberBundles(
    allocator: std.mem.Allocator,
    sets: []const Bundle,
) error{OutOfMemory}![]const Bundle {
    if (sets.len == 0) return sets;
    const out = try allocator.alloc(Bundle, sets.len);
    for (sets, out, 1..) |set, *slot, i| {
        slot.* = set;
        slot.bundle = @intCast(i);
    }
    return out;
}

pub fn bundleSetsNumbered(sets: []const Bundle) bool {
    for (sets) |set| {
        if (set.bundle == no_bundle) return false;
    }
    return true;
}

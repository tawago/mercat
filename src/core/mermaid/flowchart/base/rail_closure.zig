const std = @import("std");

pub const NodeId = u32;
pub const EdgeId = u32;

pub const Member = struct {
    edge: EdgeId,
    leaf: NodeId,
    kind: u8,
    arrow_free: bool,
    undecorated: bool,
};

pub const Backer = struct {
    edge: EdgeId,
    a: NodeId,
    b: NodeId,
    kind: u8,
    undecorated: bool,
    unlabeled: bool,
};

pub const Discharge = struct {
    pair: [2]NodeId,
    backer: EdgeId,
};

pub const Outcome = enum {
    untouched,
    keep,
    salvage,
    refuse,
};

pub const Verdict = struct {
    outcome: Outcome,
    members: []const EdgeId = &.{},
    discharges: []const Discharge = &.{},
};

pub const max_salvage_members: usize = 16;

pub fn decide(
    allocator: std.mem.Allocator,
    members: []const Member,
    backers: []const Backer,
) error{OutOfMemory}!Verdict {
    if (members.len < 2 or !allArrowFree(members)) return .{ .outcome = .untouched, .members = try edgeIds(allocator, members) };

    const full = try attempt(allocator, members, backers);
    if (full) |d| return .{
        .outcome = .keep,
        .members = try edgeIds(allocator, members),
        .discharges = d,
    };

    if (members.len > max_salvage_members) return .{ .outcome = .refuse };

    const compatible = pairMatrix(members, backers);
    var widest: usize = 0;
    for (0..members.len) |i| widest = @max(widest, @popCount(compatible[i]));
    if (widest < 1) return .{ .outcome = .refuse };
    var size: usize = @min(members.len - 1, widest + 1);
    while (size >= 2) : (size -= 1) {
        var mask: u32 = 0;
        const limit: u32 = @as(u32, 1) << @intCast(members.len);
        while (mask < limit) : (mask += 1) {
            if (@popCount(mask) != size or !maskCompatible(compatible, mask)) continue;
            const subset = try subsetOf(allocator, members, mask);
            defer allocator.free(subset);
            const d = try attempt(allocator, subset, backers) orelse continue;
            return .{
                .outcome = .salvage,
                .members = try edgeIds(allocator, subset),
                .discharges = d,
            };
        }
    }
    return .{ .outcome = .refuse };
}

pub fn nodesClosed(
    allocator: std.mem.Allocator,
    nodes: []const NodeId,
    kind: u8,
    backers: []const Backer,
) error{OutOfMemory}!?[]const Discharge {
    var used: std.ArrayListUnmanaged(EdgeId) = .empty;
    defer used.deinit(allocator);
    var out: std.ArrayListUnmanaged(Discharge) = .empty;
    errdefer out.deinit(allocator);
    for (nodes, 0..) |x, i| {
        for (nodes[0..i]) |y| {
            if (x == y) continue;
            const b = findBacker(backers, kind, x, y, used.items) orelse {
                out.deinit(allocator);
                return null;
            };
            try used.append(allocator, b.edge);
            try out.append(allocator, .{ .pair = normalize(y, x), .backer = b.edge });
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn attempt(
    allocator: std.mem.Allocator,
    members: []const Member,
    backers: []const Backer,
) error{OutOfMemory}!?[]const Discharge {
    for (members) |m| {
        if (!m.undecorated) return null;
    }
    for (members[1..]) |m| {
        if (m.kind != members[0].kind) return null;
    }
    const leaves = try allocator.alloc(NodeId, members.len);
    defer allocator.free(leaves);
    for (members, leaves) |m, *slot| slot.* = m.leaf;
    return nodesClosed(allocator, leaves, members[0].kind, backers);
}

fn pairMatrix(members: []const Member, backers: []const Backer) [max_salvage_members]u32 {
    var rows: [max_salvage_members]u32 = @splat(0);
    for (members, 0..) |m, i| {
        for (members[0..i], 0..) |n, j| {
            const ok = m.leaf == n.leaf or findBacker(backers, m.kind, m.leaf, n.leaf, &.{}) != null;
            if (!m.undecorated or !n.undecorated or m.kind != n.kind or !ok) continue;
            rows[i] |= @as(u32, 1) << @intCast(j);
            rows[j] |= @as(u32, 1) << @intCast(i);
        }
    }
    return rows;
}

fn maskCompatible(rows: [max_salvage_members]u32, mask: u32) bool {
    var rest = mask;
    while (rest != 0) {
        const bit = @ctz(rest);
        rest &= rest - 1;
        const others = mask & ~(@as(u32, 1) << @intCast(bit));
        if (others & ~rows[bit] != 0) return false;
    }
    return true;
}

fn findBacker(
    backers: []const Backer,
    kind: u8,
    x: NodeId,
    y: NodeId,
    used: []const EdgeId,
) ?Backer {
    for (backers) |b| {
        if (!samePair(b, x, y)) continue;
        if (b.kind != kind or !b.undecorated or !b.unlabeled) continue;
        if (contains(used, b.edge)) continue;
        return b;
    }
    return null;
}

fn samePair(b: Backer, x: NodeId, y: NodeId) bool {
    return (b.a == x and b.b == y) or (b.a == y and b.b == x);
}

fn allArrowFree(members: []const Member) bool {
    for (members) |m| {
        if (!m.arrow_free) return false;
    }
    return true;
}

fn normalize(x: NodeId, y: NodeId) [2]NodeId {
    return if (x <= y) .{ x, y } else .{ y, x };
}

fn subsetOf(allocator: std.mem.Allocator, members: []const Member, mask: u32) error{OutOfMemory}![]Member {
    const out = try allocator.alloc(Member, @popCount(mask));
    var i: usize = 0;
    for (members, 0..) |m, bit| {
        if (mask & (@as(u32, 1) << @intCast(bit)) == 0) continue;
        out[i] = m;
        i += 1;
    }
    return out;
}

fn edgeIds(allocator: std.mem.Allocator, members: []const Member) error{OutOfMemory}![]const EdgeId {
    const out = try allocator.alloc(EdgeId, members.len);
    for (members, out) |m, *slot| slot.* = m.edge;
    return out;
}

pub fn contains(edges: []const EdgeId, edge: EdgeId) bool {
    for (edges) |e| {
        if (e == edge) return true;
    }
    return false;
}

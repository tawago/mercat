const std = @import("std");
const sg = @import("../sem_graph.zig");
const rail_star = @import("../base/rail_star.zig");
const types = @import("bridge_types.zig");

fn pivotOf(c: types.Crossing, end: rail_star.Endpoint) sg.NodeId {
    return if (end == .source) c.from else c.to;
}

fn joinable(c: types.Crossing) bool {
    return c.from != c.to and c.kind != .invisible;
}

pub fn groups(
    arena: std.mem.Allocator,
    crossings: []const types.Crossing,
    end: rail_star.Endpoint,
) error{OutOfMemory}![]const []const usize {
    const grouped = try arena.alloc(bool, crossings.len);
    @memset(grouped, false);
    var out: std.ArrayListUnmanaged([]const usize) = .empty;
    for (crossings, 0..) |first, i| {
        if (grouped[i] or !joinable(first)) continue;
        var members: std.ArrayListUnmanaged(usize) = .empty;
        for (crossings[i..], i..) |c, j| {
            if (!joinable(c) or pivotOf(c, end) != pivotOf(first, end)) continue;
            grouped[j] = true;
            try members.append(arena, j);
        }
        if (members.items.len >= 2) try out.append(arena, try members.toOwnedSlice(arena));
    }
    return out.toOwnedSlice(arena);
}

pub fn licensed(
    arena: std.mem.Allocator,
    crossings: []const types.Crossing,
    members: []const usize,
    end: rail_star.Endpoint,
) error{OutOfMemory}!bool {
    const rows = try arena.alloc(rail_star.RailLicenceMember, members.len);
    for (members, rows) |mi, *row| {
        const c = crossings[mi];
        row.* = .{
            .edge = if (c.origin == sg.SENTINEL) c.id else c.origin,
            .endpoints = .{ c.from, c.to },
            .arrows = .{ c.arrow_from, c.arrow_to },
            .stands_for = .arrow_free,
            .kind = c.kind,
            .pivot_end = end,
        };
    }
    return rail_star.checkLicence(.{
        .id = 1,
        .polarity = if (end == .source) .out else .in,
        .pivot = pivotOf(crossings[members[0]], end),
        .members = rows,
    }).isValid();
}

test {
    _ = @import("bridge_fans_test.zig");
}

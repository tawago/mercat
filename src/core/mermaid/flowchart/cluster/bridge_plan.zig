const std = @import("std");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const rail_star = @import("../base/rail_star.zig");
const bridges = @import("bridges.zig");
const bridge_fans = @import("bridge_fans.zig");
const rails = @import("bridge_rails.zig");

pub fn plan(
    arena: std.mem.Allocator,
    crossings: []const bridges.Crossing,
    routed: []const sketch.EdgePath,
    bridge_base: sketch.EdgeId,
) error{OutOfMemory}!ledger.RealizedBundles {
    const side_of = try arena.alloc([2]?ledger.MembershipDisposition, crossings.len);
    for (side_of) |*s| s.* = .{ null, null };

    var group_id: ledger.CandidateBundleId = 0;
    var next_bundle: ledger.SelectedBundleId = 0;
    var selected: std.ArrayListUnmanaged(ledger.SelectedBundle) = .empty;
    for ([2]rail_star.Endpoint{ .source, .target }) |end| {
        for (try bridge_fans.groups(arena, crossings, end)) |members| {
            const licensed = try bridge_fans.licensed(arena, crossings, members, end);
            if (licensed and try realized(arena, crossings, members, routed, bridge_base, end)) {
                const medges = try arena.alloc(ledger.EdgeId, members.len);
                for (members, medges) |mi, *e| e.* = crossings[mi].id + bridge_base;
                try selected.append(arena, .{
                    .id = next_bundle,
                    .proposal = 0,
                    .candidate_bundle = group_id,
                    .members = medges,
                });
                for (members) |mi| side_of[mi][end.index()] = .{ .selected = next_bundle };
                next_bundle += 1;
            } else for (members) |mi| side_of[mi][end.index()] = .{ .independent = .{
                .candidate_bundle = group_id,
                .reason = if (licensed) .not_selected else .licence_refused,
            } };
            group_id += 1;
        }
    }

    var memberships: std.ArrayListUnmanaged(ledger.RealizedEdgeMembership) = .empty;
    for (crossings, side_of) |c, s| {
        if (routedPath(routed, bridge_base, c.id) == null) continue;
        try memberships.append(arena, .{
            .edge = c.id + bridge_base,
            .source = s[0],
            .target = s[1],
        });
    }

    return .{
        .selected_bundles = try selected.toOwnedSlice(arena),
        .memberships = try memberships.toOwnedSlice(arena),
    };
}

fn realized(
    arena: std.mem.Allocator,
    crossings: []const bridges.Crossing,
    members: []const usize,
    routed: []const sketch.EdgePath,
    bridge_base: sketch.EdgeId,
    end: rail_star.Endpoint,
) error{OutOfMemory}!bool {
    const paths = try arena.alloc(sketch.EdgePath, members.len);
    for (members, paths) |mi, *p| {
        p.* = routedPath(routed, bridge_base, crossings[mi].id) orelse return false;
    }
    return rails.realizedRail(arena, paths, end);
}

fn routedPath(
    routed: []const sketch.EdgePath,
    bridge_base: sketch.EdgeId,
    crossing_id: sketch.EdgeId,
) ?sketch.EdgePath {
    for (routed) |p| {
        if (p.id == crossing_id + bridge_base) return p;
    }
    return null;
}

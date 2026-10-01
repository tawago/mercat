const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const rail_star = @import("../base/rail_star.zig");
const split_mod = @import("split.zig");
const edge_ends = @import("edge_ends.zig");
const Final = @import("final_scene.zig").Final;

pub const ChildSource = struct {
    sketch: sketch.Sketch,
    node_map: []const sketch.NodeId,
    edge_base: sketch.EdgeId,
};

pub fn transport(
    arena: std.mem.Allocator,
    sr: split_mod.SplitResult,
    children: []const ChildSource,
    outer: sketch.Sketch,
    outer_node_map: []const sketch.NodeId,
    outer_edge_base: sketch.EdgeId,
) error{OutOfMemory}![]const rail_star.RailClaim {
    var out: std.ArrayListUnmanaged(rail_star.RailClaim) = .empty;
    for (children) |source| {
        for (source.sketch.sharing.claims) |claim| {
            try appendClaim(arena, &out, claim, source.node_map, source.edge_base, null);
        }
    }
    for (outer.sharing.claims) |claim| {
        try appendClaim(arena, &out, claim, outer_node_map, outer_edge_base, .{ .sr = sr, .outer = outer });
    }
    return out.toOwnedSlice(arena);
}

const OuterPending = struct {
    sr: split_mod.SplitResult,
    outer: sketch.Sketch,
};

fn appendClaim(
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(rail_star.RailClaim),
    claim: rail_star.RailClaim,
    node_map: []const sketch.NodeId,
    edge_base: sketch.EdgeId,
    pending: ?OuterPending,
) error{OutOfMemory}!void {
    const members = try arena.alloc(rail_star.RailClaimMember, claim.members.len);
    for (claim.members, members) |member, *copy| {
        const dropped = if (pending) |outer| droppedEnds(outer.sr, outer.outer, member.edge) else .{ false, false };
        copy.* = remapMember(member, node_map, edge_base, dropped);
    }

    try out.append(arena, .{
        .id = @intCast(out.items.len + 1),
        .polarity = claim.polarity,
        .members = members,
    });
}

fn remapMember(
    member: rail_star.RailClaimMember,
    node_map: []const sketch.NodeId,
    edge_base: sketch.EdgeId,
    dropped: [2]bool,
) rail_star.RailClaimMember {
    var out = member;
    out.edge += edge_base;
    inline for ([2]rail_star.Endpoint{ .source, .target }) |end| {
        const i = end.index();
        out.endpoints[i] = mapOptionalNode(node_map, member.endpoints[i]);
        out.sites[i] = mapSite(node_map, member.sites[i]);
        if (dropped[i]) {
            out.endpoints[i] = null;
            out.sites[i] = null;
        }
    }
    return out;
}

fn mapOptionalNode(node_map: []const sketch.NodeId, node: ?sketch.NodeId) ?sketch.NodeId {
    return mapNode(node_map, node orelse return null);
}

fn mapNode(node_map: []const sketch.NodeId, node: sketch.NodeId) ?sketch.NodeId {
    if (node >= node_map.len or node_map[node] == sg.SENTINEL) return null;
    return node_map[node];
}

fn mapSite(node_map: []const sketch.NodeId, site: ?rail_star.AttachmentSite) ?rail_star.AttachmentSite {
    const old = site orelse return null;
    const node = mapNode(node_map, old.node) orelse return null;
    return .{ .node = node, .side = old.side, .offset = old.offset };
}

fn droppedEnds(sr: split_mod.SplitResult, outer: sketch.Sketch, edge: sketch.EdgeId) [2]bool {
    const ends = edge_ends.find(outer.edges, outer.rails, edge) orelse return .{ false, false };
    return .{ sr.isSuper(ends.from), sr.isSuper(ends.to) };
}

pub fn finalMember(fin: Final, edge: sketch.EdgeId, pivot_end: rail_star.Endpoint) ?rail_star.RailClaimMember {
    for (fin.paths) |path| {
        if (path.id != edge) continue;
        const ends = edge_ends.ofPath(path);
        return .{
            .edge = edge,
            .endpoints = .{ ends.from, ends.to },
            .sites = .{ siteFromPort(path.port_from, path.from), siteFromPort(path.port_to, path.to) },
            .arrows = ends.arrows,
            .kind = ends.kind,
            .pivot_end = pivot_end,
        };
    }
    for (fin.rails) |rail| {
        for (rail.taps) |tap| {
            if (tap.edge != edge or rail.stem.len == 0) continue;
            const ends = edge_ends.ofTap(rail, tap);
            const fan_in = edge_ends.isFanIn(rail);
            return .{
                .edge = edge,
                .endpoints = .{ ends.from, ends.to },
                .sites = .{
                    siteFromPoint(fin.placements, ends.from, if (fan_in) tap.landing else rail.stem[0]),
                    siteFromPoint(fin.placements, ends.to, if (fan_in) rail.stem[0] else tap.landing),
                },
                .arrows = ends.arrows,
                .kind = ends.kind,
                .pivot_end = pivot_end,
            };
        }
    }
    return null;
}

fn siteFromPort(port: sketch.Port, node: sketch.NodeId) ?rail_star.AttachmentSite {
    if (port.node != node) return null;
    return .{ .node = node, .side = port.side, .offset = port.offset };
}

fn siteFromPoint(placements: []const sketch.NodePlacement, node: sketch.NodeId, point: sketch.Point) ?rail_star.AttachmentSite {
    for (placements) |placement| {
        if (placement.id != node) continue;
        const rect = placement.rect;
        if (point.y == rect.y and point.x >= rect.x and point.x < rect.right())
            return .{ .node = node, .side = .north, .offset = @intCast(point.x - rect.x) };
        if (point.y == rect.bottom() - 1 and point.x >= rect.x and point.x < rect.right())
            return .{ .node = node, .side = .south, .offset = @intCast(point.x - rect.x) };
        if (point.x == rect.x and point.y >= rect.y and point.y < rect.bottom())
            return .{ .node = node, .side = .west, .offset = @intCast(point.y - rect.y) };
        if (point.x == rect.right() - 1 and point.y >= rect.y and point.y < rect.bottom())
            return .{ .node = node, .side = .east, .offset = @intCast(point.y - rect.y) };
        return null;
    }
    return null;
}

test "stitch rails:" {
    _ = @import("stitch_rails_test.zig");
}

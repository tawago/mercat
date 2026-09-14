//! Transport semantic RailClaims from piece-local Sketches into one stitch.
//!
//! Child claims follow the same node maps and edge-id windows as their paths
//! and taps. Outer placement members that touch a super-node are not replaced
//! here: their shifted edge id remains reserved, while the unavailable end is
//! made explicitly unresolved for the later bridge-expansion phase.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const split_mod = @import("split.zig");

/// One child in stitch order, with the exact maps/windows used for its paths.
pub const ChildSource = struct {
    sketch: sketch.Sketch,
    node_map: []const sketch.NodeId,
    edge_base: sketch.EdgeId,
};

/// Deep-copy and globally number all child claims, then all outer claims.
/// Outer bridge substitution deliberately remains pending in the returned
/// unresolved members; a follow-up can resolve them from `sr`, `outer`, and
/// the reserved `outer_edge_base` window without recovering child-local ids.
pub fn transport(
    arena: std.mem.Allocator,
    sr: split_mod.SplitResult,
    children: []const ChildSource,
    outer: sketch.Sketch,
    outer_node_map: []const sketch.NodeId,
    outer_edge_base: sketch.EdgeId,
) error{OutOfMemory}![]const ledger.RailClaim {
    var out: std.ArrayListUnmanaged(ledger.RailClaim) = .empty;
    for (children) |source| {
        for (source.sketch.rail_claims) |claim| {
            try appendClaim(arena, &out, claim, source.node_map, source.edge_base, null);
        }
    }
    for (outer.rail_claims) |claim| {
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
    out: *std.ArrayListUnmanaged(ledger.RailClaim),
    claim: ledger.RailClaim,
    node_map: []const sketch.NodeId,
    edge_base: sketch.EdgeId,
    pending: ?OuterPending,
) error{OutOfMemory}!void {
    const members = try arena.alloc(ledger.RailClaimMember, claim.members.len);
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
    member: ledger.RailClaimMember,
    node_map: []const sketch.NodeId,
    edge_base: sketch.EdgeId,
    dropped: [2]bool,
) ledger.RailClaimMember {
    var out = member;
    out.edge += edge_base;
    inline for ([2]ledger.Endpoint{ .source, .target }) |end| {
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

fn mapSite(node_map: []const sketch.NodeId, site: ?ledger.AttachmentSite) ?ledger.AttachmentSite {
    const old = site orelse return null;
    const node = mapNode(node_map, old.node) orelse return null;
    return .{ .node = node, .side = old.side, .offset = old.offset };
}

/// Ends that belonged to a placement carrier which stitch drops. The edge id
/// itself remains in the outer reserved window as the bridge-pending key.
fn droppedEnds(sr: split_mod.SplitResult, outer: sketch.Sketch, edge: sketch.EdgeId) [2]bool {
    for (outer.edges) |path| {
        if (path.id != edge) continue;
        return .{ isSuper(sr, path.from), isSuper(sr, path.to) };
    }
    for (outer.rails) |rail| {
        for (rail.taps) |tap| {
            if (tap.edge != edge) continue;
            const fan_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
            return if (fan_in)
                .{ isSuper(sr, tap.node), isSuper(sr, rail.pivot) }
            else
                .{ isSuper(sr, rail.pivot), isSuper(sr, tap.node) };
        }
    }
    return .{ false, false };
}

fn isSuper(sr: split_mod.SplitResult, node: sketch.NodeId) bool {
    for (sr.supers) |super| if (super.outer_node == node) return true;
    return false;
}

/// Rebuild one claim member from a final carrier. `pivot_end` remains semantic
/// input; every other field comes from final endpoints, ports, or rail sites.
pub fn finalMember(
    paths: []const sketch.EdgePath,
    rails_buf: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
    edge: sketch.EdgeId,
    pivot_end: ledger.Endpoint,
) ?ledger.RailClaimMember {
    for (paths) |path| {
        if (path.id != edge) continue;
        return .{
            .edge = edge,
            .endpoints = .{ path.from, path.to },
            .sites = .{ siteFromPort(path.port_from, path.from), siteFromPort(path.port_to, path.to) },
            .arrows = .{ path.arrow_from, path.arrow_to },
            .kind = path.kind,
            .pivot_end = pivot_end,
        };
    }
    for (rails_buf) |rail| {
        const fan_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
        for (rail.taps) |tap| {
            if (tap.edge != edge or rail.stem.len == 0) continue;
            const source = if (fan_in) tap.node else rail.pivot;
            const target = if (fan_in) rail.pivot else tap.node;
            return .{
                .edge = edge,
                .endpoints = .{ source, target },
                .sites = if (fan_in)
                    .{ siteFromPoint(placements, source, tap.landing), siteFromPoint(placements, target, rail.stem[0]) }
                else
                    .{ siteFromPoint(placements, source, rail.stem[0]), siteFromPoint(placements, target, tap.landing) },
                .arrows = if (fan_in) .{ tap.arrow, rail.pivot_arrow } else .{ rail.pivot_arrow, tap.arrow },
                .kind = rail.kind,
                .pivot_end = pivot_end,
            };
        }
    }
    return null;
}

fn siteFromPort(port: sketch.Port, node: sketch.NodeId) ?ledger.AttachmentSite {
    if (port.node != node) return null;
    return .{ .node = node, .side = port.side, .offset = port.offset };
}

fn siteFromPoint(placements: []const sketch.NodePlacement, node: sketch.NodeId, point: sketch.Point) ?ledger.AttachmentSite {
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

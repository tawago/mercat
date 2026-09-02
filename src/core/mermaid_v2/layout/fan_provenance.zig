//! Final-artifact production of semantic fan RailClaims.
//!
//! A claim follows the detected fan and its effective member lane, not the
//! drawing form selected for that lane. First-class Rails, coordinated peer
//! paths, grids, and detours therefore produce the same record shape.

const std = @import("std");
const ledger = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const fan_mod = @import("fan.zig");

pub fn build(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    placements: []const sketch.NodePlacement,
    fans: []const fan_mod.Fan,
    bundles: ledger.RealizedBundles,
    paths: []const sketch.EdgePath,
    rails: []const sketch.Rail,
) error{OutOfMemory}![]const ledger.RailClaim {
    var out: std.ArrayListUnmanaged(ledger.RailClaim) = .empty;
    for (fans) |f| {
        if (deferredToArrivals(bundles, f)) continue;
        for (f.peers, 0..) |seed, i| {
            if (!seed.shared) continue;
            const seed_edge = edgeById(graph, seed.edge_id) orelse continue;
            if (!effective(bundles, seed_edge)) continue;
            const lane = fan_mod.effectiveLane(f, seed.lane);
            if (groupSeen(graph, f, bundles, f.peers[0..i], lane)) continue;

            var members: std.ArrayListUnmanaged(ledger.RailClaimMember) = .empty;
            for (f.peers) |peer| {
                if (!peer.shared) continue;
                if (fan_mod.effectiveLane(f, peer.lane) != lane) continue;
                const semantic = edgeById(graph, peer.edge_id) orelse continue;
                if (!effective(bundles, semantic)) continue;
                try members.append(a, memberFor(f, semantic, placements, paths, rails));
            }
            if (members.items.len < 2) {
                members.deinit(a);
                continue;
            }

            const owned = try members.toOwnedSlice(a);
            const claim: ledger.RailClaim = .{
                .id = @intCast(out.items.len + 1),
                .polarity = if (f.direction == .out) .out else .in,
                .members = owned,
            };
            std.debug.assert(ledger.checkRailClaim(claim).derived_pivot == f.pivot);
            try out.append(a, claim);
        }
    }
    return out.toOwnedSlice(a);
}

fn memberFor(
    f: fan_mod.Fan,
    semantic: sg.Edge,
    placements: []const sketch.NodePlacement,
    paths: []const sketch.EdgePath,
    rails: []const sketch.Rail,
) ledger.RailClaimMember {
    if (railMember(f, semantic, placements, rails)) |member| return member;
    if (pathById(paths, semantic.id)) |path| {
        var member = memberFromPath(f, path);
        member.stands_for = semantic.stands_for;
        return member;
    }

    return .{
        .edge = semantic.id,
        .endpoints = .{ semantic.from, semantic.to },
        .sites = .{ null, null },
        .arrows = .{ mapArrow(semantic.arrow_from), mapArrow(semantic.arrow_to) },
        .stands_for = semantic.stands_for,
        .kind = semantic.kind,
        .pivot_end = if (f.direction == .out) .source else .target,
    };
}

fn memberFromPath(f: fan_mod.Fan, path: sketch.EdgePath) ledger.RailClaimMember {
    return .{
        .edge = path.id,
        .endpoints = .{ path.from, path.to },
        .sites = .{ siteFromPort(path.port_from, path.from), siteFromPort(path.port_to, path.to) },
        .arrows = .{ path.arrow_from, path.arrow_to },
        .kind = path.kind,
        .pivot_end = if (f.direction == .out) .source else .target,
    };
}

fn railMember(
    f: fan_mod.Fan,
    semantic: sg.Edge,
    placements: []const sketch.NodePlacement,
    rails: []const sketch.Rail,
) ?ledger.RailClaimMember {
    for (rails) |rail| {
        if (rail.pivot != f.pivot or !roleMatches(f.direction, rail.role) or rail.stem.len == 0) continue;
        for (rail.taps) |tap| {
            if (tap.edge != semantic.id) continue;
            const rail_in = rail.role == .fan_in_dropper or rail.role == .fan_in_rail;
            const artifact_source = if (rail_in) tap.node else rail.pivot;
            const artifact_target = if (rail_in) rail.pivot else tap.node;
            const source_site = if (artifact_source == semantic.from)
                siteFromPoint(placements, artifact_source, if (rail_in) tap.landing else rail.stem[0])
            else
                null;
            const target_site = if (artifact_target == semantic.to)
                siteFromPoint(placements, artifact_target, if (rail_in) rail.stem[0] else tap.landing)
            else
                null;
            return .{
                .edge = semantic.id,
                .endpoints = .{ semantic.from, semantic.to },
                .sites = .{ source_site, target_site },
                .arrows = if (rail_in) .{ tap.arrow, rail.pivot_arrow } else .{ rail.pivot_arrow, tap.arrow },
                .stands_for = semantic.stands_for,
                .kind = rail.kind,
                .pivot_end = if (f.direction == .out) .source else .target,
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

fn groupSeen(graph: sg.SemGraph, f: fan_mod.Fan, bundles: ledger.RealizedBundles, peers: []const fan_mod.FanEdge, lane: u32) bool {
    for (peers) |peer| {
        if (!peer.shared) continue;
        if (fan_mod.effectiveLane(f, peer.lane) != lane) continue;
        const prior = edgeById(graph, peer.edge_id) orelse continue;
        if (effective(bundles, prior)) return true;
    }
    return false;
}

fn deferredToArrivals(bundles: ledger.RealizedBundles, f: fan_mod.Fan) bool {
    if (f.direction != .out or bundles.memberships.len == 0) return false;
    var any = false;
    for (f.peers) |peer| {
        if (!peer.shared) continue;
        any = true;
        const arrival = for (bundles.memberships) |m| {
            if (m.edge == peer.edge_id) break m.target orelse return false;
        } else return false;
        if (arrival != .selected) return false;
    }
    return any;
}

fn effective(bundles: ledger.RealizedBundles, edge: sg.Edge) bool {
    if (edge.kind == .invisible) return false;
    for (bundles.discharged) |spent| if (spent == edge.id) return false;
    return true;
}

fn pathById(paths: []const sketch.EdgePath, edge: sg.EdgeId) ?sketch.EdgePath {
    for (paths) |path| if (path.id == edge) return path;
    return null;
}

fn edgeById(graph: sg.SemGraph, edge: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |item| if (item.id == edge) return item;
    return null;
}

fn roleMatches(direction: fan_mod.Direction, role: sketch.EdgeRole) bool {
    return switch (direction) {
        .out => role == .fan_out_dropper or role == .fan_out_rail,
        .in => role == .fan_in_dropper or role == .fan_in_rail,
    };
}

fn mapArrow(arrow: sg.ArrowEnd) sketch.ArrowKind {
    return switch (arrow) {
        .none => .none,
        .open => .open,
        .filled => .filled,
        .circle => .circle,
        .cross => .cross,
    };
}

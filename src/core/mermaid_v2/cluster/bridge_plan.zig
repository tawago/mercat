//! cluster/bridge_plan.zig — outer-scope sharing plan for cross-border
//! edges. A group of crossings sharing one original endpoint is a bundle
//! candidate exactly like a piece fan; it answers to the same geometry-free
//! licence tier (base/rail_star.checkLicence, members keyed by ROOT edge
//! ids), and the decision is RECORDED in the merged plan's memberships:
//! `licence_refused` when the licence fails, `not_selected` when it holds
//! but no rail realized. A licensed group whose routed geometry IS a rail
//! read from its convergent end (bridge_rails.realizedRail: shared stem,
//! disjoint tails — the source-end shape traced outward from the node at
//! either end) flips to `selected` with one selected bundle over the
//! members — on that shape the position-independent authority is inert away
//! from the shared run. An edge may be selected at both ends (rail
//! membership at both ends). Any
//! other group stays independent: a global sanction was tried and measured —
//! it merges member-vs-member crossings away from the approach into junction
//! glyphs a third edge then lands on. Groups span CROSSINGS only: absorbing
//! a piece edge sharing the pivot is licence-permitted but its committed
//! geometry starts one column over with its arrowhead on the shared face
//! (decorations refuse transit even among members), so no rail containing
//! it can exist and the honest record is the crossing-only group.
//! Group ids are bridge-plan-internal (same rule as piece plans crossing the
//! stitch); membership edge ids are merged-sketch bridge ids. PURE DATA:
//! crossings + routed paths in, one RealizedBundles fragment out.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const bridges = @import("bridges.zig");
const rails = @import("bridge_rails.zig");

/// Plan the cross-border bundles over the routed bridges. `routed` are the
/// final merged-sketch bridge paths (ids already offset by `bridge_base`);
/// `crossings[i]` maps to merged edge id `crossings[i].id + bridge_base`.
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
    for ([2]ledger.BundleDirection{ .out, .in }) |direction| {
        const di: usize = if (direction == .out) 0 else 1;
        const grouped = try arena.alloc(bool, crossings.len);
        @memset(grouped, false);
        for (crossings, 0..) |c0, i| {
            if (grouped[i] or c0.from == c0.to or c0.kind == .invisible) continue;
            const pivot = pivotOf(c0, direction);
            var members: std.ArrayListUnmanaged(usize) = .empty;
            for (crossings, 0..) |c, j| {
                if (c.from == c.to or c.kind == .invisible) continue;
                if (pivotOf(c, direction) != pivot) continue;
                grouped[j] = true;
                try members.append(arena, j);
            }
            if (members.items.len < 2) continue;

            const licensed = (try checkGroup(arena, crossings, members.items, direction, pivot)).isValid();
            if (licensed and try realized(arena, crossings, members.items, routed, bridge_base, direction)) {
                const medges = try arena.alloc(ledger.EdgeId, members.items.len);
                for (members.items, medges) |mi, *e| e.* = crossings[mi].id + bridge_base;
                try selected.append(arena, .{
                    .id = next_bundle,
                    .proposal = 0,
                    .candidate_bundle = group_id,
                    .members = medges,
                });
                for (members.items) |mi| side_of[mi][di] = .{ .selected = next_bundle };
                next_bundle += 1;
            } else for (members.items) |mi| side_of[mi][di] = .{ .independent = .{
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

/// A licensed group realized a rail iff EVERY member routed and the final
/// paths are one rail read from the convergent end
/// (bridge_rails.realizedRail): shared stem, disjoint tails — the shape on
/// which the sanction is inert away from the shared run.
fn realized(
    arena: std.mem.Allocator,
    crossings: []const bridges.Crossing,
    members: []const usize,
    routed: []const sketch.EdgePath,
    bridge_base: sketch.EdgeId,
    direction: ledger.BundleDirection,
) error{OutOfMemory}!bool {
    const paths = try arena.alloc(sketch.EdgePath, members.len);
    for (members, paths) |mi, *p| {
        p.* = routedPath(routed, bridge_base, crossings[mi].id) orelse return false;
    }
    return rails.realizedRail(arena, paths, if (direction == .out) .source else .target);
}

fn pivotOf(c: bridges.Crossing, direction: ledger.BundleDirection) sg.NodeId {
    return if (direction == .out) c.from else c.to;
}

/// The geometry-free licence over the group, members keyed by root edge ids.
fn checkGroup(
    arena: std.mem.Allocator,
    crossings: []const bridges.Crossing,
    members: []const usize,
    direction: ledger.BundleDirection,
    pivot: sg.NodeId,
) error{OutOfMemory}!ledger.RailLicenceCheck {
    const rows = try arena.alloc(ledger.RailLicenceMember, members.len);
    for (members, rows) |mi, *row| {
        const c = crossings[mi];
        row.* = .{
            .edge = if (c.origin == sg.SENTINEL) c.id else c.origin,
            .endpoints = .{ c.from, c.to },
            .arrows = .{ c.arrow_from, c.arrow_to },
            .stands_for = .arrow_free,
            .kind = c.kind,
            .pivot_end = if (direction == .out) .source else .target,
        };
    }
    return ledger.checkRailLicence(.{
        .id = 1,
        .polarity = if (direction == .out) .out else .in,
        .pivot = pivot,
        .members = rows,
    });
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

fn fanInPath(id: sketch.EdgeId, from: sketch.NodeId, poly: []const sketch.Point) sketch.EdgePath {
    return .{ .id = id, .from = from, .to = 9, .polyline = poly, .port_from = .{ .node = from, .side = .south, .offset = 1 }, .port_to = .{ .node = 9, .side = .north, .offset = 3 }, .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid };
}

test "a licensed cross-border fan-in with no routed geometry records not selected; a mixed one records the refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]bridges.Crossing{
        .{ .id = 0, .from = 1, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 4 },
        .{ .id = 1, .from = 2, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 5 },
        .{ .id = 2, .from = 3, .to = 8, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 6 },
    };
    const base: sketch.EdgeId = 100;
    const routed = [_]sketch.EdgePath{
        fanInPath(100, 1, &.{}),
        fanInPath(101, 2, &.{}),
        .{ .id = 102, .from = 3, .to = 8, .polyline = &.{}, .port_from = .{ .node = 3, .side = .south, .offset = 1 }, .port_to = .{ .node = 8, .side = .north, .offset = 0 }, .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid },
    };

    const bundles = try plan(a, &crossings, &routed, base);
    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 3), bundles.memberships.len);
    const licensed = bundles.memberships[0].target.?;
    try std.testing.expect(licensed == .independent);
    try std.testing.expectEqual(ledger.IndependentReason.not_selected, licensed.independent.reason);
    try std.testing.expectEqual(licensed.independent.candidate_bundle, bundles.memberships[1].target.?.independent.candidate_bundle);
    try std.testing.expect(bundles.memberships[0].source == null);
    try std.testing.expect(bundles.memberships[2].source == null and bundles.memberships[2].target == null);

    var mixed = crossings;
    mixed[1].arrow_to = .circle;
    const refused = try plan(a, &mixed, &routed, base);
    try std.testing.expectEqual(@as(usize, 0), refused.selected_bundles.len);
    const disp = refused.memberships[0].target.?;
    try std.testing.expectEqual(ledger.IndependentReason.licence_refused, disp.independent.reason);
}

test "a licensed cross-border fan-in whose members join on one rail from the target port records a selected bundle; re-contact past the rail stays not selected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]bridges.Crossing{
        .{ .id = 0, .from = 1, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 4 },
        .{ .id = 1, .from = 2, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 5 },
        .{ .id = 2, .from = 3, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 6 },
    };
    const base: sketch.EdgeId = 100;
    const from_west = [_]sketch.Point{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const straight = [_]sketch.Point{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 9 } };
    const from_east = [_]sketch.Point{ .{ .x = 18, .y = 0 }, .{ .x = 18, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    const routed = [_]sketch.EdgePath{
        fanInPath(100, 1, &from_west),
        fanInPath(101, 2, &straight),
        fanInPath(102, 3, &from_east),
    };

    const bundles = try plan(a, &crossings, &routed, base);
    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{ 100, 101, 102 }, bundles.selected_bundles[0].members);
    for (bundles.memberships) |m| {
        try std.testing.expectEqual(ledger.MembershipDisposition{ .selected = 0 }, m.target.?);
        try std.testing.expect(m.source == null);
    }

    const retouch = [_]sketch.Point{ .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 3 }, .{ .x = 18, .y = 3 }, .{ .x = 18, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    var touching = routed;
    touching[2] = fanInPath(102, 3, &retouch);
    const stays = try plan(a, &crossings, &touching, base);
    try std.testing.expectEqual(@as(usize, 0), stays.selected_bundles.len);
    try std.testing.expectEqual(ledger.IndependentReason.not_selected, stays.memberships[0].target.?.independent.reason);
}

test "invisible crossings sharing a pivot re-form no group and keep one stable id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]bridges.Crossing{
        .{ .id = 0, .from = 1, .to = 8, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 3 },
        .{ .id = 1, .from = 1, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 4 },
        .{ .id = 2, .from = 1, .to = 6, .kind = .invisible, .arrow_from = .none, .arrow_to = .none, .label = null, .origin = 5 },
        .{ .id = 3, .from = 1, .to = 7, .kind = .invisible, .arrow_from = .none, .arrow_to = .none, .label = null, .origin = 6 },
    };
    var routed: [4]sketch.EdgePath = undefined;
    for (&routed, crossings) |*r, c| {
        r.* = .{ .id = c.id, .from = c.from, .to = c.to, .polyline = &.{}, .port_from = .{ .node = c.from, .side = .south, .offset = 1 }, .port_to = .{ .node = c.to, .side = .north, .offset = 1 }, .arrow_from = c.arrow_from, .arrow_to = c.arrow_to, .label = null, .kind = c.kind };
    }

    const bundles = try plan(a, &crossings, &routed, 0);
    try std.testing.expectEqual(@as(usize, 4), bundles.memberships.len);
    const g0 = bundles.memberships[0].source.?.independent.candidate_bundle;
    try std.testing.expectEqual(@as(ledger.CandidateBundleId, 0), g0);
    try std.testing.expectEqual(g0, bundles.memberships[1].source.?.independent.candidate_bundle);
    try std.testing.expect(bundles.memberships[2].source == null and bundles.memberships[2].target == null);
    try std.testing.expect(bundles.memberships[3].source == null and bundles.memberships[3].target == null);
}

test "a crossing the router skipped takes no membership row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]bridges.Crossing{
        .{ .id = 0, .from = 1, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 0 },
        .{ .id = 1, .from = 2, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 1 },
    };
    const routed = [_]sketch.EdgePath{
        .{ .id = 50, .from = 1, .to = 9, .polyline = &.{}, .port_from = .{ .node = 1, .side = .south, .offset = 1 }, .port_to = .{ .node = 9, .side = .north, .offset = 2 }, .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid },
    };
    const bundles = try plan(a, &crossings, &routed, 50);
    try std.testing.expectEqual(@as(usize, 1), bundles.memberships.len);
    try std.testing.expectEqual(@as(ledger.EdgeId, 50), bundles.memberships[0].edge);
}

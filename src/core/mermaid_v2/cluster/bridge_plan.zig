//! cluster/bridge_plan.zig — outer-scope sharing plan for cross-border
//! edges. A group of crossings sharing one original endpoint is a bundle
//! candidate exactly like a piece fan; it answers to the same geometry-free
//! licence tier (base/rail_star.checkLicence, members keyed by ROOT edge
//! ids), and the decision is RECORDED in the merged plan's memberships:
//! `licence_refused` when the licence fails, `not_selected` when it holds —
//! licensed, realization deferred. No bridge group emits a selected join:
//! `selected_joins` authorizes position-INDEPENDENT shared geometry, and a
//! bridge fan's legal sharing is only its coincident approach — which the
//! cell-scoped port-share co-set already sanctions exactly there. (A global
//! sanction was tried and measured: it merges member-vs-member crossings
//! away from the approach into junction glyphs a third edge then lands on.)
//! Group ids are bridge-plan-internal (same rule as piece plans crossing the
//! stitch); membership edge ids are merged-sketch bridge ids. PURE DATA:
//! crossings + routed paths in, one RealizedJoins fragment out.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const bridges = @import("bridges.zig");

/// Plan the cross-border bundles over the routed bridges. `routed` are the
/// final merged-sketch bridge paths (ids already offset by `bridge_base`);
/// `crossings[i]` maps to merged edge id `crossings[i].id + bridge_base`.
pub fn plan(
    arena: std.mem.Allocator,
    crossings: []const bridges.Crossing,
    routed: []const sketch.EdgePath,
    bridge_base: sketch.EdgeId,
) error{OutOfMemory}!ledger.RealizedJoins {
    const side_of = try arena.alloc([2]?ledger.MembershipDisposition, crossings.len);
    for (side_of) |*s| s.* = .{ null, null };

    var group_id: ledger.JoinGroupId = 0;
    for ([2]ledger.JoinDirection{ .out, .in }) |direction| {
        const di: usize = if (direction == .out) 0 else 1;
        const grouped = try arena.alloc(bool, crossings.len);
        @memset(grouped, false);
        for (crossings, 0..) |c0, i| {
            if (grouped[i] or c0.from == c0.to) continue;
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
            for (members.items) |mi| side_of[mi][di] = .{ .independent = .{
                .permission_group = group_id,
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

    return .{ .memberships = try memberships.toOwnedSlice(arena) };
}

fn pivotOf(c: bridges.Crossing, direction: ledger.JoinDirection) sg.NodeId {
    return if (direction == .out) c.from else c.to;
}

/// The geometry-free licence over the group, members keyed by root edge ids.
fn checkGroup(
    arena: std.mem.Allocator,
    crossings: []const bridges.Crossing,
    members: []const usize,
    direction: ledger.JoinDirection,
    pivot: sg.NodeId,
) error{OutOfMemory}!ledger.RailLicenceCheck {
    const rows = try arena.alloc(ledger.RailLicenceMember, members.len);
    for (members, rows) |mi, *row| {
        const c = crossings[mi];
        row.* = .{
            .edge = if (c.origin == sg.SENTINEL) c.id else c.origin,
            .endpoints = .{ c.from, c.to },
            .arrows = .{ c.arrow_from, c.arrow_to },
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

test "a licensed cross-border fan-in records deferred; a mixed one records the refusal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Crossings 0,1: A(1)->E(9), B(2)->E(9) — uniform filled fan-in.
    // Crossing 2: C(3)->F(8) lone. Origins are root edge ids.
    const crossings = [_]bridges.Crossing{
        .{ .id = 0, .from = 1, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 4 },
        .{ .id = 1, .from = 2, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 5 },
        .{ .id = 2, .from = 3, .to = 8, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 6 },
    };
    const base: sketch.EdgeId = 100;
    const routed = [_]sketch.EdgePath{
        .{ .id = 100, .from = 1, .to = 9, .polyline = &.{}, .port_from = .{ .node = 1, .side = .south, .offset = 1 }, .port_to = .{ .node = 9, .side = .north, .offset = 3 }, .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid },
        .{ .id = 101, .from = 2, .to = 9, .polyline = &.{}, .port_from = .{ .node = 2, .side = .south, .offset = 1 }, .port_to = .{ .node = 9, .side = .north, .offset = 3 }, .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid },
        .{ .id = 102, .from = 3, .to = 8, .polyline = &.{}, .port_from = .{ .node = 3, .side = .south, .offset = 1 }, .port_to = .{ .node = 8, .side = .north, .offset = 0 }, .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid },
    };

    const joins = try plan(a, &crossings, &routed, base);
    try std.testing.expectEqual(@as(usize, 0), joins.selected_joins.len);
    try std.testing.expectEqual(@as(usize, 3), joins.memberships.len);
    const licensed = joins.memberships[0].target.?;
    try std.testing.expect(licensed == .independent);
    try std.testing.expectEqual(ledger.IndependentReason.not_selected, licensed.independent.reason);
    try std.testing.expectEqual(licensed.independent.permission_group, joins.memberships[1].target.?.independent.permission_group);
    try std.testing.expect(joins.memberships[0].source == null);
    try std.testing.expect(joins.memberships[2].source == null and joins.memberships[2].target == null);

    // Same shape but mixed arrows at the pivot: the licence refuses, and the
    // record names the refusal.
    var mixed = crossings;
    mixed[1].arrow_to = .circle;
    const refused = try plan(a, &mixed, &routed, base);
    try std.testing.expectEqual(@as(usize, 0), refused.selected_joins.len);
    const disp = refused.memberships[0].target.?;
    try std.testing.expectEqual(ledger.IndependentReason.licence_refused, disp.independent.reason);
}

test "a crossing the router skipped takes no membership row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]bridges.Crossing{
        .{ .id = 0, .from = 1, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 0 },
        .{ .id = 1, .from = 2, .to = 9, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null, .origin = 1 },
    };
    // Only crossing 0 routed.
    const routed = [_]sketch.EdgePath{
        .{ .id = 50, .from = 1, .to = 9, .polyline = &.{}, .port_from = .{ .node = 1, .side = .south, .offset = 1 }, .port_to = .{ .node = 9, .side = .north, .offset = 2 }, .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid },
    };
    const joins = try plan(a, &crossings, &routed, 50);
    try std.testing.expectEqual(@as(usize, 1), joins.memberships.len);
    try std.testing.expectEqual(@as(ledger.EdgeId, 50), joins.memberships[0].edge);
}

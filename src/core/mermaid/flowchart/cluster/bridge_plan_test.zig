const std = @import("std");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const bridges = @import("bridges.zig");
const bridge_plan = @import("bridge_plan.zig");

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

    const bundles = try bridge_plan.plan(a, &crossings, &routed, base);
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
    const refused = try bridge_plan.plan(a, &mixed, &routed, base);
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

    const bundles = try bridge_plan.plan(a, &crossings, &routed, base);
    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);
    try std.testing.expectEqualSlices(ledger.EdgeId, &.{ 100, 101, 102 }, bundles.selected_bundles[0].members);
    for (bundles.memberships) |m| {
        try std.testing.expectEqual(ledger.MembershipDisposition{ .selected = 0 }, m.target.?);
        try std.testing.expect(m.source == null);
    }

    const retouch = [_]sketch.Point{ .{ .x = 4, .y = 0 }, .{ .x = 4, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 3 }, .{ .x = 18, .y = 3 }, .{ .x = 18, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 9 } };
    var touching = routed;
    touching[2] = fanInPath(102, 3, &retouch);
    const stays = try bridge_plan.plan(a, &crossings, &touching, base);
    try std.testing.expectEqual(@as(usize, 0), stays.selected_bundles.len);
    try std.testing.expectEqual(ledger.IndependentReason.not_selected, stays.memberships[0].target.?.independent.reason);
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
    const bundles = try bridge_plan.plan(a, &crossings, &routed, 50);
    try std.testing.expectEqual(@as(usize, 1), bundles.memberships.len);
    try std.testing.expectEqual(@as(ledger.EdgeId, 50), bundles.memberships[0].edge);
}

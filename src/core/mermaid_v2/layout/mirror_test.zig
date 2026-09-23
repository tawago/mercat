const std = @import("std");
const ledger = @import("../base/ledger.zig");
const rail_star = @import("../base/rail_star.zig");
const mirror = @import("mirror.zig");
const routing = @import("routing.zig");
const sketch = @import("../sketch.zig");

const testing = std.testing;
const NodeGeom = routing.NodeGeom;

test "mirror.applyDirection swaps x/y/w/h but leaves NodeGeom.layer untouched" {
    var geom = [_]NodeGeom{
        .{ .x = 2, .y = 5, .w = 7, .h = 3, .layer = 4 },
        .{ .x = 10, .y = 1, .w = 4, .h = 9, .layer = 0 },
    };
    mirror.applyDirection(NodeGeom, &geom, .LR);

    try testing.expectEqual(@as(i32, 5), geom[0].x);
    try testing.expectEqual(@as(i32, 2), geom[0].y);
    try testing.expectEqual(@as(u32, 3), geom[0].w);
    try testing.expectEqual(@as(u32, 7), geom[0].h);

    try testing.expectEqual(@as(u32, 4), geom[0].layer);
    try testing.expectEqual(@as(u32, 0), geom[1].layer);
}

test "vertical mirror preserves the bundle stamp state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 20, .h = 10 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .rails = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 20, .rung = 0 },
        .bundle_stamp_state = .rail_invariant,
    };
    const m = try mirror.vertical(a, s, .BT);
    try testing.expectEqual(sketch.Direction.BT, m.direction);
    try testing.expectEqual(sketch.BundleStampState.rail_invariant, m.bundle_stamp_state);
}

test "vertical mirror deeply mirrors RailClaim sites and preserves identity" {
    const nodes = [_]sketch.NodePlacement{
        .{ .id = 10, .rect = .{ .x = 2, .y = 1, .w = 7, .h = 5 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 20, .rect = .{ .x = 2, .y = 10, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 21, .rect = .{ .x = 12, .y = 10, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const members = [_]ledger.RailClaimMember{
        .{ .edge = 4, .endpoints = .{ 10, 20 }, .sites = .{ .{ .node = 10, .side = .east, .offset = 1 }, .{ .node = 20, .side = .north, .offset = 3 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
        .{ .edge = 5, .endpoints = .{ 10, 21 }, .sites = .{ .{ .node = 10, .side = .east, .offset = 1 }, .{ .node = 21, .side = .north, .offset = 3 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
    };
    const claims = [_]ledger.RailClaim{.{
        .id = 7,
        .polarity = .out,
        .members = &members,
    }};
    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 22, .h = 16 },
        .direction = .TD,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &.{},
        .rail_claims = &claims,
        .diagnostics = &.{},
        .budget = .{ .max_width = 40, .rung = 0 },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try mirror.vertical(arena.allocator(), s, .BT);
    const claim = out.rail_claims[0];

    try testing.expectEqual(@as(rail_star.RailClaimId, 7), claim.id);
    try testing.expectEqual(ledger.RailPolarity.out, claim.polarity);
    const checked = ledger.checkRailClaim(claim);
    try testing.expectEqual(@as(?ledger.NodeId, 10), checked.derived_pivot);
    try testing.expect(claim.members.ptr != claims[0].members.ptr);
    try testing.expectEqual(@as(ledger.EdgeId, 4), claim.members[0].edge);
    try testing.expectEqualDeep(members[0].endpoints, claim.members[0].endpoints);
    try testing.expectEqual(sketch.Dir4.east, checked.derived_pi.?.side);
    try testing.expectEqual(@as(u32, 3), checked.derived_pi.?.offset);
    try testing.expectEqual(sketch.Dir4.south, claim.members[0].sites[1].?.side);
    try testing.expect(checked.isValid());
}

test "vertical BT mirror remaps clustered bundle scopes without changing identity" {
    const flat_cells = [_]ledger.BundleCell{ .{ .x = 4, .y = 12 }, .{ .x = 4, .y = 13 } };
    const pair_12 = [_]ledger.BundleCell{.{ .x = 4, .y = 12 }};
    const pair_13 = [_]ledger.BundleCell{ .{ .x = 5, .y = 13 }, .{ .x = 5, .y = 14 } };
    const pairs = [_]ledger.PairCells{
        .{ .a = 1, .b = 2, .cells = &pair_12 },
        .{ .a = 1, .b = 3, .cells = &pair_13 },
    };
    const empty_cells = [_]ledger.BundleCell{};
    const empty_pairs = [_]ledger.PairCells{};
    const sets = [_]ledger.Bundle{
        .{ .origin = .fan_rail, .bundle = 3, .members = &.{ 20, 21 } },
        .{ .origin = .port_share, .bundle = 9, .members = &.{ 1, 2, 3 }, .cells = &flat_cells, .pairwise = &pairs },
        .{ .origin = .port_share, .bundle = 10, .members = &.{ 4, 5 } },
        .{ .origin = .port_share, .bundle = 11, .members = &.{ 6, 7 }, .cells = &empty_cells, .pairwise = &empty_pairs },
    };
    const clusters = [_]sketch.ClusterFrame{.{
        .id = 7,
        .rect = .{ .x = 2, .y = 11, .w = 12, .h = 5 },
        .parent_id = null,
        .label = "cluster",
        .depth = 0,
    }};
    const s: sketch.Sketch = .{
        .bbox = .{ .x = 2, .y = 10, .w = 20, .h = 12 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &clusters,
        .edges = &.{},
        .bundle_sets = &sets,
        .bundle_stamp_state = .complete,
        .diagnostics = &.{},
        .budget = .{ .max_width = 40, .rung = 0 },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try mirror.vertical(arena.allocator(), s, .BT);

    try testing.expectEqual(sketch.Direction.BT, out.direction);
    try testing.expectEqual(sketch.BundleStampState.complete, out.bundle_stamp_state);
    try testing.expectEqual(@as(i32, 16), out.clusters[0].rect.y);
    try testing.expectEqual(@as(usize, 4), out.bundle_sets.len);
    for (sets, out.bundle_sets) |before, after| {
        try testing.expectEqual(before.origin, after.origin);
        try testing.expectEqual(before.bundle, after.bundle);
        try testing.expect(before.members.ptr == after.members.ptr);
    }

    try testing.expectEqualDeep(sets[0], out.bundle_sets[0]);
    try testing.expect(out.bundle_sets[2].cells == null);
    try testing.expect(out.bundle_sets[2].pairwise == null);
    try testing.expect(out.bundle_sets[3].cells != null);
    try testing.expectEqual(@as(usize, 0), out.bundle_sets[3].cells.?.len);
    try testing.expect(out.bundle_sets[3].pairwise != null);
    try testing.expectEqual(@as(usize, 0), out.bundle_sets[3].pairwise.?.len);

    const scoped = out.bundle_sets[1];
    try testing.expectEqual(@as(i32, 19), scoped.cells.?[0].y);
    try testing.expectEqual(@as(i32, 18), scoped.cells.?[1].y);
    try testing.expectEqual(@as(ledger.EdgeId, 1), scoped.pairwise.?[0].a);
    try testing.expectEqual(@as(ledger.EdgeId, 2), scoped.pairwise.?[0].b);
    try testing.expectEqual(@as(i32, 19), scoped.pairwise.?[0].cells[0].y);
    try testing.expectEqual(@as(i32, 18), scoped.pairwise.?[1].cells[0].y);
    try testing.expectEqual(@as(i32, 17), scoped.pairwise.?[1].cells[1].y);

    try testing.expect(ledger.bundleMembersAt(s.bundle_sets, 1, 2, .{ .x = 4, .y = 12 }));
    try testing.expect(!ledger.bundleMembersAt(out.bundle_sets, 1, 2, .{ .x = 4, .y = 12 }));
    try testing.expect(ledger.bundleMembersAt(out.bundle_sets, 1, 2, .{ .x = 4, .y = 19 }));
}

test "vertical mirror fails rather than exposing partially mirrored scopes" {
    const flat = [_]ledger.BundleCell{.{ .x = 4, .y = 12 }};
    const pair_cells = [_]ledger.BundleCell{.{ .x = 4, .y = 12 }};
    const pairs = [_]ledger.PairCells{.{ .a = 1, .b = 2, .cells = &pair_cells }};
    const sets = [_]ledger.Bundle{.{
        .origin = .port_share,
        .bundle = 5,
        .members = &.{ 1, 2 },
        .cells = &flat,
        .pairwise = &pairs,
    }};
    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 10, .w = 10, .h = 12 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .bundle_sets = &sets,
        .bundle_stamp_state = .complete,
        .diagnostics = &.{},
        .budget = .{ .max_width = 20, .rung = 0 },
    };

    var saw_success = false;
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const a = failing.allocator();
        if (mirror.vertical(a, s, .BT)) |out| {
            try testing.expect(!failing.has_induced_failure);
            try testing.expectEqual(sketch.BundleStampState.complete, out.bundle_stamp_state);
            try testing.expectEqual(@as(i32, 19), out.bundle_sets[0].cells.?[0].y);
            a.free(out.bundle_sets[0].pairwise.?[0].cells);
            a.free(out.bundle_sets[0].pairwise.?);
            a.free(out.bundle_sets[0].cells.?);
            a.free(out.bundle_sets);
            try testing.expectEqual(failing.allocations, failing.deallocations);
            saw_success = true;
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            try testing.expectEqual(failing.allocations, failing.deallocations);
            try testing.expectEqual(sketch.BundleStampState.complete, s.bundle_stamp_state);
            try testing.expectEqual(@as(i32, 12), s.bundle_sets[0].cells.?[0].y);
        }
    }
    try testing.expect(saw_success);
}

const std = @import("std");
const ledger = @import("../base/ledger.zig");
const bundle_mod = @import("../base/bundle.zig");
const rail_star = @import("../base/rail_star.zig");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const mirror = @import("mirror.zig");
const node_geom = @import("node_geom.zig");
const sketch = @import("../sketch.zig");

const testing = std.testing;
const NodeGeom = node_geom.NodeGeom;

test "mirror.applyDirection swaps x/y/w/h but leaves NodeGeom.layer untouched" {
    var geom = [_]NodeGeom{
        .{ .x = 2, .y = 5, .w = 7, .h = 3, .layer = 4 },
        .{ .x = 10, .y = 1, .w = 4, .h = 9, .layer = 0 },
    };
    mirror.applyDirection(&geom, .LR);

    try testing.expectEqual(@as(i32, 5), geom[0].x);
    try testing.expectEqual(@as(i32, 2), geom[0].y);
    try testing.expectEqual(@as(u32, 3), geom[0].w);
    try testing.expectEqual(@as(u32, 7), geom[0].h);

    try testing.expectEqual(@as(u32, 4), geom[0].layer);
    try testing.expectEqual(@as(u32, 0), geom[1].layer);
}

test "vertical mirror deeply mirrors RailClaim sites and preserves identity" {
    const nodes = [_]sketch.NodePlacement{
        .{ .id = 10, .rect = .{ .x = 2, .y = 1, .w = 7, .h = 5 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 20, .rect = .{ .x = 2, .y = 10, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 21, .rect = .{ .x = 12, .y = 10, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const members = [_]rail_star.RailClaimMember{
        .{ .edge = 4, .endpoints = .{ 10, 20 }, .sites = .{ .{ .node = 10, .side = .east, .offset = 1 }, .{ .node = 20, .side = .north, .offset = 3 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
        .{ .edge = 5, .endpoints = .{ 10, 21 }, .sites = .{ .{ .node = 10, .side = .east, .offset = 1 }, .{ .node = 21, .side = .north, .offset = 3 } }, .arrows = .{ .none, .filled }, .kind = .solid, .pivot_end = .source },
    };
    const claims = [_]rail_star.RailClaim{.{
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
    try testing.expectEqual(rail_star.RailPolarity.out, claim.polarity);
    const checked = rail_star.check(claim);
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
    const flat_cells = [_]bundle_mod.BundleCell{ .{ .x = 4, .y = 12 }, .{ .x = 4, .y = 13 } };
    const pair_12 = [_]bundle_mod.BundleCell{.{ .x = 4, .y = 12 }};
    const pair_13 = [_]bundle_mod.BundleCell{ .{ .x = 5, .y = 13 }, .{ .x = 5, .y = 14 } };
    const pairs = [_]bundle_mod.PairCells{
        .{ .a = 1, .b = 2, .cells = &pair_12 },
        .{ .a = 1, .b = 3, .cells = &pair_13 },
    };
    const empty_cells = [_]bundle_mod.BundleCell{};
    const empty_pairs = [_]bundle_mod.PairCells{};
    const sets = [_]bundle_mod.Bundle{
        .{ .origin = .fan_rail, .members = &.{ 20, 21 } },
        .{ .origin = .port_share, .members = &.{ 1, 2, 3 }, .cells = &flat_cells, .pairwise = &pairs },
        .{ .origin = .port_share, .members = &.{ 4, 5 } },
        .{ .origin = .port_share, .members = &.{ 6, 7 }, .cells = &empty_cells, .pairwise = &empty_pairs },
    };
    const s: sketch.Sketch = .{
        .bbox = .{ .x = 2, .y = 10, .w = 20, .h = 12 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .bundle_sets = &sets,
        .diagnostics = &.{},
        .budget = .{ .max_width = 40, .rung = 0 },
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try mirror.vertical(arena.allocator(), s, .BT);

    try testing.expectEqual(sketch.Direction.BT, out.direction);
    try testing.expectEqual(@as(usize, 4), out.bundle_sets.len);
    for (sets, out.bundle_sets) |before, after| {
        try testing.expectEqual(before.origin, after.origin);
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

    try testing.expect(bundle_mod.bundleMembersAt(s.bundle_sets, 1, 2, .{ .x = 4, .y = 12 }));
    try testing.expect(!bundle_mod.bundleMembersAt(out.bundle_sets, 1, 2, .{ .x = 4, .y = 12 }));
    try testing.expect(bundle_mod.bundleMembersAt(out.bundle_sets, 1, 2, .{ .x = 4, .y = 19 }));
}

test "vertical mirror fails rather than exposing partially mirrored scopes" {
    const flat = [_]bundle_mod.BundleCell{.{ .x = 4, .y = 12 }};
    const pair_cells = [_]bundle_mod.BundleCell{.{ .x = 4, .y = 12 }};
    const pairs = [_]bundle_mod.PairCells{.{ .a = 1, .b = 2, .cells = &pair_cells }};
    const sets = [_]bundle_mod.Bundle{.{
        .origin = .port_share,
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
            try testing.expectEqual(@as(i32, 12), s.bundle_sets[0].cells.?[0].y);
        }
    }
    try testing.expect(saw_success);
}

test "vertical mirror flips y geometry and ports" {
    const nodes = [_]sketch.NodePlacement{
        .{ .id = 1, .rect = .{ .x = 2, .y = 1, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 2, .y = 6, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const poly = [_]sketch.Point{ .{ .x = 4, .y = 3 }, .{ .x = 4, .y = 5 } };
    const edges = [_]sketch.EdgePath{
        .{
            .id = 1,
            .from = 1,
            .to = 2,
            .polyline = &poly,
            .port_from = .{ .node = 1, .side = .south, .offset = 2 },
            .port_to = .{ .node = 2, .side = .west, .offset = 0 },
            .arrow_from = .none,
            .arrow_to = .filled,
            .label = null,
            .kind = .solid,
        },
    };
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 9, .h = 10 },
        .direction = .TD,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try mirror.vertical(arena.allocator(), s, .BT);

    try std.testing.expectEqual(sketch.Direction.BT, out.direction);
    try std.testing.expectEqual(@as(i32, 6), out.nodes[0].rect.y);
    try std.testing.expectEqual(@as(i32, 1), out.nodes[1].rect.y);
    try std.testing.expectEqual(@as(i32, 6), out.edges[0].polyline[0].y);
    try std.testing.expectEqual(@as(i32, 4), out.edges[0].polyline[1].y);
    try std.testing.expectEqual(sketch.Dir4.north, out.edges[0].port_from.side);
    try std.testing.expectEqual(sketch.Dir4.west, out.edges[0].port_to.side);
    try std.testing.expectEqual(@as(u32, 2), out.edges[0].port_to.offset);
}

test "vertical mirror preserves rail tap x-order; only the rail row shifts" {
    const nodes = [_]sketch.NodePlacement{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 0, .y = 8, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"L"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 20, .y = 8, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"R"}, .cluster_id = null },
    };
    const stem = [_]sketch.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 5 } };
    const taps = [_]sketch.Tap{
        .{ .edge = 1, .node = 2, .at = .{ .x = 2, .y = 5 }, .landing = .{ .x = 2, .y = 8 } },
        .{ .edge = 2, .node = 3, .at = .{ .x = 22, .y = 5 }, .landing = .{ .x = 22, .y = 8 } },
    };
    const rails = [_]sketch.Rail{
        .{ .pivot = 1, .stem = &stem, .crossbar = .{ .{ .x = 2, .y = 5 }, .{ .x = 22, .y = 5 } }, .taps = &taps, .kind = .solid },
    };
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 12 },
        .direction = .TD,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &.{},
        .rails = &rails,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try mirror.vertical(arena.allocator(), s, .BT);

    try std.testing.expectEqual(taps[0].at.x, out.rails[0].taps[0].at.x);
    try std.testing.expectEqual(taps[1].at.x, out.rails[0].taps[1].at.x);
    try std.testing.expectEqual(taps[0].landing.x, out.rails[0].taps[0].landing.x);
    try std.testing.expectEqual(taps[1].landing.x, out.rails[0].taps[1].landing.x);

    try std.testing.expect(out.rails[0].crossbar[0].x <= out.rails[0].crossbar[1].x);
    try std.testing.expectEqual(out.rails[0].crossbar[0].y, out.rails[0].crossbar[1].y);
    try std.testing.expect(out.rails[0].crossbar[0].y != rails[0].crossbar[0].y);
}

test "RL: sugiyama's own layer reversal plus applyDirection's axis swap alone yields correct right-to-left order" {
    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const g = sg.SemGraph{
        .direction = .RL,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(std.testing.allocator, g);
    defer lg.deinit(std.testing.allocator);

    var geom = try std.testing.allocator.alloc(NodeGeom, lg.nodes.len);
    defer std.testing.allocator.free(geom);
    for (lg.layers, 0..) |row, li| {
        for (row) |idx| geom[idx] = .{ .x = 0, .y = @as(i32, @intCast(li)) * 10, .w = 6, .h = 3, .layer = @intCast(li) };
    }

    mirror.applyDirection(geom, .RL);

    const idx_a = lg.real_index.get(0).?;
    const idx_c = lg.real_index.get(2).?;
    try std.testing.expect(geom[idx_a].x > geom[idx_c].x);
}

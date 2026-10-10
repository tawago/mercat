const std = @import("std");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const sketch_mod = @import("sketch.zig");
const ladder = @import("budget.zig");
const select = @import("select.zig");
const permits_mod = @import("ledger/permits.zig");
const raster = @import("raster.zig");
const score_mod = @import("score.zig");
const parse = @import("parse.zig").parse;

const test_bundle_permits: ledger.BundlePermits = .{ .policy = .joined };

fn testBundlePermits() *const ledger.BundlePermits {
    return &test_bundle_permits;
}

test "truncate cannot win while natural fits cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  A --> B\n  B --> C\n");
    const candidates = try ladder.enumerate(a, g, testBundlePermits(), 80);
    const natural = candidates[@intFromEnum(ladder.Rung.natural)];
    const truncate = candidates[@intFromEnum(ladder.Rung.truncate)];
    const ns = try score_mod.eval(a, natural.sketch, g.direction, 0, try select.audit(a, natural.sketch, .bridge));
    const ts = try score_mod.eval(a, truncate.sketch, g.direction, 4, try select.audit(a, truncate.sketch, .bridge));
    try std.testing.expectEqual(@as(u32, 0), ns.t0_fit);
    try std.testing.expectEqual(@as(u32, 0), ns.t1_integrity);
    try std.testing.expect(ts.lessThan(ns));

    const winner = candidates[try select.argmin(a, candidates, g.direction, .bridge)];
    try std.testing.expect(winner.rung != .truncate);
}

test "packed candidates: a TD parallel graph yields clustered motif_pack candidates; LR yields none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  A --> B1 --> C1
        \\  A --> B2 --> C2
        \\
    );
    const packed_cands = try select.packedCandidates(a, g, testBundlePermits(), 80);
    try std.testing.expect(packed_cands.len != 0);
    for (packed_cands) |cand| {
        try std.testing.expectEqual(ladder.Transform.motif_pack, cand.transform);
        try std.testing.expect(cand.sketch.clusters.len != 0);
    }

    const g_lr = try parse(a, "flowchart LR\n  A --> B1 --> C1\n  A --> B2 --> C2\n");
    try std.testing.expectEqual(@as(usize, 0), (try select.packedCandidates(a, g_lr, testBundlePermits(), 80)).len);
}

test "a clustered render's rail bundles come from its piece plan and survive the stitch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  subgraph S
        \\    A --> B
        \\    A --> C
        \\    A --> D
        \\  end
        \\  B --> Z
        \\
    );
    const permits = (try permits_mod.build(a, g, .joined)).plan;
    const winner = try select.choose(a, g, &permits, 120, .bridge);

    try std.testing.expectEqual(@as(usize, 1), winner.cand.sketch.sharing.realized.selected_bundles.len);
    const rail = winner.cand.sketch.sharing.realized.selected_bundles[0];
    try std.testing.expectEqual(@as(usize, 3), rail.members.len);
    try std.testing.expect(winner.cand.sketch.sharing.bundles.len > 0);
    for (winner.cand.sketch.sharing.bundles) |set| {
        try std.testing.expect(set.origin == .selected_bundle or set.origin == .port_share);
        try std.testing.expect(set.members.len >= 2);
    }
    var plan_sets: usize = 0;
    for (winner.cand.sketch.sharing.bundles) |set| {
        if (set.origin != .selected_bundle) continue;
        plan_sets += 1;
        try std.testing.expectEqualSlices(ledger.EdgeId, rail.members, set.members);
    }
    try std.testing.expectEqual(@as(usize, 1), plan_sets);
}

fn permitsFor(a: std.mem.Allocator, g: sem_graph.SemGraph) !ledger.BundlePermits {
    var plan = (try permits_mod.build(a, g, .joined)).plan;
    plan.scope = .skipped_clustered;
    return plan;
}

test "the audit prices the raster that ships: the subgraph-edge mode changes the counts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  subgraph S1
        \\    A --> B
        \\  end
        \\  subgraph S2
        \\    C --> D
        \\  end
        \\  A --> D
        \\  C --> B
        \\
    );
    const permits = try permitsFor(a, g);
    const winner = try select.choose(a, g, &permits, 90, .cross);

    const shipped = winner.report;
    const priced = try select.audit(a, winner.cand.sketch, .cross);
    const redrawn = try raster.rasterize(a, winner.cand.sketch, .cross);
    try std.testing.expectEqualDeep(redrawn.lattice.cells, shipped.lattice.cells);
    try std.testing.expectEqual(shipped.arrow_base.violations, priced.arrow_base);
    try std.testing.expectEqual(shipped.crossings.foreign_junction_violation, priced.foreign_junction);
    try std.testing.expectEqual(shipped.crossings.arrowhead_transit_violation, priced.arrowhead_transit);
    try std.testing.expectEqual(shipped.edge_cells_lost, priced.edge_cells_lost);

    const counterfactual = try select.audit(a, winner.cand.sketch, .bridge);
    try std.testing.expect(counterfactual.arrow_base != priced.arrow_base);
}

fn bridgePinSketch(cross_x: i32, polys: *[2][2]sketch_mod.Point, nodes: *[2]sketch_mod.NodePlacement, edges: *[2]sketch_mod.EdgePath) sketch_mod.Sketch {
    nodes.* = .{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 8, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    polys.* = .{
        .{ .{ .x = 4, .y = 1 }, .{ .x = 8, .y = 1 } },
        .{ .{ .x = cross_x, .y = 5 }, .{ .x = cross_x, .y = 0 } },
    };
    edges.* = .{
        .{
            .id = 0,
            .from = 1,
            .to = 2,
            .polyline = polys[0][0..],
            .port_from = .{ .node = 1, .side = .east, .offset = 1 },
            .port_to = .{ .node = 2, .side = .west, .offset = 1 },
            .arrow_from = .none,
            .arrow_to = .filled,
            .label = null,
            .kind = .solid,
        },
        .{
            .id = 1,
            .from = 3,
            .to = 4,
            .polyline = polys[1][0..],
            .port_from = .{ .node = 3, .side = .north, .offset = 0 },
            .port_to = .{ .node = 4, .side = .south, .offset = 0 },
            .arrow_from = .none,
            .arrow_to = .none,
            .label = null,
            .kind = .solid,
        },
    };
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 13, .h = 6 },
        .direction = .TD,
        .nodes = nodes[0..],
        .clusters = &.{},
        .edges = edges[0..],
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

test "bridge variants: the real-raster score decides, and flips when the counts flip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var polys_clean: [2][2]sketch_mod.Point = undefined;
    var nodes_clean: [2]sketch_mod.NodePlacement = undefined;
    var edges_clean: [2]sketch_mod.EdgePath = undefined;
    const clean = bridgePinSketch(6, &polys_clean, &nodes_clean, &edges_clean);
    var polys_bad: [2][2]sketch_mod.Point = undefined;
    var nodes_bad: [2]sketch_mod.NodePlacement = undefined;
    var edges_bad: [2]sketch_mod.EdgePath = undefined;
    const bad = bridgePinSketch(7, &polys_bad, &nodes_bad, &edges_bad);

    const c_clean = try select.audit(a, clean, .bridge);
    const c_bad = try select.audit(a, bad, .bridge);
    try std.testing.expectEqual(@as(u32, 0), c_clean.arrowhead_transit);
    try std.testing.expect(c_bad.arrowhead_transit > 0);

    const cands_a = [_]ladder.Candidate{
        .{ .rung = .natural, .sketch = clean, .transform = .raw },
        .{ .rung = .natural, .sketch = bad, .transform = .bridge_dodged },
    };
    try std.testing.expectEqual(@as(usize, 0), try select.argmin(a, &cands_a, .TD, .bridge));

    const cands_b = [_]ladder.Candidate{
        .{ .rung = .natural, .sketch = bad, .transform = .raw },
        .{ .rung = .natural, .sketch = clean, .transform = .bridge_dodged },
    };
    try std.testing.expectEqual(@as(usize, 1), try select.argmin(a, &cands_b, .TD, .bridge));
    _ = score_mod.W_ARROWHEAD_TRANSIT;
}

test "bridge variants: a clustered graph enumerates dodged/railed twins behind the raw set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flat = try parse(a, "flowchart TD\n  A --> B\n  A --> C\n");
    const flat_permits = try permitsFor(a, flat);
    const flat_set = try select.enumerateAll(a, flat, &flat_permits, 120);
    for (flat_set) |c| {
        try std.testing.expect(c.transform != .bridge_dodged and c.transform != .bridge_railed);
    }

    const clustered = try parse(a,
        \\flowchart TD
        \\  subgraph S1
        \\    A --> B
        \\  end
        \\  subgraph S2
        \\    C --> D
        \\  end
        \\  A --> C
        \\  A --> D
        \\  B --> D
    );
    const permits = try permitsFor(a, clustered);
    const set = try select.enumerateAll(a, clustered, &permits, 120);
    var last_raw: usize = 0;
    var first_bridge: usize = set.len;
    for (set, 0..) |c, i| {
        switch (c.transform) {
            .raw => last_raw = i,
            .bridge_dodged, .bridge_railed => {
                first_bridge = @min(first_bridge, i);
                for (set) |base| {
                    if (base.transform != .raw or base.rung != c.rung) continue;
                    var same = base.sketch.edges.len == c.sketch.edges.len;
                    if (same) for (base.sketch.edges, c.sketch.edges) |ea, eb| {
                        if (ea.polyline.len != eb.polyline.len) same = false;
                    };
                    try std.testing.expect(!same or blk: {
                        var differs = false;
                        for (base.sketch.edges, c.sketch.edges) |ea, eb| {
                            for (ea.polyline, eb.polyline) |pa, pb| {
                                if (pa.x != pb.x or pa.y != pb.y) differs = true;
                            }
                        }
                        break :blk differs;
                    });
                }
            },
            else => {},
        }
    }
    try std.testing.expect(first_bridge > last_raw);
}

fn unroute(a: std.mem.Allocator, s: sketch_mod.Sketch, edge: usize) !sketch_mod.Sketch {
    var out = s;
    const edges = try a.dupe(sketch_mod.EdgePath, s.edges);
    edges[edge].polyline = &.{};
    out.edges = edges;
    return out;
}

fn clip(s: sketch_mod.Sketch) sketch_mod.Sketch {
    var out = s;
    out.budget.max_width = s.bbox.w - 1;
    return out;
}

test "a clipped candidate that routes everything beats a fitting one with an unrouted edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parse(a, "flowchart TD\n  A --> B\n  B --> C\n");
    const set = try select.enumerateAll(a, g, testBundlePermits(), 120);
    const natural = set[@intFromEnum(ladder.Rung.natural)];

    const cands = [_]ladder.Candidate{
        .{ .rung = .natural, .sketch = clip(natural.sketch), .transform = .raw },
        .{ .rung = .tight, .sketch = try unroute(a, natural.sketch, 0), .transform = .raw },
    };
    const clipped = (try select.evaluate(a, cands[0].sketch, .TD, 0, .bridge)).score;
    const omitting = (try select.evaluate(a, cands[1].sketch, .TD, 1, .bridge)).score;
    try std.testing.expect(clipped.t0_fit > 0);
    try std.testing.expectEqual(@as(u32, 1), omitting.t_omit.relations);
    try std.testing.expectEqual(@as(usize, 0), try select.chooseIndex(a, &cands, .TD, .bridge));
}

test "fewer omitted labels beat a lower composite, and an unrouted relation outranks labels" {
    const keeping: score_mod.Score = .{ .t0_fit = 0, .t1_integrity = 0, .t2_legibility = 0, .t3_height = 0, .t4_index = 1, .t12_composite = 1_000_000 };
    var dropping = keeping;
    dropping.t4_index = 0;
    dropping.t12_composite = 0;
    dropping.t_omit.labels = 1;
    try std.testing.expect(keeping.lessThan(dropping));
    try std.testing.expect(score_mod.displacesNatural(keeping, dropping));

    var unrouting = keeping;
    unrouting.t_omit.relations = 1;
    var labelless = keeping;
    labelless.t_omit.labels = 5;
    try std.testing.expect(labelless.lessThan(unrouting));

    var clipped = keeping;
    clipped.t0_fit = 1;
    try std.testing.expect(clipped.lessThan(unrouting));
    try std.testing.expect(labelless.lessThan(clipped));
}

test "the natural margin never keeps natural over a candidate with fewer omissions" {
    const natural: score_mod.Score = .{ .t0_fit = 0, .t_omit = .{ .labels = 1 }, .t1_integrity = 0, .t2_legibility = 0, .t3_height = 0, .t4_index = 0, .t12_composite = 1000 };
    var close = natural;
    close.t4_index = 1;
    close.t_omit = .{};
    close.t12_composite = natural.t12_composite + score_mod.NATURAL_PREFERENCE_MARGIN * 4;
    try std.testing.expect(score_mod.displacesNatural(close, natural));
    close.t12_composite = natural.t12_composite - 1;
    try std.testing.expect(score_mod.displacesNatural(close, natural));
}

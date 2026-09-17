//! select_test.zig — tests for select.zig, split out of the module under
//! the Step 4 cap watch (plan N3: keep select.zig's call sites thin and
//! its line count clear of the 500-line cap). Aggregated into the test
//! build from entry.zig's `test {}` block.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! sem_graph, sketch, budget, parse, select, select_filter, permits, audit,
//! raster, score.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const sketch_mod = @import("sketch.zig");
const ladder = @import("budget.zig");
const select = @import("select.zig");
const select_filter = @import("select_filter.zig");
const permits_mod = @import("ledger/permits.zig");
const audit = @import("audit.zig");
const raster = @import("raster.zig");
const score_mod = @import("score.zig");
const parse = @import("parse.zig").parse;

const PACK_RUNGS = ladder.Transform.motif_pack.rungs();

const test_bundle_permits: ledger.BundlePermits = .{ .policy = .joined };

fn testBundlePermits() *const ledger.BundlePermits {
    return &test_bundle_permits;
}

test "truncate rung is ineligible when natural fits cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a, "flowchart TD\n  A --> B\n  B --> C\n");
    const enumerated = try ladder.enumerate(a, g, testBundlePermits(), 80);
    const sel = select.scoreCandidates(a, enumerated.candidates, enumerated.incumbent.final_rung, g.direction, .bridge) orelse
        return error.ScoringFailed;

    var natural_idx: ?usize = null;
    var truncate_idx: ?usize = null;
    for (enumerated.candidates, 0..) |cand, i| {
        if (cand.rung == .natural) natural_idx = i;
        if (cand.rung == .truncate) truncate_idx = i;
    }
    const ns = sel.scores[natural_idx.?];
    const ts = sel.scores[truncate_idx.?];

    try std.testing.expectEqual(@as(u32, 0), ns.t0_fit);
    try std.testing.expectEqual(@as(u32, 0), ns.t1_integrity);
    try std.testing.expect(ts.lessThan(ns));

    try std.testing.expect(enumerated.candidates[sel.argmin_idx].rung != .truncate);
}

test "packed candidates: TD parallel graph yields motif_pack candidates at capped rungs" {
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
    try std.testing.expectEqual(@as(usize, PACK_RUNGS.len), packed_cands.len);
    for (packed_cands, PACK_RUNGS) |cand, rung| {
        try std.testing.expectEqual(ladder.Transform.motif_pack, cand.transform);
        try std.testing.expectEqual(rung, cand.rung);
        try std.testing.expect(!cand.accepted);
        try std.testing.expect(cand.sketch.clusters.len != 0);
    }

    const g_lr = try parse(a, "flowchart LR\n  A --> B1 --> C1\n  A --> B2 --> C2\n");
    try std.testing.expectEqual(@as(usize, 0), (try select.packedCandidates(a, g_lr, testBundlePermits(), 80)).len);
}

test "choose: merged selection anchors to raw natural and never fails the render" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = try parse(a,
        \\flowchart TD
        \\  A --> B1 --> C1
        \\  A --> B2 --> C2
        \\
    );
    const result = try select.choose(a, g, testBundlePermits(), 120, false, false, .bridge);
    try std.testing.expect(result.sketch.bbox.w > 0);

    const incumbent = (try ladder.enumerate(a, g, testBundlePermits(), 120)).incumbent;
    const off = try select.choose(a, g, testBundlePermits(), 120, true, false, .bridge);
    try std.testing.expectEqual(incumbent.final_rung, off.final_rung);
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
    const winner = try select.choose(a, g, &permits, 120, false, false, .bridge);

    try std.testing.expectEqual(@as(usize, 1), winner.sketch.bundles.selected_bundles.len);
    const rail = winner.sketch.bundles.selected_bundles[0];
    try std.testing.expectEqual(@as(usize, 3), rail.members.len);
    try std.testing.expect(winner.sketch.bundle_sets.len > 0);
    for (winner.sketch.bundle_sets) |set| {
        try std.testing.expect(set.origin == .selected_bundle or set.origin == .port_share);
        try std.testing.expect(set.members.len >= 2);
    }
    const plan_sets = try ledger.keepOrigin(a, winner.sketch.bundle_sets, .selected_bundle);
    try std.testing.expectEqual(@as(usize, 1), plan_sets.len);
    try std.testing.expectEqualSlices(ledger.EdgeId, rail.members, plan_sets[0].members);
}

/// The root plan of a graph marked clustered-skipped: the candidates enumerate
/// with every fan detected and no rail committed, so the tests below read the
/// enumeration order and the scorer's choice with no plan in the way.
fn permitsFor(a: std.mem.Allocator, g: sem_graph.SemGraph) !ledger.BundlePermits {
    var plan = (try permits_mod.build(a, g, .joined)).plan;
    plan.scope = .skipped_clustered;
    return plan;
}

test "the audit prices the raster that ships: mode reaches collect and changes the counts" {
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
    const winner = try select.choose(a, g, &permits, 90, false, false, .cross);

    const shipped = try raster.rasterize(a, winner.sketch, .cross);
    const priced = audit.collect(a, winner.sketch, .cross) orelse return error.RasterFailed;
    try std.testing.expectEqual(shipped.arrow_base.violations, priced.arrow_base);
    try std.testing.expectEqual(shipped.crossings.foreign_junction_violation, priced.foreign_junction);
    try std.testing.expectEqual(shipped.crossings.arrowhead_transit_violation, priced.arrowhead_transit);
    try std.testing.expectEqual(shipped.edge_cells_lost, priced.edge_cells_lost);

    const counterfactual = audit.collect(a, winner.sketch, .bridge) orelse return error.RasterFailed;
    try std.testing.expect(counterfactual.arrow_base != priced.arrow_base);
}

/// Two-node fixture whose second edge either transits the first edge's
/// arrowhead cell (x = 7 — a raster violation the sketch-side proxy could
/// not classify) or crosses its plain run legally (x = 6).
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

    const c_clean = audit.collect(a, clean, .bridge) orelse return error.RasterFailed;
    const c_bad = audit.collect(a, bad, .bridge) orelse return error.RasterFailed;
    try std.testing.expectEqual(@as(u32, 0), c_clean.arrowhead_transit);
    try std.testing.expect(c_bad.arrowhead_transit > 0);

    const cands_a = [_]ladder.Candidate{
        .{ .rung = .natural, .sketch = clean, .accepted = true, .transform = .raw },
        .{ .rung = .natural, .sketch = bad, .accepted = false, .transform = .bridge_dodged },
    };
    const sel_a = select.scoreCandidates(a, &cands_a, .natural, .TD, .bridge) orelse return error.ScoreFailed;
    try std.testing.expectEqual(@as(usize, 0), sel_a.argmin_idx);

    const cands_b = [_]ladder.Candidate{
        .{ .rung = .natural, .sketch = bad, .accepted = true, .transform = .raw },
        .{ .rung = .natural, .sketch = clean, .accepted = false, .transform = .bridge_dodged },
    };
    const sel_b = select.scoreCandidates(a, &cands_b, .natural, .TD, .bridge) orelse return error.ScoreFailed;
    try std.testing.expectEqual(@as(usize, 1), sel_b.argmin_idx);
    _ = score_mod.W_ARROWHEAD_TRANSIT;
}

test "bridge variants: a clustered graph enumerates dodged/railed twins behind the raw set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const flat = try parse(a, "flowchart TD\n  A --> B\n  A --> C\n");
    const flat_permits = try permitsFor(a, flat);
    const flat_set = try select.enumerateAll(a, flat, &flat_permits, 120);
    for (flat_set.merged) |c| {
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
    var first_bridge: usize = set.merged.len;
    for (set.merged, 0..) |c, i| {
        switch (c.transform) {
            .raw => last_raw = i,
            .bridge_dodged, .bridge_railed => {
                first_bridge = @min(first_bridge, i);
                for (set.merged) |base| {
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

test "a candidate with an unrouted visible edge is filtered out before scoring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parse(a, "flowchart TD\n  A --> B\n  B --> C\n");
    const set = try select.enumerateAll(a, g, testBundlePermits(), 120);
    try std.testing.expect(set.merged.len >= 2);
    // Every enumerated candidate drew both edges: the filter is the identity.
    for (set.merged) |cand| try std.testing.expectEqual(@as(u32, 0), select_filter.unroutedEdges(cand.sketch));
    try std.testing.expectEqual(set.merged.len, select_filter.ciFilter(a, set.merged).len);

    // Blank one candidate's first polyline: that candidate alone is excluded,
    // whatever its rung; the others keep their order.
    const forged = try a.dupe(ladder.Candidate, set.merged);
    const edges = try a.dupe(@TypeOf(forged[1].sketch.edges[0]), forged[1].sketch.edges);
    edges[0].polyline = &.{};
    forged[1].sketch.edges = edges;
    try std.testing.expectEqual(@as(u32, 1), select_filter.unroutedEdges(forged[1].sketch));
    const survivors = select_filter.ciFilter(a, forged);
    try std.testing.expectEqual(forged.len - 1, survivors.len);
    try std.testing.expectEqual(forged[0].rung, survivors[0].rung);
    for (survivors) |cand| try std.testing.expect(cand.rung != forged[1].rung);
}

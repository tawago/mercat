//! select_test.zig — tests for select.zig, split out of the module under
//! the Step 4 cap watch (plan N3: keep select.zig's call sites thin and
//! its line count clear of the 500-line cap). Aggregated into the test
//! build from entry.zig's `test {}` block.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! budget, parse, select, select_filter, permits.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const ladder = @import("budget.zig");
const select = @import("select.zig");
const select_filter = @import("select_filter.zig");
const permits_mod = @import("ledger/permits.zig");
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

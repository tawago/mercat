//! Root-level cross-instrument pin for the JUNCTION LICENCE, against REAL
//! renders: parse -> permits -> select -> rasterize -> scan.
//!
//! WHY THIS EXISTS. `tiling/strokes.zig`'s fusion pair check used to file
//! EVERY junction-adjacent id difference as a convention, on the ground
//! that "the runs genuinely meet there". That ground holds only where the
//! two edges legally share a bundle at the junction; where they do not,
//! the glyph asserts an adjacency no source declares. Splitting the two
//! needs the licence, which the raster records on each `.carrier` and the
//! tiling zone reads back. Neither side may import the other, so the two
//! meet only here — the same arrangement, and the same lint-row grant, as
//! `tiling_records_test.zig`, which is full to its cap.
//!
//! The three verdicts partition the parent population exactly, so every
//! render is its own consistency check; the shapes below add the two
//! outcomes a partition identity alone cannot distinguish.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const scan = @import("tiling/scan.zig");
const counts = @import("tiling/counts.zig");

const testing = std.testing;

/// The production path with the side table collected, exactly as the
/// composition root drives it.
fn renderCounts(a: std.mem.Allocator, source: []const u8, width: u32) !counts.Counts {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    return scan.run(a, .{
        .graph = graph,
        .sketch = winner.sketch,
        .lat = &report.lattice,
        .mode = .bridge,
        .labels_placed = report.labels_placed,
        .labels_dropped = report.labels_dropped,
        .labels_displaced = report.labels_displaced,
        .edge_cells_lost = report.edge_cells_lost,
    });
}

/// A rendered witness for pair-specific scope after clustered bridge
/// reconstruction. The final sketch has three edges sharing the port at
/// (25,46). Two pairs share only (25,45)..(25,40); the third pair shares the
/// longer approach through (25,16). One port gives the group one identity,
/// but it does not let either short pair borrow the long pair's cells.
const three_way_port_share =
    \\flowchart TB
    \\  subgraph S1[Group One]
    \\    A
    \\    B
    \\  end
    \\  C ==>|lab9| E
    \\  F -.->|lab3| E
    \\  F --> D
    \\  F ==> A
    \\  F -.-> C
    \\  C -.-> B
    \\  B -->|lab1| C
    \\  E ==>|lab6| F
    \\  F -->|lab4| D
    \\  B -.-> E
    \\  D --> C
    \\  D --> A
    \\  D --> F
    \\
;

/// A plain chain and a plain fan: nothing meets anything foreign, so the
/// junction population is empty and every verdict must be empty with it.
const quiet = [_][]const u8{
    "flowchart TD\n  A --> B\n  B --> C\n",
    "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n",
};

fn expectReconstructedThreeWayPortShare() !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try renderCounts(a, three_way_port_share, 140);
    // The invalid duplicate no longer contributes a junction. All three
    // remaining junction events are licensed; the three-way port bundle below still has
    // exact scope for all three member pairs. The exact
    // partition prevents the stale port-wide union from reintroducing the
    // former eight extra junction readings or hiding one in another verdict.
    try testing.expectEqual(@as(u32, 3), c.c_run_fused_crossing);
    try testing.expectEqual(@as(u32, 3), c.c_run_fused_licensed);
    try testing.expectEqual(@as(u32, 0), c.d_run_fused_foreign);
    try testing.expectEqual(@as(u32, 0), c.u_run_fused_unevidenced);
    try testing.expectEqual(
        c.c_run_fused_crossing,
        c.c_run_fused_licensed + c.d_run_fused_foreign + c.u_run_fused_unevidenced,
    );

    const graph = try parse(a, three_way_port_share);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, 140, false, false, .bridge);

    var found: ?ledger.Bundle = null;
    for (winner.sketch.bundle_sets) |set| {
        if (set.origin != .port_share) continue;
        if (!std.mem.eql(ledger.EdgeId, set.members, &.{ 14, 15, 16 })) continue;
        found = set;
        break;
    }
    const share = found orelse return error.MissingThreeWayPortShare;
    const cells = share.cells orelse return error.MissingPortShareScope;
    const pairs = share.pairwise orelse return error.MissingPairScopes;


    // The flat field is the exact union, retained as the set's narrowness
    // marker. Licensing reads the three entries below instead.
    // (Geometry re-pinned when bridge-build variants became scored
    // candidates: the winner is now the bridge_dodged twin — one fewer
    // displaced label — whose shared descent runs one cell longer.)
    try testing.expectEqual(@as(usize, 36), cells.len);
    for (cells, 0..) |cell, i| {
        try testing.expectEqual(@as(i32, 38), cell.x);
        try testing.expectEqual(50 - @as(i32, @intCast(i)), cell.y);
    }

    const expected = [_]struct {
        a: ledger.EdgeId,
        b: ledger.EdgeId,
        last_y: i32,
    }{
        .{ .a = 14, .b = 15, .last_y = 45 },
        .{ .a = 14, .b = 16, .last_y = 45 },
        .{ .a = 15, .b = 16, .last_y = 15 },
    };
    try testing.expectEqual(expected.len, pairs.len);
    for (pairs, expected) |pair, want| {
        try testing.expectEqual(want.a, pair.a);
        try testing.expectEqual(want.b, pair.b);
        try testing.expectEqual(@as(usize, @intCast(50 - want.last_y + 1)), pair.cells.len);
        for (pair.cells, 0..) |cell, i| {
            try testing.expectEqual(@as(i32, 38), cell.x);
            try testing.expectEqual(50 - @as(i32, @intCast(i)), cell.y);
        }
    }

    const only_share = [_]ledger.Bundle{share};
    const long_pair_only: ledger.BundleCell = .{ .x = 38, .y = 16 };
    try testing.expect(ledger.bundleMembersAt(&only_share, 15, 16, long_pair_only));
    try testing.expect(!ledger.bundleMembersAt(&only_share, 14, 15, long_pair_only));
    try testing.expect(!ledger.bundleMembersAt(&only_share, 14, 16, long_pair_only));

    try testing.expectEqual(@as(u32, 0), c.d_run_fused_collinear);
    try testing.expectEqual(@as(u32, 0), c.d_rail_star_violation);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "licence: a reconstructed three-way port share keeps exact pair scopes and partitions junction verdicts" {
    try expectReconstructedThreeWayPortShare();
}

// Historical guarded-by anchor in lattice.zig. It runs the current exact-scope
// contract rather than preserving the port-wide union interpretation.
test "licence: a three-way port share the pairwise flood missed is now licensed, and the render files no defect" {
    try expectReconstructedThreeWayPortShare();
}

test "licence: the three verdicts partition the junction population on every render" {
    // The parent bucket is kept whole precisely so this identity exists.
    // A verdict that silently swallowed a case — or a fourth path added
    // later without a bucket — breaks it here rather than in the field.
    const corpus = [_][]const u8{
        three_way_port_share,
        quiet[0],
        quiet[1],
        "flowchart TD\n  A --> D\n  B --> D\n  C --> D\n",
        "flowchart TD\n  subgraph S1\n    A --> B\n  end\n  subgraph S2\n    C --> D\n  end\n  A --> D\n  C --> B\n",
        "flowchart TD\n  A[Start] --> B{Check}\n  B -->|yes| C[Run]\n  B -->|no| D[Stop]\n  C --> E[Done]\n  D --> E\n",
    };
    for (corpus) |source| for ([3]u32{ 60, 100, 140 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try renderCounts(arena.allocator(), source, w);
        try testing.expectEqual(
            c.c_run_fused_crossing,
            c.c_run_fused_licensed + c.d_run_fused_foreign + c.u_run_fused_unevidenced,
        );
    };
}

test "licence: a shape with no foreign meeting reports no foreign junction" {
    // The complement of the witness. A defect bucket that fired on honest
    // ink would be worse than useless, so the quiet side is pinned too.
    for (quiet) |source| for ([2]u32{ 60, 120 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try renderCounts(arena.allocator(), source, w);
        try testing.expectEqual(@as(u32, 0), c.d_run_fused_foreign);
        try testing.expectEqual(@as(u32, 0), c.defectTotal());
    };
}

test "licence: a render that DOES merge, honestly, reports licensed and no defect" {
    // THE FALSE-DEFECT DIRECTION. The complement test above uses a chain
    // and a plain fan — neither ever merges, so neither can catch a licence
    // that got flipped the wrong way: a producer filing `.merged_foreign`
    // where the crossing rule actually said yes would leave those shapes at
    // zero and still invent a defect on every real diagram.
    //
    // This shape closes that. Two fans overlap enough to put a genuine
    // junction on the grid and drive a real merge through it, and every one
    // of those merges IS licensed — so `c_run_fused_licensed` must be the
    // whole population here. Pinning it as an exact count rather than
    // `> 0` means the defect bucket cannot borrow from it unnoticed.
    const merges_honestly = "flowchart TD\n  A --> C\n  A --> D\n  B --> C\n  B --> E\n";
    for ([3]u32{ 60, 100, 140 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try renderCounts(arena.allocator(), merges_honestly, w);

        try testing.expectEqual(@as(u32, 1), c.c_run_fused_crossing);
        try testing.expectEqual(@as(u32, 1), c.c_run_fused_licensed);
        try testing.expectEqual(@as(u32, 0), c.d_run_fused_foreign);
        try testing.expectEqual(@as(u32, 0), c.u_run_fused_unevidenced);
        try testing.expectEqual(@as(u32, 0), c.defectTotal());
    }
}

test "licence: the two-rail K(2,2) is the smallest render that fabricates" {
    // Once THE SIZING CASE: two separated rails whose crossbars OR-merged
    // over each other's tap legs, both fused pairs foreign. The two-sided
    // fusion licence changed the verdict, not the detector: the DIRECTED
    // complete K(2,2) declares exactly srcs x tgts with one-way heads, so
    // the plan records one fused union, the two arrivals share one rail row,
    // and every fused meeting on it is LICENSED — no defect. Drop one head
    // (see the arrow-free complement above) or one edge and the licence
    // lapses, which the incomplete-bipartite pins elsewhere hold.
    const k22 = "flowchart TD\n  A --> C\n  B --> C\n  A --> D\n  B --> D\n";
    for ([3]u32{ 60, 100, 140 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try renderCounts(arena.allocator(), k22, w);

        try testing.expectEqual(@as(u32, 1), c.c_run_fused_crossing);
        try testing.expectEqual(@as(u32, 1), c.c_run_fused_licensed);
        try testing.expectEqual(@as(u32, 0), c.d_run_fused_foreign);
        try testing.expectEqual(@as(u32, 0), c.u_run_fused_unevidenced);
        try testing.expectEqual(@as(u32, 0), c.defectTotal());
    }
}

const labeled_fan_cases = [_]struct { source: []const u8, labels: u32, arrows: u32 }{
    .{ .source = "flowchart TD\n  P -->|alpha-member-1| A\n  P -->|bravo-member-2| B\n  P -.->|charlie-member-3| C\n  P -.->|delta-member-4| D\n  P ==>|echo-member-5| E\n  P ==>|foxtrot-member-6| F\n", .labels = 6, .arrows = 6 },
    .{ .source = "flowchart TD\n  P -->|alpha| A\n  P -->|bravo| B\n  P -->|charlie| C\n", .labels = 3, .arrows = 3 },
    .{ .source = "flowchart TD\n  A -->|left-source-label| T\n  B -->|middle-source-label| T\n  C -->|right-source-label| T\n", .labels = 3, .arrows = 3 },
    .{ .source = "flowchart TD\n  P --> A\n  P -->|only-label| B\n  P --> C\n", .labels = 1, .arrows = 3 },
    .{ .source = "flowchart TD\n  P -->|a| A\n  P -->|b| A\n  P -->|c| B\n", .labels = 3, .arrows = 3 },
    .{ .source = "flowchart BT\n  P -->|alpha| A\n  P -->|bravo| B\n  P -->|charlie| C\n", .labels = 3, .arrows = 3 },
    .{ .source = "flowchart TD\n  P -->|x| A\n  P --> B\n  subgraph G\n    B\n  end\n", .labels = 1, .arrows = 2 },
};

test "fan labels: feasible mixed, in-out, BND-S, clustered and BT renders lose none" {
    for (labeled_fan_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, case.source);
        const built = try permits.build(a, graph, .joined);
        const winner = try select.choose(a, graph, &built.plan, 60, false, false, .bridge);
        const report = try raster.rasterize(a, winner.sketch, .bridge);
        try testing.expectEqual(@as(u32, 0), report.labels_dropped);
        try testing.expectEqual(case.labels, report.labels_placed - @as(u32, @intCast(winner.sketch.nodes.len)));
        const c = scan.run(a, .{ .graph = graph, .sketch = winner.sketch, .lat = &report.lattice, .mode = .bridge, .labels_placed = report.labels_placed, .labels_dropped = report.labels_dropped, .labels_displaced = report.labels_displaced, .edge_cells_lost = report.edge_cells_lost });
        try testing.expectEqual(case.arrows, c.n_arrows_declared);
        try testing.expectEqual(@as(u32, 0), c.d_arrow_missing);
        try testing.expectEqual(@as(u32, @intCast(graph.edges.len)), c.m_sketch_edges);
        try testing.expect(winner.sketch.bbox.w <= 60);
    }
}

test "fan labels: explicit clipping reports width overflow and declared loss" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  P -->|abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789| A\n  P -->|short| B\n");
    const built = try permits.build(a, graph, .joined);
    const winner = try select.choose(a, graph, &built.plan, 20, false, false, .bridge);
    var marked = false;
    for (winner.sketch.diagnostics) |d| switch (d) {
        .width_overflow => marked = true,
        else => {},
    };
    try testing.expect(marked);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    try testing.expectEqual(@as(u32, 1), report.labels_dropped);
}

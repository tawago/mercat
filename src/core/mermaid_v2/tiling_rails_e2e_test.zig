//! End-to-end pin for the fused-crossbar tier (`tiling/rails.zig`), over
//! REAL renders: parse -> permits -> select -> rasterize (side table
//! collected) -> scan.
//!
//! WHY THIS EXISTS SEPARATELY FROM THE UNIT PIN. The shape the tier is about
//! — two rails sharing one crossbar row with two nodes on each side — is
//! constructible by hand, and `tiling/rails_test.zig` does that and drives
//! both verdicts. What a hand-built fixture cannot show is that the shape
//! occurs in production AT ALL: it is narrow enough that a whole corpus can
//! render without one, so a zero population there is evidence of nothing.
//! This file exhibits the shape from source text, and its counterpart — the
//! same graph without the subgraph, which lands its rails on separate rows —
//! pins the other side of the population boundary.
//!
//! Root-level for the same reason as the other cross-instrument pins: the
//! tiling zone may not import raster or select, so the production path and
//! the audit meet only here.

const std = @import("std");
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
    const flat = !built.report.join_permits_skipped_clustered;
    const winner = try select.choose(a, graph, &plan, flat, width, false, false);
    const report = try raster.rasterize(a, winner.sketch, .bridge, .{ .collect_aux = true });
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

const clustered =
    \\flowchart TD
    \\  subgraph S1
    \\    A --> C
    \\    A --> D
    \\    B --> C
    \\    B --> D
    \\  end
    \\
;

const unclustered =
    \\flowchart TD
    \\  A --> C
    \\  A --> D
    \\  B --> C
    \\  B --> D
    \\
;

test "rails: a real render puts two rails on one row and accounts for every pair" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try renderCounts(arena.allocator(), clustered, 120);

    // The population is non-empty in production: this is the whole point of
    // the file. Two rails, one crossbar row, two pivots and two leaves.
    try testing.expectEqual(@as(u32, 1), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 4), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 4), c.c_rail_pair_accounted);
    try testing.expectEqual(@as(u32, 0), c.d_rail_pair_undeclared);
    try testing.expectEqual(@as(u32, 0), c.d_rail_branch_unrecorded);
    try testing.expectEqual(@as(u32, 0), c.u_rail_pair_unevidenced);
    try testing.expectEqual(@as(u32, 0), c.u_rail_run_records_absent);
    try testing.expectEqual(@as(u32, 0), c.u_audit_oom);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    // The line drawn here IS the two crossbars and nothing more, so the
    // pair counts above are the whole answer and not a floor.
    try testing.expectEqual(@as(u32, 0), c.u_rail_run_continued);
}

test "rails: the same graph unclustered separates its rails, so nothing fuses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try renderCounts(arena.allocator(), unclustered, 120);

    // Distinct crossbar rows: the other side of the population boundary.
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 0), c.u_rail_run_records_absent);
}

/// Nine edges over six nodes, three of them inside a subgraph. The render
/// puts the two fan-OUT rails on SEPARATE rows — B's crossbar inside the
/// frame, E's above it — so no two crossbars fuse and the pair tier's
/// population is empty. A->E's horizontal jog then lands collinear with E's
/// crossbar and extends that row into ONE unbroken line, from D's riser at
/// the left clear across to A's on the right: a line reaching an endpoint
/// (A) that E's crossbar never names.
const continued =
    \\flowchart TB
    \\  subgraph S1
    \\    B --> A
    \\    B --> C
    \\    C --> B
    \\  end
    \\  A --> E
    \\  B --> E
    \\  E --> C
    \\  E --> D
    \\  F --> A
    \\
;

test "rails: a run the crossbars under-measure is reported as continued, not as silence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const c = try renderCounts(arena.allocator(), continued, 140);

    // Neither rail fuses with the other, so every pair bucket is empty and
    // the population reads zero. The drawn row is nonetheless one unbroken
    // line reaching endpoints the crossbars never named. Without the
    // counter below, that zero would be indistinguishable from "no fused
    // line here" — which is exactly what it is not.
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.n_rail_pairs_asserted);
    try testing.expect(c.u_rail_run_continued > 0);

    // The collinear family still reports nothing: the junction where the
    // jog meets the crossbar has three arms, so the pair check takes its
    // junction branch and leaves `d_run_fused_collinear` empty. That is
    // still the whole reason THIS limitation needs a counter of its own —
    // the pair tier cannot see the run at all.
    try testing.expectEqual(@as(u32, 0), c.d_run_fused_collinear);
    try testing.expect(c.c_run_fused_crossing > 0);

    // AMENDED when the junction licence landed (R3). The junction branch is
    // no longer filed wholesale as convention: it is decomposed by what the
    // carrier records say about the two edges' channel AT the junction, and
    // the one junction this render has is unlicensed — B->E's ink was
    // REFUSED at the crossbar's own cell, where the fused line now runs
    // straight through it toward D. So the shortfall has a SECOND instrument
    // — a different one, counting adjacent cell PAIRS rather than runs, and
    // still a floor. Read them together: neither is the whole count.
    try testing.expect(c.d_run_fused_foreign > 0);
    try testing.expectEqual(c.d_run_fused_foreign, c.defectTotal());
}

test "rails: the audit stays silent on shapes with no fused run" {
    // A plain fan-OUT is a lone-pivot run and a chain has no rail at all;
    // neither may enter the population, at either width.
    const quiet = [_][]const u8{
        "flowchart TD\n  A --> B\n  B --> C\n",
        "flowchart TD\n  A --> B\n  A --> C\n  A --> D\n",
        "flowchart TD\n  A --> D\n  B --> D\n  C --> D\n",
    };
    for (quiet) |source| for ([2]u32{ 60, 120 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const c = try renderCounts(arena.allocator(), source, w);
        try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
        try testing.expectEqual(@as(u32, 0), c.n_rail_pairs_asserted);
        try testing.expectEqual(@as(u32, 0), c.u_rail_run_records_absent);
        // Silent means silent: a shape with nothing to measure must not
        // report a limitation either, or the counter would be noise.
        try testing.expectEqual(@as(u32, 0), c.u_rail_run_continued);
    };
}

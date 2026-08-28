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
    const winner = try select.choose(a, graph, &plan, width, false, false);
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

test "rails: a clustered complete bipartite renders exactly as its flat form" {
    // Cluster unification: the subgraph piece realizes the same piece plan a
    // flat graph would, so the graph inside a frame and the graph without one
    // produce one and the same rail story — the fan-IN trunk arrangement,
    // with no fused two-sided row. (The pre-unification piece path bypassed
    // the plan and fused the two fan-OUT crossbars on one row; that
    // clustered-only population is gone.)
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const in_frame = try renderCounts(arena.allocator(), clustered, 120);
    const flat = try renderCounts(arena.allocator(), unclustered, 120);

    try testing.expectEqual(@as(u32, 0), in_frame.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), in_frame.u_rail_run_continued);
    try testing.expectEqual(@as(u32, 0), in_frame.u_rail_run_records_absent);
    try testing.expectEqual(@as(u32, 0), in_frame.u_audit_oom);
    // The whole rail tier agrees between the two forms, defect for defect.
    try testing.expectEqual(flat.n_rails_first_class, in_frame.n_rails_first_class);
    try testing.expectEqual(flat.n_rail_pairs_asserted, in_frame.n_rail_pairs_asserted);
    try testing.expectEqual(flat.d_rail_pair_undeclared, in_frame.d_rail_pair_undeclared);
    try testing.expectEqual(flat.u_rail_pair_unevidenced, in_frame.u_rail_pair_unevidenced);
    try testing.expectEqual(flat.defectTotal(), in_frame.defectTotal());
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
/// population is empty. A->E's horizontal jog used to land collinear with
/// E's crossbar and extend that row into one unbroken line; the bridge
/// router now treats trunk runs as jog obstacles and dodges the row, so
/// the continued-run counter's population here is empty BY REPAIR — the
/// counter itself stays, as the floor for any leak the router cannot see.
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
    // the population reads zero. The jog that used to extend E's crossbar
    // into an unbroken foreign line now dodges the row (trunk runs are
    // bridge-router obstacles), so the continued-run counter reads zero
    // TRUTHFULLY: no drawn row exceeds what its crossbar names.
    try testing.expectEqual(@as(u32, 0), c.n_rail_runs_two_sided);
    try testing.expectEqual(@as(u32, 0), c.n_rail_pairs_asserted);
    try testing.expectEqual(@as(u32, 0), c.u_rail_run_continued);
    try testing.expectEqual(@as(u32, 0), c.d_run_fused_collinear);

    // The dodged jogs still CROSS runs perpendicular (legal). The one
    // genuinely foreign fused pair this shape used to ship is gone BY
    // SELECTION: the score's violation tier now prefers the candidate
    // without it, so the defect population here is empty by repair too —
    // the counter itself stays, as the floor for any leak selection
    // cannot dodge.
    try testing.expect(c.c_run_fused_crossing > 0);
    try testing.expectEqual(@as(u32, 0), c.d_run_fused_foreign);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
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

/// Production-path crossing counters for one source at one width.
fn renderCrossings(a: std.mem.Allocator, source: []const u8, width: u32) !raster.RasterReport {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, width, false, false);
    return try raster.rasterize(a, winner.sketch, .bridge);
}

test "bridges: a dodge that cannot halve measured conflict never ships" {
    // A mixed cross-border fan over two subgraphs plus an inter-subgraph
    // edge: the dodging build wins only marginal proxy points here while
    // its displaced jogs fuse corners into other bridges' runs at the
    // raster. The plain build (the incumbent geometry) must ship, keeping
    // the render violation-free at both widths.
    const source =
        \\flowchart TD
        \\subgraph SG0
        \\  S0N0 -.-> S0N1
        \\end
        \\subgraph SG1
        \\  S1N0 --o S1N1
        \\end
        \\O0 ==> S1N0
        \\O0 --> S0N0
        \\O0 --o S0N1
        \\O0 --- S1N1
        \\S1N0 --> S0N0
        \\
    ;
    for ([2]u32{ 60, 120 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const report = try renderCrossings(arena.allocator(), source, w);
        try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
        try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    }
}

test "bridges: mixed-kind cross-border fans keep a clean scene" {
    // Dotted, solid and thick bridges from one outer pivot into two
    // subgraphs, plus a dotted subgraph-to-subgraph edge — a second shape
    // whose always-dodged build measured worse than plain at the raster.
    const source =
        \\flowchart TD
        \\subgraph SG0
        \\  S0N0 --- S0N1
        \\end
        \\subgraph SG1
        \\  S1N0 --x S1N1
        \\end
        \\O0 -.-> S1N0
        \\O0 -.-> S0N1
        \\O0 --> S0N0
        \\O0 ==> S1N1
        \\S0N1 -.-> S1N0
        \\
    ;
    for ([2]u32{ 60, 120 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const report = try renderCrossings(arena.allocator(), source, w);
        try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
        try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    }
}

test "bridges: a licensed cross-border fan records its realized trunk; a mixed fan keeps the refusal" {
    // O fans across the border into two subgraphs; the crossings leave one
    // exit port and split cleanly, so the bridge plan flips the group to
    // SELECTED (one join over the bridge edges) and the scene stays clean.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a,
        \\graph TD
        \\    subgraph G1
        \\        N1[N1]
        \\    end
        \\    subgraph G2
        \\        M1[M1]
        \\        M2[M2]
        \\    end
        \\    X --> N1
        \\    X --> M1
        \\    X --> M2
        \\
    );
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, 60, false, false);
    var realized: usize = 0;
    for (winner.sketch.joins.selected_joins) |j| {
        if (j.members.len >= 2) realized += 1;
    }
    try testing.expectEqual(@as(usize, 1), realized);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);

    // Mixed decorations at the pivot: the licence refuses, the record names
    // it, and no join is selected.
    const mixed = try parse(a,
        \\graph TD
        \\    subgraph S
        \\        A[A]
        \\        B[B]
        \\    end
        \\    Q -.-> A
        \\    Q --o B
        \\
    );
    const mixed_built = try permits.build(a, mixed, .joined);
    const mixed_plan = mixed_built.plan;
    const mixed_winner = try select.choose(a, mixed, &mixed_plan, 60, false, false);
    try testing.expectEqual(@as(usize, 0), mixed_winner.sketch.joins.selected_joins.len);
    var refused = false;
    for (mixed_winner.sketch.joins.memberships) |m| {
        const d = m.source orelse continue;
        if (d == .independent and d.independent.reason == .licence_refused) refused = true;
    }
    try testing.expect(refused);
}

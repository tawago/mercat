//! Root-level pin for the JUNCTION LICENCE, read from the raster alone,
//! against REAL renders: parse -> permits -> select -> rasterize.
//!
//! THE PROPERTY. A junction glyph may assert a sharing only where the two
//! edges legally share a bundle at that junction. The raster records that
//! answer itself: every edge whose ink lands on a cell the Cell does not
//! name files a `.carrier` record there, and the record's detail is the
//! crossing rule's transcript for the ordered pair at that position —
//! `merged_licensed` where the two carriers name one bundle, `merged_foreign`
//! or `suppressed` where they do not, `merged_untested` where nobody asked
//! (`raster/crossings.zig` `licenceFor`; `lattice.CarrierKind`). The
//! sketch's bundles are the witness the record is measured against: a
//! record that admits a sharing must agree with the membership derivation,
//! and a record that denies one must agree with the identity lookup.
//!
//! This file reads only raster-side data — the lattice's ink state and
//! occupant, its side table, the licence lookup, and the sketch's bundles.
//! It supersedes the retired `tiling_licence_test.zig`, which stated the
//! same property through the report-only audit's counters, on the same
//! shapes, with the same outcomes.
//!
//! The three verdicts partition the junction population exactly, so every
//! render is its own consistency check; the shapes below add the outcomes
//! a partition identity alone cannot distinguish.

const std = @import("std");
const ledger = @import("base/ledger.zig");
const parse = @import("parse.zig").parse;
const permits = @import("ledger/permits.zig");
const select = @import("select.zig");
const raster = @import("raster.zig");
const crossings = @import("raster/crossings.zig");
const lattice = @import("lattice.zig");
const sketch_mod = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");

const testing = std.testing;

/// A finished production render: the graph, the winning sketch, and the
/// raster report whose lattice carries the side table.
const Rendered = struct {
    graph: sem_graph.SemGraph,
    sketch: sketch_mod.Sketch,
    report: raster.RasterReport,
};

/// The production path exactly as the composition root drives it.
fn render(a: std.mem.Allocator, source: []const u8, width: u32) !Rendered {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    return .{ .graph = graph, .sketch = winner.sketch, .report = report };
}

/// What the recorded facts say about one junction pair.
const Verdict = enum { licensed, foreign, unevidenced };

/// The junction population of one render, judged from carrier records alone.
///
/// The population is every (junction cell, anonymous edge) pair: a cell the
/// producer recorded as `.junction` — the owner set changes there — together
/// with each edge a `.carrier` record names at that cell other than the
/// cell's own surviving owner. The verdict for a pair reads the records
/// directly: any record stating FOREIGN (`suppressed`, `merged_foreign`)
/// decides; else any stating LICENSED; else nothing was said.
const Verdicts = struct {
    population: u32 = 0,
    licensed: u32 = 0,
    foreign: u32 = 0,
    unevidenced: u32 = 0,

    fn add(self: *Verdicts, v: Verdict) void {
        self.population += 1;
        switch (v) {
            .licensed => self.licensed += 1,
            .foreign => self.foreign += 1,
            .unevidenced => self.unevidenced += 1,
        }
    }
};

/// The edge a junction cell's occupant names, or null where the cell is not
/// edge ink (a frame or border junction carries no owner to pair with).
fn ownerOf(cell: *const lattice.Cell) ?ledger.EdgeId {
    return switch (cell.occupant) {
        .edge_segment => |seg| seg.edge,
        .arrowhead => |h| h.edge,
        else => null,
    };
}

/// Walk the side table in its sorted (cell, kind, value) order and judge
/// each junction pair. Along the way, hold every record to the property: a
/// record that admits a sharing must be one the membership derivation and
/// the identity lookup both grant at that cell; a record that denies one
/// must be one the identity lookup denies, or a refusal the derivation
/// denies.
fn judge(s: sketch_mod.Sketch, lat: *const lattice.Lattice) !Verdicts {
    var out: Verdicts = .{};
    const aux = lat.aux;
    var i: usize = 0;
    while (i < aux.len) {
        const head = aux[i];
        var j = i + 1;
        while (j < aux.len and aux[j].cell == head.cell and aux[j].kind == head.kind and aux[j].value == head.value) j += 1;
        defer i = j;
        if (head.kind != .carrier) continue;

        const x = head.cell % lat.width;
        const y = head.cell / lat.width;
        const cell = lat.at(x, y);
        if (cell.state != .junction) continue;
        const owner = ownerOf(cell) orelse continue;
        const other: ledger.EdgeId = head.value;
        if (owner == other) continue;

        const at = crossings.cellAt(x, y);
        const derived = ledger.derivedSameBundle(s.bundles, s.bundle_sets, owner, other, at);
        const identity = crossings.licenceFor(owner, other, s.bundle_sets, s.bundle_stamp_state, at);

        var foreign = false;
        var licensed = false;
        for (aux[i..j]) |r| {
            const kind = std.meta.intToEnum(lattice.CarrierKind, r.detail) catch continue;
            switch (kind) {
                .merged_licensed => {
                    licensed = true;
                    try testing.expect(derived);
                    try testing.expectEqual(lattice.CarrierKind.merged_licensed, identity);
                },
                .merged_foreign => {
                    foreign = true;
                    try testing.expectEqual(lattice.CarrierKind.merged_foreign, identity);
                },
                .suppressed => {
                    foreign = true;
                    try testing.expect(!derived);
                },
                .merged_untested => {},
            }
        }
        out.add(if (foreign) .foreign else if (licensed) .licensed else .unevidenced);
    }
    return out;
}

/// The raster's own shipped-defect tallies, all of which must stay zero on
/// a shape that merges honestly: no fabricated junction, no transit through
/// a decoration cell, no arm into a head, no ink or head lost, every tip on
/// its port.
fn expectNoRasterDefect(report: raster.RasterReport) !void {
    try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try testing.expectEqual(@as(u32, 0), report.armIntoHead());
    try testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
    try testing.expectEqual(@as(u32, 0), report.edge_heads_lost);
    try testing.expectEqual(@as(u32, 0), report.arrow_base.tip_not_port);
}

/// Arrowhead cells on the grid: the raster-side count of heads that shipped.
fn arrowheadCells(lat: *const lattice.Lattice) u32 {
    var n: u32 = 0;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            if (lat.at(x, y).occupant == .arrowhead) n += 1;
        }
    }
    return n;
}

/// A rendered witness for pair-specific scope after clustered bridge
/// reconstruction. The final sketch has three edges sharing one port. Two
/// pairs share only the short approach; the third pair shares the longer
/// approach. One port gives the group one identity, but it does not let
/// either short pair borrow the long pair's cells.
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
    const r = try render(a, three_way_port_share, 140);
    const v = try judge(r.sketch, &r.report.lattice);
    // Nine junction pairs, every one licensed. The unit here is a
    // (junction cell, anonymous edge) pair read off the side table, not the
    // audit's collinear-adjacency count (which saw one): the three-way port
    // share files a record for each co-member at each cell where a member
    // joins or leaves the shared approach. What matters is the split — no
    // pair foreign, no pair unevidenced — and that the population is exact.
    try testing.expectEqual(@as(u32, 9), v.population);
    try testing.expectEqual(@as(u32, 9), v.licensed);
    try testing.expectEqual(@as(u32, 0), v.foreign);
    try testing.expectEqual(@as(u32, 0), v.unevidenced);
    try testing.expectEqual(v.population, v.licensed + v.foreign + v.unevidenced);

    var found: ?ledger.Bundle = null;
    for (r.sketch.bundle_sets) |set| {
        if (set.origin != .port_share) continue;
        if (!std.mem.eql(ledger.EdgeId, set.members, &.{ 14, 15, 16 })) continue;
        found = set;
        break;
    }
    const share = found orelse return error.MissingThreeWayPortShare;
    const cells = share.cells orelse return error.MissingPortShareScope;
    const pairs = share.pairwise orelse return error.MissingPairScopes;

    // 35 rows since the decoration-cell tallies entered the score
    // (2026-09-03): the candidate that shipped two lateral arms into its
    // heads lost to one shipping one, whose shared approach is a row shorter.
    try testing.expectEqual(@as(usize, 35), cells.len);
    for (cells, 0..) |cell, i| {
        try testing.expectEqual(@as(i32, 24), cell.x);
        try testing.expectEqual(50 - @as(i32, @intCast(i)), cell.y);
    }

    const expected = [_]struct {
        a: ledger.EdgeId,
        b: ledger.EdgeId,
        last_y: i32,
    }{
        .{ .a = 14, .b = 15, .last_y = 45 },
        .{ .a = 14, .b = 16, .last_y = 45 },
        .{ .a = 15, .b = 16, .last_y = 16 },
    };
    try testing.expectEqual(expected.len, pairs.len);
    for (pairs, expected) |pair, want| {
        try testing.expectEqual(want.a, pair.a);
        try testing.expectEqual(want.b, pair.b);
        try testing.expectEqual(@as(usize, @intCast(50 - want.last_y + 1)), pair.cells.len);
        for (pair.cells, 0..) |cell, i| {
            try testing.expectEqual(@as(i32, 24), cell.x);
            try testing.expectEqual(50 - @as(i32, @intCast(i)), cell.y);
        }
    }

    const only_share = [_]ledger.Bundle{share};
    const long_pair_only: ledger.BundleCell = .{ .x = 24, .y = 16 };
    try testing.expect(ledger.bundleMembersAt(&only_share, 15, 16, long_pair_only));
    try testing.expect(!ledger.bundleMembersAt(&only_share, 14, 15, long_pair_only));
    try testing.expect(!ledger.bundleMembersAt(&only_share, 14, 16, long_pair_only));

    // No fabricated junction, no transit, no lost ink, every tip on its
    // port. One lateral arm into a head remains on this seed at w140: the
    // candidate that ships one beat the candidate that shipped two (the
    // decoration-cell tallies entered the score 2026-09-03), and that arm is
    // priced, not hidden.
    try testing.expectEqual(@as(u32, 0), r.report.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), r.report.crossings.arrowhead_transit_violation);
    try testing.expectEqual(@as(u32, 0), r.report.edge_cells_lost);
    try testing.expectEqual(@as(u32, 0), r.report.edge_heads_lost);
    try testing.expectEqual(@as(u32, 0), r.report.arrow_base.tip_not_port);
    try testing.expectEqual(@as(u32, 1), r.report.armIntoHead());
}

test "junction licence: a reconstructed three-way port share keeps exact pair scopes and partitions junction verdicts" {
    try expectReconstructedThreeWayPortShare();
}

test "junction licence: a three-way port share the pairwise flood missed is licensed on the raster, and the render files no defect" {
    try expectReconstructedThreeWayPortShare();
}

test "junction licence: the three verdicts partition the junction population on every render, and every record agrees with the bundles" {
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
        const r = try render(arena.allocator(), source, w);
        const v = try judge(r.sketch, &r.report.lattice);
        try testing.expectEqual(v.population, v.licensed + v.foreign + v.unevidenced);
    };
}

test "junction licence: a shape with no foreign meeting reports no foreign junction" {
    for (quiet) |source| for ([2]u32{ 60, 120 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try render(arena.allocator(), source, w);
        const v = try judge(r.sketch, &r.report.lattice);
        try testing.expectEqual(@as(u32, 0), v.foreign);
        try testing.expectEqual(@as(u32, 0), r.report.crossings.foreign_junction_violation);
        try expectNoRasterDefect(r.report);
    };
}

test "junction licence: a render that DOES merge, honestly, reports licensed and no defect" {
    const merges_honestly = "flowchart TD\n  A --> C\n  A --> D\n  B --> C\n  B --> E\n";
    for ([3]u32{ 60, 100, 140 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try render(arena.allocator(), merges_honestly, w);
        const v = try judge(r.sketch, &r.report.lattice);
        try testing.expectEqual(@as(u32, 3), v.population);
        try testing.expectEqual(@as(u32, 3), v.licensed);
        try testing.expectEqual(@as(u32, 0), v.foreign);
        try testing.expectEqual(@as(u32, 0), v.unevidenced);
        try expectNoRasterDefect(r.report);
    }
}

test "junction licence: the two-rail K(2,2) is the smallest render that fabricates" {
    const k22 = "flowchart TD\n  A --> C\n  B --> C\n  A --> D\n  B --> D\n";
    for ([3]u32{ 60, 100, 140 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try render(arena.allocator(), k22, w);
        const v = try judge(r.sketch, &r.report.lattice);
        try testing.expectEqual(@as(u32, 3), v.population);
        try testing.expectEqual(@as(u32, 3), v.licensed);
        try testing.expectEqual(@as(u32, 0), v.foreign);
        try testing.expectEqual(@as(u32, 0), v.unevidenced);
        try expectNoRasterDefect(r.report);
    }
}

/// `heads` is the number of arrowhead cells the raster ships: one per
/// member of a fan-out, and ONE for a fan-in rail, whose members discharge
/// into the rail's single head at the pivot.
const labeled_fan_cases = [_]struct { source: []const u8, labels: u32, heads: u32 }{
    .{ .source = "flowchart TD\n  P -->|alpha-member-1| A\n  P -->|bravo-member-2| B\n  P -.->|charlie-member-3| C\n  P -.->|delta-member-4| D\n  P ==>|echo-member-5| E\n  P ==>|foxtrot-member-6| F\n", .labels = 6, .heads = 6 },
    .{ .source = "flowchart TD\n  P -->|alpha| A\n  P -->|bravo| B\n  P -->|charlie| C\n", .labels = 3, .heads = 3 },
    .{ .source = "flowchart TD\n  A -->|left-source-label| T\n  B -->|middle-source-label| T\n  C -->|right-source-label| T\n", .labels = 3, .heads = 1 },
    .{ .source = "flowchart TD\n  P --> A\n  P -->|only-label| B\n  P --> C\n", .labels = 1, .heads = 3 },
    .{ .source = "flowchart TD\n  P -->|a| A\n  P -->|b| A\n  P -->|c| B\n", .labels = 3, .heads = 3 },
    .{ .source = "flowchart BT\n  P -->|alpha| A\n  P -->|bravo| B\n  P -->|charlie| C\n", .labels = 3, .heads = 3 },
    .{ .source = "flowchart TD\n  P -->|x| A\n  P --> B\n  subgraph G\n    B\n  end\n", .labels = 1, .heads = 2 },
};

/// Every graph edge is in the sketch as its own path or as a rail tap.
fn sketchEdgeCount(s: sketch_mod.Sketch) usize {
    var taps: usize = 0;
    for (s.rails) |rail| taps += rail.taps.len;
    return s.edges.len + taps;
}

test "fan labels: feasible mixed, in-out, star-law-refused, clustered and BT renders lose none" {
    for (labeled_fan_cases) |case| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const r = try render(a, case.source, 60);
        try testing.expectEqual(@as(u32, 0), r.report.labels_dropped);
        try testing.expectEqual(case.labels, r.report.labels_placed - @as(u32, @intCast(r.sketch.nodes.len)));
        try testing.expectEqual(case.heads, arrowheadCells(&r.report.lattice));
        try testing.expectEqual(@as(u32, 0), r.report.edge_heads_lost);
        try testing.expectEqual(r.graph.edges.len, sketchEdgeCount(r.sketch));
        try testing.expect(r.sketch.bbox.w <= 60);
    }
}

test "fan labels: explicit clipping reports width overflow and declared loss" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try render(a, "flowchart TD\n  P -->|abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789| A\n  P -->|short| B\n", 20);
    var marked = false;
    for (r.sketch.diagnostics) |d| switch (d) {
        .width_overflow => marked = true,
        else => {},
    };
    try testing.expect(marked);
    try testing.expectEqual(@as(u32, 1), r.report.labels_dropped);
}

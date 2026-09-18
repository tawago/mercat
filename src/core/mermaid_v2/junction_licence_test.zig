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
/// a stroke: a frame or border junction carries no owner to pair with, and
/// a decoration cell is never a junction (constitution, ink attribution),
/// so an arrowhead occupant owns no junction pair — a head the raster left
/// in junction state fails `expectDecorationCellsHonest` instead.
fn ownerOf(cell: *const lattice.Cell) ?ledger.EdgeId {
    return switch (cell.occupant) {
        .edge_segment => |seg| seg.edge,
        else => null,
    };
}

/// Arrowhead cells the raster recorded in junction state — the one ink
/// state a decoration cell never holds. Today's only way in is a head
/// stamped over another edge's ink (`edges_write.writeArrowCell`).
fn headsInJunctionState(lat: *const lattice.Lattice) u32 {
    var n: u32 = 0;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.atConst(x, y);
            if (cell.occupant == .arrowhead and cell.state == .junction) n += 1;
        }
    }
    return n;
}

/// The base side of every decoration cell is fed by its own run
/// (`arrow_base.validate` counts the unfed ones), and no head is a junction.
fn expectDecorationCellsHonest(report: raster.RasterReport) !void {
    try testing.expectEqual(@as(u32, 0), report.arrow_base.violations);
    try testing.expectEqual(@as(u32, 0), headsInJunctionState(&report.lattice));
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
/// its port, every base fed, no head in junction state, and no painted arm
/// without an owner to explain it.
fn expectNoRasterDefect(report: raster.RasterReport) !void {
    try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try testing.expectEqual(@as(u32, 0), report.armIntoHead());
    try testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
    try testing.expectEqual(@as(u32, 0), report.edge_heads_lost);
    try testing.expectEqual(@as(u32, 0), report.arrow_base.tip_not_port);
    try expectDecorationCellsHonest(report);
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
    // Eight junction pairs, every one licensed. The unit here is a
    // (junction cell, anonymous edge) pair read off the side table, not the
    // audit's collinear-adjacency count: the three-way port share files a
    // record for each co-member at each cell where a member joins or leaves
    // the shared approach. Three further pairs sit on the head the members
    // discharge into at B's port; a decoration cell is never a junction, so
    // the raster records that head rail-interior and `ownerOf` names no
    // head — those pairs are shared-stem ink, not junctions. Two pairs
    // joined the population when the row ledger began claiming the band a
    // bridge lands under an outer node's departure cell (C's and E's south
    // ports): each bridge now tees into the shared stem below the head
    // instead of cornering under it. What matters is the split — no pair
    // foreign, no pair unevidenced — and that the population is exact.
    try testing.expectEqual(@as(u32, 8), v.population);
    try testing.expectEqual(@as(u32, 8), v.licensed);
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

    // 30 rows: B's port sits at row 48 and the long pair leaves the shared
    // approach at row 19 — the row ledger sized every gap to its runs (the
    // F→D gap lost five rows of lane bloat; the C→E and E→F gaps hold the
    // bands their bridges claim, and the placement edges into the group's
    // stand-in claim nothing of their own — two rows the outer piece once
    // reserved for runs the stitch never painted).
    const port_y: i32 = 48;
    try testing.expectEqual(@as(usize, 30), cells.len);
    for (cells, 0..) |cell, i| {
        try testing.expectEqual(@as(i32, 24), cell.x);
        try testing.expectEqual(port_y - @as(i32, @intCast(i)), cell.y);
    }

    const expected = [_]struct {
        a: ledger.EdgeId,
        b: ledger.EdgeId,
        last_y: i32,
    }{
        .{ .a = 14, .b = 15, .last_y = 43 },
        .{ .a = 14, .b = 16, .last_y = 43 },
        .{ .a = 15, .b = 16, .last_y = 19 },
    };
    try testing.expectEqual(expected.len, pairs.len);
    for (pairs, expected) |pair, want| {
        try testing.expectEqual(want.a, pair.a);
        try testing.expectEqual(want.b, pair.b);
        try testing.expectEqual(@as(usize, @intCast(port_y - want.last_y + 1)), pair.cells.len);
        for (pair.cells, 0..) |cell, i| {
            try testing.expectEqual(@as(i32, 24), cell.x);
            try testing.expectEqual(port_y - @as(i32, @intCast(i)), cell.y);
        }
    }

    const only_share = [_]ledger.Bundle{share};
    const long_pair_only: ledger.BundleCell = .{ .x = 24, .y = 19 };
    try testing.expect(ledger.bundleMembersAt(&only_share, 15, 16, long_pair_only));
    try testing.expect(!ledger.bundleMembersAt(&only_share, 14, 15, long_pair_only));
    try testing.expect(!ledger.bundleMembersAt(&only_share, 14, 16, long_pair_only));

    // No fabricated junction, no transit, no lost ink, every tip on its
    // port, every base fed, no painted arm without an owner, and no lateral
    // arm into a head: the cluster bridge router lands a piece edge's head
    // on C's centre south port, the cell where the flat plan's C ==> E
    // departs, and once shipped that head stamped over the departure's
    // corner. The row ledger now claims the band a bridge lands under an
    // outer node's departure cell, so the departure runs straight through
    // the head cell and bends two rows lower; no head is in junction state.
    try testing.expectEqual(@as(u32, 0), r.report.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), r.report.crossings.arrowhead_transit_violation);
    try testing.expectEqual(@as(u32, 0), r.report.edge_cells_lost);
    try testing.expectEqual(@as(u32, 0), r.report.edge_heads_lost);
    try testing.expectEqual(@as(u32, 0), r.report.arrow_base.tip_not_port);
    try testing.expectEqual(@as(u32, 0), r.report.arrow_base.violations);
    try testing.expectEqual(@as(u32, 0), r.report.armIntoHead());
    try testing.expectEqual(@as(u32, 0), headsInJunctionState(&r.report.lattice));
}

test "junction licence: a reconstructed three-way port share keeps exact pair scopes and partitions junction verdicts" {
    try expectReconstructedThreeWayPortShare();
}

test "junction licence: a three-way port share the pairwise flood missed is licensed on the raster; the render ships one lateral arm, a bridge-routed head stamped over a departure bend" {
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
        both_ends_mirrored,
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

/// The edge `from --> to` names in `graph`.
fn edgeId(graph: sem_graph.SemGraph, from: []const u8, to: []const u8) ledger.EdgeId {
    for (graph.edges) |e| {
        if (std.mem.eql(u8, nodeRaw(graph, e.from), from) and std.mem.eql(u8, nodeRaw(graph, e.to), to)) return e.id;
    }
    unreachable;
}

fn nodeRaw(graph: sem_graph.SemGraph, id: u32) []const u8 {
    for (graph.nodes) |n| if (n.id == id) return n.raw_id;
    unreachable;
}

/// The rail whose taps name `edge` and whose role is a fan-IN.
fn fanInRailOf(s: sketch_mod.Sketch, edge: ledger.EdgeId) sketch_mod.Rail {
    for (s.rails) |rail| {
        if (rail.role != .fan_in_dropper and rail.role != .fan_in_rail) continue;
        for (rail.taps) |tap| if (tap.edge == edge) return rail;
    }
    unreachable;
}

/// The one `.carrier` record `edge` filed at (x, y), as its `CarrierKind`.
/// Errors when the cell holds no record for the edge, or more than one.
fn carrierAt(lat: *const lattice.Lattice, x: u32, y: u32, edge: ledger.EdgeId) !lattice.CarrierKind {
    var found: ?lattice.CarrierKind = null;
    for (lat.aux) |r| {
        if (r.kind != .carrier or r.cell != y * lat.width + x or r.value != edge) continue;
        if (found != null) return error.SecondCarrierRecord;
        found = try std.meta.intToEnum(lattice.CarrierKind, r.detail);
    }
    return found orelse error.NoCarrierRecord;
}

/// The skip-layer repro: A --> C is a member of the fan-OUT at A and of the
/// fan-IN at C (theory 10-confluence, "Rail membership at both ends").
const both_ends = "flowchart TD\n  A --> B\n  B --> C\n  A --> C\n";

/// The same both-ends member, left-handed. D --> B moves A to the left of
/// B, so A --> C reaches C's rail from the LEFT and is that rail's first
/// tap — the crossbar's owner — instead of its last; A --> E keeps a
/// fan-out at A so the edge still sits in two structural sets.
const both_ends_mirrored = "flowchart TD\n  A --> B\n  B --> C\n  A --> C\n  D --> B\n  A --> E\n";

/// Both structural sets in `sets` that name `edge`: the earlier one in
/// slice order and the later one. Errors unless there are exactly two.
fn twoStructuralSets(sets: []const ledger.Bundle, edge: ledger.EdgeId) ![2]ledger.Bundle {
    var out: [2]ledger.Bundle = undefined;
    var n: usize = 0;
    for (sets) |set| {
        if (!ledger.structuralUnscoped(set)) continue;
        for (set.members) |m| if (m == edge) {
            if (n == 2) return error.ThirdStructuralSet;
            out[n] = set;
            n += 1;
        };
    }
    if (n != 2) return error.NotTwoStructuralSets;
    return out;
}

// PINS TODAY'S ANSWER, WHICH IS WRONG. Theory 10-confluence, "Rail
// membership at both ends": each end of an edge is judged on its own, so
// A --> C is a member of the fan-out bundle at A AND of the fan-in bundle
// at C, and a cell of C's rail should read it as C's bundle. Today
// `ledger.bundleOf(sets, edge, at)` returns the FIRST numbered set in slice
// order that names the edge and licenses the cell; both sets are structural
// with `cells = null`, so both license everywhere, `at` cannot tell them
// apart, and the edge resolves to the fan-out set on every cell of the
// fan-in rail. `sketch_bundles.resolveRailBundle` refuses to key a rail by
// one tap for exactly this reason; `bundleOf` does what it refuses to do.
//
// Two shapes, four widths each, one render per width (the picture does
// not move between 60 and 120):
//
//   * `both_ends`: A --> C is the LAST tap of C's rail, so the rail writer
//     compares its own stamped identity against the crossbar's owner
//     B --> C and files `.merged_licensed` — the right record by luck of
//     tap order. But the identity lookup the record is measured against,
//     `crossings.licenceFor(B-->C, A-->C, at)`, answers `.merged_foreign`
//     at that same cell, and the `judge` helper's record-versus-identity
//     check refuses the render. That is why this shape is NOT in the
//     partition corpus above: it cannot pass today.
//
//   * `both_ends_mirrored`: A --> C is the FIRST tap of C's rail and owns
//     the crossbar, so `rails.licenceAt` compares the rail's identity (3)
//     against `bundleOf(A-->C)` (1, the fan-out set) at B --> C's branch
//     cell and FILES `.merged_foreign` on ink the plan licensed. The
//     derivation (`derivedSameBundle`) knows better at the same cell. The
//     judge counts the pair foreign; nothing else refuses, so the raster's
//     defect tallies stay zero — the wrong record is label-only.
//
// When the per-cell carrier-label path is refactored to read the rail's
// own membership, every `WRONG` line below flips; change them deliberately.
test "junction licence: rail membership at both ends — bundleOf resolves the both-ends member to the earlier set on the fan-in rail (today's answer, wrong)" {
    for ([4]u32{ 60, 90, 94, 120 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try render(arena.allocator(), both_ends, w);
        const s = r.sketch;
        const lat = &r.report.lattice;
        const bc = edgeId(r.graph, "B", "C");
        const ac = edgeId(r.graph, "A", "C");
        try testing.expectEqual(sketch_mod.BundleStampState.complete, s.bundle_stamp_state);

        // Two structural sets name A --> C: the fan-out at A first (1), the
        // fan-in at C second (2). Both license everywhere.
        const sets = try twoStructuralSets(s.bundle_sets, ac);
        try testing.expectEqual(@as(ledger.BundleId, 1), sets[0].bundle);
        try testing.expectEqual(@as(ledger.BundleId, 2), sets[1].bundle);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[1].members, bc) != null);

        // C's rail is bundle 2; A --> C is its LAST tap and continues on as
        // a member stroke; B --> C is its first tap and owns the crossbar.
        const rail = fanInRailOf(s, ac);
        try testing.expectEqual(@as(ledger.BundleId, 2), rail.bundle);
        try testing.expectEqual(@as(usize, 2), rail.taps.len);
        try testing.expectEqual(bc, rail.taps[0].edge);
        try testing.expectEqual(ac, rail.taps[1].edge);
        try testing.expect(rail.taps[1].continues);
        const at = rail.taps[1].at;
        try testing.expectEqual(@as(i32, 9), at.x);
        try testing.expectEqual(@as(i32, 9), at.y);
        const x: u32 = @intCast(at.x);
        const y: u32 = @intCast(at.y);
        const cell = lat.atConst(x, y);
        try testing.expectEqual(lattice.InkState.junction, cell.state);
        try testing.expectEqual(bc, ownerOf(cell).?);
        const here = crossings.cellAt(x, y);

        // The derivation knows the two share C's bundle here.
        try testing.expect(ledger.derivedSameBundle(s.bundles, s.bundle_sets, bc, ac, here));
        // WRONG: a cell of C's rail (bundle 2) resolves A --> C to bundle 1.
        try testing.expectEqual(@as(ledger.BundleId, 1), ledger.bundleOf(s.bundle_sets, ac, here));
        try testing.expectEqual(@as(ledger.BundleId, 2), ledger.bundleOf(s.bundle_sets, bc, here));
        // WRONG: the identity lookup calls the licensed pair foreign.
        try testing.expectEqual(lattice.CarrierKind.merged_foreign, crossings.licenceFor(bc, ac, s.bundle_sets, s.bundle_stamp_state, here));
        // The record the rail writer filed is right (it compared the rail's
        // own stamped identity, not `bundleOf(A-->C)`), so record and
        // identity disagree and the judge refuses the render.
        try testing.expectEqual(lattice.CarrierKind.merged_licensed, try carrierAt(lat, x, y, ac));
        try testing.expectError(error.TestExpectedEqual, judge(s, lat));
        try expectNoRasterDefect(r.report);
    }
}

test "junction licence: rail membership at both ends, mirrored — the rail writer files merged_foreign on licensed ink when the both-ends member owns the crossbar (today's answer, wrong)" {
    for ([4]u32{ 60, 90, 94, 120 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try render(arena.allocator(), both_ends_mirrored, w);
        const s = r.sketch;
        const lat = &r.report.lattice;
        const bc = edgeId(r.graph, "B", "C");
        const ac = edgeId(r.graph, "A", "C");
        const ae = edgeId(r.graph, "A", "E");
        try testing.expectEqual(sketch_mod.BundleStampState.complete, s.bundle_stamp_state);

        // The fan-out at A {A-->C, A-->E} is stamped first (1); the fan-in
        // at B sits between (2); the fan-in at C {A-->C, B-->C} is third (3).
        const sets = try twoStructuralSets(s.bundle_sets, ac);
        try testing.expectEqual(@as(ledger.BundleId, 1), sets[0].bundle);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[0].members, ae) != null);
        try testing.expectEqual(@as(ledger.BundleId, 3), sets[1].bundle);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[1].members, bc) != null);

        // C's rail is bundle 3; A --> C is its FIRST tap, from the left, and
        // owns the crossbar; B --> C branches onto it at (16, 11).
        const rail = fanInRailOf(s, ac);
        try testing.expectEqual(@as(ledger.BundleId, 3), rail.bundle);
        try testing.expectEqual(@as(usize, 2), rail.taps.len);
        try testing.expectEqual(ac, rail.taps[0].edge);
        try testing.expect(rail.taps[0].continues);
        try testing.expectEqual(bc, rail.taps[1].edge);
        const at = rail.taps[1].at;
        try testing.expectEqual(@as(i32, 16), at.x);
        try testing.expectEqual(@as(i32, 11), at.y);
        const x: u32 = @intCast(at.x);
        const y: u32 = @intCast(at.y);
        const cell = lat.atConst(x, y);
        try testing.expectEqual(lattice.InkState.junction, cell.state);
        try testing.expectEqual(ac, ownerOf(cell).?);
        const here = crossings.cellAt(x, y);

        try testing.expect(ledger.derivedSameBundle(s.bundles, s.bundle_sets, ac, bc, here));
        // WRONG: a cell of C's rail (bundle 3) resolves A --> C to bundle 1.
        try testing.expectEqual(@as(ledger.BundleId, 1), ledger.bundleOf(s.bundle_sets, ac, here));
        try testing.expectEqual(@as(ledger.BundleId, 3), ledger.bundleOf(s.bundle_sets, bc, here));
        // WRONG: the identity lookup calls the licensed pair foreign ...
        try testing.expectEqual(lattice.CarrierKind.merged_foreign, crossings.licenceFor(ac, bc, s.bundle_sets, s.bundle_stamp_state, here));
        // ... and this time the rail writer FILED that answer: `rails.licenceAt`
        // held the rail's identity (3) against `bundleOf(A-->C)` (1).
        try testing.expectEqual(lattice.CarrierKind.merged_foreign, try carrierAt(lat, x, y, bc));

        // Record and identity agree (both wrong), so the judge accepts the
        // render and counts the pair foreign: one foreign among three
        // junction pairs, the other two the fan-in at B and A's port share.
        const v = try judge(s, lat);
        try testing.expectEqual(@as(u32, 3), v.population);
        try testing.expectEqual(@as(u32, 2), v.licensed);
        try testing.expectEqual(@as(u32, 1), v.foreign); // WRONG: should be 0
        try testing.expectEqual(@as(u32, 0), v.unevidenced);
        // Label-only: nothing refused a byte.
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

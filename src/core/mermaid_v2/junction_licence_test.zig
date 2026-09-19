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

const Rendered = struct {
    graph: sem_graph.SemGraph,
    sketch: sketch_mod.Sketch,
    report: raster.RasterReport,
};

fn render(a: std.mem.Allocator, source: []const u8, width: u32) !Rendered {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    const plan = built.plan;
    const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    return .{ .graph = graph, .sketch = winner.sketch, .report = report };
}

const Verdict = enum { licensed, foreign, unevidenced };

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

fn ownerOf(cell: *const lattice.Cell) ?ledger.EdgeId {
    return switch (cell.occupant) {
        .edge_segment => |seg| seg.edge,
        else => null,
    };
}

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

fn expectDecorationCellsHonest(report: raster.RasterReport) !void {
    try testing.expectEqual(@as(u32, 0), report.arrow_base.violations);
    try testing.expectEqual(@as(u32, 0), headsInJunctionState(&report.lattice));
}

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
        const identity = crossings.carrierKindFor(owner, other, s.bundle_sets, s.bundle_stamp_state, at);

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

fn expectNoRasterDefect(report: raster.RasterReport) !void {
    try testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    try testing.expectEqual(@as(u32, 0), report.armIntoHead());
    try testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
    try testing.expectEqual(@as(u32, 0), report.edge_heads_lost);
    try testing.expectEqual(@as(u32, 0), report.arrow_base.tip_not_port);
    try expectDecorationCellsHonest(report);
}

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
        both_ends,
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

fn fanInRailOf(s: sketch_mod.Sketch, edge: ledger.EdgeId) sketch_mod.Rail {
    for (s.rails) |rail| {
        if (rail.role != .fan_in_dropper and rail.role != .fan_in_rail) continue;
        for (rail.taps) |tap| if (tap.edge == edge) return rail;
    }
    unreachable;
}

fn carrierAt(lat: *const lattice.Lattice, x: u32, y: u32, edge: ledger.EdgeId) !lattice.CarrierKind {
    var found: ?lattice.CarrierKind = null;
    for (lat.aux) |r| {
        if (r.kind != .carrier or r.cell != y * lat.width + x or r.value != edge) continue;
        if (found != null) return error.SecondCarrierRecord;
        found = try std.meta.intToEnum(lattice.CarrierKind, r.detail);
    }
    return found orelse error.NoCarrierRecord;
}

const both_ends = "flowchart TD\n  A --> B\n  B --> C\n  A --> C\n";

const both_ends_mirrored = "flowchart TD\n  A --> B\n  B --> C\n  A --> C\n  D --> B\n  A --> E\n";

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

test "junction licence: rail membership at both ends — a cell of the fan-in rail reads the both-ends member as the fan-in bundle's" {
    for ([4]u32{ 60, 90, 94, 120 }) |w| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const r = try render(arena.allocator(), both_ends, w);
        const s = r.sketch;
        const lat = &r.report.lattice;
        const bc = edgeId(r.graph, "B", "C");
        const ac = edgeId(r.graph, "A", "C");
        try testing.expectEqual(sketch_mod.BundleStampState.complete, s.bundle_stamp_state);

        const sets = try twoStructuralSets(s.bundle_sets, ac);
        try testing.expectEqual(@as(ledger.BundleId, 1), sets[0].bundle);
        try testing.expectEqual(@as(ledger.BundleId, 2), sets[1].bundle);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[1].members, bc) != null);

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

        try testing.expect(ledger.derivedSameBundle(s.bundles, s.bundle_sets, bc, ac, here));
        try testing.expect(ledger.memberOfBundleAt(s.bundle_sets, 2, ac, here));
        try testing.expect(ledger.memberOfBundleAt(s.bundle_sets, 1, ac, here));
        try testing.expect(!ledger.memberOfBundleAt(s.bundle_sets, 1, bc, here));
        try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKindFor(bc, ac, s.bundle_sets, s.bundle_stamp_state, here));
        try testing.expectEqual(lattice.CarrierKind.merged_licensed, try carrierAt(lat, x, y, ac));
        const v = try judge(s, lat);
        try testing.expectEqual(@as(u32, 2), v.population);
        try testing.expectEqual(@as(u32, 2), v.licensed);
        try testing.expectEqual(@as(u32, 0), v.foreign);
        try testing.expectEqual(@as(u32, 0), v.unevidenced);
        try expectNoRasterDefect(r.report);
    }
}

test "junction licence: rail membership at both ends, mirrored — the rail writer files merged_licensed on licensed ink when the both-ends member owns the crossbar" {
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

        const sets = try twoStructuralSets(s.bundle_sets, ac);
        try testing.expectEqual(@as(ledger.BundleId, 1), sets[0].bundle);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[0].members, ae) != null);
        try testing.expectEqual(@as(ledger.BundleId, 3), sets[1].bundle);
        try testing.expect(std.mem.indexOfScalar(ledger.EdgeId, sets[1].members, bc) != null);

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
        try testing.expect(ledger.memberOfBundleAt(s.bundle_sets, 3, ac, here));
        try testing.expect(ledger.memberOfBundleAt(s.bundle_sets, 1, ac, here));
        try testing.expect(!ledger.memberOfBundleAt(s.bundle_sets, 1, bc, here));
        try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKindFor(ac, bc, s.bundle_sets, s.bundle_stamp_state, here));
        try testing.expectEqual(lattice.CarrierKind.merged_licensed, try carrierAt(lat, x, y, bc));

        const v = try judge(s, lat);
        try testing.expectEqual(@as(u32, 3), v.population);
        try testing.expectEqual(@as(u32, 3), v.licensed);
        try testing.expectEqual(@as(u32, 0), v.foreign);
        try testing.expectEqual(@as(u32, 0), v.unevidenced);
        try expectNoRasterDefect(r.report);
    }
}

const labeled_fan_cases = [_]struct { source: []const u8, labels: u32, heads: u32 }{
    .{ .source = "flowchart TD\n  P -->|alpha-member-1| A\n  P -->|bravo-member-2| B\n  P -.->|charlie-member-3| C\n  P -.->|delta-member-4| D\n  P ==>|echo-member-5| E\n  P ==>|foxtrot-member-6| F\n", .labels = 6, .heads = 6 },
    .{ .source = "flowchart TD\n  P -->|alpha| A\n  P -->|bravo| B\n  P -->|charlie| C\n", .labels = 3, .heads = 3 },
    .{ .source = "flowchart TD\n  A -->|left-source-label| T\n  B -->|middle-source-label| T\n  C -->|right-source-label| T\n", .labels = 3, .heads = 1 },
    .{ .source = "flowchart TD\n  P --> A\n  P -->|only-label| B\n  P --> C\n", .labels = 1, .heads = 3 },
    .{ .source = "flowchart TD\n  P -->|a| A\n  P -->|b| A\n  P -->|c| B\n", .labels = 3, .heads = 3 },
    .{ .source = "flowchart BT\n  P -->|alpha| A\n  P -->|bravo| B\n  P -->|charlie| C\n", .labels = 3, .heads = 3 },
    .{ .source = "flowchart TD\n  P -->|x| A\n  P --> B\n  subgraph G\n    B\n  end\n", .labels = 1, .heads = 2 },
};

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

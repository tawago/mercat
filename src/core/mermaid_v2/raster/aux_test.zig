//! Unit tests for raster/aux.zig — the lattice side-table builder — and for
//! the one fact it carries today (`.port`, filed by `drawPortStroke`).
//!
//! The load-bearing test here is the last one: the bundle's whole premise
//! is that a record outlives every in-place rewrite of the Cell it sits on,
//! so that premise is measured against the real post-walk passes rather
//! than argued in a comment.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const raster = @import("../raster.zig");
const aux = @import("aux.zig");
const edge_walk = @import("edges.zig");
const ew = @import("edges_write.zig");
const ep = @import("edges_port.zig");
const fan_roles = @import("fan_roles.zig");
const reconcile = @import("reconcile.zig");
const crossings = @import("crossings.zig");
const ledger = @import("../base/ledger.zig");

const testing = std.testing;

/// A 1×2 lattice whose cell at row 0 is a solid rect `node_border` carrying
/// a horizontal {e,w} run — a box bottom. A polyline leaving it southwards
/// is a port departure.
fn sourceBorderLattice(a: std.mem.Allocator) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, 2);
    for (cells) |*c| c.* = lattice.Cell.empty;
    cells[0] = .{
        .occupant = .{ .node_border = .{ .node = 0, .role = .edge_s } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .solid,
        .shape = .rect,
    };
    return .{ .width = 1, .height = 2, .cells = cells };
}

test "drawPortStroke files a port record only for a stroke it actually draws" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var lat = try sourceBorderLattice(a);
        var c = aux.Collector.init(a);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
        ep.drawPortStroke(&lat, &pts, .solid, 42, .{}, &c);
        const table = c.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(lat.cellIndex(0, 0), table[0].cell);
        try testing.expectEqual(lattice.AuxKind.port, table[0].kind);
        try testing.expectEqual(@as(u32, 42), table[0].value);
        try testing.expectEqual(lattice.portArmDetail(.south), table[0].detail);
    }

    {
        var lat = try sourceBorderLattice(a);
        var c = aux.Collector.init(a);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
        ep.drawPortStroke(&lat, &pts, .invisible, 42, .{}, &c);
        try testing.expectEqual(@as(usize, 0), c.finish().len);
    }

    {
        var lat = try sourceBorderLattice(a);
        lat.at(0, 0).* = lattice.Cell.empty;
        var c = aux.Collector.init(a);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
        ep.drawPortStroke(&lat, &pts, .solid, 42, .{}, &c);
        try testing.expectEqual(@as(usize, 0), c.finish().len);
    }
}

/// Two stacked nodes joined by one downward edge: the edge departs node 1's
/// south border at (2,2), which is exactly one port stroke.
fn stackedPairSketch(a: std.mem.Allocator) !sketch.Sketch {
    const nodes = try a.alloc(sketch.NodePlacement, 2);
    nodes[0] = .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    nodes[1] = .{ .id = 2, .rect = .{ .x = 0, .y = 6, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };

    const poly = try a.alloc(sketch.Point, 2);
    poly[0] = .{ .x = 2, .y = 2 };
    poly[1] = .{ .x = 2, .y = 6 };

    const edges = try a.alloc(sketch.EdgePath, 1);
    edges[0] = .{
        .id = 7,
        .from = 1,
        .to = 2,
        .polyline = poly,
        .port_from = .{ .node = 1, .side = .south, .offset = 2 },
        .port_to = .{ .node = 2, .side = .north, .offset = 2 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    };

    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 5, .h = 9 },
        .direction = .TD,
        .nodes = nodes,
        .clusters = &.{},
        .edges = edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

test "every rasterization carries its complete side table" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try stackedPairSketch(a);

    const on = try raster.rasterize(a, s, .bridge);
    try testing.expect(on.lattice.aux.len > 0);
    try testing.expectEqual(lattice.AuxCollectionState.complete, on.lattice.aux_collection.state);
    try testing.expectEqual(@as(u64, @intCast(on.lattice.aux.len)), on.lattice.aux_collection.attempted_records);
    try testing.expectEqual(@as(u64, 0), on.lattice.aux_collection.lostRecords());
}

test "raster distinguishes complete-empty and AUX OOM without changing cells" {
    const empty = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    var empty_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer empty_arena.deinit();
    const empty_on = try raster.rasterize(empty_arena.allocator(), empty, .bridge);
    try testing.expectEqual(lattice.AuxCollectionState.complete, empty_on.lattice.aux_collection.state);
    try testing.expectEqual(@as(u64, 0), empty_on.lattice.aux_collection.attempted_records);
    try testing.expectEqual(@as(usize, 0), empty_on.lattice.aux.len);

    var sketch_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer sketch_arena.deinit();
    const s = try stackedPairSketch(sketch_arena.allocator());

    var complete_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer complete_arena.deinit();
    const complete = try raster.rasterize(complete_arena.allocator(), s, .bridge);
    try testing.expectEqual(lattice.AuxCollectionState.complete, complete.lattice.aux_collection.state);
    try testing.expect(complete.lattice.aux_collection.attempted_records > 0);

    var failed_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer failed_arena.deinit();
    var failing = std.testing.FailingAllocator.init(failed_arena.allocator(), .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    const failed = try raster.rasterize(failing.allocator(), s, .bridge);
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(lattice.AuxCollectionState.out_of_memory, failed.lattice.aux_collection.state);
    try testing.expectEqual(complete.lattice.aux_collection.attempted_records, failed.lattice.aux_collection.attempted_records);
    try testing.expectEqual(@as(u64, 0), failed.lattice.aux_collection.retainedRecords());
    try testing.expectEqual(failed.lattice.aux_collection.attempted_records, failed.lattice.aux_collection.lostRecords());
    try testing.expectEqual(@as(usize, 0), failed.lattice.aux.len);

    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(complete.lattice.cells),
        std.mem.sliceAsBytes(failed.lattice.cells),
    );
}

test "aux records survive the post-walk mutating passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try stackedPairSketch(a);

    const report = try raster.rasterize(a, s, .bridge);
    var lat = report.lattice;

    const source_port_cell = lat.cellIndex(2, 2);
    const target_port_cell = lat.cellIndex(2, 6);
    var found_source: usize = 0;
    var found_target: usize = 0;
    for (lat.aux) |r| {
        if (r.kind != .port) continue;
        try testing.expectEqual(@as(u32, 7), r.value);
        if (r.cell == source_port_cell) found_source += 1;
        if (r.cell == target_port_cell) found_target += 1;
    }
    try testing.expectEqual(@as(usize, 1), found_source);
    try testing.expectEqual(@as(usize, 0), found_target);

    const before = try a.dupe(lattice.Aux, lat.aux);
    fan_roles.resolveMasks(&lat, s);
    _ = reconcile.reconcileNeighbours(&lat);
    lat.at(2, 2).* = lattice.Cell.empty;

    try testing.expectEqual(before.len, lat.aux.len);
    for (before, lat.aux) |b, after| {
        try testing.expectEqual(b.cell, after.cell);
        try testing.expectEqual(b.kind, after.kind);
        try testing.expectEqual(b.value, after.value);
        try testing.expectEqual(b.detail, after.detail);
    }
}

/// A 4x4 lattice, so a Recorder built from it keys records the way the
/// production one does (`y * width + x`).
fn blankLattice(a: std.mem.Allocator) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, 16);
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = 4, .height = 4, .cells = cells };
}

/// A blank w×h lattice, plus the minimal Sketch/EdgePath pair that drives
/// `rasterizeEdges` — the only way to reach the walk's own corner-cell arm.
/// The Sketch carries no bundles, so the crossing rule is inert.
fn walkLattice(a: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn walkSketch(es: []const sketch.EdgePath) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = es,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn walkEdge(id: u32, pts: []const sketch.Point) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 1,
        .polyline = pts,
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .solid,
    };
}

test "a Recorder with no sink files nothing" {
    const rec: aux.Recorder = .{};
    rec.at(3, 3, .carrier, 1, 0);
    rec.at(0, 0, .port, 2, 0);
}

test "a Recorder keys a record at y * width + x" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lat = try blankLattice(a);
    var c = aux.Collector.init(a);
    const rec = aux.Recorder.init(&c, &lat);
    rec.at(2, 3, .carrier, 5, 1);

    const table = c.finish();
    try testing.expectEqual(@as(usize, 1), table.len);
    try testing.expectEqual(lat.cellIndex(2, 3), table[0].cell);
    try testing.expectEqual(@as(u8, 1), table[0].detail);
}

test "an OR-merge onto a foreign cell files a merged carrier; onto its own ink, nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lat = try blankLattice(a);
    var lost: u32 = 0;

    {
        var c = aux.Collector.init(a);
        const rec = aux.Recorder.init(&c, &lat);
        var cell = lattice.Cell{
            .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
            .neighbours = .{ .e = true, .w = true },
        };
        ew.writeEdgeCell(&cell, 8, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, .merged_foreign, rec);
        const table = c.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(lattice.AuxKind.carrier, table[0].kind);
        try testing.expectEqual(@as(u32, 8), table[0].value);
        try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged_foreign), table[0].detail);
        try testing.expectEqual(@as(u32, 3), cell.occupant.edge_segment.edge);
    }

    {
        var c = aux.Collector.init(a);
        const rec = aux.Recorder.init(&c, &lat);
        var cell = lattice.Cell{
            .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
            .neighbours = .{ .e = true, .w = true },
        };
        ew.writeEdgeCell(&cell, 3, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, .merged_licensed, rec);
        try testing.expectEqual(@as(usize, 0), c.finish().len);
    }

    {
        var c = aux.Collector.init(a);
        const rec = aux.Recorder.init(&c, &lat);
        var cell = lattice.Cell.empty;
        ew.writeEdgeCell(&cell, 8, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, .merged_untested, rec);
        try testing.expectEqual(@as(usize, 0), c.finish().len);
    }
}

test "an arrowhead stamped over a foreign run files a carrier for the run it covered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lat = try blankLattice(a);
    var lost: u32 = 0;
    var hlost: u32 = 0;

    var c = aux.Collector.init(a);
    const rec = aux.Recorder.init(&c, &lat);
    var cell = lattice.Cell{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
        .neighbours = .{ .e = true, .w = true },
    };
    ew.writeArrowCell(&cell, 9, .solid, .filled, .south, .{ .n = true }, 2, 2, &lost, &hlost, .merged_foreign, rec);

    const table = c.finish();
    try testing.expectEqual(@as(usize, 1), table.len);
    try testing.expectEqual(@as(u32, 3), table[0].value);
    try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged_foreign), table[0].detail);
}

test "a corner arm merged onto a foreign run files a merged carrier; onto its own ink, nothing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var lat = try walkLattice(a, 10, 10);
        var c = aux.Collector.init(a);
        const p3 = [_]sketch.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 7 } };
        const p8 = [_]sketch.Point{ .{ .x = 1, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = 3 } };
        const es = [_]sketch.EdgePath{ walkEdge(3, &p3), walkEdge(8, &p8) };
        const members = [_]ledger.EdgeId{ 3, 8 };
        const bundle_sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &members }};
        var s = walkSketch(&es);
        s.bundle_sets = &bundle_sets;
        _ = try edge_walk.rasterizeEdges(a, &lat, s, .bridge, &c);

        const table = c.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(lat.cellIndex(4, 4), table[0].cell);
        try testing.expectEqual(lattice.AuxKind.carrier, table[0].kind);
        try testing.expectEqual(@as(u32, 8), table[0].value);
        try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged_licensed), table[0].detail);
        const shared = lat.atConst(4, 4);
        try testing.expectEqual(@as(u32, 3), shared.occupant.edge_segment.edge);
        try testing.expect(shared.neighbours.w);
    }

    {
        var lat = try walkLattice(a, 10, 10);
        var c = aux.Collector.init(a);
        const pts = [_]sketch.Point{
            .{ .x = 1, .y = 3 }, .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 5 },
            .{ .x = 3, .y = 5 }, .{ .x = 3, .y = 3 }, .{ .x = 1, .y = 3 },
        };
        const es = [_]sketch.EdgePath{walkEdge(2, &pts)};
        _ = try edge_walk.rasterizeEdges(a, &lat, walkSketch(&es), .bridge, &c);

        try testing.expectEqual(@as(usize, 0), c.finish().len);
        try testing.expectEqual(@as(u32, 2), lat.atConst(3, 3).occupant.edge_segment.edge);
    }
}

test "a refused arrowhead transit files a suppressed carrier for the crossed run" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lat = try blankLattice(a);
    var lost: u32 = 0;
    var hlost: u32 = 0;

    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };

    var c = aux.Collector.init(a);
    const rec = aux.Recorder.init(&c, &lat);
    var cell = lattice.Cell{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
        .neighbours = .{ .e = true, .w = true },
    };
    ew.writeArrowGuarded(&cell, 9, .solid, .filled, .south, .{ .n = true }, 2, 2, &lost, &hlost, ctx, rec);

    try testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
    const table = c.finish();
    try testing.expectEqual(@as(usize, 1), table.len);
    try testing.expectEqual(@as(u32, 3), table[0].value);
    try testing.expectEqual(@intFromEnum(lattice.CarrierKind.suppressed), table[0].detail);
}

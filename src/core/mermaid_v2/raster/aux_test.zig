//! Unit tests for raster/aux.zig — the lattice side-table builder — and for
//! the one fact it carries today (`.port`, filed by `drawPortStroke`).
//!
//! The load-bearing test here is the last one: the channel's whole premise
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
const roles = @import("edge_roles.zig");
const reconcile = @import("reconcile.zig");
const arrow_base = @import("arrow_base.zig");
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

test "collector sorts by (cell, kind, value) and keeps producer order on ties" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var c = aux.Collector.init(arena.allocator());
    // Synthetic details: the ORDER must be a property of the engine, not of
    // whichever kinds happen to exist today.
    aux.record(&c, 9, .port, 1, 0);
    aux.record(&c, 4, .port, 7, 0);
    aux.record(&c, 4, .port, 2, 0);
    aux.record(&c, 4, .port, 2, 11); // ties with the previous record on the key
    aux.record(&c, 4, .port, 2, 22); // ... and so does this one

    const table = c.finish();
    try testing.expectEqual(@as(usize, 5), table.len);
    try testing.expectEqual(@as(u32, 0), c.dropped);

    // (cell, kind, value) ascending.
    try testing.expectEqual(@as(u32, 4), table[0].cell);
    try testing.expectEqual(@as(u32, 2), table[0].value);
    try testing.expectEqual(@as(u32, 2), table[1].value);
    try testing.expectEqual(@as(u32, 2), table[2].value);
    try testing.expectEqual(@as(u32, 7), table[3].value);
    try testing.expectEqual(@as(u32, 9), table[4].cell);

    // Stable: the three key-equal records keep the order they were filed in,
    // so a table built from a deterministic raster is itself deterministic.
    try testing.expectEqual(@as(u8, 0), table[0].detail);
    try testing.expectEqual(@as(u8, 11), table[1].detail);
    try testing.expectEqual(@as(u8, 22), table[2].detail);
}

test "a null sink is the off switch: recording is a no-op" {
    // No Collector exists, so no allocator is reachable from here: a
    // non-collecting rasterization cannot allocate for the channel.
    const sink: aux.Sink = null;
    aux.record(sink, 0, .port, 1, 0);
    aux.record(sink, 7, .port, 2, 0);
}

test "drawPortStroke files a port record only for a stroke it actually draws" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Drawn: a solid edge exiting the border southwards.
    {
        var lat = try sourceBorderLattice(a);
        var c = aux.Collector.init(a);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
        ew.drawPortStroke(&lat, &pts, .solid, 42, &c);
        const table = c.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(lat.cellIndex(0, 0), table[0].cell);
        try testing.expectEqual(lattice.AuxKind.port, table[0].kind);
        try testing.expectEqual(@as(u32, 42), table[0].value); // the attaching edge
        try testing.expectEqual(@as(u8, 0), table[0].detail); // direction is a Cell fact
    }

    // Refused (invisible edge): no ink, therefore no record. The channel
    // records what was drawn, never what was intended.
    {
        var lat = try sourceBorderLattice(a);
        var c = aux.Collector.init(a);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
        ew.drawPortStroke(&lat, &pts, .invisible, 42, &c);
        try testing.expectEqual(@as(usize, 0), c.finish().len);
    }

    // Refused (no node_border under the departure point): likewise nothing.
    {
        var lat = try sourceBorderLattice(a);
        lat.at(0, 0).* = lattice.Cell.empty;
        var c = aux.Collector.init(a);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
        ew.drawPortStroke(&lat, &pts, .solid, 42, &c);
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

test "collect_aux is opt-in: the same raster yields no table when it is off" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try stackedPairSketch(a);

    const off = try raster.rasterize(a, s, .bridge, .{});
    try testing.expectEqual(@as(usize, 0), off.lattice.aux.len);

    const on = try raster.rasterize(a, s, .bridge, .{ .collect_aux = true });
    try testing.expect(on.lattice.aux.len > 0);

    // Off vs on differ ONLY in the side table: the painted grid is identical.
    try testing.expectEqual(off.lattice.width, on.lattice.width);
    try testing.expectEqual(off.lattice.height, on.lattice.height);
    for (off.lattice.cells, on.lattice.cells) |x, y| {
        try testing.expectEqual(x.neighbours.toMask(), y.neighbours.toMask());
        try testing.expectEqual(x.stroke_kind, y.stroke_kind);
        try testing.expectEqual(x.shape, y.shape);
        try testing.expectEqual(std.meta.activeTag(x.occupant), std.meta.activeTag(y.occupant));
    }
}

test "aux records survive the three post-walk mutating passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try stackedPairSketch(a);

    // The record below is filed DURING the edge walk. Everything the
    // orchestrator runs afterwards — fan role stamping, neighbour
    // reconciliation + reciprocity repair, and arrowhead-base receiving —
    // rewrites cells in place. The record is still here at the end.
    const report = try raster.rasterize(a, s, .bridge, .{ .collect_aux = true });
    var lat = report.lattice;

    const port_cell = lat.cellIndex(2, 2);
    var found: usize = 0;
    for (lat.aux) |r| {
        if (r.kind != .port) continue;
        found += 1;
        try testing.expectEqual(port_cell, r.cell);
        try testing.expectEqual(@as(u32, 7), r.value); // the departing edge id
    }
    try testing.expectEqual(@as(usize, 1), found);

    // Snapshot, then run the three post-walk passes AGAIN over the shipped
    // lattice and, harsher than any of them, blank the recorded cell
    // outright. A record is keyed by position, not by occupant, so none of
    // this may disturb it.
    const before = try a.dupe(lattice.Aux, lat.aux);
    roles.stampFanTrunks(&lat);
    _ = reconcile.reconcileNeighbours(&lat);
    _ = reconcile.repairReciprocalStrokes(&lat);
    _ = arrow_base.receiveBase(&lat);
    lat.at(2, 2).* = lattice.Cell.empty;

    try testing.expectEqual(before.len, lat.aux.len);
    for (before, lat.aux) |b, after| {
        try testing.expectEqual(b.cell, after.cell);
        try testing.expectEqual(b.kind, after.kind);
        try testing.expectEqual(b.value, after.value);
        try testing.expectEqual(b.detail, after.detail);
    }
}

// -- Carrier records ---------------------------------------------------------

/// A 4x4 lattice, so a Recorder built from it keys records the way the
/// production one does (`y * width + x`).
fn blankLattice(a: std.mem.Allocator) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, 16);
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = 4, .height = 4, .cells = cells };
}

/// A blank w×h lattice, plus the minimal Sketch/EdgePath pair that drives
/// `rasterizeEdges` — the only way to reach the walk's own corner-cell arm.
/// The Sketch carries no joins, so the crossing rule is inert.
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
    // The inert default is what every synthetic caller uses, so it must be
    // reachable without constructing anything.
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

    // Foreign: edge 8 merges onto edge 3's run. The cell keeps edge 3, so
    // edge 8's presence is exactly what it cannot express.
    {
        var c = aux.Collector.init(a);
        const rec = aux.Recorder.init(&c, &lat);
        var cell = lattice.Cell{
            .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
            .neighbours = .{ .e = true, .w = true },
        };
        ew.writeEdgeCell(&cell, 8, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, rec);
        const table = c.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(lattice.AuxKind.carrier, table[0].kind);
        try testing.expectEqual(@as(u32, 8), table[0].value);
        try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged), table[0].detail);
        // The Cell still names the first writer: no restatement, no drift.
        try testing.expectEqual(@as(u32, 3), cell.occupant.edge_segment.edge);
    }

    // Own ink: nothing anonymous happened, so nothing is recorded.
    {
        var c = aux.Collector.init(a);
        const rec = aux.Recorder.init(&c, &lat);
        var cell = lattice.Cell{
            .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
            .neighbours = .{ .e = true, .w = true },
        };
        ew.writeEdgeCell(&cell, 3, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, rec);
        try testing.expectEqual(@as(usize, 0), c.finish().len);
    }

    // An empty cell is claimed outright: the Cell names the writer.
    {
        var c = aux.Collector.init(a);
        const rec = aux.Recorder.init(&c, &lat);
        var cell = lattice.Cell.empty;
        ew.writeEdgeCell(&cell, 8, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost, rec);
        try testing.expectEqual(@as(usize, 0), c.finish().len);
    }
}

test "an arrowhead stamped over a foreign run files a carrier for the run it covered" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lat = try blankLattice(a);
    var lost: u32 = 0;

    var c = aux.Collector.init(a);
    const rec = aux.Recorder.init(&c, &lat);
    var cell = lattice.Cell{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
        .neighbours = .{ .e = true, .w = true },
    };
    ew.writeArrowCell(&cell, 9, .solid, .filled, .south, .{ .n = true }, 2, 2, &lost, rec);

    const table = c.finish();
    try testing.expectEqual(@as(usize, 1), table.len);
    // The occupant is now edge 9's arrowhead; edge 3's run still passes
    // through the position and nothing on the cell says so.
    try testing.expectEqual(@as(u32, 3), table[0].value);
    try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged), table[0].detail);
}

test "a corner arm merged onto a foreign run files a merged carrier; onto its own ink, nothing" {
    // The walk writes corner cells itself instead of going through
    // `writeEdgeCell`, so its merge arm is a SECOND id-dropping site with the
    // same consequence: the arm lands in the mask under the first writer's
    // name. Driven through `rasterizeEdges` because that arm is reachable
    // only from the walk.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Edge 3 runs straight down column 4; edge 8 arrives from the west and
    // turns north ON that run. A co-set makes them ONE channel, so the
    // (unconditional) crossing rule exempts the pair and the merge — not a
    // refusal — is what happens.
    {
        var lat = try walkLattice(a, 10, 10);
        var c = aux.Collector.init(a);
        const p3 = [_]sketch.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 7 } };
        const p8 = [_]sketch.Point{ .{ .x = 1, .y = 4 }, .{ .x = 4, .y = 4 }, .{ .x = 4, .y = 3 } };
        const es = [_]sketch.EdgePath{ walkEdge(3, &p3), walkEdge(8, &p8) };
        const members = [_]ledger.EdgeId{ 3, 8 };
        const co_sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &members }};
        var s = walkSketch(&es);
        s.co_sets = &co_sets;
        _ = try edge_walk.rasterizeEdges(a, &lat, s, .bridge, &c);

        const table = c.finish();
        try testing.expectEqual(@as(usize, 1), table.len);
        try testing.expectEqual(lat.cellIndex(4, 4), table[0].cell);
        try testing.expectEqual(lattice.AuxKind.carrier, table[0].kind);
        try testing.expectEqual(@as(u32, 8), table[0].value);
        // Merged, not suppressed: the corner arm IS in the mask (the west
        // bit), and only edge 8's name was dropped.
        try testing.expectEqual(@intFromEnum(lattice.CarrierKind.merged), table[0].detail);
        const shared = lat.atConst(4, 4);
        try testing.expectEqual(@as(u32, 3), shared.occupant.edge_segment.edge);
        try testing.expect(shared.neighbours.w);
    }

    // Own ink: one edge whose last leg corners back onto a cell it laid down
    // itself. The cell already names it, so a record would restate a Cell
    // field.
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

    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };

    var c = aux.Collector.init(a);
    const rec = aux.Recorder.init(&c, &lat);
    var cell = lattice.Cell{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
        .neighbours = .{ .e = true, .w = true },
    };
    ew.writeArrowGuarded(&cell, 9, .solid, .filled, .south, .{ .n = true }, 2, 2, &lost, ctx, rec);

    try testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
    const table = c.finish();
    try testing.expectEqual(@as(usize, 1), table.len);
    try testing.expectEqual(@as(u32, 3), table[0].value);
    // Suppressed, not merged: the refusal dropped edge 3's bits as well as
    // its name, so the cell carries no trace of it at all.
    try testing.expectEqual(@intFromEnum(lattice.CarrierKind.suppressed), table[0].detail);
}

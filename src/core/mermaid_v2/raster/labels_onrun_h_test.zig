//! Unit tests for raster/labels_onrun_h.zig — the INLINE horizontal on-run
//! label (`──── label ────`): OWN-INK RULE (edge-only private run ink, double
//! enforced), FLANKED-RESUMPTION RULE (full-stroke flanks left and right), isolation,
//! infeasible fall-through, determinism, and the vertical/horizontal tie
//! order fixed in labels_onrun.zig.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const onrun = @import("labels_onrun.zig");
const lw = @import("labels_write.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn emptySketch(bw: u32, bh: u32) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = bw, .h = bh },
        .direction = .LR,
        .nodes = &[_]sketch.NodePlacement{},
        .clusters = &[_]sketch.ClusterFrame{},
        .edges = &[_]sketch.EdgePath{},
        .diagnostics = &[_]sketch.Diagnostic{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

/// One horizontal private run cell of `edge` at (x, y).
fn runCell(lat: *lattice.Lattice, x: u32, y: u32, edge: u32, role: lattice.EdgeRole, kind: lattice.EdgeKind) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge, .kind = kind, .role = role } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = kind,
    };
}

/// One vertical private dropper cell of `edge` at (x, y).
fn dropCell(lat: *lattice.Lattice, x: u32, y: u32, edge: u32, role: lattice.EdgeRole) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid, .role = role } },
        .neighbours = .{ .n = true, .s = true },
    };
}

fn labelCharAt(lat: lattice.Lattice, x: u32, y: u32) u21 {
    return switch (lat.atConst(x, y).occupant) {
        .label_char => |c| c,
        else => 0,
    };
}

fn paintRun(lat: *lattice.Lattice, x0: u32, x1: u32, y: u32, edge: u32, kind: lattice.EdgeKind) void {
    var x = x0;
    while (x <= x1) : (x += 1) runCell(lat, x, y, edge, .forward, kind);
}

/// A straight LR edge whose polyline runs (2,4) → (12,4): strict interior
/// columns 3..11, painted as this edge's own private forward run.
fn straightEdge(poly: []const sketch.Point, kind: lattice.EdgeKind) sketch.EdgePath {
    return .{
        .id = 7,
        .from = 0,
        .to = 1,
        .polyline = poly,
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = "ok",
        .kind = kind,
        .role = .forward,
    };
}

const long_poly = [_]sketch.Point{ .{ .x = 2, .y = 4 }, .{ .x = 12, .y = 4 } };
/// Exactly the minimum feasible shape: interior 3..6 = label(2) + 2 flanks.
const tight_poly = [_]sketch.Point{ .{ .x = 2, .y = 4 }, .{ .x = 7, .y = 4 } };

test "happy path: the label sits inline in its own horizontal run, flanked both sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 16, 9);
    paintRun(&lat, 3, 11, 4, 7, .solid);
    const ep = straightEdge(&long_poly, .solid);
    var s = emptySketch(16, 9);
    const edges = [_]sketch.EdgePath{ep};
    s.edges = &edges;

    try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));

    try testing.expectEqual(@as(u21, 'o'), labelCharAt(lat, 6, 4));
    try testing.expectEqual(@as(u21, 'k'), labelCharAt(lat, 7, 4));

    for ([_]u32{ 5, 8 }) |x| {
        const c = lat.atConst(x, 4);
        try testing.expect(c.occupant == .edge_segment);
        try testing.expectEqual(@as(u32, 7), c.occupant.edge_segment.edge);
        try testing.expect(c.neighbours.e);
        try testing.expect(c.neighbours.w);
    }
}

test "the inline flanks keep the edge's own stroke kind on both sides" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_]lattice.EdgeKind{ .solid, .dotted, .thick }) |kind| {
        var lat = try makeLattice(a, 16, 9);
        paintRun(&lat, 3, 11, 4, 7, kind);
        const ep = straightEdge(&long_poly, kind);
        var s = emptySketch(16, 9);
        const edges = [_]sketch.EdgePath{ep};
        s.edges = &edges;

        try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
        for ([_]u32{ 5, 8 }) |x| {
            const c = lat.atConst(x, 4);
            try testing.expectEqual(kind, c.stroke_kind);
            try testing.expectEqual(kind, c.occupant.edge_segment.kind);
            try testing.expect(c.neighbours.e and c.neighbours.w);
        }
    }
}

test "OWN-INK RULE: a shared crossbar cell inside the stretch refuses the inline label" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 16, 9);
    paintRun(&lat, 3, 6, 4, 7, .solid);
    runCell(&lat, 4, 4, 7, .fan_out_rail, .solid);
    const ep = straightEdge(&tight_poly, .solid);
    var s = emptySketch(16, 9);
    const edges = [_]sketch.EdgePath{ep};
    s.edges = &edges;

    try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
    try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 4, 4));
}

test "OWN-INK RULE: a foreign-crossed stretch is refused by the geometry sweep" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 16, 9);
    paintRun(&lat, 3, 6, 4, 7, .solid);
    const ep = straightEdge(&tight_poly, .solid);
    const other_poly = [_]sketch.Point{ .{ .x = 4, .y = 1 }, .{ .x = 4, .y = 7 } };
    var other = straightEdge(&other_poly, .solid);
    other.id = 9;
    other.label = null;
    var s = emptySketch(16, 9);
    const edges = [_]sketch.EdgePath{ ep, other };
    s.edges = &edges;

    try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
    try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 4, 4));
}

test "FLANKED-RESUMPTION RULE: a corner or an arrowhead in the flank cell refuses the candidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var lat = try makeLattice(a, 16, 9);
        paintRun(&lat, 3, 6, 4, 7, .solid);
        lat.at(3, 4).neighbours.n = true;
        const ep = straightEdge(&tight_poly, .solid);
        var s = emptySketch(16, 9);
        const edges = [_]sketch.EdgePath{ep};
        s.edges = &edges;
        try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
        try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 4, 4));
    }

    {
        var lat = try makeLattice(a, 16, 9);
        paintRun(&lat, 3, 5, 4, 7, .solid);
        lat.at(6, 4).* = .{
            .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 7 } },
            .neighbours = .{ .w = true },
        };
        const ep = straightEdge(&tight_poly, .solid);
        var s = emptySketch(16, 9);
        const edges = [_]sketch.EdgePath{ep};
        s.edges = &edges;
        try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
        try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 4, 4));
    }
}

test "a too-short horizontal run falls through to the ordinary ladder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 16, 9);
    paintRun(&lat, 3, 5, 4, 7, .solid);
    const short_poly = [_]sketch.Point{ .{ .x = 2, .y = 4 }, .{ .x = 6, .y = 4 } };
    const ep = straightEdge(&short_poly, .solid);
    var s = emptySketch(16, 9);
    const edges = [_]sketch.EdgePath{ep};
    s.edges = &edges;

    try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
    var x: u32 = 3;
    while (x <= 5) : (x += 1) try testing.expect(lat.atConst(x, 4).occupant == .edge_segment);
}

test "foreign ink above the inline span refuses the candidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 16, 9);
    paintRun(&lat, 3, 6, 4, 7, .solid);
    runCell(&lat, 4, 3, 99, .forward, .solid);
    const ep = straightEdge(&tight_poly, .solid);
    var s = emptySketch(16, 9);
    const edges = [_]sketch.EdgePath{ep};
    s.edges = &edges;

    try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
    try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 4, 4));
}

test "determinism: identical inputs place the inline label identically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat1 = try makeLattice(a, 16, 9);
    var lat2 = try makeLattice(a, 16, 9);
    paintRun(&lat1, 3, 11, 4, 7, .solid);
    paintRun(&lat2, 3, 11, 4, 7, .solid);
    const ep = straightEdge(&long_poly, .solid);
    var s = emptySketch(16, 9);
    const edges = [_]sketch.EdgePath{ep};
    s.edges = &edges;

    try testing.expect(onrun.tryOnRunEdge(&lat1, s, ep, lw.asciiRun("ok"), null));
    try testing.expect(onrun.tryOnRunEdge(&lat2, s, ep, lw.asciiRun("ok"), null));
    for (lat1.cells, lat2.cells) |c1, c2| {
        try testing.expect(std.meta.eql(c1, c2));
    }
}

/// An elbow that offers BOTH forms: a vertical dropper on column 5 (rows
/// 2..5 private) and a horizontal run on row 6 starting at column 6.
fn elbow(poly: []const sketch.Point) sketch.EdgePath {
    var ep = straightEdge(poly, .solid);
    ep.port_from = .{ .node = 0, .side = .south, .offset = 0 };
    ep.port_to = .{ .node = 1, .side = .west, .offset = 0 };
    return ep;
}

test "tie order: the longer qualifying stretch is tried first, ties go vertical" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var lat = try makeLattice(a, 18, 10);
        for ([_]u32{ 2, 3, 4, 5 }) |y| dropCell(&lat, 5, y, 7, .fan_out_dropper);
        paintRun(&lat, 6, 13, 6, 7, .solid);
        const poly = [_]sketch.Point{ .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 6 }, .{ .x = 14, .y = 6 } };
        const ep = elbow(&poly);
        var s = emptySketch(18, 10);
        const edges = [_]sketch.EdgePath{ep};
        s.edges = &edges;

        try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
        try testing.expectEqual(@as(u21, 'o'), labelCharAt(lat, 9, 6));
        try testing.expectEqual(@as(u21, 'k'), labelCharAt(lat, 10, 6));
        try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 5, 3));
    }

    {
        var lat = try makeLattice(a, 18, 10);
        for ([_]u32{ 2, 3, 4, 5 }) |y| dropCell(&lat, 5, y, 7, .fan_out_dropper);
        paintRun(&lat, 6, 9, 6, 7, .solid);
        const poly = [_]sketch.Point{ .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 6 }, .{ .x = 10, .y = 6 } };
        const ep = elbow(&poly);
        var s = emptySketch(18, 10);
        const edges = [_]sketch.EdgePath{ep};
        s.edges = &edges;

        try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
        try testing.expectEqual(@as(u21, 'o'), labelCharAt(lat, 5, 3));
        try testing.expectEqual(@as(u21, 'k'), labelCharAt(lat, 6, 3));
        try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 7, 6));
    }
}

test "OWN-INK RULE: a private prefix of a collinear shared run is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const foreign_poly = [_]sketch.Point{ .{ .x = 12, .y = 4 }, .{ .x = 14, .y = 4 } };
    var foreign = straightEdge(&foreign_poly, .solid);
    foreign.id = 9;
    const ep = straightEdge(&long_poly, .solid);

    {
        var lat = try makeLattice(a, 16, 9);
        paintRun(&lat, 3, 11, 4, 7, .solid);
        paintRun(&lat, 12, 14, 4, 9, .solid);
        var s = emptySketch(16, 9);
        const edges = [_]sketch.EdgePath{ ep, foreign };
        s.edges = &edges;
        try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
    }

    {
        var lat = try makeLattice(a, 16, 9);
        paintRun(&lat, 3, 11, 4, 7, .solid);
        paintRun(&lat, 13, 14, 4, 9, .solid);
        var s = emptySketch(16, 9);
        const edges = [_]sketch.EdgePath{ ep, foreign };
        s.edges = &edges;
        try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, lw.asciiRun("ok"), null));
        try testing.expectEqual(@as(u21, 'o'), labelCharAt(lat, 6, 4));
    }
}

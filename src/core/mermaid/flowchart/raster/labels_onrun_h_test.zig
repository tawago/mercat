const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const onrun = @import("labels_onrun.zig");
const lw = @import("labels_write.zig");

fn asciiRun(comptime text: []const u8) lw.Run {
    const cells = comptime blk: {
        var out: [text.len]lw.LabelCell = undefined;
        for (text, 0..) |byte, i| out[i] = .{ .value = byte, .span = 1 };
        break :blk out;
    };
    return .{ .cells = &cells, .cell_count = text.len, .width = text.len };
}

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

fn runCell(lat: *lattice.Lattice, x: u32, y: u32, edge: u32, role: lattice.EdgeRole, kind: lattice.EdgeKind) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge, .kind = kind, .role = role } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = kind,
    };
}

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

    try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, asciiRun("ok")));

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

test "inline label refusals: shared crossbar cell, foreign-crossed stretch, corner or head flank, too-short run, foreign ink above" {
    const Mutation = enum { crossbar_cell, foreign_crossing, corner_flank, head_flank, too_short, foreign_above };
    const other_poly = [_]sketch.Point{ .{ .x = 4, .y = 1 }, .{ .x = 4, .y = 7 } };
    const short_poly = [_]sketch.Point{ .{ .x = 2, .y = 4 }, .{ .x = 6, .y = 4 } };
    for (std.enums.values(Mutation)) |m| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lat = try makeLattice(arena.allocator(), 16, 9);
        const short = m == .head_flank or m == .too_short;
        paintRun(&lat, 3, if (short) 5 else 6, 4, 7, .solid);
        switch (m) {
            .crossbar_cell => runCell(&lat, 4, 4, 7, .fan_out_rail, .solid),
            .corner_flank => lat.at(3, 4).neighbours.n = true,
            .head_flank => lat.at(6, 4).* = .{ .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 7 } }, .neighbours = .{ .w = true } },
            .foreign_above => runCell(&lat, 4, 3, 99, .forward, .solid),
            .foreign_crossing, .too_short => {},
        }
        const ep = straightEdge(if (m == .too_short) &short_poly else &tight_poly, .solid);
        var other = straightEdge(&other_poly, .solid);
        other.id = 9;
        other.label = null;
        const edges = [_]sketch.EdgePath{ ep, other };
        var s = emptySketch(16, 9);
        s.edges = if (m == .foreign_crossing) &edges else edges[0..1];

        try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, asciiRun("ok")));
        var x: u32 = 3;
        while (x <= 5) : (x += 1) try testing.expect(lat.atConst(x, 4).occupant == .edge_segment);
    }
}

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

        try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, asciiRun("ok")));
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

        try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, asciiRun("ok")));
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
        try testing.expect(!onrun.tryOnRunEdge(&lat, s, ep, asciiRun("ok")));
    }

    {
        var lat = try makeLattice(a, 16, 9);
        paintRun(&lat, 3, 11, 4, 7, .solid);
        paintRun(&lat, 13, 14, 4, 9, .solid);
        var s = emptySketch(16, 9);
        const edges = [_]sketch.EdgePath{ ep, foreign };
        s.edges = &edges;
        try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, asciiRun("ok")));
        try testing.expectEqual(@as(u21, 'o'), labelCharAt(lat, 6, 4));
    }
}

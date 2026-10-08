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
        .direction = .TD,
        .nodes = &[_]sketch.NodePlacement{},
        .clusters = &[_]sketch.ClusterFrame{},
        .edges = &[_]sketch.EdgePath{},
        .diagnostics = &[_]sketch.Diagnostic{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn dropCell(lat: *lattice.Lattice, x: u32, y: u32, edge: u32, role: lattice.EdgeRole) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid, .role = role } },
        .neighbours = .{ .n = true, .s = true },
    };
}

fn arrowCell(lat: *lattice.Lattice, x: u32, y: u32, edge: u32) void {
    lat.at(x, y).* = .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = edge } },
        .neighbours = .{ .n = true },
    };
}

fn labelCharAt(lat: lattice.Lattice, x: u32, y: u32) u21 {
    return switch (lat.atConst(x, y).occupant) {
        .label_char => |c| c,
        else => 0,
    };
}

fn paintTapDropper(lat: *lattice.Lattice, edge: u32) void {
    dropCell(lat, 5, 1, edge, .fan_out_rail);
    dropCell(lat, 5, 2, edge, .fan_out_dropper);
    dropCell(lat, 5, 3, edge, .fan_out_dropper);
    dropCell(lat, 5, 4, edge, .fan_out_dropper);
    arrowCell(lat, 5, 5, edge);
}

fn theTap(edge: u32) sketch.Tap {
    return .{ .edge = edge, .node = 1, .at = .{ .x = 5, .y = 1 }, .landing = .{ .x = 5, .y = 6 }, .label = "ok" };
}

fn theRail(taps: []const sketch.Tap, stem: []const sketch.Point) sketch.Rail {
    return .{
        .pivot = 0,
        .stem = stem,
        .crossbar = .{ .{ .x = 2, .y = 1 }, .{ .x = 8, .y = 1 } },
        .taps = taps,
        .kind = .solid,
        .role = .fan_out_dropper,
    };
}

const stem_pts = [_]sketch.Point{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 1 } };

test "happy path: the label interrupts its own dropper for one row, sandwiched by run flanks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 12, 9);
    paintTapDropper(&lat, 7);
    const taps = [_]sketch.Tap{theTap(7)};
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    try testing.expect(onrun.tryOnRunTap(&lat, s, taps[0], asciiRun("ok")));

    try testing.expectEqual(@as(u21, 'o'), labelCharAt(lat, 5, 3));
    try testing.expectEqual(@as(u21, 'k'), labelCharAt(lat, 6, 3));

    const above = lat.atConst(5, 2);
    try testing.expect(above.occupant == .edge_segment);
    const below = lat.atConst(5, 4);
    try testing.expect(below.occupant == .edge_segment);
    try testing.expect(lat.atConst(5, 5).occupant == .arrowhead);
}

test "on-run tap refusals: head-adjacent row, rail cell, another tap's drop, 1-cell dropper, foreign ink beside" {
    const Mutation = enum { none, rail_cell, other_tap, foreign_beside };
    const Row = struct { head_y: u32, mutation: Mutation = .none, row: u32 = 3 };
    const rows = [_]Row{
        .{ .head_y = 4 }, // FLANKED-RESUMPTION: an arrowhead is not a flank
        .{ .head_y = 5, .mutation = .rail_cell }, // OWN-INK: a rail/crossbar cell is never interrupted
        .{ .head_y = 5, .mutation = .other_tap }, // OWN-INK: a cell another tap's drop covers
        .{ .head_y = 3, .row = 2 }, // FLANKED-RESUMPTION: a 1-cell private dropper
        .{ .head_y = 5, .mutation = .foreign_beside },
    };
    for (rows) |r| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var lat = try makeLattice(arena.allocator(), 12, 9);
        dropCell(&lat, 5, 1, 7, .fan_out_rail);
        var y: u32 = 2;
        while (y < r.head_y) : (y += 1) dropCell(&lat, 5, y, 7, .fan_out_dropper);
        arrowCell(&lat, 5, r.head_y, 7);
        if (r.mutation == .rail_cell) dropCell(&lat, 5, 3, 7, .fan_out_rail);
        if (r.mutation == .foreign_beside) dropCell(&lat, 7, 3, 99, .forward);
        const tap: sketch.Tap = .{ .edge = 7, .node = 1, .at = .{ .x = 5, .y = 1 }, .landing = .{ .x = 5, .y = @intCast(r.head_y + 1) }, .label = "ok" };
        const taps = [_]sketch.Tap{ tap, .{ .edge = 9, .node = 2, .at = .{ .x = 5, .y = 1 }, .landing = .{ .x = 5, .y = 5 } } };
        var s = emptySketch(12, 9);
        const rails = [_]sketch.Rail{theRail(if (r.mutation == .other_tap) &taps else taps[0..1], &stem_pts)};
        s.rails = &rails;

        try testing.expect(!onrun.tryOnRunTap(&lat, s, tap, asciiRun("ok")));
        try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 5, r.row));
    }
}

test "on-run placement over a routed polyline dropper (fan-IN member)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 14, 8);
    dropCell(&lat, 5, 1, 3, .fan_in_dropper);
    dropCell(&lat, 5, 2, 3, .fan_in_dropper);
    dropCell(&lat, 5, 3, 3, .fan_in_dropper);

    const poly = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 4 }, .{ .x = 9, .y = 4 } };
    const ep: sketch.EdgePath = .{
        .id = 3,
        .from = 0,
        .to = 1,
        .polyline = &poly,
        .port_from = .{ .node = 0, .side = .south, .offset = 0 },
        .port_to = .{ .node = 1, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = "grpc",
        .kind = .solid,
        .role = .fan_in_dropper,
    };
    var s = emptySketch(14, 8);
    const edges = [_]sketch.EdgePath{ep};
    s.edges = &edges;

    try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, asciiRun("grpc")));
    try testing.expectEqual(@as(u21, 'g'), labelCharAt(lat, 4, 2));
    try testing.expectEqual(@as(u21, 'r'), labelCharAt(lat, 5, 2));
    try testing.expectEqual(@as(u21, 'p'), labelCharAt(lat, 6, 2));
    try testing.expectEqual(@as(u21, 'c'), labelCharAt(lat, 7, 2));
    try testing.expect(lat.atConst(5, 1).neighbours.s);
    try testing.expect(lat.atConst(5, 3).neighbours.n);
}

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");
const prim = @import("prim");

const testing = std.testing;

fn makeLattice(allocator: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try allocator.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn makeSketch(es: []const sketch.EdgePath) sketch.Sketch {
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

fn makeEdge(
    id: u32,
    pts: []const sketch.Point,
    arrow_from: sketch.ArrowKind,
    arrow_to: sketch.ArrowKind,
) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 1,
        .polyline = pts,
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = arrow_from,
        .arrow_to = arrow_to,
        .label = null,
        .kind = .solid,
    };
}

test "single horizontal segment writes interior cells with E+W bits" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 } };
    var e = makeEdge(1, &pts, .none, .none);
    e.role = .back_edge;
    const es = [_]sketch.EdgePath{e};
    const report = edges.rasterizeEdges(&lat, makeSketch(&es), .bridge);
    try testing.expectEqual(@as(u32, 0), report.cells_lost);

    try testing.expect(switch (lat.atConst(2, 2).occupant) {
        .empty => true,
        else => false,
    });
    try testing.expect(switch (lat.atConst(6, 2).occupant) {
        .empty => true,
        else => false,
    });

    var x: u32 = 3;
    while (x <= 5) : (x += 1) {
        const cell = lat.atConst(x, 2);
        try testing.expect(switch (cell.occupant) {
            .edge_segment => |seg| seg.edge == 1 and seg.role == .back_edge,
            else => false,
        });
        try testing.expectEqual(
            (lattice.Neighbours{ .e = true, .w = true }).toMask(),
            cell.neighbours.toMask(),
        );
    }
}

test "arrowhead at end of polyline" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 4);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 } };
    const es = [_]sketch.EdgePath{makeEdge(42, &pts, .none, .filled)};
    _ = edges.rasterizeEdges(&lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(4, 0);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .east and ah.edge == 42,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "length-1 final segment after a corner points the terminal arrowhead into the port" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 8, 5);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 1 } };
    const es = [_]sketch.EdgePath{makeEdge(11, &pts, .none, .filled)};
    _ = edges.rasterizeEdges(&lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(5, 0);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 11,
        else => false,
    });
}

test "a co-member's corner arm into a head is refused" {
    const a = testing.allocator;
    const members = [_]u32{ 1, 2 };
    const Bundle = @typeInfo(@TypeOf((makeSketch(&.{})).sharing.bundles)).pointer.child;
    const mates = [_]Bundle{.{ .origin = .fan_rail, .members = &members }};

    for ([2]bool{ true, false }) |co_member| {
        var lat = try makeLattice(a, 12, 10);
        defer a.free(lat.cells);
        const pts_v = [_]sketch.Point{ .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 6 } };
        const pts_turn = [_]sketch.Point{ .{ .x = 1, .y = 5 }, .{ .x = 5, .y = 5 }, .{ .x = 5, .y = 3 } };
        const es = [_]sketch.EdgePath{
            makeEdge(1, &pts_v, .none, .filled),
            makeEdge(2, &pts_turn, .none, .none),
        };
        var s = makeSketch(&es);
        if (co_member) s.sharing.bundles = &mates;
        const report = edges.rasterizeEdges(&lat, s, .bridge);

        const head = lat.atConst(5, 5);
        try testing.expectEqual(@as(u32, 1), head.occupant.arrowhead.edge);
        try testing.expectEqual(lattice.Dir4.south, head.occupant.arrowhead.dir);
        try testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), head.neighbours.toMask());
        try testing.expectEqual(@as(u32, if (co_member) 0 else 1), report.crossings.arrowhead_transit_violation);
        try testing.expect(lat.atConst(4, 5).neighbours.e);
    }
}

test "degenerate polylines: a lone point and an all-duplicate run paint nothing; a duplicate point is skipped" {
    const a = testing.allocator;
    const lone = [_]sketch.Point{.{ .x = 1, .y = 1 }};
    const dups = [_]sketch.Point{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 } };
    const mid = [_]sketch.Point{ .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 5, .y = 1 } };
    for ([_][]const sketch.Point{ &lone, &dups, &mid }) |pts| {
        var lat = try makeLattice(a, 10, 4);
        defer a.free(lat.cells);
        const es = [_]sketch.EdgePath{makeEdge(3, pts, .none, .none)};
        _ = edges.rasterizeEdges(&lat, makeSketch(&es), .bridge);
        var painted: u32 = 0;
        for (lat.cells) |c| painted += @intFromBool(c.occupant != .empty);
        try testing.expectEqual(@as(u32, if (pts.len == 3) 3 else 0), painted);
        if (pts.len == 3) {
            var x: u32 = 2;
            while (x <= 4) : (x += 1) try testing.expectEqual(@as(u32, 3), lat.atConst(x, 1).occupant.edge_segment.edge);
        }
    }
}

test "edge cells colliding with node-owned cells are counted as lost" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    var x: u32 = 3;
    while (x <= 5) : (x += 1) {
        lat.at(x, 2).* = .{
            .occupant = .{ .node_interior = 7 },
            .neighbours = .{},
        };
    }

    const pts = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 8, .y = 2 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .none)};
    const report = edges.rasterizeEdges(&lat, makeSketch(&es), .bridge);

    try testing.expectEqual(@as(u32, 3), report.cells_lost);
    try testing.expect(lat.atConst(4, 2).occupant == .node_interior);
}

fn stampBorder(lat: *lattice.Lattice, x: u32, y: u32, mask: lattice.Neighbours) void {
    lat.at(x, y).* = .{
        .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } },
        .neighbours = mask,
    };
}

test "a subgraph frame border: bridge mode keeps it under a through-crossing and refuses a corner arm; cross mode welds both" {
    const a = testing.allocator;
    const N = lattice.Neighbours;
    const through = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 8 } };
    const corner = [_]sketch.Point{ .{ .x = 2, .y = 5 }, .{ .x = 6, .y = 5 }, .{ .x = 6, .y = 9 } };
    const Row = struct { mode: prim.SubgraphEdges, pts: []const sketch.Point, bx: u32, border: N, welded: bool, want: N };
    const rows = [_]Row{
        .{ .mode = .bridge, .pts = &through, .bx = 5, .border = .{ .e = true, .w = true }, .welded = false, .want = .{ .e = true, .w = true } },
        .{ .mode = .bridge, .pts = &corner, .bx = 6, .border = .{ .n = true, .s = true }, .welded = false, .want = .{ .n = true, .s = true } },
        .{ .mode = .cross, .pts = &through, .bx = 5, .border = .{ .e = true, .w = true }, .welded = true, .want = .{ .n = true, .e = true, .s = true, .w = true } },
        .{ .mode = .cross, .pts = &corner, .bx = 6, .border = .{ .n = true, .s = true }, .welded = true, .want = .{ .w = true, .s = true } },
    };
    for (rows) |r| {
        var lat = try makeLattice(a, 12, 12);
        defer a.free(lat.cells);
        stampBorder(&lat, r.bx, 5, r.border);
        const es = [_]sketch.EdgePath{makeEdge(1, r.pts, .none, .none)};
        _ = edges.rasterizeEdges(&lat, makeSketch(&es), r.mode);
        const cell = lat.atConst(r.bx, 5).*;
        if (r.welded) {
            try testing.expectEqual(@as(u32, 1), cell.occupant.edge_segment.edge);
        } else {
            try testing.expect(cell.occupant == .cluster_border);
        }
        try testing.expectEqual(r.want.toMask(), cell.neighbours.toMask());
        if (r.mode == .bridge and r.bx == 5) {
            try testing.expectEqual((N{ .n = true, .s = true }).toMask(), lat.atConst(5, 4).neighbours.toMask());
            try testing.expectEqual((N{ .n = true, .s = true }).toMask(), lat.atConst(5, 6).neighbours.toMask());
        }
    }
}

test "terminal segment cell on a frame border keeps today's merge" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 5, 6, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 7 } };
    const es = [_]sketch.EdgePath{makeEdge(9, &pts, .none, .none)};
    _ = edges.rasterizeEdges(&lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(5, 6).*;
    try testing.expect(switch (cell.occupant) {
        .edge_segment => |seg| seg.edge == 9,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "an arrowhead terminating on a frame border is stamped (arrival AT the cluster)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 5, 6, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 7 } };
    const es = [_]sketch.EdgePath{makeEdge(9, &pts, .none, .filled)};
    _ = edges.rasterizeEdges(&lat, makeSketch(&es), .bridge);

    const cell = lat.atConst(5, 6).*;
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 9,
        else => false,
    });
}

test "a member stroke paints neither port nor head at its rail end and both at a private end" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    const stem = [_]sketch.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 4 } };
    const taps = [_]sketch.Tap{
        .{ .edge = 6, .node = 2, .at = .{ .x = 4, .y = 4 }, .landing = .{ .x = 4, .y = 7 } },
        .{ .edge = 7, .node = 1, .at = .{ .x = 8, .y = 4 }, .landing = .{ .x = 8, .y = 5 }, .continues = true },
    };
    const rails = [_]sketch.Rail{.{ .pivot = 0, .stem = &stem, .crossbar = .{ .{ .x = 4, .y = 4 }, .{ .x = 8, .y = 4 } }, .taps = &taps, .kind = .solid }};
    const pts = [_]sketch.Point{ .{ .x = 8, .y = 4 }, .{ .x = 8, .y = 10 } };
    var stroke = makeEdge(7, &pts, .none, .filled);
    stroke.role = .member_stroke;
    stroke.port_from = .{ .node = 0, .side = .south, .offset = 0 };
    stroke.port_to = .{ .node = 1, .side = .north, .offset = 2 };
    const es = [_]sketch.EdgePath{stroke};
    var s = makeSketch(&es);
    s.rails = &rails;
    var x: u32 = 6;
    while (x <= 10) : (x += 1) lat.at(x, 10).* = .{
        .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } },
        .neighbours = .{ .e = x < 10, .w = x > 6 },
    };

    _ = edges.rasterizeEdges(&lat, s, .bridge);

    try testing.expect(lat.atConst(8, 4).occupant == .empty);
    try testing.expect(lat.atConst(8, 5).occupant != .arrowhead);
    try testing.expect(switch (lat.atConst(8, 9).occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 7,
        else => false,
    });
    try testing.expect(!lat.atConst(8, 10).neighbours.n);
}

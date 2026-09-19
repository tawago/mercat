const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");

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
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .none)};
    const written = (try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null)).edges_written;
    try testing.expectEqual(@as(u32, 1), written);

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
            .edge_segment => |seg| seg.edge == 1,
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
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

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
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    const cell = lat.atConst(5, 0);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 11,
        else => false,
    });
}

test "two foreign crossing edges read as a transversal, not a junction" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 10);
    defer a.free(lat.cells);

    const pts_h = [_]sketch.Point{ .{ .x = 1, .y = 5 }, .{ .x = 10, .y = 5 } };
    const pts_v = [_]sketch.Point{ .{ .x = 5, .y = 1 }, .{ .x = 5, .y = 9 } };
    const es = [_]sketch.EdgePath{
        makeEdge(1, &pts_h, .none, .none),
        makeEdge(2, &pts_v, .none, .none),
    };
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    const cell = lat.atConst(5, 5);
    try testing.expect(switch (cell.occupant) {
        .edge_segment => true,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "a co-member's corner arm into a head is refused, counted against the corner's edge, and the head keeps its state" {
    const a = testing.allocator;
    const members = [_]u32{ 1, 2 };
    const Bundle = @typeInfo(@TypeOf((makeSketch(&.{})).bundle_sets)).pointer.child;
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
        if (co_member) s.bundle_sets = &mates;
        const report = try edges.rasterizeEdges(a, &lat, s, .bridge, null);

        const head = lat.atConst(5, 5);
        try testing.expectEqual(@as(u32, 1), head.occupant.arrowhead.edge);
        try testing.expectEqual(lattice.Dir4.south, head.occupant.arrowhead.dir);
        try testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), head.neighbours.toMask());
        try testing.expectEqual(lattice.InkState.stroke, head.state);
        try testing.expectEqual(@as(u32, 1), report.crossings.arm_into_head);
        try testing.expectEqual(@as(u32, if (co_member) 0 else 1), report.crossings.arrowhead_transit_violation);
        try testing.expectEqual(@as(u32, 0), report.heads_lost);
        try testing.expect(lat.atConst(4, 5).neighbours.e);
    }
}

test "degenerate polyline with < 2 points is skipped" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 4, 4);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{.{ .x = 1, .y = 1 }};
    const es = [_]sketch.EdgePath{makeEdge(99, &pts, .none, .none)};
    const written = (try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null)).edges_written;
    try testing.expectEqual(@as(u32, 0), written);
}

test "EdgeRole round-trips from EdgePath into Cell.edge_segment.role" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 4);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 1, .y = 1 }, .{ .x = 7, .y = 1 } };
    var e = makeEdge(11, &pts, .none, .none);
    e.role = .back_edge;
    const es = [_]sketch.EdgePath{e};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    var x: u32 = 2;
    while (x <= 6) : (x += 1) {
        const cell = lat.atConst(x, 1);
        try testing.expect(switch (cell.occupant) {
            .edge_segment => |seg| seg.role == .back_edge and seg.edge == 11,
            else => false,
        });
    }
}

test "zero-length intermediate point is skipped" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 4);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{
        .{ .x = 1, .y = 1 },
        .{ .x = 1, .y = 1 },
        .{ .x = 5, .y = 1 },
    };
    const es = [_]sketch.EdgePath{makeEdge(3, &pts, .none, .none)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    var x: u32 = 2;
    while (x <= 4) : (x += 1) {
        try testing.expect(switch (lat.atConst(x, 1).occupant) {
            .edge_segment => |seg| seg.edge == 3,
            else => false,
        });
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
    const report = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    try testing.expectEqual(@as(u32, 3), report.cells_lost);
    try testing.expectEqual(@as(u32, 1), report.edges_written);
    try testing.expect(lat.atConst(4, 2).occupant == .node_interior);
}

test "collision-free edge reports zero cells lost" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 6, .y = 2 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .filled)};
    const report = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);
    try testing.expectEqual(@as(u32, 0), report.cells_lost);
}

fn stampBorder(lat: *lattice.Lattice, x: u32, y: u32, mask: lattice.Neighbours) void {
    lat.at(x, y).* = .{
        .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } },
        .neighbours = mask,
    };
}

test "through-crossing bridges a subgraph frame border" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 5, 5, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 8 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    const border = lat.atConst(5, 5).*;
    try testing.expect(border.occupant == .cluster_border);
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        border.neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        lat.atConst(5, 4).neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        lat.atConst(5, 6).neighbours.toMask(),
    );
    try testing.expectEqual(@as(u32, 1), r.crossings.b_frame_bridge);
    try testing.expectEqual(@as(u32, 0), r.crossings.b_border_fusion_refused);
}

test "terminal segment cell on a frame border keeps today's merge" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 5, 6, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 7 } };
    const es = [_]sketch.EdgePath{makeEdge(9, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    const cell = lat.atConst(5, 6).*;
    try testing.expect(switch (cell.occupant) {
        .edge_segment => |seg| seg.edge == 9,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
}

test "an arrowhead terminating on a frame border is stamped (arrival AT the cluster)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 5, 6, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 7 } };
    const es = [_]sketch.EdgePath{makeEdge(9, &pts, .none, .filled)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    const cell = lat.atConst(5, 6).*;
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 9,
        else => false,
    });
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
}

test "corner arm onto a subgraph frame border is refused" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 6, 5, .{ .n = true, .s = true });
    const pts = [_]sketch.Point{ .{ .x = 2, .y = 5 }, .{ .x = 6, .y = 5 }, .{ .x = 6, .y = 9 } };
    const es = [_]sketch.EdgePath{makeEdge(3, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    const border = lat.atConst(6, 5).*;
    try testing.expect(border.occupant == .cluster_border);
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        border.neighbours.toMask(),
    );
    try testing.expectEqual(@as(u32, 1), r.crossings.b_border_fusion_refused);
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
}

test "cross mode: through-crossing welds the frame border (pre-slice-1)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 5, 5, .{ .e = true, .w = true });
    const pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 8 } };
    const es = [_]sketch.EdgePath{makeEdge(1, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .cross, null);

    const border = lat.atConst(5, 5).*;
    try testing.expect(switch (border.occupant) {
        .edge_segment => |seg| seg.edge == 1,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        border.neighbours.toMask(),
    );
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
    try testing.expectEqual(@as(u32, 0), r.crossings.b_border_fusion_refused);
}

test "cross mode: corner arm onto a subgraph frame border welds a tee (pre-slice-1)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    stampBorder(&lat, 6, 5, .{ .n = true, .s = true });
    const pts = [_]sketch.Point{ .{ .x = 2, .y = 5 }, .{ .x = 6, .y = 5 }, .{ .x = 6, .y = 9 } };
    const es = [_]sketch.EdgePath{makeEdge(3, &pts, .none, .none)};
    const r = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .cross, null);

    const border = lat.atConst(6, 5).*;
    try testing.expect(switch (border.occupant) {
        .edge_segment => |seg| seg.edge == 3,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .w = true, .s = true }).toMask(),
        border.neighbours.toMask(),
    );
    try testing.expectEqual(@as(u32, 0), r.crossings.b_border_fusion_refused);
    try testing.expectEqual(@as(u32, 0), r.crossings.b_frame_bridge);
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

    _ = try edges.rasterizeEdges(a, &lat, s, .bridge, null);

    try testing.expect(lat.atConst(8, 4).occupant == .empty);
    try testing.expect(lat.atConst(8, 5).occupant != .arrowhead);
    try testing.expect(switch (lat.atConst(8, 9).occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 7,
        else => false,
    });
    try testing.expect(!lat.atConst(8, 10).neighbours.n);
}

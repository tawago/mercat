const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");
const ledger = @import("../base/ledger.zig");

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

fn makeEdge(id: u32, pts: []const sketch.Point) sketch.EdgePath {
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

test "L-shaped corner has reverse-incoming + outgoing bits" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{
        .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 6 },
        .{ .x = 6, .y = 6 },
    };
    const es = [_]sketch.EdgePath{makeEdge(7, &pts)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    const corner = lat.atConst(2, 6);
    try testing.expect(switch (corner.occupant) {
        .edge_segment => |seg| seg.edge == 7,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true }).toMask(),
        corner.neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        lat.atConst(2, 3).neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        lat.atConst(4, 6).neighbours.toMask(),
    );
}

test "a route that doubles back keeps both visits' arms at the cell it re-enters" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{
        .{ .x = 1, .y = 7 }, .{ .x = 2, .y = 7 }, .{ .x = 2, .y = 5 },
        .{ .x = 8, .y = 5 }, .{ .x = 2, .y = 5 }, .{ .x = 2, .y = 3 },
    };
    const es = [_]sketch.EdgePath{makeEdge(2, &pts)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true }).toMask(),
        lat.atConst(2, 5).neighbours.toMask(),
    );
    try testing.expect(lat.atConst(2, 6).neighbours.n);
    try testing.expectEqual(
        (lattice.Neighbours{ .w = true }).toMask(),
        lat.atConst(8, 5).neighbours.toMask(),
    );
}

test "shared rail corner: sibling drops bending at one cell yield ┴, not a phantom ┼" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    const a_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 2, .y = 5 }, .{ .x = 2, .y = 8 } };
    const b_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 4, .y = 5 }, .{ .x = 4, .y = 8 } };
    const c_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 8, .y = 5 }, .{ .x = 8, .y = 8 } };
    const es = [_]sketch.EdgePath{
        makeEdge(1, &a_pts),
        makeEdge(2, &b_pts),
        makeEdge(3, &c_pts),
    };
    const members = [_]ledger.EdgeId{ 1, 2, 3 };
    const bundle_sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &members }};
    var s = makeSketch(&es);
    s.bundle_sets = &bundle_sets;
    _ = try edges.rasterizeEdges(a, &lat, s, .bridge, null);

    const rail = lat.atConst(5, 5).neighbours;
    try testing.expect(rail.n and rail.e and rail.w);
    try testing.expect(!rail.s);

    const drop = lat.atConst(4, 5).neighbours;
    try testing.expect(drop.s);
}

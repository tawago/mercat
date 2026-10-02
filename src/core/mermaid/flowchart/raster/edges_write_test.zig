const std = @import("std");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");
const crossings = @import("crossings.zig");

const testing = std.testing;

fn borderCell(mask: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } },
        .neighbours = mask,
    };
}

fn southHead(edge: u32) lattice.Cell {
    return .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = edge, .arrow = .filled } },
        .neighbours = .{ .n = true, .s = true },
    };
}

test "writeEdgeCell: a terminal segment cell onto a cluster_border merges" {
    var cell = borderCell(.{ .e = true, .w = true });
    var lost: u32 = 0;
    edges.writeEdgeCell(&cell, 7, .solid, .forward, .{ .n = true, .s = true }, 3, 3, &lost);
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(switch (cell.occupant) {
        .edge_segment => |seg| seg.edge == 7,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "writeEdgeCell onto a foreign run keeps the first owner and ORs the arms" {
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
        .neighbours = .{ .e = true, .w = true },
    };
    var lost: u32 = 0;
    edges.writeEdgeCell(&cell, 8, .solid, .forward, .{ .n = true, .s = true }, 1, 1, &lost);
    try testing.expectEqual(@as(u32, 3), cell.occupant.edge_segment.edge);
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "writeArrowCell: an arrowhead may stamp onto a cluster_border" {
    var cell = borderCell(.{ .e = true, .w = true });
    var lost: u32 = 0;
    edges.writeArrowCell(&cell, 7, .solid, .filled, .south, .{ .n = true, .s = true }, 3, 3, &lost);
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 7,
        else => false,
    });
}

test "writeArrowCell stamps the edge's own stroke_kind" {
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .solid,
    };
    var lost: u32 = 0;
    edges.writeArrowCell(&cell, 9, .dotted, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.edge == 9,
        else => false,
    });
    try testing.expectEqual(lattice.EdgeKind.dotted, cell.stroke_kind);

    var empty = lattice.Cell.empty;
    edges.writeArrowCell(&empty, 4, .thick, .filled, .south, .{ .n = true, .s = true }, 0, 0, &lost);
    try testing.expectEqual(lattice.EdgeKind.thick, empty.stroke_kind);
}

test "writeArrowCell records the declared head style on the cell" {
    var plain = lattice.Cell.empty;
    var lost: u32 = 0;
    edges.writeArrowCell(&plain, 1, .solid, .open, .south, .{ .n = true }, 0, 0, &lost);
    try testing.expectEqual(lattice.ArrowKind.open, plain.occupant.arrowhead.arrow);

    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var refused: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
    };
    edges.writeArrowGuarded(&refused, 6, .solid, .cross, .east, .{ .e = true }, 1, 1, &lost, ctx);
    try testing.expectEqual(lattice.ArrowKind.cross, refused.occupant.arrowhead.arrow);
}

test "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind" {
    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .thick, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .thick,
    };
    var lost: u32 = 0;
    edges.writeArrowGuarded(&cell, 5, .solid, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost, ctx);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.edge == 5,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
    try testing.expectEqual(lattice.EdgeKind.solid, cell.stroke_kind);
    try testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}

test "an arrowhead landing on a same-way foreign arrowhead rides it" {
    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var cell = southHead(4);
    var lost: u32 = 0;
    edges.writeArrowGuarded(&cell, 9, .solid, .filled, .south, .{ .n = true, .s = true }, 2, 2, &lost, ctx);
    try testing.expectEqual(@as(u32, 4), cell.occupant.arrowhead.edge);
    try testing.expectEqual(@as(u32, 0), counts.arrowhead_transit_violation);
    try testing.expectEqual(@as(u32, 0), lost);
}

test "a head or run refused at a node collision counts a lost cell" {
    var border: lattice.Cell = .{
        .occupant = .{ .node_border = .{ .node = 3, .role = .edge_s } },
        .neighbours = .{},
    };
    var lost: u32 = 0;
    edges.writeArrowCell(&border, 7, .solid, .filled, .south, .{ .n = true, .s = true }, 0, 0, &lost);
    try testing.expectEqual(@as(u32, 1), lost);
    try testing.expect(border.occupant == .node_border);

    edges.writeEdgeCell(&border, 7, .solid, .forward, .{ .n = true, .s = true }, 0, 0, &lost);
    try testing.expectEqual(@as(u32, 2), lost);
    try testing.expect(border.occupant == .node_border);
}

test "a foreign lateral arm into a head is refused and counted against the writer" {
    var lost: u32 = 0;
    var cell = southHead(4);
    edges.writeEdgeCell(&cell, 9, .solid, .forward, .{ .n = true, .e = true }, 1, 1, &lost);
    try testing.expectEqual(@as(u32, 4), cell.occupant.arrowhead.edge);
    try testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), cell.neighbours.toMask());
    try testing.expectEqual(@as(u32, 1), lost);

    var through = southHead(4);
    edges.writeEdgeCell(&through, 9, .solid, .forward, .{ .e = true, .w = true }, 1, 1, &lost);
    try testing.expectEqual(@as(u32, 2), lost);
    try testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), through.neighbours.toMask());

    var riding = southHead(4);
    edges.writeEdgeCell(&riding, 9, .solid, .fan_in_dropper, .{ .n = true, .s = true }, 1, 1, &lost);
    try testing.expectEqual(@as(u32, 2), lost);
    try testing.expectEqual(@as(u32, 4), riding.occupant.arrowhead.edge);
}

test "a foreign head pointing another way is refused; one pointing the same way rides" {
    var lost: u32 = 0;

    var across = southHead(4);
    edges.writeArrowCell(&across, 9, .solid, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost);
    try testing.expectEqual(@as(u32, 4), across.occupant.arrowhead.edge);
    try testing.expectEqual(lattice.Dir4.south, across.occupant.arrowhead.dir);
    try testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), across.neighbours.toMask());
    try testing.expectEqual(@as(u32, 1), lost);

    var opposed = southHead(4);
    edges.writeArrowCell(&opposed, 9, .solid, .filled, .north, .{ .n = true, .s = true }, 1, 1, &lost);
    try testing.expectEqual(lattice.Dir4.south, opposed.occupant.arrowhead.dir);
    try testing.expectEqual(@as(u32, 2), lost);

    var same = southHead(4);
    edges.writeArrowCell(&same, 9, .solid, .filled, .south, .{ .n = true, .s = true }, 1, 1, &lost);
    try testing.expectEqual(@as(u32, 4), same.occupant.arrowhead.edge);
    try testing.expectEqual(@as(u32, 2), lost);

    var own = southHead(4);
    edges.writeArrowCell(&own, 4, .solid, .filled, .south, .{ .n = true, .s = true }, 1, 1, &lost);
    try testing.expectEqual(@as(u32, 2), lost);
}

test "mergeRole: a rail outranks a dropper, which outranks routing roles" {
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_rail,
        edges.mergeRole(.fan_out_rail, .fan_out_dropper),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_in_rail,
        edges.mergeRole(.fan_in_dropper, .fan_in_rail),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_dropper,
        edges.mergeRole(.back_edge, .fan_out_dropper),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_in_dropper,
        edges.mergeRole(.fan_in_dropper, .self_loop),
    );
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_dropper,
        edges.mergeRole(.forward, .fan_out_dropper),
    );
}

test "mergeRole: a same-tier arrival never displaces the first writer" {
    try testing.expectEqual(
        lattice.EdgeRole.fan_out_rail,
        edges.mergeRole(.fan_out_rail, .fan_in_rail),
    );
    try testing.expectEqual(
        lattice.EdgeRole.back_edge,
        edges.mergeRole(.back_edge, .self_loop),
    );
    try testing.expectEqual(
        lattice.EdgeRole.forward,
        edges.mergeRole(.forward, .forward),
    );
}

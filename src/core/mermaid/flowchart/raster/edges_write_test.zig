const std = @import("std");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");
const crossings = @import("crossings.zig");

const testing = std.testing;

fn southHead(edge: u32) lattice.Cell {
    return .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = edge, .arrow = .filled } },
        .neighbours = .{ .n = true, .s = true },
    };
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

test "a head write carries its stroke kind and head style on the plain and the guarded-refuse branch" {
    var lost: u32 = 0;
    var run: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .solid,
    };
    edges.writeArrowCell(&run, 9, .dotted, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost);
    try testing.expectEqual(@as(u32, 9), run.occupant.arrowhead.edge);
    try testing.expectEqual(lattice.EdgeKind.dotted, run.stroke_kind);

    var empty = lattice.Cell.empty;
    edges.writeArrowCell(&empty, 4, .thick, .open, .south, .{ .n = true, .s = true }, 0, 0, &lost);
    try testing.expectEqual(lattice.EdgeKind.thick, empty.stroke_kind);
    try testing.expectEqual(lattice.ArrowKind.open, empty.occupant.arrowhead.arrow);

    // The refuse branch replaces the mask (never ORs it) and counts the transit.
    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var refused: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .thick, .role = .forward } },
        .neighbours = .{ .n = true, .s = true },
        .stroke_kind = .thick,
    };
    edges.writeArrowGuarded(&refused, 5, .solid, .cross, .east, .{ .e = true, .w = true }, 1, 1, &lost, ctx);
    try testing.expectEqual(@as(u32, 5), refused.occupant.arrowhead.edge);
    try testing.expectEqual(lattice.ArrowKind.cross, refused.occupant.arrowhead.arrow);
    try testing.expectEqual((lattice.Neighbours{ .e = true, .w = true }).toMask(), refused.neighbours.toMask());
    try testing.expectEqual(lattice.EdgeKind.solid, refused.stroke_kind);
    try testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}

test "a head refused at a node border counts a lost cell" {
    var border: lattice.Cell = .{
        .occupant = .{ .node_border = .{ .node = 3, .role = .edge_s } },
        .neighbours = .{},
    };
    var lost: u32 = 0;
    edges.writeArrowCell(&border, 7, .solid, .filled, .south, .{ .n = true, .s = true }, 0, 0, &lost);
    try testing.expectEqual(@as(u32, 1), lost);
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

test "mergeRole: rail beats dropper beats routing roles; a same-tier arrival keeps the first writer" {
    const R = lattice.EdgeRole;
    const rows = [_][3]R{
        .{ .fan_out_rail, .fan_out_dropper, .fan_out_rail },
        .{ .fan_in_dropper, .fan_in_rail, .fan_in_rail },
        .{ .back_edge, .fan_out_dropper, .fan_out_dropper },
        .{ .fan_in_dropper, .self_loop, .fan_in_dropper },
        .{ .forward, .fan_out_dropper, .fan_out_dropper },
        .{ .fan_out_rail, .fan_in_rail, .fan_out_rail },
        .{ .back_edge, .self_loop, .back_edge },
    };
    for (rows) |r| try testing.expectEqual(r[2], edges.mergeRole(r[0], r[1]));
}

test "a joined cell stays joined under a later legal crossing; a crossed cell a later writer joins becomes joined" {
    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    const at = crossings.bundleCellAt(1, 1);
    const H: lattice.Neighbours = .{ .e = true, .w = true };
    const V: lattice.Neighbours = .{ .n = true, .s = true };

    var joined: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .cohabit = .joined } },
        .neighbours = H,
    };
    try testing.expect(edges.crossingKeepsFirstWriter(&joined, 9, V, at, ctx));
    try testing.expectEqual(lattice.Cohabit.joined, joined.occupant.edge_segment.cohabit);

    var crossed: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid } },
        .neighbours = H,
    };
    try testing.expect(edges.crossingKeepsFirstWriter(&crossed, 9, V, at, ctx));
    try testing.expectEqual(lattice.Cohabit.crossed, crossed.occupant.edge_segment.cohabit);
    try testing.expect(edges.crossingKeepsFirstWriter(&crossed, 7, H, at, ctx));
    try testing.expectEqual(lattice.Cohabit.joined, crossed.occupant.edge_segment.cohabit);
}

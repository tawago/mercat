//! Unit tests for raster/edges_write.zig — the cell-writer contract at the
//! `cluster_border` occupant (frame-solid ruling, terminal-arrival half).
//! Through-going bridging lives in the caller (`walkPolyline`) and is pinned
//! in edges_test.zig; here we pin the writer-level behaviors those callers
//! rely on: a TERMINAL segment cell and an ARROWHEAD still land on a border.
//! The PORT-STROKE half (`drawPortStroke`/`drawTargetPortStroke`, the facing
//! rule, the gap probe and its painted approach) lives in the sibling
//! `edges_port_test.zig` — split for the 500-line cap.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const aux = @import("aux.zig");
const crossings = @import("crossings.zig");

const testing = std.testing;

fn borderCell(mask: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } },
        .neighbours = mask,
    };
}


test "writeEdgeCell: a terminal segment cell onto a cluster_border merges (today's behavior)" {
    // A polyline that TERMINATES on the frame keeps the pre-ruling merge: the
    // caller reaches writeEdgeCell only for the final cell, and here the border
    // is overwritten as an edge_segment with OR-merged bits. (Through-going
    // cells never reach this arm — the caller bridges them.)
    var cell = borderCell(.{ .e = true, .w = true }); // horizontal frame run
    var lost: u32 = 0;
    ew.writeEdgeCell(&cell, 7, .solid, .forward, .{ .n = true, .s = true }, 3, 3, &lost, .{});
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(switch (cell.occupant) {
        .edge_segment => |seg| seg.edge == 7,
        else => false,
    });
    // Frame bits fused with the arriving vertical arms → a ┼-class mask.
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
}

test "writeArrowCell: an arrowhead may stamp onto a cluster_border (arrival AT the cluster)" {
    var cell = borderCell(.{ .e = true, .w = true });
    var lost: u32 = 0;
    ew.writeArrowCell(&cell, 7, .solid, .filled, .south, .{ .n = true, .s = true }, 3, 3, &lost, .{});
    try testing.expectEqual(@as(u32, 0), lost);
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.dir == .south and ah.edge == 7,
        else => false,
    });
}

test "writeArrowCell stamps the edge's own stroke_kind" {
    // An arrowhead landing on a FOREIGN edge's run must carry ITS OWN stroke,
    // not the foreign run's. Pre-seed a solid edge_segment (stroke .solid),
    // then land a dotted-edge arrowhead: the cell's stroke becomes .dotted.
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .solid,
    };
    var lost: u32 = 0;
    ew.writeArrowCell(&cell, 9, .dotted, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost, .{});
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.edge == 9,
        else => false,
    });
    try testing.expectEqual(lattice.EdgeKind.dotted, cell.stroke_kind);
}

test "writeArrowCell on an empty cell stamps stroke_kind" {
    // Regression pin: the .empty arm also stamps, so a lone arrowhead cell's
    // stroke agrees with its edge kind.
    var cell = lattice.Cell.empty;
    var lost: u32 = 0;
    ew.writeArrowCell(&cell, 4, .thick, .filled, .south, .{ .n = true, .s = true }, 0, 0, &lost, .{});
    try testing.expectEqual(lattice.EdgeKind.thick, cell.stroke_kind);
}

test "writeArrowCell records the declared head style on the cell" {
    // The head style travels from the sketch edge to the cell; both writers
    // must carry it, including the pristine refuse branch of the guarded one.
    var plain = lattice.Cell.empty;
    var lost: u32 = 0;
    ew.writeArrowCell(&plain, 1, .solid, .open, .south, .{ .n = true }, 0, 0, &lost, .{});
    try testing.expectEqual(lattice.ArrowKind.open, plain.occupant.arrowhead.arrow);

    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var refused: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .solid, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
    };
    ew.writeArrowGuarded(&refused, 6, .solid, .cross, .east, .{ .e = true }, 1, 1, &lost, ctx, .{});
    try testing.expectEqual(lattice.ArrowKind.cross, refused.occupant.arrowhead.arrow);
}

test "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind" {
    // Active crossing rule + a FOREIGN edge under the cell → the refuse branch
    // lays a pristine arrowhead. Its stroke must be the incoming edge's OWN
    // kind (.solid), never the foreign run's (.thick).
    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .counts = &counts };
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .thick, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .thick,
    };
    var lost: u32 = 0;
    ew.writeArrowGuarded(&cell, 5, .solid, .filled, .east, .{ .e = true, .w = true }, 1, 1, &lost, ctx, .{});
    try testing.expect(switch (cell.occupant) {
        .arrowhead => |ah| ah.edge == 5,
        else => false,
    });
    // Pristine bits (no foreign junction) and own stroke.
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        cell.neighbours.toMask(),
    );
    try testing.expectEqual(lattice.EdgeKind.solid, cell.stroke_kind);
    try testing.expectEqual(@as(u32, 1), counts.arrowhead_transit_violation);
}



test "directional primitives round-trip (straightMask/bitMask/reverse)" {
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        ew.straightMask(.north).toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        ew.straightMask(.east).toMask(),
    );
    try testing.expectEqual(ew.Move.south, ew.reverse(.north));
    try testing.expectEqual(
        (lattice.Neighbours{ .w = true }).toMask(),
        ew.bitMask(.west).toMask(),
    );
}

//! Unit tests for raster/edges_write.zig — the cell-writer contract at the
//! `cluster_border` occupant (frame-solid ruling, terminal-arrival half).
//! Through-going bridging lives in the caller (`walkPolyline`) and is pinned
//! in edges_test.zig; here we pin the writer-level behaviors those callers
//! rely on: a TERMINAL segment cell and an ARROWHEAD still land on a border.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");
const crossings = @import("crossings.zig");

const testing = std.testing;

fn borderCell(mask: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } },
        .neighbours = mask,
    };
}

/// A 1×2 lattice whose cell at (0, border_y) is a solid rect node_border with
/// a horizontal {e,w} run (a box-bottom/box-top border). Callers drive
/// `mergeSourceBorder` with a polyline that exits that cell vertically.
fn sourceBorderLattice(a: std.mem.Allocator, border_y: u32) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, 2);
    for (cells) |*c| c.* = lattice.Cell.empty;
    cells[border_y] = .{
        .occupant = .{ .node_border = .{ .node = 0, .role = .edge_s } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .solid,
        .shape = .rect,
    };
    return .{ .width = 1, .height = 2, .cells = cells };
}

test "writeEdgeCell: a terminal segment cell onto a cluster_border merges (today's behavior)" {
    // A polyline that TERMINATES on the frame keeps the pre-ruling merge: the
    // caller reaches writeEdgeCell only for the final cell, and here the border
    // is overwritten as an edge_segment with OR-merged bits. (Through-going
    // cells never reach this arm — the caller bridges them.)
    var cell = borderCell(.{ .e = true, .w = true }); // horizontal frame run
    var lost: u32 = 0;
    ew.writeEdgeCell(&cell, 7, .solid, .forward, .{ .n = true, .s = true }, 3, 3, &lost);
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
    ew.writeArrowCell(&cell, 7, .solid, .south, .{ .n = true, .s = true }, 3, 3, &lost);
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
    ew.writeArrowCell(&cell, 9, .dotted, .east, .{ .e = true, .w = true }, 1, 1, &lost);
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
    ew.writeArrowCell(&cell, 4, .thick, .south, .{ .n = true, .s = true }, 0, 0, &lost);
    try testing.expectEqual(lattice.EdgeKind.thick, cell.stroke_kind);
}

test "writeArrowGuarded refuse branch stamps the arrowhead's own stroke_kind" {
    // Active crossing rule + a FOREIGN edge under the cell → the refuse branch
    // lays a pristine arrowhead. Its stroke must be the incoming edge's OWN
    // kind (.solid), never the foreign run's (.thick).
    var counts: crossings.CrossingCounts = .{};
    const ctx: crossings.Ctx = .{ .active = true, .counts = &counts };
    var cell: lattice.Cell = .{
        .occupant = .{ .edge_segment = .{ .edge = 2, .kind = .thick, .role = .forward } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .thick,
    };
    var lost: u32 = 0;
    ew.writeArrowGuarded(&cell, 5, .solid, .east, .{ .e = true, .w = true }, 1, 1, &lost, ctx);
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

test "mergeSourceBorder: an invisible edge leaves the source node border untouched" {
    // Witness geometry: a `~~~` link exits a box-bottom southward. The border
    // must keep its natural {e,w} mask (glyph ─, not ┬) and its .solid stroke.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.mergeSourceBorder(&lat, &pts, .invisible);

    const cell = lat.atConst(0, 0);
    try testing.expect(!cell.neighbours.s); // no phantom south tee
    try testing.expectEqual(lattice.EdgeKind.solid, cell.stroke_kind); // no stroke corruption
}

test "mergeSourceBorder: a solid edge still ORs the south exit bit into the source border" {
    // Control: the ordinary box-bottom tee is preserved — the guard bites
    // ONLY invisible.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.mergeSourceBorder(&lat, &pts, .solid);

    try testing.expect(lat.atConst(0, 0).neighbours.s);
}

test "mergeSourceBorder: a north-exit invisible edge is also suppressed" {
    // Axis-generic: an invisible link exiting a box-top northward must not tee
    // either (guards against a south-only fix).
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 1);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 0 } };
    ew.mergeSourceBorder(&lat, &pts, .invisible);

    try testing.expect(!lat.atConst(0, 1).neighbours.n);
}

test "mergeSourceBorder: a thick edge still stamps stroke_kind on the source border" {
    // The non-solid stroke path (╥/╨) is narrowed to exclude .invisible only,
    // not all non-solid kinds: a thick edge still ORs the bit AND stamps stroke.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.mergeSourceBorder(&lat, &pts, .thick);

    const cell = lat.atConst(0, 0);
    try testing.expect(cell.neighbours.s);
    try testing.expectEqual(lattice.EdgeKind.thick, cell.stroke_kind);
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

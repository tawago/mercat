//! Unit tests for raster/edges_write.zig — the cell-writer contract at the
//! `cluster_border` occupant (frame-solid ruling, terminal-arrival half).
//! Through-going bridging lives in the caller (`walkPolyline`) and is pinned
//! in edges_test.zig; here we pin the writer-level behaviors those callers
//! rely on: a TERMINAL segment cell and an ARROWHEAD still land on a border.

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

/// A 1×2 lattice whose cell at (0, border_y) is a solid rect node_border with
/// a horizontal {e,w} run (a box-bottom/box-top border). Callers drive
/// `drawPortStroke` with a polyline that exits that cell vertically.
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

test "drawPortStroke: an invisible edge leaves the source node border untouched" {
    // Witness geometry: a `~~~` link exits a box-bottom southward. The border
    // must keep its natural {e,w} mask (glyph ─, not ┬) and its .solid stroke.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.drawPortStroke(&lat, &pts, .invisible, 0, null, null);

    const cell = lat.atConst(0, 0);
    try testing.expect(!cell.neighbours.s); // no phantom south tee
    try testing.expectEqual(lattice.EdgeKind.solid, cell.stroke_kind); // no stroke corruption
}

test "drawPortStroke: a solid edge still ORs the south exit bit into the source border" {
    // Control: the ordinary box-bottom tee is preserved — the guard bites
    // ONLY invisible.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.drawPortStroke(&lat, &pts, .solid, 0, null, null);

    try testing.expect(lat.atConst(0, 0).neighbours.s);
}

test "drawPortStroke: a north-exit invisible edge is also suppressed" {
    // Axis-generic: an invisible link exiting a box-top northward must not tee
    // either (guards against a south-only fix).
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 1);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 0 } };
    ew.drawPortStroke(&lat, &pts, .invisible, 0, null, null);

    try testing.expect(!lat.atConst(0, 1).neighbours.n);
}

test "drawPortStroke: a thick edge still stamps stroke_kind on the source border" {
    // The non-solid stroke path (╥/╨) is narrowed to exclude .invisible only,
    // not all non-solid kinds: a thick edge still ORs the bit AND stamps stroke.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.drawPortStroke(&lat, &pts, .thick, 0, null, null);

    const cell = lat.atConst(0, 0);
    try testing.expect(cell.neighbours.s);
    try testing.expectEqual(lattice.EdgeKind.thick, cell.stroke_kind);
}

/// 3×3 lattice with a single node_border cell at (bx, by) carrying `mask`
/// (solid rect). Everything else empty — hosts port-stroke geometry on any
/// face.
fn borderLattice3(a: std.mem.Allocator, bx: u32, by: u32, mask: lattice.Neighbours) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, 9);
    for (cells) |*c| c.* = lattice.Cell.empty;
    cells[by * 3 + bx] = .{
        .occupant = .{ .node_border = .{ .node = 0, .role = .edge_n } },
        .neighbours = mask,
        .stroke_kind = .solid,
        .shape = .rect,
    };
    return .{ .width = 3, .height = 3, .cells = cells };
}

test "drawPortStroke: an east/west departure also merges its exit bit (all four faces)" {
    // The old N/S-only restriction is lifted: an LR departure through the
    // east border merges .e so the border paints ├ instead of a flat │.
    const a = testing.allocator;
    var lat = try borderLattice3(a, 0, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 2, .y = 1 } };
    ew.drawPortStroke(&lat, &pts, .solid, 0, null, null);

    try testing.expect(lat.atConst(0, 1).neighbours.e);
}

test "drawTargetPortStroke: arrival arms merge on all four faces" {
    const a = testing.allocator;
    const cases = [_]struct {
        border: [2]u32, // border cell x, y
        border_mask: lattice.Neighbours,
        from: sketch.Point, // polyline start
        expect: lattice.Neighbours, // the merged arrival arm
    }{
        // TD arrival onto a box-top: run above, arm .n → e|w|n (┴).
        .{ .border = .{ 1, 2 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 0 }, .expect = .{ .n = true } },
        // BT arrival onto a box-bottom: run below, arm .s.
        .{ .border = .{ 1, 0 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 2 }, .expect = .{ .s = true } },
        // LR arrival onto a west border: run west, arm .w → n|s|w (┤).
        .{ .border = .{ 2, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 0, .y = 1 }, .expect = .{ .w = true } },
        // RL arrival onto an east border: run east, arm .e → n|s|e (├).
        .{ .border = .{ 0, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 2, .y = 1 }, .expect = .{ .e = true } },
    };
    for (cases) |tc| {
        var lat = try borderLattice3(a, tc.border[0], tc.border[1], tc.border_mask);
        defer a.free(lat.cells);
        const pts = [_]sketch.Point{ tc.from, .{ .x = @intCast(tc.border[0]), .y = @intCast(tc.border[1]) } };
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, null, null);
        const got = lat.atConst(tc.border[0], tc.border[1]).neighbours;
        try testing.expectEqual(
            ew.orMask(tc.border_mask, tc.expect).toMask(),
            got.toMask(),
        );
    }
}

test "drawTargetPortStroke: a thick arrival stamps stroke_kind; dotted does too" {
    const a = testing.allocator;
    var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
    defer a.free(lat.cells);
    const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
    ew.drawTargetPortStroke(&lat, &pts, .thick, 0, null, null);
    try testing.expect(lat.atConst(1, 2).neighbours.n);
    try testing.expectEqual(lattice.EdgeKind.thick, lat.atConst(1, 2).stroke_kind);

    var lat2 = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
    defer a.free(lat2.cells);
    ew.drawTargetPortStroke(&lat2, &pts, .dotted, 0, null, null);
    try testing.expectEqual(lattice.EdgeKind.dotted, lat2.atConst(1, 2).stroke_kind);
}

test "drawTargetPortStroke: refuses non-border occupants and invisible edges" {
    const a = testing.allocator;
    // Endpoint on an empty cell: nothing merged.
    {
        var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 } };
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, null, null);
        try testing.expectEqual(@as(u4, 0), lat.atConst(0, 2).neighbours.toMask());
    }
    // Endpoint on a label cell: refused, untouched.
    {
        var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        lat.at(1, 2).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, null, null);
        try testing.expectEqual(@as(u4, 0), lat.atConst(1, 2).neighbours.toMask());
    }
    // Invisible edge: border stays pristine.
    {
        var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
        ew.drawTargetPortStroke(&lat, &pts, .invisible, 0, null, null);
        try testing.expect(!lat.atConst(1, 2).neighbours.n);
        try testing.expectEqual(lattice.EdgeKind.solid, lat.atConst(1, 2).stroke_kind);
    }
}

test "a decorated arrival whose head abuts the wall leaves it pristine" {
    // The arrowhead already declares the attachment; a tee behind it (`▼`
    // sitting on `┴`) asserts a continuation past the wall that does not
    // exist. Same geometry as the four-face merge test above, decorated
    // with the head ON the last interior cell — orthogonally adjacent to
    // the border: every face must stay exactly as the node rasterizer left
    // it, and no `.port` record may be filed (nothing was drawn).
    const a = testing.allocator;
    const cases = [_]struct {
        border: [2]u32,
        border_mask: lattice.Neighbours,
        from: sketch.Point,
    }{
        .{ .border = .{ 1, 2 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 0 } },
        .{ .border = .{ 1, 0 }, .border_mask = .{ .e = true, .w = true }, .from = .{ .x = 1, .y = 2 } },
        .{ .border = .{ 2, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 0, .y = 1 } },
        .{ .border = .{ 0, 1 }, .border_mask = .{ .n = true, .s = true }, .from = .{ .x = 2, .y = 1 } },
    };
    for (cases) |tc| {
        var lat = try borderLattice3(a, tc.border[0], tc.border[1], tc.border_mask);
        defer a.free(lat.cells);
        var col = aux.Collector.init(a);
        defer col.records.deinit(a);
        const border: sketch.Point = .{ .x = @intCast(tc.border[0]), .y = @intCast(tc.border[1]) };
        const pts = [_]sketch.Point{ tc.from, border };
        // Every case runs two cells into the border, so the last INTERIOR
        // cell — where the walk stamps the head — is the midpoint, which
        // abuts the wall.
        const head: sketch.Point = .{
            .x = @divExact(tc.from.x + border.x, 2),
            .y = @divExact(tc.from.y + border.y, 2),
        };
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, head, &col);
        try testing.expectEqual(
            tc.border_mask.toMask(),
            lat.atConst(tc.border[0], tc.border[1]).neighbours.toMask(),
        );
        try testing.expectEqual(lattice.EdgeKind.solid, lat.atConst(tc.border[0], tc.border[1]).stroke_kind);
        try testing.expectEqual(@as(usize, 0), col.finish().len);
    }
}

test "a decorated source end whose head abuts the wall leaves it pristine" {
    // The reversed-edge mirror: `arrow_from` decorates the DEPARTURE, and
    // the departing wall must stay plain for exactly the same reason — the
    // head at (0,1) faces (0,0) across one seam.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.drawPortStroke(&lat, &pts, .solid, 0, .{ .x = 0, .y = 1 }, &col);
    try testing.expect(!lat.atConst(0, 0).neighbours.s);
    try testing.expectEqual(@as(usize, 0), col.finish().len);
}

test "a decorated arrival whose head is DETACHED still tees the wall" {
    // The correction to the decoration-only rule. The run stops one cell
    // SHORT of the border (the gap convention) and the head lands on the
    // last interior cell — TWO cells from the wall, `┤`-blank-`◀`. Nothing
    // then touches the border, so without this merge the edge visually
    // never attaches to the node: the arrival appears to circulate from
    // nowhere. Suppression is keyed to head ADJACENCY, so a detached head
    // merges its bit exactly like an undecorated end, and records it.
    const a = testing.allocator;
    // Border on the east face at (2,1); the run travels east and stops at
    // the empty gap cell (1,1); the head sits back at (0,1).
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .x = 0, .y = 1 }, &col);
    try testing.expect(lat.atConst(2, 1).neighbours.w);
    const recs = col.finish();
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expectEqual(lattice.AuxKind.port, recs[0].kind);
}

test "a bidirectional edge: abutting heads leave BOTH walls plain, detached heads tee both" {
    // `A <--> B` on one column. When each head abuts its wall the two
    // arrowheads carry the whole story and both borders stay bare `─`.
    const a = testing.allocator;
    {
        var lat = try borderLattice3(a, 1, 0, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        lat.at(1, 2).* = .{
            .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } },
            .neighbours = .{ .e = true, .w = true },
            .stroke_kind = .solid,
            .shape = .rect,
        };
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
        const head: sketch.Point = .{ .x = 1, .y = 1 }; // abuts both walls
        ew.drawPortStroke(&lat, &pts, .solid, 0, head, null);
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, head, null);
        try testing.expect(!lat.atConst(1, 0).neighbours.s);
        try testing.expect(!lat.atConst(1, 2).neighbours.n);
    }
    // The stacked back-edge shape the judges caught: both heads sit one row
    // clear of their walls (`└───┬──┘` with a detached `▲` below). Neither
    // head abuts, so BOTH walls tee and the return leg is attached at both
    // ends even though the heads float.
    {
        const cells = try a.alloc(lattice.Cell, 15); // 3 wide, 5 tall
        defer a.free(cells);
        for (cells) |*c| c.* = lattice.Cell.empty;
        const wall: lattice.Cell = .{
            .occupant = .{ .node_border = .{ .node = 0, .role = .edge_n } },
            .neighbours = .{ .e = true, .w = true },
            .stroke_kind = .solid,
            .shape = .rect,
        };
        cells[0 * 3 + 1] = wall;
        cells[4 * 3 + 1] = wall;
        var lat = lattice.Lattice{ .width = 3, .height = 5, .cells = cells };
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 4 } };
        ew.drawPortStroke(&lat, &pts, .solid, 0, .{ .x = 1, .y = 2 }, null);
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .x = 1, .y = 2 }, null);
        try testing.expect(lat.atConst(1, 0).neighbours.s);
        try testing.expect(lat.atConst(1, 4).neighbours.n);
    }
}

test "a gap arrival merges its port bit across the 1-cell reprieve" {
    // Back-edge arrivals stop one cell SHORT of the border (the gap
    // convention reconcile reprieves): the polyline endpoint is EMPTY and
    // the border sits one further step along the travel direction. The
    // arrival port must land there — otherwise gap arrivals are the one
    // un-erased class.
    const a = testing.allocator;
    // Border on the east face at (2,1); polyline travels east but stops at
    // the empty gap cell (1,1).
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, null, null);
    try testing.expect(lat.atConst(2, 1).neighbours.w);
    // The gap cell itself stays untouched.
    try testing.expectEqual(@as(u4, 0), lat.atConst(1, 1).neighbours.toMask());
}

test "a corner landing is refused: no merge, no record" {
    // Ports are face offsets; ink ending on a corner is a routing defect.
    // Merging there would morph the corner glyph and file the `.port`
    // that launders the landing out of the terminal audit's corner
    // bucket — so the writer refuses, leaving the defect visible.
    const a = testing.allocator;
    var lat = try borderLattice3(a, 1, 2, .{ .e = true, .s = true });
    defer a.free(lat.cells);
    lat.at(1, 2).occupant.node_border.role = .corner_nw;
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, null, &col);
    try testing.expect(!lat.atConst(1, 2).neighbours.n);
    try testing.expectEqual(@as(usize, 0), col.finish().len);
}

test "a merged port files its arm direction in the record" {
    const a = testing.allocator;
    var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
    defer a.free(lat.cells);
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 9, null, &col);
    const recs = col.finish();
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expectEqual(lattice.AuxKind.port, recs[0].kind);
    try testing.expectEqual(@as(u32, 9), recs[0].value);
    // Arrival travelling south merges the north arm.
    try testing.expectEqual(lattice.portArmDetail(.north), recs[0].detail);
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

//! Unit tests for the PORT-STROKE half of raster/edges_write.zig —
//! `drawPortStroke`/`drawTargetPortStroke` and the shared `mergePortBit`
//! tail: uniform four-face erasure, the invisible-edge refusal, the
//! stroke_kind stamp, the corner refusal, the `.port` record's arm detail,
//! the port-tee FACING rule, and the 1-cell gap probe. Split out of
//! `edges_write_test.zig` for the 500-line cap; the cell-writer contract
//! tests stay there, and the HEAD SLIDE that closes a decorated end's gap
//! approach is pinned in `edges_slide_test.zig`.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ew = @import("edges_port.zig");
const prims = @import("edges_write.zig");
const aux = @import("aux.zig");

const testing = std.testing;

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

test "drawPortStroke: an invisible edge leaves the source node border untouched" {
    // Witness geometry: a `~~~` link exits a box-bottom southward. The border
    // must keep its natural {e,w} mask (glyph ─, not ┬) and its .solid stroke.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.drawPortStroke(&lat, &pts, .invisible, 0, .{}, null);

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
    ew.drawPortStroke(&lat, &pts, .solid, 0, .{}, null);

    try testing.expect(lat.atConst(0, 0).neighbours.s);
}

test "drawPortStroke: a north-exit invisible edge is also suppressed" {
    // Axis-generic: an invisible link exiting a box-top northward must not tee
    // either (guards against a south-only fix).
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 1);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 0 } };
    ew.drawPortStroke(&lat, &pts, .invisible, 0, .{}, null);

    try testing.expect(!lat.atConst(0, 1).neighbours.n);
}

test "drawPortStroke: a thick edge still stamps stroke_kind on the source border" {
    // The non-solid stroke path (╥/╨) is narrowed to exclude .invisible only,
    // not all non-solid kinds: a thick edge still ORs the bit AND stamps stroke.
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    ew.drawPortStroke(&lat, &pts, .thick, 0, .{}, null);

    const cell = lat.atConst(0, 0);
    try testing.expect(cell.neighbours.s);
    try testing.expectEqual(lattice.EdgeKind.thick, cell.stroke_kind);
}

test "drawPortStroke: an east/west departure also merges its exit bit (all four faces)" {
    // The old N/S-only restriction is lifted: an LR departure through the
    // east border merges .e so the border paints ├ instead of a flat │.
    const a = testing.allocator;
    var lat = try borderLattice3(a, 0, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 2, .y = 1 } };
    ew.drawPortStroke(&lat, &pts, .solid, 0, .{}, null);

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
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{}, null);
        const got = lat.atConst(tc.border[0], tc.border[1]).neighbours;
        try testing.expectEqual(
            prims.orMask(tc.border_mask, tc.expect).toMask(),
            got.toMask(),
        );
    }
}

test "drawTargetPortStroke: a thick arrival stamps stroke_kind; dotted does too" {
    const a = testing.allocator;
    var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
    defer a.free(lat.cells);
    const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
    ew.drawTargetPortStroke(&lat, &pts, .thick, 0, .{}, null);
    try testing.expect(lat.atConst(1, 2).neighbours.n);
    try testing.expectEqual(lattice.EdgeKind.thick, lat.atConst(1, 2).stroke_kind);

    var lat2 = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
    defer a.free(lat2.cells);
    ew.drawTargetPortStroke(&lat2, &pts, .dotted, 0, .{}, null);
    try testing.expectEqual(lattice.EdgeKind.dotted, lat2.atConst(1, 2).stroke_kind);
}

test "drawTargetPortStroke: refuses non-border occupants and invisible edges" {
    const a = testing.allocator;
    // Endpoint on an empty cell: nothing merged.
    {
        var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 } };
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{}, null);
        try testing.expectEqual(@as(u4, 0), lat.atConst(0, 2).neighbours.toMask());
    }
    // Endpoint on a label cell: refused, untouched.
    {
        var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        lat.at(1, 2).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{}, null);
        try testing.expectEqual(@as(u4, 0), lat.atConst(1, 2).neighbours.toMask());
    }
    // Invisible edge: border stays pristine.
    {
        var lat = try borderLattice3(a, 1, 2, .{ .e = true, .w = true });
        defer a.free(lat.cells);
        const pts = [_]sketch.Point{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 2 } };
        ew.drawTargetPortStroke(&lat, &pts, .invisible, 0, .{}, null);
        try testing.expect(!lat.atConst(1, 2).neighbours.n);
        try testing.expectEqual(lattice.EdgeKind.solid, lat.atConst(1, 2).stroke_kind);
    }
}

test "a decorated arrival whose head faces the wall leaves it pristine" {
    // The arrowhead already declares the attachment; a tee behind it (`▼`
    // sitting on `┴`) asserts a continuation past the wall that does not
    // exist. Same geometry as the four-face merge test above, decorated
    // with the head ON the last interior cell, TIP toward the border: every
    // face must stay exactly as the node rasterizer left it, and no `.port`
    // record may be filed (nothing was drawn).
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
        // cell — where the walk stamps the head — is the midpoint, and the
        // head points along the run, i.e. straight at the wall.
        const head: ew.Head = .{
            .cell = .{
                .x = @divExact(tc.from.x + border.x, 2),
                .y = @divExact(tc.from.y + border.y, 2),
            },
            .dir = prims.segmentDir(tc.from, border).?,
        };
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .head = head }, &col);
        try testing.expectEqual(
            tc.border_mask.toMask(),
            lat.atConst(tc.border[0], tc.border[1]).neighbours.toMask(),
        );
        try testing.expectEqual(lattice.EdgeKind.solid, lat.atConst(tc.border[0], tc.border[1]).stroke_kind);
        try testing.expectEqual(@as(usize, 0), col.finish().len);
    }
}

test "a decorated source end whose head faces the wall leaves it pristine" {
    // The reversed-edge mirror: `arrow_from` decorates the DEPARTURE, and
    // the departing wall must stay plain for exactly the same reason — the
    // head at (0,1) looks north, straight into (0,0).
    const a = testing.allocator;
    var lat = try sourceBorderLattice(a, 0);
    defer a.free(lat.cells);
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };
    const head: ew.Head = .{ .cell = .{ .x = 0, .y = 1 }, .dir = .north };
    ew.drawPortStroke(&lat, &pts, .solid, 0, .{ .head = head }, &col);
    try testing.expect(!lat.atConst(0, 0).neighbours.s);
    try testing.expectEqual(@as(usize, 0), col.finish().len);
}

test "a head adjacent to the wall but pointing ALONG the route still tees it" {
    // DEFECT 1. Adjacency alone was the wrong key. Here a `◀` sits at (1,1),
    // one cell under the bottom wall at (1,0), travelling WEST — orthogonally
    // adjacent to the border, but its tip faces (0,1), not the wall. This is
    // the return leg of a bidirectional pair passing beneath a closed box:
    // suppressing the tap leaves the arrowheads floating below a wall that
    // shows no attachment at all. Only a TIP-FACING head is redundant.
    const a = testing.allocator;
    var lat = try borderLattice3(a, 1, 0, .{ .e = true, .w = true });
    defer a.free(lat.cells);
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    // The run arrives at the wall from the south, so the port arm is .s;
    // the head lives on that last interior cell but looks west.
    const pts = [_]sketch.Point{ .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 0 } };
    const head: ew.Head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .west };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .head = head }, &col);
    try testing.expect(lat.atConst(1, 0).neighbours.s);
    const recs = col.finish();
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expectEqual(lattice.AuxKind.port, recs[0].kind);
}

test "a decorated arrival whose head is DETACHED still tees the wall" {
    // The correction to the decoration-only rule. The run stops one cell
    // SHORT of the border (the gap convention) and the head lands on the
    // last interior cell — TWO cells from the wall. Nothing then touches the
    // border, so without this merge the edge visually never attaches to the
    // node: the arrival appears to circulate from nowhere.
    //
    // The polyline walk now SLIDES such a head onto the gap (see
    // `edges_slide_test.zig`), so what this pins is the writer's own rule
    // for every head it is still handed detached — a rail stub, or a
    // slide the geometry refused. Non-facing head → tee, unchanged.
    const a = testing.allocator;
    // Border on the east face at (2,1); the run travels east and stops at
    // the empty gap cell (1,1); the head sits back at (0,1).
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    const head: ew.Head = .{ .cell = .{ .x = 0, .y = 1 }, .dir = .east };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .head = head }, &col);
    try testing.expect(lat.atConst(2, 1).neighbours.w);
    const recs = col.finish();
    // One port record for the wall; the gap fill claims background and
    // files nothing.
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expectEqual(lattice.AuxKind.port, recs[0].kind);
}

test "a DECORATED gap arrival paints nothing: the slid head owns the gap" {
    // The tip-side law. Painting the gap behind a head produced `├─◀` — run
    // ink between the arrowhead's TIP and the border, which the arrowhead
    // contract forbids (a head is terminal; only its BASE side may carry
    // ink). The head is slid onto the gap by the caller instead, so here it
    // arrives already facing the wall: the facing gate suppresses the tee
    // and the paint is never reached. The gap belongs to the arrowhead,
    // which `rasterizeEdges` stamps after this call.
    // guarded-by: edges_slide_test.zig "a decorated gap arrival stamps its head against the wall, run ink behind it"
    const a = testing.allocator;
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    // The SLID head: it sits on the gap cell (1,1), tip facing (2,1).
    const head: ew.Head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .east };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 7, .{ .head = head, .role = .forward }, &col);
    // Plain wall, no tap, no record — the abutting-decorated convention.
    try testing.expect(!lat.atConst(2, 1).neighbours.w);
    try testing.expectEqual(@as(usize, 0), col.finish().len);
    // And nothing painted on the gap: the arrowhead takes that cell.
    try testing.expectEqual(
        lattice.Occupant.empty,
        std.meta.activeTag(lat.atConst(1, 1).occupant),
    );
}

test "an UNDECORATED gap arrival also gets tee, painted gap and run" {
    // The gap fill follows the port stroke, not the decoration: an
    // undecorated end merges unconditionally and the approach is painted
    // just the same, so a bare run never leaves a blank at the wall.
    const a = testing.allocator;
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    ew.drawTargetPortStroke(&lat, &pts, .dotted, 3, .{}, null);
    try testing.expect(lat.atConst(2, 1).neighbours.w);
    try testing.expectEqual(
        lattice.Occupant.edge_segment,
        std.meta.activeTag(lat.atConst(1, 1).occupant),
    );
    try testing.expectEqual(lattice.EdgeKind.dotted, lat.atConst(1, 1).stroke_kind);
}

test "an OCCUPIED gap cell is never painted and never probed across" {
    // First-writer discipline: the probe fires only across an EMPTY
    // endpoint, so a cell somebody already owns refuses the whole stroke —
    // no jump to the border beyond it, no overwrite, nothing lost.
    const a = testing.allocator;
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    lat.at(1, 1).* = .{
        .occupant = .{ .label_char = 'x' },
        .neighbours = .{},
    };
    var col = aux.Collector.init(a);
    defer col.records.deinit(a);
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{}, &col);
    // The endpoint is not a border, so nothing merges anywhere.
    try testing.expect(!lat.atConst(2, 1).neighbours.w);
    try testing.expectEqual(
        lattice.Occupant.label_char,
        std.meta.activeTag(lat.atConst(1, 1).occupant),
    );
    try testing.expectEqual(@as(usize, 0), col.finish().len);
}

test "painting the gap cell costs no lost cells" {
    // Selection neutrality. `audit.collect` scores candidates on
    // `edge_cells_lost`/`labels_dropped`; the gap fill must not move any of
    // them. It cannot: the cell is empty by the probe's own precondition, so
    // `writeEdgeCell` takes its `.empty` arm, which touches no counter — the
    // whole port path is invisible to the audit.
    const a = testing.allocator;
    var lat = try borderLattice3(a, 2, 1, .{ .n = true, .s = true });
    defer a.free(lat.cells);
    lat.at(2, 1).occupant.node_border.role = .edge_w;
    const pts = [_]sketch.Point{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{}, null);
    // Nothing but background was consumed: the head/run cells are untouched
    // and the only new occupant is on the formerly-empty gap.
    try testing.expectEqual(
        lattice.Occupant.empty,
        std.meta.activeTag(lat.atConst(0, 1).occupant),
    );
    try testing.expectEqual(
        lattice.Occupant.edge_segment,
        std.meta.activeTag(lat.atConst(1, 1).occupant),
    );
}

test "a bidirectional edge: facing heads leave BOTH walls plain, others tee both" {
    // `A <--> B` on one column. When each head faces its wall the two
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
        // One shared cell carries both heads; each looks at its own wall.
        const up: ew.Head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .north };
        const down: ew.Head = .{ .cell = .{ .x = 1, .y = 1 }, .dir = .south };
        ew.drawPortStroke(&lat, &pts, .solid, 0, .{ .head = up }, null);
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .head = down }, null);
        try testing.expect(!lat.atConst(1, 0).neighbours.s);
        try testing.expect(!lat.atConst(1, 2).neighbours.n);
    }
    // The stacked back-edge shape the judges caught: both heads sit clear of
    // their walls (`└───┬──┘` with a detached `▲` below). Neither faces a
    // wall, so BOTH tee and the return leg is attached at both ends even
    // though the heads float.
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
        const up: ew.Head = .{ .cell = .{ .x = 1, .y = 2 }, .dir = .north };
        const down: ew.Head = .{ .cell = .{ .x = 1, .y = 2 }, .dir = .south };
        ew.drawPortStroke(&lat, &pts, .solid, 0, .{ .head = up }, null);
        ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{ .head = down }, null);
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
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{}, null);
    try testing.expect(lat.atConst(2, 1).neighbours.w);
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
    ew.drawTargetPortStroke(&lat, &pts, .solid, 0, .{}, &col);
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
    ew.drawTargetPortStroke(&lat, &pts, .solid, 9, .{}, &col);
    const recs = col.finish();
    try testing.expectEqual(@as(usize, 1), recs.len);
    try testing.expectEqual(lattice.AuxKind.port, recs[0].kind);
    try testing.expectEqual(@as(u32, 9), recs[0].value);
    // Arrival travelling south merges the north arm.
    try testing.expectEqual(lattice.portArmDetail(.north), recs[0].detail);
}

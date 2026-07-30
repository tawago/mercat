//! Unit tests for `tiling/cell.zig`: the classification table, the
//! mirrored ring-arm and arrow-bit tables, and the reprieve walk.

const std = @import("std");
const lattice = @import("../lattice.zig");
const cell = @import("cell.zig");

const testing = std.testing;

fn edgeCell(kind: lattice.EdgeKind, nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = kind } },
        .neighbours = nb,
    };
}

test "classify: invisible edge_segment is ghost with zero ink" {
    const ghost = cell.classify(edgeCell(.invisible, .{ .n = true, .s = true }));
    try testing.expectEqual(cell.Kind.ghost, ghost.kind);
    // The mask survives verbatim; only ink is zeroed — this is the ONE
    // place the invisible-edge exclusion lives.
    try testing.expectEqual(@as(u4, 0b0101), ghost.mask);
    try testing.expectEqual(@as(u4, 0), ghost.ink);
    try testing.expectEqual(@as(?u32, 3), ghost.edge);

    for ([_]lattice.EdgeKind{ .solid, .dotted, .thick }) |k| {
        const t = cell.classify(edgeCell(k, .{ .n = true, .s = true }));
        try testing.expectEqual(cell.Kind.stroke, t.kind);
        try testing.expectEqual(@as(u4, 0b0101), t.ink);
    }
}

test "classify: ring cells are ink regardless of stroke_kind" {
    // A node border whose stroke_kind is invisible still paints a glyph
    // (paint picks it from the shape table), so it is ink either way.
    var c: lattice.Cell = .{
        .occupant = .{ .node_border = .{ .node = 9, .role = .edge_n } },
        .neighbours = .{ .e = true, .w = true },
        .stroke_kind = .invisible,
    };
    var t = cell.classify(c);
    try testing.expectEqual(cell.Kind.ring_node, t.kind);
    try testing.expectEqual(@as(u4, 0b1010), t.ink);
    try testing.expectEqual(@as(?u32, 9), t.node);
    try testing.expectEqual(lattice.BorderRole.edge_n, t.role.?);

    c = .{
        .occupant = .{ .cluster_border = .{ .cluster = 4, .role = .corner_se } },
        .neighbours = .{ .n = true },
        .stroke_kind = .invisible,
    };
    t = cell.classify(c);
    try testing.expectEqual(cell.Kind.ring_frame, t.kind);
    try testing.expectEqual(@as(u4, 0b0001), t.ink);
    try testing.expectEqual(@as(?u32, 4), t.cluster);
}

test "classify: every occupant maps to one kind and only ink kinds carry ink" {
    const cases = [_]struct { c: lattice.Cell, k: cell.Kind }{
        .{ .c = .{ .occupant = .empty, .neighbours = .{ .n = true } }, .k = .blank },
        .{ .c = .{ .occupant = .{ .node_interior = 1 }, .neighbours = .{ .n = true } }, .k = .fill },
        .{ .c = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{ .n = true } }, .k = .glyph },
        // The tail column of a wide glyph classifies as the same opaque
        // kind as its head: no ink, real, conducts nothing.
        .{ .c = .{ .occupant = .label_cont, .neighbours = .{ .n = true } }, .k = .glyph },
        .{ .c = edgeCell(.solid, .{ .n = true }), .k = .stroke },
        .{ .c = edgeCell(.invisible, .{ .n = true }), .k = .ghost },
        .{ .c = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0 } }, .neighbours = .{ .n = true } }, .k = .arrow },
        .{ .c = .{ .occupant = .{ .node_border = .{ .node = 0, .role = .edge_w } }, .neighbours = .{ .n = true } }, .k = .ring_node },
        .{ .c = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_w } }, .neighbours = .{ .n = true } }, .k = .ring_frame },
    };
    for (cases) |case| {
        const t = cell.classify(case.c);
        try testing.expectEqual(case.k, t.kind);
        try testing.expectEqual(@as(u4, 0b0001), t.mask);
        const inky = switch (case.k) {
            .stroke, .arrow, .ring_node, .ring_frame => true,
            .blank, .fill, .glyph, .ghost => false,
        };
        try testing.expectEqual(if (inky) @as(u4, 0b0001) else @as(u4, 0), t.ink);
        // isReal: everything except background, no reciprocity required.
        try testing.expectEqual(case.k != .blank, cell.isReal(t));
    }
}

test "intoArrowBit is the tip-direction bit for all four tips" {
    // Mirror of raster/arrow_base.intoArrowBit: the base's arm points
    // TOWARD the arrowhead, i.e. in the tip direction itself.
    try testing.expectEqual(@as(u4, 0b0001), cell.intoArrowBit(.north));
    try testing.expectEqual(@as(u4, 0b0010), cell.intoArrowBit(.east));
    try testing.expectEqual(@as(u4, 0b0100), cell.intoArrowBit(.south));
    try testing.expectEqual(@as(u4, 0b1000), cell.intoArrowBit(.west));

    for ([_]cell.Dir4{ .north, .east, .south, .west }) |d| {
        try testing.expectEqual(d, cell.reverse(cell.reverse(d)));
        try testing.expect(cell.bit(d) & cell.bit(cell.reverse(d)) == 0);
        for (cell.perpendicular(d)) |p| {
            try testing.expect(cell.bit(p) & (cell.bit(d) | cell.bit(cell.reverse(d))) == 0);
        }
    }
}

test "ringAxes matches the nodes.zig full-rect table and contains every thin form" {
    const n = cell.bit(.north);
    const e = cell.bit(.east);
    const s = cell.bit(.south);
    const w = cell.bit(.west);

    // Hand-copied from raster/nodes.zig `rasterizeRect`.
    try testing.expectEqual(e | s, cell.ringAxes(.corner_nw, false));
    try testing.expectEqual(w | s, cell.ringAxes(.corner_ne, false));
    try testing.expectEqual(w | n, cell.ringAxes(.corner_se, false));
    try testing.expectEqual(e | n, cell.ringAxes(.corner_sw, false));
    try testing.expectEqual(e | w, cell.ringAxes(.edge_n, false));
    try testing.expectEqual(e | w, cell.ringAxes(.edge_s, false));
    try testing.expectEqual(n | s, cell.ringAxes(.edge_w, false));
    try testing.expectEqual(n | s, cell.ringAxes(.edge_e, false));

    // Hand-copied from `writeThinRect`: 1x1 writes {}, a horizontal run
    // writes corner_nw {e} / edge_n {e,w} / corner_ne {w}, a vertical run
    // corner_nw {s} / edge_w {n,s} / corner_sw {n}. Every one of those
    // must be contained in the thin answer, and the thin answer in the
    // full-rect one (masks only ever gain bits).
    const thin_forms = [_]struct { role: lattice.BorderRole, mask: u4 }{
        .{ .role = .corner_nw, .mask = 0 },
        .{ .role = .corner_nw, .mask = e },
        .{ .role = .corner_nw, .mask = s },
        .{ .role = .edge_n, .mask = e | w },
        .{ .role = .corner_ne, .mask = w },
        .{ .role = .edge_w, .mask = n | s },
        .{ .role = .corner_sw, .mask = n },
    };
    for (thin_forms) |f| {
        const thin = cell.ringAxes(f.role, true);
        try testing.expectEqual(f.mask, f.mask & thin);
        try testing.expectEqual(thin, thin & cell.ringAxes(f.role, false));
    }
}

test "gapReprieve honours reciprocation and refuses a non-reciprocating collinear cell" {
    var buf: [4]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 1, .height = 4, .cells = &buf };
    const v = cell.View.init(&lat);

    // (0,0) claims a south arm; (0,1) is the empty 1-cell port gap.
    buf[0] = edgeCell(.solid, .{ .s = true });

    // Nothing beyond the gap: no reprieve.
    try testing.expect(!v.gapReprieve(0, 0, .south));

    // A cell that merely sits collinear without reciprocating: refused.
    buf[2] = edgeCell(.solid, .{ .e = true, .w = true });
    try testing.expect(!v.gapReprieve(0, 0, .south));

    // Reciprocating (carries the north arm back at us): reprieved.
    buf[2] = edgeCell(.solid, .{ .n = true, .s = true });
    try testing.expect(v.gapReprieve(0, 0, .south));

    // A terminal arrowhead always faces its run: reprieved with no mask.
    buf[2] = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0 } }, .neighbours = .{} };
    try testing.expect(v.gapReprieve(0, 0, .south));

    // Walking off the grid is never a reprieve.
    try testing.expect(!v.gapReprieve(0, 3, .south));
    try testing.expect(!v.gapReprieve(0, 0, .north));
}

test "View hands out copies and bounds-checks every accessor" {
    var buf: [4]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    buf[1] = edgeCell(.solid, .{ .n = true });
    const lat = lattice.Lattice{ .width = 2, .height = 2, .cells = &buf };
    const v = cell.View.init(&lat);

    try testing.expectEqual(@as(u32, 2), v.width());
    try testing.expectEqual(@as(u32, 2), v.height());
    try testing.expect(v.at(2, 0) == null);
    try testing.expect(v.at(0, 2) == null);
    try testing.expect(v.arm(1, 0, .east) == null);
    try testing.expectEqual(cell.Kind.stroke, v.arm(0, 0, .east).?.kind);

    // reciprocates reads the neighbour's committed mask.
    try testing.expect(!v.reciprocates(0, 0, .east)); // (1,0) has no west arm
    buf[1] = edgeCell(.solid, .{ .w = true });
    try testing.expect(v.reciprocates(0, 0, .east));
    try testing.expect(!v.reciprocates(1, 0, .east)); // off-grid

    // A returned Typed is a copy: mutating it cannot reach the lattice.
    var t = v.at(1, 0).?;
    t.mask = 0;
    try testing.expectEqual(@as(u4, 0b1000), v.at(1, 0).?.mask);
}

test "columns mirrors paint.cellWidth: wide label glyph is two columns" {
    var buf: [5]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    buf[0] = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };
    // The continuation the label writers stamp for that head. It paints
    // nothing, so head+tail claim two cells and charge two columns — the
    // equality `m_row_col_overflow` measures.
    buf[1] = .{ .occupant = .label_cont, .neighbours = .{} };
    buf[2] = .{ .occupant = .{ .label_char = 'a' }, .neighbours = .{} };
    buf[3] = .{ .occupant = .{ .node_interior = 0 }, .neighbours = .{} };
    buf[4] = edgeCell(.solid, .{ .n = true });
    const lat = lattice.Lattice{ .width = 5, .height = 1, .cells = &buf };
    const v = cell.View.init(&lat);

    try testing.expectEqual(@as(u32, 2), v.columns(0, 0));
    try testing.expectEqual(@as(u32, 0), v.columns(1, 0));
    try testing.expectEqual(@as(u32, 1), v.columns(2, 0));
    try testing.expectEqual(@as(u32, 1), v.columns(3, 0));
    try testing.expectEqual(@as(u32, 1), v.columns(4, 0));
    try testing.expectEqual(@as(u32, 0), v.columns(5, 0));

    try testing.expect(v.isWideGlyph(0, 0));
    // A continuation is not itself a head: the wide-glyph probe answers
    // for the cell that carries the codepoint, not for its tail.
    try testing.expect(!v.isWideGlyph(1, 0));
    try testing.expect(!v.isWideGlyph(2, 0));
    try testing.expect(!v.isWideGlyph(4, 0));
    try testing.expect(!v.isWideGlyph(9, 9));
}

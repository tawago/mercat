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
        try testing.expectEqual(case.k != .blank, cell.isReal(t));
    }
}

test "intoArrowBit is the tip-direction bit for all four tips" {
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

    try testing.expectEqual(e | s, cell.ringAxes(.corner_nw, false));
    try testing.expectEqual(w | s, cell.ringAxes(.corner_ne, false));
    try testing.expectEqual(w | n, cell.ringAxes(.corner_se, false));
    try testing.expectEqual(e | n, cell.ringAxes(.corner_sw, false));
    try testing.expectEqual(e | w, cell.ringAxes(.edge_n, false));
    try testing.expectEqual(e | w, cell.ringAxes(.edge_s, false));
    try testing.expectEqual(n | s, cell.ringAxes(.edge_w, false));
    try testing.expectEqual(n | s, cell.ringAxes(.edge_e, false));

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

    buf[0] = edgeCell(.solid, .{ .s = true });

    try testing.expect(!v.gapReprieve(0, 0, .south));

    buf[2] = edgeCell(.solid, .{ .e = true, .w = true });
    try testing.expect(!v.gapReprieve(0, 0, .south));

    buf[2] = edgeCell(.solid, .{ .n = true, .s = true });
    try testing.expect(v.gapReprieve(0, 0, .south));

    buf[2] = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0 } }, .neighbours = .{} };
    try testing.expect(v.gapReprieve(0, 0, .south));

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

    try testing.expect(!v.reciprocates(0, 0, .east));
    buf[1] = edgeCell(.solid, .{ .w = true });
    try testing.expect(v.reciprocates(0, 0, .east));
    try testing.expect(!v.reciprocates(1, 0, .east));

    var t = v.at(1, 0).?;
    t.mask = 0;
    try testing.expectEqual(@as(u4, 0b1000), v.at(1, 0).?.mask);
}

test "columns mirrors paint.cellWidth: wide label glyph is two columns" {
    var buf: [5]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    buf[0] = .{ .occupant = .{ .label_char = '日' }, .neighbours = .{} };
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
    try testing.expect(!v.isWideGlyph(1, 0));
    try testing.expect(!v.isWideGlyph(2, 0));
    try testing.expect(!v.isWideGlyph(4, 0));
    try testing.expect(!v.isWideGlyph(9, 9));
}

/// A 3-cell lattice whose middle cell carries a mixed run of records, in
/// the (cell, kind, value) order the collector guarantees.
fn viewWithRecords(buf: []lattice.Cell, table: []const lattice.Aux) lattice.Lattice {
    for (buf) |*c| c.* = lattice.Cell.empty;
    return .{ .width = @intCast(buf.len), .height = 1, .cells = buf, .aux = table };
}

test "ofKind returns the contiguous run of one kind and nothing else" {
    var buf: [3]lattice.Cell = undefined;
    const table = [_]lattice.Aux{
        .{ .cell = 0, .value = 99, .kind = .carrier },
        .{ .cell = 1, .value = 4, .kind = .port },
        .{ .cell = 1, .value = 7, .kind = .carrier },
        .{ .cell = 1, .value = 8, .kind = .carrier },
        .{ .cell = 1, .value = 2, .kind = .label_owner, .detail = 1 },
        .{ .cell = 2, .value = 5, .kind = .port },
    };
    const lat = viewWithRecords(&buf, &table);
    const v = cell.View.init(&lat);

    const t = v.at(1, 0).?;
    try testing.expectEqual(@as(usize, 4), t.aux.len);

    const carriers = t.carriers();
    try testing.expectEqual(@as(usize, 2), carriers.len);
    try testing.expectEqual(@as(u32, 7), carriers[0].value);
    try testing.expectEqual(@as(u32, 8), carriers[1].value);

    const ports = t.ports();
    try testing.expectEqual(@as(usize, 1), ports.len);
    try testing.expectEqual(@as(u32, 4), ports[0].value);

    try testing.expectEqual(@as(usize, 1), v.at(0, 0).?.carriers().len);
    try testing.expectEqual(@as(usize, 0), v.at(0, 0).?.ports().len);
    try testing.expectEqual(@as(usize, 0), v.at(2, 0).?.carriers().len);
}

test "labelOwner reports the last owner recorded at a cell" {
    var buf: [2]lattice.Cell = undefined;
    const table = [_]lattice.Aux{
        .{ .cell = 0, .value = 11, .kind = .label_owner, .detail = @intFromEnum(lattice.LabelOwnerKind.node) },
        .{ .cell = 0, .value = 12, .kind = .label_owner, .detail = @intFromEnum(lattice.LabelOwnerKind.edge) },
    };
    const lat = viewWithRecords(&buf, &table);
    const v = cell.View.init(&lat);

    const owner = v.at(0, 0).?.labelOwner().?;
    try testing.expectEqual(lattice.LabelOwnerKind.edge, owner.kind);
    try testing.expectEqual(@as(u32, 12), owner.id);

    try testing.expectEqual(@as(?cell.LabelOwner, null), v.at(1, 0).?.labelOwner());
}

test "classify alone carries no records; the View is what attaches them" {
    const t = cell.classify(lattice.Cell.empty);
    try testing.expectEqual(@as(usize, 0), t.aux.len);
    try testing.expectEqual(@as(?cell.LabelOwner, null), t.labelOwner());
}

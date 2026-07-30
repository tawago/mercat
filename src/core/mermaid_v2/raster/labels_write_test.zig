//! Unit tests for `raster/labels_write.zig` — the label cell-writer
//! contract.
//!
//! The pin these exist for: a label write REPLACES the whole cell. Each
//! test seeds a cell whose every field is non-default (a thick dotted edge
//! segment on a cylinder-shaped run, all four neighbour bits set) and then
//! asserts the write left nothing of it behind. Before the contract was one
//! module the three writers each spelled this reset out separately, so a
//! field could be reset in two of them and inherited in the third without
//! anything noticing.

const std = @import("std");
const lattice = @import("../lattice.zig");
const lw = @import("labels_write.zig");

const testing = std.testing;

/// A cell with NO field at its default: whatever a write leaves behind is
/// therefore visible.
fn dirtyCell() lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = 3, .kind = .thick, .role = .fan_out_rail } },
        .neighbours = .{ .n = true, .e = true, .s = true, .w = true },
        .stroke_kind = .dotted,
        .shape = .cylinder,
    };
}

fn dirtyLattice(buf: []lattice.Cell) lattice.Lattice {
    for (buf) |*c| c.* = dirtyCell();
    return .{ .width = @intCast(buf.len), .height = 1, .cells = buf };
}

/// Every field except the occupant is back at its default.
fn expectReset(c: lattice.Cell) !void {
    try testing.expectEqual(@as(u4, 0), c.neighbours.toMask());
    try testing.expectEqual(lattice.EdgeKind.solid, c.stroke_kind);
    try testing.expectEqual(lattice.Shape.rect, c.shape);
}

test "a glyph write resets every field of the cell it covers" {
    var buf: [1]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);

    lw.writeGlyph(&lat, 0, 0, 'A');

    const c = lat.atConst(0, 0).*;
    switch (c.occupant) {
        .label_char => |cp| try testing.expectEqual(@as(u21, 'A'), cp),
        else => return error.NotALabelChar,
    }
    try expectReset(c);
}

test "a continuation write resets every field, exactly as a glyph write does" {
    // `label_cont` is the field-reset case most easily forgotten: it carries
    // no codepoint, so a writer that only cleared the occupant would leave
    // the covered run's mask conducting through an opaque cell.
    var buf: [1]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);

    lw.writeCont(&lat, 0, 0);

    const c = lat.atConst(0, 0).*;
    try testing.expectEqual(lattice.Occupant.label_cont, std.meta.activeTag(c.occupant));
    try expectReset(c);
}

test "a span write claims head plus continuations and resets both" {
    var buf: [3]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);

    lw.writeSpan(&lat, 0, 0, '日', 2);

    switch (lat.atConst(0, 0).occupant) {
        .label_char => |cp| try testing.expectEqual(@as(u21, '日'), cp),
        else => return error.NotALabelChar,
    }
    try expectReset(lat.atConst(0, 0).*);

    try testing.expectEqual(
        lattice.Occupant.label_cont,
        std.meta.activeTag(lat.atConst(1, 0).occupant),
    );
    try expectReset(lat.atConst(1, 0).*);

    // A span of 2 claims exactly 2 cells: the third is untouched, which is
    // what makes "reserve by cellSpan, write by cellSpan" checkable.
    try testing.expectEqual(
        lattice.Occupant.edge_segment,
        std.meta.activeTag(lat.atConst(2, 0).occupant),
    );
}

test "a span of 1 writes no continuation" {
    // The all-ASCII byte-identity argument in miniature: a narrow glyph
    // claims its single cell and nothing else, so an ASCII lattice cannot
    // grow a continuation.
    var buf: [2]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);

    lw.writeSpan(&lat, 0, 0, 'x', 1);

    try testing.expectEqual(
        lattice.Occupant.label_char,
        std.meta.activeTag(lat.atConst(0, 0).occupant),
    );
    try testing.expectEqual(
        lattice.Occupant.edge_segment,
        std.meta.activeTag(lat.atConst(1, 0).occupant),
    );
}

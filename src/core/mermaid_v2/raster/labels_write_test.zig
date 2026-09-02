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
const aux = @import("aux.zig");

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

/// The owner every reset test writes under; irrelevant to the reset, so
/// it is named once rather than spelled at each call.
const node_owner: lw.Owner = .{ .kind = .node, .id = 1 };

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

    lw.writeGlyph(&lat, 0, 0, 'A', node_owner, null);

    const c = lat.atConst(0, 0).*;
    switch (c.occupant) {
        .label_char => |cp| try testing.expectEqual(@as(u21, 'A'), cp),
        else => return error.NotALabelChar,
    }
    try expectReset(c);
}

test "a continuation write resets every field, exactly as a glyph write does" {
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

    lw.writeSpan(&lat, 0, 0, '日', 2, node_owner, null);

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

    try testing.expectEqual(
        lattice.Occupant.edge_segment,
        std.meta.activeTag(lat.atConst(2, 0).occupant),
    );
}

test "a span of 1 writes no continuation" {
    var buf: [2]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);

    lw.writeSpan(&lat, 0, 0, 'x', 1, node_owner, null);

    try testing.expectEqual(
        lattice.Occupant.label_char,
        std.meta.activeTag(lat.atConst(0, 0).occupant),
    );
    try testing.expectEqual(
        lattice.Occupant.edge_segment,
        std.meta.activeTag(lat.atConst(1, 0).occupant),
    );
}

test "a glyph write files one owner record; a continuation files none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var buf: [3]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);
    var c = aux.Collector.init(arena.allocator());

    lw.writeSpan(&lat, 0, 0, '\u{65e5}', 2, .{ .kind = .cluster, .id = 4 }, &c);

    const table = c.finish();
    try testing.expectEqual(@as(usize, 1), table.len);
    try testing.expectEqual(lat.cellIndex(0, 0), table[0].cell);
    try testing.expectEqual(lattice.AuxKind.label_owner, table[0].kind);
    try testing.expectEqual(@as(u32, 4), table[0].value);
    try testing.expectEqual(@intFromEnum(lattice.LabelOwnerKind.cluster), table[0].detail);
}

test "a null sink writes the same cells and files nothing" {
    var with_buf: [2]lattice.Cell = undefined;
    var without_buf: [2]lattice.Cell = undefined;
    var with = dirtyLattice(&with_buf);
    var without = dirtyLattice(&without_buf);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var c = aux.Collector.init(arena.allocator());

    lw.writeSpan(&with, 0, 0, '\u{65e5}', 2, node_owner, &c);
    lw.writeSpan(&without, 0, 0, '\u{65e5}', 2, node_owner, null);

    try testing.expectEqualSlices(lattice.Cell, with.cells, without.cells);
    try testing.expectEqual(@as(usize, 1), c.finish().len);
}

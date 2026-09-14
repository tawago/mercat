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

test "prepare resolves one cell per grapheme head, interning multi-codepoint graphemes once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var table = lw.GlyphTable.init(a);
    const run = try lw.prepare(a, &table, "e\u{0301}\u{1F680}e\u{0301} 日");
    try testing.expectEqual(@as(usize, 5), run.cells.len);
    try testing.expectEqual(@as(u32, 7), run.cell_count);
    try testing.expectEqual(@as(u32, 7), run.width);
    try testing.expect(lattice.isGlyphRef(run.cells[0].value));
    try testing.expectEqual(@as(u8, 1), run.cells[0].span);
    try testing.expectEqual(@as(u21, 0x1F680), run.cells[1].value);
    try testing.expectEqual(@as(u8, 2), run.cells[1].span);
    // The same grapheme interns to the same reference.
    try testing.expectEqual(run.cells[0].value, run.cells[2].value);
    try testing.expectEqual(@as(u21, ' '), run.cells[3].value);
    try testing.expectEqual(@as(u21, '日'), run.cells[4].value);
    try testing.expectEqual(@as(u8, 2), run.cells[4].span);

    const glyphs = try table.finish();
    try testing.expectEqual(@as(usize, 1), glyphs.len);
    try testing.expectEqualStrings("e\u{0301}", glyphs[0].bytes);
    try testing.expectEqual(@as(u8, 1), glyphs[0].width);
}

test "prepare walks graphemes through controls and malformed bytes exactly as prim.displayWidth counts them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var table = lw.GlyphTable.init(a);

    // The sentinel is a control the strict measure rejects; the walk still
    // keeps the mark on its base and maps the sentinel to a space.
    const with_sentinel = try lw.prepare(a, &table, "e\u{0301}\nx");
    try testing.expectEqual(@as(usize, 3), with_sentinel.cells.len);
    try testing.expect(lattice.isGlyphRef(with_sentinel.cells[0].value));
    try testing.expectEqual(@as(u21, ' '), with_sentinel.cells[1].value);
    try testing.expectEqual(@as(u21, 'x'), with_sentinel.cells[2].value);
    try testing.expectEqual(@as(u32, 3), with_sentinel.cell_count);
    try testing.expectEqual(@as(u32, 3), with_sentinel.width);

    // A malformed byte is its own one-cell piece carrying the raw byte;
    // the graphemes after it are walked whole.
    const malformed = try lw.prepare(a, &table, "a\xffe\u{0301}");
    try testing.expectEqual(@as(usize, 3), malformed.cells.len);
    try testing.expectEqual(@as(u21, 0xFF), malformed.cells[1].value);
    try testing.expect(lattice.isGlyphRef(malformed.cells[2].value));
    try testing.expectEqual(@as(u32, 3), malformed.cell_count);
    try testing.expectEqual(@as(u32, 3), malformed.width);

    // A tab is the one frozen skew: one cell, but measured to the next
    // four-column stop (column 1 -> 4), so the label is five columns wide.
    const tabbed = try lw.prepare(a, &table, "a\tb");
    try testing.expectEqual(@as(u32, 3), tabbed.cell_count);
    try testing.expectEqual(@as(u32, 5), tabbed.width);

    try testing.expectEqual(@as(usize, 1), (try table.finish()).len);
}

test "the glyph table owns its bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var scratch = [_]u8{ 'e', 0xCC, 0x81 };
    var table = lw.GlyphTable.init(a);
    const ref = try table.intern(&scratch, 1);
    try testing.expectEqual(ref, try table.intern("e\u{0301}", 1));
    scratch[0] = 'x';
    const glyphs = try table.finish();
    try testing.expectEqual(@as(usize, 1), glyphs.len);
    try testing.expectEqualStrings("e\u{0301}", glyphs[0].bytes);
    try testing.expectEqual(lattice.glyphRef(0), ref);
}

test "a span write with an interned reference stores the reference, not a scalar" {
    var buf: [2]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);
    const ref = lattice.glyphRef(3);
    lw.writeSpan(&lat, 0, 0, ref, 2, node_owner, null);
    switch (lat.atConst(0, 0).occupant) {
        .label_char => |cp| try testing.expectEqual(ref, cp),
        else => return error.NotALabelChar,
    }
    try testing.expectEqual(lattice.Occupant.label_cont, std.meta.activeTag(lat.atConst(1, 0).occupant));
}

test "a run write lays every cell out in order and claims exactly cell_count cells" {
    var buf: [5]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);
    const cells = [_]lw.LabelCell{ .{ .value = 'a', .span = 1 }, .{ .value = '日', .span = 2 }, .{ .value = lattice.glyphRef(0), .span = 1 } };
    const run: lw.Run = .{ .cells = &cells, .cell_count = 4, .width = 4 };

    lw.writeRun(&lat, 0, 0, run, node_owner, null);

    const expectHead = struct {
        fn f(l: lattice.Lattice, x: u32, want: u21) !void {
            switch (l.atConst(x, 0).occupant) {
                .label_char => |cp| try testing.expectEqual(want, cp),
                else => return error.NotALabelChar,
            }
        }
    }.f;
    try expectHead(lat, 0, 'a');
    try expectHead(lat, 1, '日');
    try testing.expectEqual(lattice.Occupant.label_cont, std.meta.activeTag(lat.atConst(2, 0).occupant));
    try expectHead(lat, 3, lattice.glyphRef(0));
    try testing.expectEqual(lattice.Occupant.edge_segment, std.meta.activeTag(lat.atConst(4, 0).occupant));
}

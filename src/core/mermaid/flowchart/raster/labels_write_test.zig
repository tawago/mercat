const std = @import("std");
const lattice = @import("../lattice.zig");
const lw = @import("labels_write.zig");
const prim = @import("prim");

const testing = std.testing;

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

fn expectReset(c: lattice.Cell) !void {
    try testing.expectEqual(@as(u4, 0), c.neighbours.toMask());
    try testing.expectEqual(lattice.EdgeKind.solid, c.stroke_kind);
    try testing.expectEqual(lattice.Shape.rect, c.shape);
}

test "prepare: one cell per grapheme head; cell_count follows prim.displayWidth except a tab claims one cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const Row = struct { text: []const u8, cells: usize, cell_count: u32, width: ?u32 = null };
    const rows = [_]Row{
        .{ .text = "", .cells = 0, .cell_count = 0 },
        .{ .text = "hello world", .cells = 11, .cell_count = 11 },
        .{ .text = "A日B語C", .cells = 5, .cell_count = 7 },
        .{ .text = "cafe\u{0301}", .cells = 4, .cell_count = 4 }, // a combining mark claims no cell
        .{ .text = "\u{1F680}", .cells = 1, .cell_count = 2 },
        .{ .text = family, .cells = 1, .cell_count = 2 },
        .{ .text = "\u{1F1EF}\u{1F1F5}", .cells = 1, .cell_count = 2 }, // flag
        .{ .text = "\u{2764}\u{FE0F}", .cells = 1, .cell_count = 2 }, // VS16 widens
        .{ .text = "\u{2764}", .cells = 1, .cell_count = 1 },
        .{ .text = "\u{1F44D}\u{1F3FD} OK", .cells = 4, .cell_count = 5 },
        .{ .text = "a\xffb", .cells = 3, .cell_count = 3 }, // malformed byte
        .{ .text = "a\tb", .cells = 3, .cell_count = 3, .width = 5 }, // tab: one cell, display width 5
        .{ .text = "e\u{0301}" ++ [_]u8{prim.LINE_BREAK} ++ "x", .cells = 3, .cell_count = 3 }, // as "e\u{0301} x"
    };
    for (rows) |r| {
        var table = lw.GlyphTable.init(a);
        const run = try lw.prepare(a, &table, r.text);
        try testing.expectEqual(r.cells, run.cells.len);
        try testing.expectEqual(r.cell_count, run.cell_count);
        try testing.expectEqual(r.width orelse r.cell_count, run.width);
        try testing.expectEqual(r.width orelse r.cell_count, prim.displayWidth(r.text));
    }

    var table = lw.GlyphTable.init(a);
    const run = try lw.prepare(a, &table, "e\u{0301}\u{1F680}e\u{0301} 日");
    try testing.expect(lattice.isGlyphRef(run.cells[0].value));
    try testing.expectEqual(@as(u8, 1), run.cells[0].span);
    try testing.expectEqual(@as(u21, 0x1F680), run.cells[1].value);
    try testing.expectEqual(@as(u8, 2), run.cells[1].span);
    try testing.expectEqual(run.cells[0].value, run.cells[2].value);
    try testing.expectEqual(@as(u21, ' '), run.cells[3].value);
    try testing.expectEqual(@as(u21, '日'), run.cells[4].value);
    try testing.expectEqual(@as(u8, 2), run.cells[4].span);

    const with_sentinel = try lw.prepare(a, &table, "e\u{0301}" ++ [_]u8{prim.LINE_BREAK} ++ "x");
    try testing.expectEqual(run.cells[0].value, with_sentinel.cells[0].value);
    try testing.expectEqual(@as(u21, ' '), with_sentinel.cells[1].value);
    const malformed = try lw.prepare(a, &table, "a\xffe\u{0301}");
    try testing.expectEqual(@as(u21, 0xFF), malformed.cells[1].value);
    try testing.expectEqual(run.cells[0].value, malformed.cells[2].value);

    const glyphs = try table.finish();
    try testing.expectEqual(@as(usize, 1), glyphs.len);
    try testing.expectEqualStrings("e\u{0301}", glyphs[0].bytes);
    try testing.expectEqual(@as(u8, 1), glyphs[0].width);
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

test "a run write lays every cell out in order, resets each, and claims exactly cell_count cells" {
    var buf: [5]lattice.Cell = undefined;
    var lat = dirtyLattice(&buf);
    const cells = [_]lw.LabelCell{ .{ .value = 'a', .span = 1 }, .{ .value = '日', .span = 2 }, .{ .value = lattice.glyphRef(0), .span = 1 } };
    const run: lw.Run = .{ .cells = &cells, .cell_count = 4, .width = 4 };

    lw.writeRun(&lat, 0, 0, run);

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
    for (0..4) |x| try expectReset(lat.atConst(@intCast(x), 0).*);
}

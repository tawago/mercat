//! Painter — turns a `Lattice` into a UTF-8 terminal string.
//!
//! Trailing ASCII spaces are stripped per row; rows join on '\n' with a
//! trailing '\n' after a non-empty lattice (0x0 lattice paints to "").
//! Emits at most `max_width` display columns per row — this only
//! *applies* `sketch.budget.max_width` (a raster read of the IR), it
//! does not *decide* width policy. Real content cut by the budget gets
//! a display-width-1 overflow marker (`»`); rows that already fit are
//! emitted byte-identical (no marker).

const std = @import("std");
const lattice = @import("lattice.zig");
const prim = @import("prim");
const jt = @import("paint/junction_glyphs.zig");
const st = @import("paint/stroke_glyphs.zig");
const sg = @import("paint/shape_glyphs.zig");
const ag = @import("paint/arrow_glyphs.zig");

/// Right-edge overflow marker. U+00BB (`»`) is neither East-Asian-Wide
/// nor an emoji, so the width authority (through `prim.displayWidth`)
/// measures it at one column — a hard requirement: the marker must occupy
/// exactly one terminal column so the clipped row never exceeds
/// `max_width`.
const OVERFLOW_MARKER: u21 = '\u{00BB}';

comptime {
    std.debug.assert(prim.displayWidth("\u{00BB}") == 1);
}

pub fn paint(allocator: std.mem.Allocator, lat: lattice.Lattice, max_width: u32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    if (lat.width == 0 or lat.height == 0) return out.toOwnedSlice(allocator);

    var row: std.ArrayList(u8) = .empty;
    defer row.deinit(allocator);

    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        row.clearRetainingCapacity();

        // Track the running display column as we append; a cut only "counts" when the skipped cells hold real, non-blank content. // @guarded-by: paint.zig "paint: blank content beyond max_width budget earns no overflow marker"
        var col: u32 = 0;
        var cut_real_content = false;
        // Byte offset where the last cell that painted anything begins:
        // a whole grapheme, however many codepoints, so the marker can
        // replace exactly one painted glyph. @guarded-by: paint.zig "paint: marker stamping — an interned grapheme at the boundary is popped whole"
        var last_glyph_start: usize = 0;
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.atConst(x, y).*;
            const before = row.items.len;
            const w = try appendCell(allocator, &row, lat, cell);
            if (max_width != 0 and col + w > max_width) {
                row.items.len = before;
                if (rowHasContentFrom(lat, y, x)) cut_real_content = true;
                break;
            }
            if (row.items.len != before) last_glyph_start = before;
            col += w;
        }

        if (cut_real_content) {
            // Stamp the marker at the right edge: overwrite an exact-fill glyph, or fill a width-2 glyph's leftover gap. // @guarded-by: paint.zig "paint: marker stamping — width-1-exact-fill overwrites the last glyph" / "paint: marker stamping — width-2-at-boundary fills the leftover gap"
            if (col >= max_width) row.items.len = last_glyph_start;
            try appendCp(allocator, &row, OVERFLOW_MARKER);
        }

        const trimmed = trimTrailingSpaces(row.items);
        try out.appendSlice(allocator, trimmed);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

/// The glyph an interned `label_char` reference paints. A reference the
/// table cannot resolve is a producer bug; it paints U+FFFD at one column
/// so the row's column arithmetic never drifts from what was charged.
/// @guarded-by: paint.zig "paint: a dangling glyph reference paints U+FFFD at one column"
const dangling_glyph: lattice.Glyph = .{ .bytes = "\u{FFFD}", .width = 1 };

/// True iff any cell in row `y` at column ≥ `from_x` paints a non-space
/// glyph (i.e. real content was cut, not just trailing blanks).
fn rowHasContentFrom(lat: lattice.Lattice, y: u32, from_x: u32) bool {
    var x: u32 = from_x;
    while (x < lat.width) : (x += 1) {
        const cell = lat.atConst(x, y).*;
        switch (cell.occupant) {
            .empty, .node_interior, .label_cont => {},
            .label_char => |cp| if (cp != ' ') return true,
            .edge_segment => |seg| if (seg.kind != .invisible) return true,
            .node_border => |b| {
                if (cell.stroke_kind != .invisible) return true;
                _ = b;
            },
            else => return true,
        }
    }
    return false;
}

/// Paint one cell onto `row` and return the display columns it took:
/// blanks and node interiors are a single space; every glyph this painter
/// emits is display-width 1 (all box-drawing, arrowheads, and shape glyphs
/// are narrow); a label head is sized by its grapheme — the scalar's
/// isolated width, or the interned entry's. A `label_cont` is the second
/// cell of the wide glyph already charged to its head — it paints nothing
/// and costs no column, so the row's cell count and its column count agree.
/// @guarded-by: paint.zig "paint: a wide label glyph plus its continuation paints two columns from two cells"
/// @guarded-by: paint.zig "paint: an interned grapheme paints its bytes verbatim at its table width"
fn appendCell(
    allocator: std.mem.Allocator,
    row: *std.ArrayList(u8),
    lat: lattice.Lattice,
    cell: lattice.Cell,
) !u32 {
    switch (cell.occupant) {
        .empty, .node_interior => try row.append(allocator, ' '),
        .label_cont => return 0,
        .label_char => |cp| {
            if (lattice.isGlyphRef(cp)) {
                const glyph = lat.glyphOf(cp) orelse dangling_glyph;
                try row.appendSlice(allocator, glyph.bytes);
                return glyph.width;
            }
            try appendCp(allocator, row, cp);
            return prim.codepointWidth(cp);
        },
        .arrowhead => |a| try appendCp(allocator, row, ag.glyphFor(a.arrow, a.dir)),
        .edge_segment => |seg| {
            const glyph: u21 = switch (seg.kind) {
                .solid => jt.glyphFor(cell.neighbours),
                .dotted => st.dottedGlyph(cell.neighbours),
                .thick => st.thickGlyph(cell.neighbours),
                .invisible => ' ',
            };
            try appendCp(allocator, row, glyph);
        },
        .node_border => |b| {
            // Non-solid stroke takes precedence over shape-specific glyphs; solid borders use the shape-specific glyph. // @guarded-by: paint.zig "paint: non-solid stroke wins over shape glyph on node_border"
            const glyph: u21 = switch (cell.stroke_kind) {
                .solid => sg.glyphFor(cell.shape, b.role, cell.neighbours),
                .dotted => st.dottedBorderGlyph(cell.neighbours),
                .thick => st.thickBorderGlyph(cell.neighbours),
                .invisible => sg.glyphFor(cell.shape, b.role, cell.neighbours),
            };
            try appendCp(allocator, row, glyph);
        },
        .cluster_border => {
            const glyph: u21 = switch (cell.stroke_kind) {
                .solid => jt.glyphFor(cell.neighbours),
                .dotted => st.dottedBorderGlyph(cell.neighbours),
                .thick => st.thickBorderGlyph(cell.neighbours),
                .invisible => jt.glyphFor(cell.neighbours),
            };
            try appendCp(allocator, row, glyph);
        },
    }
    return 1;
}

fn appendCp(
    allocator: std.mem.Allocator,
    row: *std.ArrayList(u8),
    cp: u21,
) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try row.appendSlice(allocator, buf[0..n]);
}

fn trimTrailingSpaces(s: []const u8) []const u8 {
    var end: usize = s.len;
    while (end > 0 and s[end - 1] == ' ') : (end -= 1) {}
    return s[0..end];
}

const testing = std.testing;

test "paint: 0x0 lattice yields empty slice" {
    const a = testing.allocator;
    var cells: [0]lattice.Cell = .{};
    const lat = lattice.Lattice{ .width = 0, .height = 0, .cells = &cells };
    const got = try paint(a, lat, 1000);
    defer a.free(got);
    try testing.expectEqualStrings("", got);
}

test "paint: all-empty 3x2 lattice strips trailing spaces to two blank rows" {
    const a = testing.allocator;
    var cells: [6]lattice.Cell = undefined;
    for (&cells) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 3, .height = 2, .cells = &cells };
    const got = try paint(a, lat, 1000);
    defer a.free(got);
    try testing.expectEqualStrings("\n\n", got);
}

test "paint: single 3x3 rect node renders box-drawing border" {
    const a = testing.allocator;
    var cells: [9]lattice.Cell = undefined;
    for (&cells) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &cells };

    lat.at(0, 0).* = .{
        .occupant = .{ .node_border = .{ .node = 7, .role = .corner_nw } },
        .neighbours = .{ .e = true, .s = true },
    };
    lat.at(2, 0).* = .{
        .occupant = .{ .node_border = .{ .node = 7, .role = .corner_ne } },
        .neighbours = .{ .w = true, .s = true },
    };
    lat.at(2, 2).* = .{
        .occupant = .{ .node_border = .{ .node = 7, .role = .corner_se } },
        .neighbours = .{ .w = true, .n = true },
    };
    lat.at(0, 2).* = .{
        .occupant = .{ .node_border = .{ .node = 7, .role = .corner_sw } },
        .neighbours = .{ .e = true, .n = true },
    };
    lat.at(1, 0).* = .{
        .occupant = .{ .node_border = .{ .node = 7, .role = .edge_n } },
        .neighbours = .{ .e = true, .w = true },
    };
    lat.at(1, 2).* = .{
        .occupant = .{ .node_border = .{ .node = 7, .role = .edge_s } },
        .neighbours = .{ .e = true, .w = true },
    };
    lat.at(0, 1).* = .{
        .occupant = .{ .node_border = .{ .node = 7, .role = .edge_w } },
        .neighbours = .{ .n = true, .s = true },
    };
    lat.at(2, 1).* = .{
        .occupant = .{ .node_border = .{ .node = 7, .role = .edge_e } },
        .neighbours = .{ .n = true, .s = true },
    };
    lat.at(1, 1).* = .{ .occupant = .{ .node_interior = 7 }, .neighbours = .{} };

    const got = try paint(a, lat, 1000);
    defer a.free(got);
    try testing.expectEqualStrings("┌─┐\n│ │\n└─┘\n", got);
}

test "paint: an abutting arrowhead shows ▼ over a plain wall; a bare arrival tees" {
    const a = testing.allocator;
    const nb = lattice.Neighbours;
    var cells: [6]lattice.Cell = .{
        .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0, .arrow = .filled } }, .neighbours = nb{ .n = true } },
        .{ .occupant = .{ .edge_segment = .{ .edge = 1, .kind = .solid } }, .neighbours = nb{ .n = true, .s = true } },
        lattice.Cell.empty,
        .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } }, .neighbours = nb{ .e = true, .w = true } },
        .{ .occupant = .{ .node_border = .{ .node = 2, .role = .edge_n } }, .neighbours = nb{ .e = true, .w = true, .n = true } },
        .{ .occupant = .{ .node_border = .{ .node = 2, .role = .edge_w } }, .neighbours = nb{ .n = true, .s = true, .w = true } },
    };
    const lat = lattice.Lattice{ .width = 3, .height = 2, .cells = &cells };
    const got = try paint(a, lat, 1000);
    defer a.free(got);
    try testing.expectEqualStrings("▼│\n─┴┤\n", got);
}

test "paint: arrival port arms paint tees on the target border (unspoken-for ends)" {
    const a = testing.allocator;
    var cells: [3]lattice.Cell = .{
        .{
            .occupant = .{ .node_border = .{ .node = 1, .role = .edge_n } },
            .neighbours = .{ .e = true, .w = true, .n = true },
        },
        .{
            .occupant = .{ .node_border = .{ .node = 1, .role = .edge_w } },
            .neighbours = .{ .n = true, .s = true, .w = true },
        },
        .{
            .occupant = .{ .node_border = .{ .node = 1, .role = .edge_e } },
            .neighbours = .{ .n = true, .s = true, .e = true },
        },
    };
    const lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 1000);
    defer a.free(got);
    try testing.expectEqualStrings("┴┤├\n", got);
}

test "paint: label_char overlay in 1x1 lattice" {
    const a = testing.allocator;
    var cells: [1]lattice.Cell = .{
        .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} },
    };
    const lat = lattice.Lattice{ .width = 1, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 1000);
    defer a.free(got);
    try testing.expectEqualStrings("A\n", got);
}

test "paint: blank content beyond max_width budget earns no overflow marker" {
    const a = testing.allocator;
    var cells: [5]lattice.Cell = undefined;
    for (&cells) |*c| c.* = lattice.Cell.empty;
    cells[0] = .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = 'B' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 5, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 2);
    defer a.free(got);
    try testing.expectEqualStrings("AB\n", got);
}

test "paint: real content beyond max_width budget does earn an overflow marker" {
    const a = testing.allocator;
    var cells: [5]lattice.Cell = undefined;
    for (&cells) |*c| c.* = lattice.Cell.empty;
    cells[0] = .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = 'B' }, .neighbours = .{} };
    cells[2] = .{ .occupant = .{ .label_char = 'C' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 5, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 2);
    defer a.free(got);
    try testing.expectEqualStrings("A\u{00BB}\n", got);
}

test "paint: marker stamping — width-1-exact-fill overwrites the last glyph" {
    const a = testing.allocator;
    var cells: [4]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = 'B' }, .neighbours = .{} };
    cells[2] = .{ .occupant = .{ .label_char = 'C' }, .neighbours = .{} };
    cells[3] = .{ .occupant = .{ .label_char = 'D' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 4, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 3);
    defer a.free(got);
    try testing.expectEqualStrings("AB\u{00BB}\n", got);
}

test "paint: marker stamping — width-2-at-boundary fills the leftover gap" {
    const a = testing.allocator;
    var cells: [3]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = '\u{4E2D}' }, .neighbours = .{} };
    cells[2] = .{ .occupant = .{ .label_char = '\u{4E2D}' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 4);
    defer a.free(got);
    try testing.expectEqualStrings("A\u{4E2D}\u{00BB}\n", got);
}

test "paint: a wide label glyph plus its continuation paints two columns from two cells" {
    const a = testing.allocator;
    var cells: [3]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = '\u{65E5}' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .label_cont, .neighbours = .{} };
    cells[2] = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 0);
    defer a.free(got);
    try testing.expectEqualStrings("\u{65E5}x\n", got);
}

test "paint: a wide glyph at the clip boundary is never split and earns one marker" {
    const a = testing.allocator;
    var cells: [4]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = 'B' }, .neighbours = .{} };
    cells[2] = .{ .occupant = .{ .label_char = '\u{65E5}' }, .neighbours = .{} };
    cells[3] = .{ .occupant = .label_cont, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 4, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 3);
    defer a.free(got);
    try testing.expectEqualStrings("AB\u{00BB}\n", got);
}

test "paint: an interned grapheme paints its bytes verbatim at its table width" {
    const a = testing.allocator;
    const table = [_]lattice.Glyph{
        .{ .bytes = "e\u{0301}", .width = 1 },
        .{ .bytes = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", .width = 2 },
    };
    var cells: [5]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = 'c' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = lattice.glyphRef(0) }, .neighbours = .{} };
    cells[2] = .{ .occupant = .{ .label_char = lattice.glyphRef(1) }, .neighbours = .{} };
    cells[3] = .{ .occupant = .label_cont, .neighbours = .{} };
    cells[4] = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 5, .height = 1, .cells = &cells, .glyphs = &table };

    const got = try paint(a, lat, 0);
    defer a.free(got);
    try testing.expectEqualStrings("ce\u{0301}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}x\n", got);

    // The family is charged two columns: at a budget of 4 the row is
    // c, é, family — an exact fill — and x is cut, so the marker replaces
    // the family whole (all five codepoints), never a slice of it.
    const clipped = try paint(a, lat, 4);
    defer a.free(clipped);
    try testing.expectEqualStrings("ce\u{0301}\u{00BB}\n", clipped);
}

test "paint: marker stamping — an interned grapheme at the boundary is popped whole" {
    const a = testing.allocator;
    const table = [_]lattice.Glyph{.{ .bytes = "e\u{0301}", .width = 1 }};
    var cells: [4]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = 'B' }, .neighbours = .{} };
    cells[2] = .{ .occupant = .{ .label_char = lattice.glyphRef(0) }, .neighbours = .{} };
    cells[3] = .{ .occupant = .{ .label_char = 'D' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 4, .height = 1, .cells = &cells, .glyphs = &table };
    const got = try paint(a, lat, 3);
    defer a.free(got);
    // Exact fill at 3 columns: the whole "e\u{0301}" (two codepoints) goes,
    // never a bare "e" with a dangling combining mark under the marker.
    try testing.expectEqualStrings("AB\u{00BB}\n", got);
}

test "paint: a dangling glyph reference paints U+FFFD at one column" {
    const a = testing.allocator;
    var cells: [2]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = lattice.glyphRef(7) }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 2, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 0);
    defer a.free(got);
    try testing.expectEqualStrings("\u{FFFD}x\n", got);
}

test "paint: a trailing continuation alone never fabricates the overflow marker" {
    const a = testing.allocator;
    var cells: [3]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = '\u{65E5}' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .label_cont, .neighbours = .{} };
    cells[2] = .{ .occupant = .label_cont, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 2);
    defer a.free(got);
    try testing.expectEqualStrings("\u{65E5}\n", got);
}

test "paint: non-solid stroke wins over shape glyph on node_border" {
    const a = testing.allocator;
    const neighbours = lattice.Neighbours{ .e = true, .s = true };

    {
        var cells: [1]lattice.Cell = .{
            .{
                .occupant = .{ .node_border = .{ .node = 1, .role = .corner_nw } },
                .neighbours = neighbours,
                .stroke_kind = .thick,
                .shape = .round,
            },
        };
        const lat = lattice.Lattice{ .width = 1, .height = 1, .cells = &cells };
        const got = try paint(a, lat, 1000);
        defer a.free(got);
        try testing.expectEqualStrings("\u{250C}\n", got);
    }
    {
        var cells: [1]lattice.Cell = .{
            .{
                .occupant = .{ .node_border = .{ .node = 1, .role = .corner_nw } },
                .neighbours = neighbours,
                .stroke_kind = .dotted,
                .shape = .rhombus,
            },
        };
        const lat = lattice.Lattice{ .width = 1, .height = 1, .cells = &cells };
        const got = try paint(a, lat, 1000);
        defer a.free(got);
        try testing.expectEqualStrings("\u{250C}\n", got);
    }
}

test "paint: non-filled ArrowKinds paint their own glyphs" {
    const a = testing.allocator;
    const cases = [_]struct { kind: lattice.ArrowKind, want: []const u8 }{
        .{ .kind = .filled, .want = "▶\n" },
        .{ .kind = .open, .want = "▷\n" },
        .{ .kind = .circle, .want = "○\n" },
        .{ .kind = .cross, .want = "\u{2715}\n" },
    };
    for (cases) |c| {
        var cells: [1]lattice.Cell = .{
            .{
                .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 0, .arrow = c.kind } },
                .neighbours = .{},
            },
        };
        const lat = lattice.Lattice{ .width = 1, .height = 1, .cells = &cells };
        const got = try paint(a, lat, 1000);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "paint: arrowhead glyphs for all four directions" {
    const a = testing.allocator;
    const cases = [_]struct { dir: lattice.Dir4, want: []const u8 }{
        .{ .dir = .north, .want = "▲\n" },
        .{ .dir = .east, .want = "▶\n" },
        .{ .dir = .south, .want = "▼\n" },
        .{ .dir = .west, .want = "◀\n" },
    };
    for (cases) |c| {
        var cells: [1]lattice.Cell = .{
            .{
                .occupant = .{ .arrowhead = .{ .dir = c.dir, .edge = 0 } },
                .neighbours = .{},
            },
        };
        const lat = lattice.Lattice{ .width = 1, .height = 1, .cells = &cells };
        const got = try paint(a, lat, 1000);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

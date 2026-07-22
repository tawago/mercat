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

/// Right-edge overflow marker. U+00BB (`»`) is below 0x1100 so
/// `prim.codepointWidth` classifies it as display-width 1 — a hard
/// requirement: the marker must occupy exactly one terminal column so
/// the clipped row never exceeds `max_width`.
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

        // Track the running display column as we append; a cut only "counts" when the skipped cells hold real, non-blank content. // guarded-by: paint.zig "paint: blank content beyond max_width budget earns no overflow marker"
        var col: u32 = 0;
        var cut_real_content = false;
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.atConst(x, y).*;
            const w = cellWidth(cell);
            if (max_width != 0 and col + w > max_width) {
                if (rowHasContentFrom(lat, y, x)) cut_real_content = true;
                break;
            }
            try appendCell(allocator, &row, cell);
            col += w;
        }

        if (cut_real_content) {
            // Stamp the marker at the right edge: overwrite an exact-fill glyph, or fill a width-2 glyph's leftover gap. // guarded-by: paint.zig "paint: marker stamping — width-1-exact-fill overwrites the last glyph" / "paint: marker stamping — width-2-at-boundary fills the leftover gap"
            if (col >= max_width) popLastGlyph(&row);
            try appendCp(allocator, &row, OVERFLOW_MARKER);
        }

        const trimmed = trimTrailingSpaces(row.items);
        try out.appendSlice(allocator, trimmed);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

/// Display width contributed by one cell when painted. Mirrors
/// `appendCell`: blanks and node interiors are a single space; every
/// glyph this painter emits is display-width 1 (all box-drawing,
/// arrowheads, and shape glyphs are narrow), and label chars are sized
/// by their codepoint.
fn cellWidth(cell: lattice.Cell) u32 {
    return switch (cell.occupant) {
        .empty, .node_interior => 1,
        .label_char => |cp| prim.codepointWidth(cp),
        else => 1,
    };
}

/// True iff any cell in row `y` at column ≥ `from_x` paints a non-space
/// glyph (i.e. real content was cut, not just trailing blanks).
fn rowHasContentFrom(lat: lattice.Lattice, y: u32, from_x: u32) bool {
    var x: u32 = from_x;
    while (x < lat.width) : (x += 1) {
        const cell = lat.atConst(x, y).*;
        switch (cell.occupant) {
            .empty, .node_interior => {},
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

/// Remove the bytes of the last UTF-8 glyph appended to `row`. Used to
/// make room for the overflow marker at the final emitted column.
fn popLastGlyph(row: *std.ArrayList(u8)) void {
    var end: usize = row.items.len;
    if (end == 0) return;
    end -= 1;
    while (end > 0 and (row.items[end] & 0xC0) == 0x80) : (end -= 1) {}
    row.items.len = end;
}

fn appendCell(
    allocator: std.mem.Allocator,
    row: *std.ArrayList(u8),
    cell: lattice.Cell,
) !void {
    switch (cell.occupant) {
        .empty, .node_interior => try row.append(allocator, ' '),
        .label_char => |cp| try appendCp(allocator, row, cp),
        .arrowhead => |a| try appendCp(allocator, row, arrowGlyph(a.dir)),
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
            // Non-solid stroke takes precedence over shape-specific glyphs; solid borders use the shape-specific glyph. // guarded-by: paint.zig "paint: non-solid stroke wins over shape glyph on node_border"
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

fn arrowGlyph(d: lattice.Dir4) u21 {
    return switch (d) {
        .north => '▲',
        .east => '▶',
        .south => '▼',
        .west => '◀',
    };
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

    // Mirror raster/nodes.zig "single 3x3 rect" expectations.
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
    // width 5, only cells 0..1 hold real content ('A','B'); cells 2..4
    // stay `.empty` — blank-beyond-budget must not earn a marker.
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
    // Same shape as above, but cell 2 holds real content — the cut now
    // "counts" and must produce a marker (sanity check for the sibling
    // no-marker test above: proves the two cases are distinguishable).
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
    // Three width-1 glyphs exactly fill max_width=3; a 4th real glyph is
    // cut. col (3) >= max_width (3), so popLastGlyph fires: the last
    // emitted glyph ('C') is overwritten by the marker.
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
    // 'A' (width 1) + '中' (width 2) exactly fill max_width=4 (col=3, one
    // column short of the budget); the next width-2 glyph is cut. col (3)
    // < max_width (4), so popLastGlyph does NOT fire: the marker simply
    // fills the one-column gap after the emitted glyphs.
    var cells: [3]lattice.Cell = undefined;
    cells[0] = .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} };
    cells[1] = .{ .occupant = .{ .label_char = '\u{4E2D}' }, .neighbours = .{} };
    cells[2] = .{ .occupant = .{ .label_char = '\u{4E2D}' }, .neighbours = .{} };
    const lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &cells };
    const got = try paint(a, lat, 4);
    defer a.free(got);
    try testing.expectEqualStrings("A\u{4E2D}\u{00BB}\n", got);
}

test "paint: non-solid stroke wins over shape glyph on node_border" {
    const a = testing.allocator;
    const neighbours = lattice.Neighbours{ .e = true, .s = true };

    // A .round-shaped corner would normally render '╭' (shape override),
    // but a thick or dotted stroke merging into the border must win.
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
        // thick_border_table[e|s] = '┌', not the round-shape '╭'.
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
        // dottedBorderGlyph falls back to the solid junction table ('┌'),
        // not the rhombus-shape '◇'.
        try testing.expectEqualStrings("\u{250C}\n", got);
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

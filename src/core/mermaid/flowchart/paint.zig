const std = @import("std");
const lattice = @import("lattice.zig");
const prim = @import("prim");
const glyphs = @import("paint/glyphs.zig");

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

        var col: u32 = 0;
        var cut_real_content = false;
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
            if (col >= max_width) row.items.len = last_glyph_start;
            try appendCp(allocator, &row, OVERFLOW_MARKER);
        }

        const trimmed = trimTrailingSpaces(row.items);
        try out.appendSlice(allocator, trimmed);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

const dangling_glyph: lattice.Glyph = .{ .bytes = "\u{FFFD}", .width = 1 };

fn rowHasContentFrom(lat: lattice.Lattice, y: u32, from_x: u32) bool {
    var x: u32 = from_x;
    while (x < lat.width) : (x += 1) {
        const cell = lat.atConst(x, y).*;
        switch (cell.occupant) {
            .empty, .node_interior, .label_cont => {},
            .label_char => |cp| if (cp != ' ') return true,
            .edge_segment => |seg| if (seg.kind != .invisible) return true,
            .node_border => {
                if (cell.stroke_kind != .invisible) return true;
            },
            else => return true,
        }
    }
    return false;
}

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
        .edge_segment, .arrowhead, .node_border, .cluster_border => try appendCp(allocator, row, glyphs.ink(cell).?),
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

fn labelCell(cp: u21) lattice.Cell {
    return .{ .occupant = .{ .label_char = cp }, .neighbours = .{} };
}

test "paint: clipping, overflow marker and grapheme cells" {
    const a = testing.allocator;
    const E = lattice.Cell.empty;
    const C: lattice.Cell = .{ .occupant = .label_cont, .neighbours = .{} };
    const L = labelCell;
    const ref = lattice.glyphRef;
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const table = [_]lattice.Glyph{ .{ .bytes = "e\u{0301}", .width = 1 }, .{ .bytes = family, .width = 2 } };
    const Row = struct { cells: []const lattice.Cell, h: u32 = 1, max: u32, want: []const u8 };
    const rows = [_]Row{
        .{ .cells = &.{}, .h = 0, .max = 1000, .want = "" },
        .{ .cells = &.{ E, E, E, E, E, E }, .h = 2, .max = 1000, .want = "\n\n" }, // trailing spaces stripped
        .{ .cells = &.{ L('A'), L('B'), E, E, E }, .max = 2, .want = "AB\n" }, // blank overflow: no marker
        .{ .cells = &.{ L('A'), L('B'), L('C'), E, E }, .max = 2, .want = "A\u{00BB}\n" }, // real overflow: marker
        .{ .cells = &.{ L('A'), L('B'), L('C'), L('D') }, .max = 3, .want = "AB\u{00BB}\n" }, // exact fill: marker overwrites
        .{ .cells = &.{ L('A'), L('\u{4E2D}'), L('\u{4E2D}') }, .max = 4, .want = "A\u{4E2D}\u{00BB}\n" }, // marker fills the gap
        .{ .cells = &.{ L('\u{65E5}'), C, L('x') }, .max = 0, .want = "\u{65E5}x\n" }, // wide glyph + continuation
        .{ .cells = &.{ L('A'), L('B'), L('\u{65E5}'), C }, .max = 3, .want = "AB\u{00BB}\n" }, // wide glyph never split
        .{ .cells = &.{ L('c'), L(ref(0)), L(ref(1)), C, L('x') }, .max = 0, .want = "ce\u{0301}" ++ family ++ "x\n" }, // interned verbatim
        .{ .cells = &.{ L('c'), L(ref(0)), L(ref(1)), C, L('x') }, .max = 4, .want = "ce\u{0301}\u{00BB}\n" },
        .{ .cells = &.{ L('A'), L('B'), L(ref(0)), L('D') }, .max = 3, .want = "AB\u{00BB}\n" }, // interned popped whole
        .{ .cells = &.{ L(ref(7)), L('x') }, .max = 0, .want = "\u{FFFD}x\n" }, // dangling reference
        .{ .cells = &.{ L('\u{65E5}'), C, C }, .max = 2, .want = "\u{65E5}\n" }, // trailing continuation: no marker
    };
    for (rows) |r| {
        var buf: [8]lattice.Cell = undefined;
        @memcpy(buf[0..r.cells.len], r.cells);
        const w: u32 = if (r.h == 0) 0 else @intCast(r.cells.len / r.h);
        const lat = lattice.Lattice{ .width = w, .height = r.h, .cells = buf[0..r.cells.len], .glyphs = &table };
        const got = try paint(a, lat, r.max);
        defer a.free(got);
        try testing.expectEqualStrings(r.want, got);
    }
}

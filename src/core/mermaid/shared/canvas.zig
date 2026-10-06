const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode");
const types = @import("../types.zig");
const Rect = types.Rect;
const BoxChars = types.BoxChars;
const LineChars = types.LineChars;

pub const Priority = enum(u8) {
    background = 0,
    edge = 2,
    edge_label = 3,
    node_border = 4,
    node_text = 5,
};

pub const Cell = struct {
    char: u21 = ' ',
    priority: Priority = .background,

    /// Write `char` unless something of higher priority is there. An edge never overwrites an
    /// edge of the crossing orientation, so the first line drawn keeps the crossing.
    pub fn set(self: *Cell, char: u21, priority: Priority) bool {
        if (priority == .edge and self.priority == .edge) {
            if ((isHorizontal(self.char) and isVertical(char)) or
                (isVertical(self.char) and isHorizontal(char)))
            {
                return false;
            }
        }
        if (@intFromEnum(priority) < @intFromEnum(self.priority)) return false;
        self.char = char;
        self.priority = priority;
        return true;
    }
};

fn isHorizontal(char: u21) bool {
    return char == LineChars.horizontal or char == '-';
}

fn isVertical(char: u21) bool {
    return char == LineChars.vertical or char == '|';
}

const continuation: u21 = 0;
const glyph_base: u21 = 0x110000;

pub const Canvas = struct {
    allocator: Allocator,
    cells: [][]Cell,
    width: u32,
    height: u32,
    glyphs: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(allocator: Allocator, width: u32, height: u32) !Canvas {
        const cells = try allocator.alloc([]Cell, height);
        errdefer allocator.free(cells);

        for (cells, 0..) |*row, i| {
            row.* = try allocator.alloc(Cell, width);
            errdefer {
                for (cells[0..i]) |r| allocator.free(r);
            }
            @memset(row.*, Cell{});
        }

        return .{
            .allocator = allocator,
            .cells = cells,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Canvas) void {
        for (self.glyphs.items) |glyph| self.allocator.free(glyph);
        self.glyphs.deinit(self.allocator);
        for (self.cells) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.cells);
    }

    pub fn getCell(self: *Canvas, x: i32, y: i32) ?*Cell {
        if (x < 0 or y < 0) return null;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        if (ux >= self.width or uy >= self.height) return null;
        return &self.cells[uy][ux];
    }

    /// Overwriting either half of a wide grapheme blanks the other half, so the row keeps one
    /// terminal column per cell.
    pub fn setChar(self: *Canvas, x: i32, y: i32, char: u21, priority: Priority) void {
        const cell = self.getCell(x, y) orelse return;
        const was = cell.char;
        if (!cell.set(char, priority)) return;
        if (char == continuation) return;
        if (was == continuation) {
            if (self.getCell(x - 1, y)) |lead| lead.char = ' ';
        }
        if (self.getCell(x + 1, y)) |next| {
            if (next.char == continuation) next.char = ' ';
        }
    }

    pub fn drawBox(self: *Canvas, rect: Rect, style: BoxChars, priority: Priority) void {
        const x = rect.x;
        const y = rect.y;
        const w: i32 = @intCast(rect.width);
        const h: i32 = @intCast(rect.height);

        self.setChar(x, y, style.top_left, priority);
        self.setChar(x + w - 1, y, style.top_right, priority);
        self.setChar(x, y + h - 1, style.bottom_left, priority);
        self.setChar(x + w - 1, y + h - 1, style.bottom_right, priority);

        var col = x + 1;
        while (col < x + w - 1) : (col += 1) {
            self.setChar(col, y, style.horizontal, priority);
            self.setChar(col, y + h - 1, style.horizontal, priority);
        }

        var row = y + 1;
        while (row < y + h - 1) : (row += 1) {
            self.setChar(x, row, style.vertical, priority);
            self.setChar(x + w - 1, row, style.vertical, priority);
        }
    }

    pub fn drawText(self: *Canvas, x: i32, y: i32, text: []const u8, priority: Priority) void {
        if (scalarTextWidth(text) == null) return;

        var col = x;
        var it = unicode.Iterator.init(text);
        while (it.next() catch unreachable) |grapheme| {
            const cp = singleScalar(grapheme.bytes).?;
            self.setChar(col, y, cp, priority);
            col += @intCast(grapheme.width);
        }
    }

    /// Like drawText, but every grapheme is drawn whole in its first cell and the rest of its
    /// columns become continuation cells that print nothing, so the row keeps one terminal column
    /// per cell. A tab is drawn as blanks and a grapheme without a base is drawn on a space as
    /// wide as the grapheme.
    pub fn drawTextSpanning(self: *Canvas, x: i32, y: i32, text: []const u8, priority: Priority) Allocator.Error!void {
        var col = x;
        var it = unicode.Iterator.init(text);
        while (it.next() catch return) |grapheme| {
            const blank = std.mem.eql(u8, grapheme.bytes, "\t");
            const lead: u21 = if (blank)
                ' '
            else if (unicode.lacksBase(grapheme.bytes))
                try self.intern(padFor(grapheme.bytes, grapheme.width), grapheme.bytes)
            else
                singleScalar(grapheme.bytes) orelse try self.intern("", grapheme.bytes);
            self.setChar(col, y, lead, priority);
            var rest: i32 = 1;
            while (rest < grapheme.width) : (rest += 1) self.setChar(col + rest, y, if (blank) ' ' else continuation, priority);
            col += @intCast(grapheme.width);
        }
    }

    fn intern(self: *Canvas, base: []const u8, grapheme: []const u8) Allocator.Error!u21 {
        const glyph = try std.mem.concat(self.allocator, u8, &.{ base, grapheme });
        errdefer self.allocator.free(glyph);
        try self.glyphs.append(self.allocator, glyph);
        return glyph_base + @as(u21, @intCast(self.glyphs.items.len - 1));
    }

    pub fn drawTextCentered(self: *Canvas, rect: Rect, text: []const u8, priority: Priority) void {
        const text_len: i32 = @intCast(scalarTextWidth(text) orelse return);
        const box_width: i32 = @intCast(rect.width);
        const box_height: i32 = @intCast(rect.height);

        const x = rect.x + @divFloor(box_width - text_len, 2);
        const y = rect.y + @divFloor(box_height, 2);

        self.drawText(x, y, text, priority);
    }

    pub fn drawTextCenteredSpanning(self: *Canvas, rect: Rect, text: []const u8, priority: Priority) Allocator.Error!void {
        const text_width: i32 = @intCast(unicode.rawDisplayWidth(text) catch return);
        const x = rect.x + @divFloor(@as(i32, @intCast(rect.width)) - text_width, 2);
        try self.drawTextSpanning(x, rect.y + @divFloor(@as(i32, @intCast(rect.height)), 2), text, priority);
    }

    pub fn drawHorizontalLine(self: *Canvas, y: i32, x1: i32, x2: i32, char: u21, priority: Priority) void {
        const start = @min(x1, x2);
        const end = @max(x1, x2);
        var x = start;
        while (x <= end) : (x += 1) {
            self.setChar(x, y, char, priority);
        }
    }

    pub fn drawVerticalLine(self: *Canvas, x: i32, y1: i32, y2: i32, char: u21, priority: Priority) void {
        const start = @min(y1, y2);
        const end = @max(y1, y2);
        var y = start;
        while (y <= end) : (y += 1) {
            self.setChar(x, y, char, priority);
        }
    }

    pub fn toString(self: *Canvas, allocator: Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var encode_buf: [4]u8 = undefined;

        for (self.cells, 0..) |row, y| {
            var last_non_space: usize = 0;
            for (row, 0..) |cell, x| {
                if (cell.char != ' ') {
                    last_non_space = x + 1;
                }
            }

            for (row[0..last_non_space]) |cell| {
                if (cell.char == continuation) continue;
                if (cell.char >= glyph_base) {
                    try result.appendSlice(allocator, self.glyphs.items[cell.char - glyph_base]);
                    continue;
                }
                const len = std.unicode.utf8Encode(cell.char, &encode_buf) catch 1;
                try result.appendSlice(allocator, encode_buf[0..len]);
            }

            if (y < self.cells.len - 1 or last_non_space > 0) {
                try result.append(allocator, '\n');
            }
        }

        return result.toOwnedSlice(allocator);
    }
};

/// The display width of `text` when every grapheme is one scalar and none is a tab, else null:
/// text the canvas cannot place one scalar to a cell is left out whole.
fn scalarTextWidth(text: []const u8) ?usize {
    var width: usize = 0;
    var it = unicode.Iterator.init(text);
    while (it.next() catch return null) |grapheme| {
        const cp = singleScalar(grapheme.bytes) orelse return null;
        if (cp == '\t') return null;
        width = grapheme.column_end;
    }
    return width;
}

/// The base a baseless grapheme is drawn on: a space, or an ideographic space under a mark measured
/// wide. An emoji modifier is wide on its own, so it takes a space.
fn padFor(bytes: []const u8, width: usize) []const u8 {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return " ";
    const first = std.unicode.utf8Decode(bytes[0..len]) catch return " ";
    return if (width == 2 and !unicode.isEmojiModifier(first)) "\u{3000}" else " ";
}

fn singleScalar(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (len != bytes.len) return null;
    return std.unicode.utf8Decode(bytes) catch null;
}

test "Canvas basic operations" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 20, 10);
    defer canvas.deinit();

    canvas.setChar(5, 5, 'X', .node_text);
    const cell = canvas.getCell(5, 5).?;
    try testing.expectEqual(@as(u21, 'X'), cell.char);

    try testing.expect(canvas.getCell(-1, 0) == null);
    try testing.expect(canvas.getCell(20, 0) == null);
}

test "Canvas draw box" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 10, 5);
    defer canvas.deinit();

    canvas.drawBox(.{ .x = 0, .y = 0, .width = 5, .height = 3 }, types.unicode_square, .node_border);

    try testing.expectEqual(types.unicode_square.top_left, canvas.getCell(0, 0).?.char);
    try testing.expectEqual(types.unicode_square.top_right, canvas.getCell(4, 0).?.char);
    try testing.expectEqual(types.unicode_square.bottom_left, canvas.getCell(0, 2).?.char);
    try testing.expectEqual(types.unicode_square.bottom_right, canvas.getCell(4, 2).?.char);
}

test "Canvas toString" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 5, 3);
    defer canvas.deinit();

    canvas.drawText(0, 0, "Hi", .node_text);
    canvas.drawText(0, 2, "Lo", .node_text);

    const str = try canvas.toString(testing.allocator);
    defer testing.allocator.free(str);

    try testing.expectEqualStrings("Hi\n\nLo\n", str);
}

test "drawText decodes multi-byte UTF-8 into one scalar per cell" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 10, 2);
    defer canvas.deinit();

    canvas.drawText(0, 0, "◁A◆", .node_text);
    try testing.expectEqual(@as(u21, 0x25C1), canvas.getCell(0, 0).?.char);
    try testing.expectEqual(@as(u21, 'A'), canvas.getCell(1, 0).?.char);
    try testing.expectEqual(@as(u21, 0x25C6), canvas.getCell(2, 0).?.char);

    const str = try canvas.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("◁A◆\n", str);
}

test "drawText uses authority width for ASCII and CJK scalars" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 12, 1);
    defer canvas.deinit();

    canvas.drawText(0, 0, "A日B", .node_text);
    try testing.expectEqual(@as(u21, 'A'), canvas.getCell(0, 0).?.char);
    try testing.expectEqual(@as(u21, 0x65E5), canvas.getCell(1, 0).?.char);
    try testing.expectEqual(@as(u21, ' '), canvas.getCell(2, 0).?.char);
    try testing.expectEqual(@as(u21, 'B'), canvas.getCell(3, 0).?.char);

    const str = try canvas.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("A日 B\n", str);

    canvas.drawTextCentered(.{ .x = 4, .y = 0, .width = 7, .height = 1 }, "日", .node_text);
    try testing.expectEqual(@as(u21, 0x65E5), canvas.getCell(6, 0).?.char);
}

test "drawTextSpanning keeps one terminal column per cell after a wide grapheme" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 6, 1);
    defer canvas.deinit();

    try canvas.drawTextSpanning(0, 0, "A日B", .node_text);
    canvas.setChar(5, 0, '|', .edge);
    const str = try canvas.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("A日B |\n", str);

    var tabbed = try Canvas.init(testing.allocator, 8, 1);
    defer tabbed.deinit();
    try tabbed.drawTextSpanning(0, 0, "ab\tc", .node_text);
    tabbed.setChar(7, 0, '|', .edge);
    const spaced = try tabbed.toString(testing.allocator);
    defer testing.allocator.free(spaced);
    try testing.expectEqualStrings("ab  c  |\n", spaced);
}

test "drawTextSpanning draws every grapheme whole and keeps the column after it" {
    const testing = std.testing;
    const cases = [_]struct { text: []const u8, row: []const u8 }{
        .{ .text = "Cafe\u{0301}!", .row = "Cafe\u{0301}!  |" },
        .{ .text = "\u{304B}\u{3099}!", .row = "\u{304B}\u{3099}!    |" },
        .{ .text = "\u{2764}\u{FE0F}!", .row = "\u{2764}\u{FE0F}!    |" },
        .{ .text = "🇯🇵!", .row = "🇯🇵!    |" },
        .{ .text = "👩‍💻!", .row = "👩‍💻!    |" },
        .{ .text = "\u{0301}x", .row = " \u{0301}x     |" },
        .{ .text = "\u{3099}x", .row = "\u{3000}\u{3099}x    |" },
    };
    for (cases) |case| {
        var canvas = try Canvas.init(testing.allocator, 8, 1);
        defer canvas.deinit();
        try canvas.drawTextSpanning(0, 0, case.text, .edge_label);
        canvas.setChar(7, 0, '|', .edge);
        const str = try canvas.toString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings(case.row, str[0 .. str.len - 1]);
        try testing.expectEqual(@as(usize, 8), try unicode.rawDisplayWidth(str[0 .. str.len - 1]));
    }
}

test "a lone emoji modifier opening a line is drawn on a space, keeping the cell before it" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 6, 1);
    defer canvas.deinit();
    canvas.setChar(0, 0, '|', .edge);
    try canvas.drawTextSpanning(1, 0, "🏽x", .edge_label);
    canvas.setChar(5, 0, '|', .edge);
    const str = try canvas.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("| 🏽x |\n", str);
    try testing.expectEqual(@as(usize, 6), try unicode.rawDisplayWidth(str[0 .. str.len - 1]));
}

test "overwriting a whole grapheme blanks its continuation" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 6, 1);
    defer canvas.deinit();
    try canvas.drawTextSpanning(0, 0, "👩‍💻👩‍💻", .edge_label);
    canvas.setChar(0, 0, '|', .node_border);
    canvas.setChar(5, 0, '#', .edge);
    const str = try canvas.toString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("| 👩‍💻 #\n", str);
}

test "overwriting either half of a wide grapheme blanks its partner" {
    const testing = std.testing;
    for ([_]i32{ 1, 2 }) |hit| {
        var canvas = try Canvas.init(testing.allocator, 6, 1);
        defer canvas.deinit();
        try canvas.drawTextSpanning(0, 0, "a日本", .edge_label);
        canvas.setChar(hit, 0, '|', .node_border);
        canvas.setChar(5, 0, '#', .edge);
        const str = try canvas.toString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqual(@as(usize, 6), try unicode.rawDisplayWidth(str[0 .. str.len - 1]));
        try testing.expect(std.mem.indexOf(u8, str, "本") != null);
        try testing.expect(std.mem.indexOf(u8, str, "日") == null);
    }
}

test "drawText declines invalid UTF-8 controls and tabs atomically" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 12, 1);
    defer canvas.deinit();

    canvas.drawText(0, 0, "A\x80B", .node_text);
    canvas.drawText(3, 0, "A\nB", .node_text);
    canvas.drawText(6, 0, "A\tB", .node_text);
    for (canvas.cells[0]) |cell| try testing.expectEqual(@as(u21, ' '), cell.char);
}

test "drawText declines combining and ZWJ graphemes atomically" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 12, 1);
    defer canvas.deinit();

    canvas.drawText(0, 0, "e\u{0301}X", .node_text);
    canvas.drawTextCentered(.{ .x = 4, .y = 0, .width = 8, .height = 1 }, "👩‍💻", .node_text);
    for (canvas.cells[0]) |cell| try testing.expectEqual(@as(u21, ' '), cell.char);
}

test "Canvas priority" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 10, 5);
    defer canvas.deinit();

    canvas.setChar(2, 2, 'A', .edge);
    canvas.setChar(2, 2, 'B', .edge);
    try testing.expectEqual(@as(u21, 'B'), canvas.getCell(2, 2).?.char);

    canvas.setChar(2, 2, 'C', .background);
    try testing.expectEqual(@as(u21, 'B'), canvas.getCell(2, 2).?.char);

    canvas.setChar(2, 2, 'D', .node_text);
    try testing.expectEqual(@as(u21, 'D'), canvas.getCell(2, 2).?.char);
}

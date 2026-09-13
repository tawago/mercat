const std = @import("std");
const markdown = @import("../parser.zig");
const line_mod = @import("line.zig");
const builder_mod = @import("builder.zig");
const inline_mod = @import("inline.zig");
const geometry = @import("geometry.zig");
const decor_mod = @import("decor.zig");

const Block = markdown.Block;
const Inline = markdown.Inline;
const SpanStyle = line_mod.SpanStyle;
const Builder = builder_mod.Builder;
const Decor = decor_mod.Decor;
const TableStyle = decor_mod.TableStyle;

pub fn renderTable(allocator: std.mem.Allocator, builder: *Builder, table: Block.Table, max_width: usize, decor: *const Decor) !void {
    if (table.rows.len == 0) return;

    var max_columns: usize = 0;
    for (table.rows) |row| max_columns = @max(max_columns, row.cells.len);

    const widths = try allocator.alloc(usize, max_columns);
    defer allocator.free(widths);
    @memset(widths, 0);

    // Natural widths first, column by column: each column's text position
    // depends on the widths already settled to its left.
    const boxed = decor.glyphs.table_style == .rounded;
    for (0..max_columns) |index| {
        const text_column = cellTextColumn(builder.left_padding, widths, index, boxed);
        for (table.rows) |row| {
            if (index >= row.cells.len) continue;
            widths[index] = @max(widths[index], try inline_mod.inlinesDisplayWidthFrom(allocator, row.cells[index], text_column));
        }
    }

    try fitColumnWidths(widths, max_width);

    switch (decor.glyphs.table_style) {
        .rounded => try renderRounded(allocator, builder, table, widths),
        else => |style| try renderGrid(allocator, builder, table, widths, tableTriple(style)),
    }
}

/// The concrete (horizontal, vertical, cross) box-drawing triple for a widened
/// `TableStyle`. Restores #17's four border weights so `heavy`/`double`/`ascii`
/// render again; every glyph is display-width 1, so column math is unchanged.
/// `rounded` draws its own bordered box (see `renderRounded`) and falls back to
/// the light triple here for any interior rule math.
const Triple = struct { h: []const u8, v: []const u8, cross: []const u8 };

fn tableTriple(style: TableStyle) Triple {
    return switch (style) {
        .grid, .rounded => .{ .h = "\u{2500}", .v = "\u{2502}", .cross = "\u{253c}" },
        .heavy => .{ .h = "\u{2501}", .v = "\u{2503}", .cross = "\u{254b}" },
        .double => .{ .h = "\u{2550}", .v = "\u{2551}", .cross = "\u{256c}" },
        .ascii => .{ .h = "-", .v = "|", .cross = "+" },
    };
}

/// The historical grid table: a header, a `─`/`┼` rule, then rows separated by
/// `│`. With the light triple this is byte-identical to the pre-theme renderer;
/// the header row is styled `.table_header`, borders `.table_border` (both
/// default to their historical borrowed tokens so parity holds).
fn renderGrid(allocator: std.mem.Allocator, builder: *Builder, table: Block.Table, widths: []const usize, triple: Triple) !void {
    for (table.rows, 0..) |row, index| {
        if (index != 0) try builder.newline();
        const cell_style: SpanStyle = if (index == 0) .table_header else .body;
        try appendTableRow(allocator, builder, row, widths, table.alignments, triple, cell_style);
        if (index == 0) {
            try builder.newline();
            try appendTableRule(builder, widths, triple);
        }
    }
}

const RoundedGlyphs = struct {
    tl: []const u8 = "\u{256D}",
    tr: []const u8 = "\u{256E}",
    bl: []const u8 = "\u{2570}",
    br: []const u8 = "\u{256F}",
    tj: []const u8 = "\u{252C}",
    bj: []const u8 = "\u{2534}",
    lj: []const u8 = "\u{251C}",
    rj: []const u8 = "\u{2524}",
    cross: []const u8 = "\u{253C}",
    h: []const u8 = "\u{2500}",
    v: []const u8 = "\u{2502}",
};

/// Rounded box table (markview): full top/bottom/side borders with rounded
/// corners and a header separator.
fn renderRounded(allocator: std.mem.Allocator, builder: *Builder, table: Block.Table, widths: []const usize) !void {
    const g = RoundedGlyphs{};
    try appendRoundedBorder(builder, widths, g, g.tl, g.tj, g.tr);
    for (table.rows, 0..) |row, index| {
        try builder.newline();
        const cell_style: SpanStyle = if (index == 0) .table_header else .body;
        try appendRoundedRow(allocator, builder, row, widths, table.alignments, g, cell_style);
        if (index == 0) {
            try builder.newline();
            try appendRoundedBorder(builder, widths, g, g.lj, g.cross, g.rj);
        }
    }
    try builder.newline();
    try appendRoundedBorder(builder, widths, g, g.bl, g.bj, g.br);
}

fn appendRoundedBorder(builder: *Builder, widths: []const usize, g: RoundedGlyphs, left: []const u8, mid: []const u8, right: []const u8) !void {
    try builder.appendSpan(.table_border, left);
    for (widths, 0..) |width, index| {
        if (index != 0) try builder.appendSpan(.table_border, mid);
        try builder.appendRepeated(.table_border, g.h, width + 2);
    }
    try builder.appendSpan(.table_border, right);
}

fn appendRoundedRow(allocator: std.mem.Allocator, builder: *Builder, row: Block.TableRow, widths: []const usize, alignments: []const Block.Table.Alignment, g: RoundedGlyphs, cell_style: SpanStyle) !void {
    try appendRowCells(allocator, builder, row, widths, alignments, g.v, true, cell_style);
}

/// Shared table-cell emitter for both grid and rounded rows. Wraps each cell,
/// aligns/pads it, and separates columns with `vbar`. When `boxed`, `vbar` also
/// frames the row's outer edges (rounded style); otherwise it appears only
/// between columns (grid style).
fn appendRowCells(allocator: std.mem.Allocator, builder: *Builder, row: Block.TableRow, widths: []const usize, alignments: []const Block.Table.Alignment, vbar: []const u8, boxed: bool, cell_style: SpanStyle) !void {
    var wrapped_cells = try allocator.alloc([][]const u8, widths.len);
    defer allocator.free(wrapped_cells);
    var row_height: usize = 1;
    for (widths, 0..) |width, index| {
        const cell_inlines = if (index < row.cells.len) row.cells[index] else &[_]Inline{};
        const cell_text = try inline_mod.inlinesToText(allocator, cell_inlines);
        defer allocator.free(cell_text);
        wrapped_cells[index] = try wrapCell(allocator, cell_text, @max(width, 1), cellTextColumn(builder.left_padding, widths, index, boxed));
        row_height = @max(row_height, wrapped_cells[index].len);
    }
    defer {
        for (wrapped_cells) |wrapped| {
            for (wrapped) |line| allocator.free(line);
            allocator.free(wrapped);
        }
    }
    for (0..row_height) |line_index| {
        if (line_index != 0) try builder.newline();
        if (boxed) try builder.appendSpan(.table_border, vbar);
        for (widths, 0..) |width, index| {
            const cell_line = if (line_index < wrapped_cells[index].len) wrapped_cells[index][line_index] else "";
            const alignment = if (index < alignments.len) alignments[index] else .none;
            const text_column = cellTextColumn(builder.left_padding, widths, index, boxed);
            const pad_left, const pad_right = try alignmentPadding(cell_line, width, text_column, alignment);
            try builder.appendSpan(cell_style, " ");
            if (pad_left != 0) try appendSpaces(builder, pad_left, cell_style);
            try builder.appendSpan(cell_style, cell_line);
            if (pad_right != 0) try appendSpaces(builder, pad_right, cell_style);
            try builder.appendSpan(cell_style, " ");
            if (boxed or index + 1 < widths.len) try builder.appendSpan(.table_border, vbar);
        }
    }
}

pub fn appendTableRule(builder: *Builder, widths: []const usize, triple: Triple) !void {
    for (widths, 0..) |width, index| {
        if (index != 0) try builder.appendSpan(.table_border, triple.cross);
        try builder.appendRepeated(.table_border, triple.h, width + 2);
    }
}

pub fn appendTableRow(allocator: std.mem.Allocator, builder: *Builder, row: Block.TableRow, widths: []const usize, alignments: []const Block.Table.Alignment, triple: Triple, cell_style: SpanStyle) !void {
    try appendRowCells(allocator, builder, row, widths, alignments, triple.v, false, cell_style);
}

pub fn fitColumnWidths(widths: []usize, max_width: usize) !void {
    if (widths.len == 0) return;
    const separator_width = if (widths.len > 1) (widths.len - 1) * 1 else 0;
    const cell_padding = widths.len * 2;
    var total: usize = separator_width + cell_padding;
    for (widths) |width| total += width;
    if (total <= max_width) return;

    var overflow = total - max_width;
    while (overflow > 0) {
        var widest_index: ?usize = null;
        var widest_value: usize = 0;
        for (widths, 0..) |width, index| {
            if (width > widest_value and width > 8) {
                widest_value = width;
                widest_index = index;
            }
        }
        if (widest_index == null) break;
        widths[widest_index.?] -= 1;
        overflow -= 1;
    }
}

pub fn appendSpaces(builder: *Builder, count: usize, style: SpanStyle) !void {
    try builder.appendRepeated(style, " ", count);
}

/// Strict source-preserving wrapping for a table cell. Long words are split at
/// extended-grapheme boundaries; tabs retain their source byte here and are
/// expanded later when the complete output row is prepared.
fn wrapCell(allocator: std.mem.Allocator, text: []const u8, width: usize, initial_column: usize) ![][]const u8 {
    var output: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (output.items) |line| allocator.free(line);
        output.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var current_width: usize = 0;

    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        const remaining = word;
        while (remaining.len != 0) {
            const separator: usize = @intFromBool(current.items.len != 0);
            const word_width = try geometry.displayWidthFrom(remaining, initial_column + current_width + separator);
            if (current_width + separator + word_width <= width) {
                if (separator != 0) try current.append(allocator, ' ');
                try current.appendSlice(allocator, remaining);
                current_width += separator + word_width;
                break;
            }
            if (current.items.len != 0) {
                try output.append(allocator, try current.toOwnedSlice(allocator));
                current_width = 0;
                continue;
            }
            try current.appendSlice(allocator, remaining);
            current_width = word_width;
            break;
        }
    }
    if (current.items.len != 0) try output.append(allocator, try current.toOwnedSlice(allocator));
    if (output.items.len == 0) try output.append(allocator, try allocator.dupe(u8, ""));
    return output.toOwnedSlice(allocator);
}

fn cellTextColumn(left_padding: usize, widths: []const usize, index: usize, boxed: bool) usize {
    var column = left_padding + @intFromBool(boxed);
    for (widths[0..index]) |width| column += width + 3;
    return column + 1;
}

fn alignmentPadding(text: []const u8, width: usize, base_column: usize, alignment: Block.Table.Alignment) !struct { usize, usize } {
    const text_width = try geometry.displayWidthFrom(text, base_column);
    if (alignment == .left or alignment == .none) return .{ 0, width -| text_width };

    // Only a tab makes the text's width depend on where it starts; any other
    // cell aligns arithmetically from the one measurement above.
    if (std.mem.indexOfScalar(u8, text, '\t') == null) {
        const remaining = width -| text_width;
        const left = if (alignment == .right) remaining else remaining / 2;
        return .{ left, remaining - left };
    }

    var best_left: usize = 0;
    var best_right: usize = 0;
    var best_balance: usize = std.math.maxInt(usize);
    for (0..width + 1) |left| {
        const shifted_width = try geometry.displayWidthFrom(text, base_column + left);
        if (left + shifted_width > width) continue;
        const right = width - left - shifted_width;
        if (alignment == .right) {
            if (left >= best_left) {
                best_left = left;
                best_right = right;
            }
            continue;
        }
        const balance = if (left > right) left - right else right - left;
        if (balance < best_balance) {
            best_balance = balance;
            best_left = left;
            best_right = right;
        }
    }
    return .{ best_left, best_right };
}

const testing = std.testing;

test "tableTriple maps each weighted variant to its box-drawing glyphs" {
    try testing.expectEqualStrings("\u{2500}", tableTriple(.grid).h);
    try testing.expectEqualStrings("\u{253c}", tableTriple(.grid).cross);
    try testing.expectEqualStrings("\u{2501}", tableTriple(.heavy).h);
    try testing.expectEqualStrings("\u{2503}", tableTriple(.heavy).v);
    try testing.expectEqualStrings("\u{254b}", tableTriple(.heavy).cross);
    try testing.expectEqualStrings("\u{2550}", tableTriple(.double).h);
    try testing.expectEqualStrings("\u{2551}", tableTriple(.double).v);
    try testing.expectEqualStrings("\u{256c}", tableTriple(.double).cross);
    try testing.expectEqualStrings("-", tableTriple(.ascii).h);
    try testing.expectEqualStrings("|", tableTriple(.ascii).v);
    try testing.expectEqualStrings("+", tableTriple(.ascii).cross);
    try testing.expectEqualStrings("\u{2500}", tableTriple(.rounded).h);
}

/// Render a 2x2 table under `style` and return the concatenated span text (one
/// newline per rendered row). Fixtures are stack literals — `renderTable` never
/// frees the table it consumes.
fn renderTableWith(allocator: std.mem.Allocator, style: TableStyle) ![]u8 {
    var cell_a = [_]Inline{.{ .text = "A" }};
    var cell_b = [_]Inline{.{ .text = "B" }};
    var cell_1 = [_]Inline{.{ .text = "1" }};
    var cell_2 = [_]Inline{.{ .text = "2" }};
    var header = [_][]Inline{ &cell_a, &cell_b };
    var body = [_][]Inline{ &cell_1, &cell_2 };
    var rows = [_]Block.TableRow{ .{ .cells = &header }, .{ .cells = &body } };
    var alignments = [_]Block.Table.Alignment{ .none, .none };
    const table = Block.Table{ .rows = &rows, .alignments = &alignments };

    var d = decor_mod.legacy;
    d.glyphs.table_style = style;

    var builder = Builder.init(allocator);
    defer builder.deinit();
    try renderTable(allocator, &builder, table, 80, &d);
    const lines = try builder.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (lines) |line| {
        for (line.spans) |span| try out.appendSlice(allocator, span.text);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "renderTable draws all five TableStyle variants with distinct borders" {
    const allocator = testing.allocator;

    inline for (.{
        .{ .style = TableStyle.grid, .h = "\u{2500}", .v = "\u{2502}", .cross = "\u{253c}" },
        .{ .style = TableStyle.heavy, .h = "\u{2501}", .v = "\u{2503}", .cross = "\u{254b}" },
        .{ .style = TableStyle.double, .h = "\u{2550}", .v = "\u{2551}", .cross = "\u{256c}" },
        .{ .style = TableStyle.ascii, .h = "-", .v = "|", .cross = "+" },
    }) |c| {
        const out = try renderTableWith(allocator, c.style);
        defer allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, c.h) != null);
        try testing.expect(std.mem.indexOf(u8, out, c.v) != null);
        try testing.expect(std.mem.indexOf(u8, out, c.cross) != null);
        try testing.expect(std.mem.indexOf(u8, out, "A") != null);
        try testing.expect(std.mem.indexOf(u8, out, "2") != null);
    }

    const ascii = try renderTableWith(allocator, .ascii);
    defer allocator.free(ascii);
    try testing.expect(std.mem.indexOf(u8, ascii, "\u{2500}") == null);

    const rounded = try renderTableWith(allocator, .rounded);
    defer allocator.free(rounded);
    try testing.expect(std.mem.indexOf(u8, rounded, "\u{256D}") != null);
    try testing.expect(std.mem.indexOf(u8, rounded, "\u{256E}") != null);
    try testing.expect(std.mem.indexOf(u8, rounded, "\u{2570}") != null);
    try testing.expect(std.mem.indexOf(u8, rounded, "\u{256F}") != null);
    try testing.expect(std.mem.indexOf(u8, rounded, "\u{2502}") != null);
}

test "a very wide table row builds in time linear in its width" {
    const allocator = testing.allocator;

    const wide = try allocator.alloc(u8, 20_000);
    defer allocator.free(wide);
    @memset(wide, 'w');

    var cell_head = [_]Inline{.{ .text = "h" }};
    var cell_body = [_]Inline{.{ .text = wide }};
    var header = [_][]Inline{&cell_head};
    var body = [_][]Inline{&cell_body};
    var rows = [_]Block.TableRow{ .{ .cells = &header }, .{ .cells = &body } };
    var alignments = [_]Block.Table.Alignment{.none};
    const table = Block.Table{ .rows = &rows, .alignments = &alignments };

    var d = decor_mod.legacy;
    d.glyphs.table_style = .rounded;

    var builder = Builder.init(allocator);
    defer builder.deinit();
    try renderTable(allocator, &builder, table, 20_000, &d);
    const lines = try builder.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }

    try testing.expect(lines.len >= 4);
    try testing.expect(lines[0].spans.len <= 4);

    var border_width: usize = 0;
    for (lines[0].spans) |span| border_width += try geometry.displayWidth(span.text);
    try testing.expectEqual(@as(usize, 20_002), border_width);
}

test "appendRepeated emits one span and matches glyph-by-glyph appends" {
    const allocator = testing.allocator;

    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.appendRepeated(.table_border, "\u{2500}", 5);
    try builder.appendSpan(.body, "x");
    try builder.appendRepeated(.body, " ", 3);
    const lines = try builder.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }

    try testing.expectEqual(@as(usize, 2), lines[0].spans.len);
    try testing.expectEqualStrings("\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}", lines[0].spans[0].text);
    try testing.expectEqualStrings("x   ", lines[0].spans[1].text);

    var empty = Builder.init(allocator);
    defer empty.deinit();
    try empty.appendRepeated(.body, " ", 0);
    try empty.appendRepeated(.body, "", 4);
    try testing.expect(!empty.hasPending());
}

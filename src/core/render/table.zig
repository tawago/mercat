const std = @import("std");
const markdown = @import("../markdown.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const inline_mod = @import("inline.zig");
const unicode = @import("../../lib/unicode.zig");

const Block = markdown.Block;
const Inline = markdown.Inline;
const SpanStyle = types.SpanStyle;
const Glyphs = types.Glyphs;
const Builder = builder_mod.Builder;

pub fn renderTable(allocator: std.mem.Allocator, builder: *Builder, table: Block.Table, max_width: usize, glyphs: Glyphs) !void {
    if (table.rows.len == 0) return;

    // Calculate column widths based on inline content
    var max_columns: usize = 0;
    for (table.rows) |row| max_columns = @max(max_columns, row.cells.len);

    var widths = try allocator.alloc(usize, max_columns);
    defer allocator.free(widths);
    @memset(widths, 0);

    for (table.rows) |row| {
        for (row.cells, 0..) |cell, index| {
            widths[index] = @max(widths[index], inline_mod.inlinesDisplayWidth(cell));
        }
    }

    try fitColumnWidths(widths, max_width);

    for (table.rows, 0..) |row, index| {
        if (index != 0) try builder.newline();
        try appendTableRow(allocator, builder, row, widths, table.alignments, index == 0, glyphs);
        if (index == 0) {
            try builder.newline();
            try appendTableRule(builder, widths, glyphs);
        }
    }
}

pub fn appendTableRule(builder: *Builder, widths: []const usize, glyphs: Glyphs) !void {
    for (widths, 0..) |width, index| {
        if (index != 0) try builder.appendSpan(.table_border, glyphs.table_cross);
        var count: usize = 0;
        while (count < width + 2) : (count += 1) try builder.appendSpan(.table_border, glyphs.table_horizontal);
    }
}

pub fn appendTableRow(allocator: std.mem.Allocator, builder: *Builder, row: Block.TableRow, widths: []const usize, alignments: []const Block.Table.Alignment, is_header: bool, glyphs: Glyphs) !void {
    const cell_style: SpanStyle = if (is_header) .table_header else .body;
    var wrapped_cells = try allocator.alloc([][]const u8, widths.len);
    defer allocator.free(wrapped_cells);
    var row_height: usize = 1;

    for (widths, 0..) |width, index| {
        const cell_inlines = if (index < row.cells.len) row.cells[index] else &[_]Inline{};
        const cell_text = try inline_mod.inlinesToText(allocator, cell_inlines);
        defer allocator.free(cell_text);
        wrapped_cells[index] = try unicode.wrapLine(allocator, cell_text, @max(width, 1), "");
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
        for (widths, 0..) |width, index| {
            const cell_line = if (line_index < wrapped_cells[index].len) wrapped_cells[index][line_index] else "";
            const alignment = if (index < alignments.len) alignments[index] else .none;
            const cell_width = unicode.displayWidth(cell_line);
            const remaining = width -| cell_width;
            const pad_left, const pad_right = switch (alignment) {
                .right => .{ remaining, 0 },
                .center => .{ remaining / 2, remaining - (remaining / 2) },
                .left, .none => .{ 0, remaining },
            };
            try builder.appendSpan(cell_style, " ");
            if (pad_left != 0) try appendSpaces(builder, pad_left, cell_style);
            try builder.appendSpan(cell_style, cell_line);
            if (pad_right != 0) try appendSpaces(builder, pad_right, cell_style);
            try builder.appendSpan(cell_style, " ");
            if (index + 1 < widths.len) try builder.appendSpan(.table_border, glyphs.table_vertical);
        }
    }
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
    var i: usize = 0;
    while (i < count) : (i += 1) try builder.appendSpan(style, " ");
}

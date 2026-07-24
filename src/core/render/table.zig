const std = @import("std");
const markdown = @import("../markdown.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const inline_mod = @import("inline.zig");
const unicode = @import("../../lib/unicode.zig");
const decor_mod = @import("decor.zig");

const Block = markdown.Block;
const Inline = markdown.Inline;
const SpanStyle = types.SpanStyle;
const Builder = builder_mod.Builder;
const Decor = decor_mod.Decor;

pub fn renderTable(allocator: std.mem.Allocator, builder: *Builder, table: Block.Table, max_width: usize, decor: *const Decor) !void {
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

    switch (decor.glyphs.table_style) {
        .grid => try renderGrid(allocator, builder, table, widths),
        .rounded => try renderRounded(allocator, builder, table, widths),
    }
}

/// The historical grid table: a header, a `─`/`┼` rule, then rows separated by
/// `│`. Byte-identical to the pre-theme renderer.
fn renderGrid(allocator: std.mem.Allocator, builder: *Builder, table: Block.Table, widths: []const usize) !void {
    for (table.rows, 0..) |row, index| {
        if (index != 0) try builder.newline();
        try appendTableRow(allocator, builder, row, widths, table.alignments);
        if (index == 0) {
            try builder.newline();
            try appendTableRule(builder, widths);
        }
    }
}

const RoundedGlyphs = struct {
    tl: []const u8 = "\u{256D}", // ╭
    tr: []const u8 = "\u{256E}", // ╮
    bl: []const u8 = "\u{2570}", // ╰
    br: []const u8 = "\u{256F}", // ╯
    tj: []const u8 = "\u{252C}", // ┬
    bj: []const u8 = "\u{2534}", // ┴
    lj: []const u8 = "\u{251C}", // ├
    rj: []const u8 = "\u{2524}", // ┤
    cross: []const u8 = "\u{253C}", // ┼
    h: []const u8 = "\u{2500}", // ─
    v: []const u8 = "\u{2502}", // │
};

/// Rounded box table (markview): full top/bottom/side borders with rounded
/// corners and a header separator.
fn renderRounded(allocator: std.mem.Allocator, builder: *Builder, table: Block.Table, widths: []const usize) !void {
    const g = RoundedGlyphs{};
    try appendRoundedBorder(builder, widths, g, g.tl, g.tj, g.tr);
    for (table.rows, 0..) |row, index| {
        try builder.newline();
        try appendRoundedRow(allocator, builder, row, widths, table.alignments, g);
        if (index == 0) {
            try builder.newline();
            try appendRoundedBorder(builder, widths, g, g.lj, g.cross, g.rj);
        }
    }
    try builder.newline();
    try appendRoundedBorder(builder, widths, g, g.bl, g.bj, g.br);
}

fn appendRoundedBorder(builder: *Builder, widths: []const usize, g: RoundedGlyphs, left: []const u8, mid: []const u8, right: []const u8) !void {
    try builder.appendSpan(.muted, left);
    for (widths, 0..) |width, index| {
        if (index != 0) try builder.appendSpan(.muted, mid);
        var count: usize = 0;
        while (count < width + 2) : (count += 1) try builder.appendSpan(.muted, g.h);
    }
    try builder.appendSpan(.muted, right);
}

fn appendRoundedRow(allocator: std.mem.Allocator, builder: *Builder, row: Block.TableRow, widths: []const usize, alignments: []const Block.Table.Alignment, g: RoundedGlyphs) !void {
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
        try builder.appendSpan(.muted, g.v);
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
            try builder.appendSpan(.body, " ");
            if (pad_left != 0) try appendSpaces(builder, pad_left, .body);
            try builder.appendSpan(.body, cell_line);
            if (pad_right != 0) try appendSpaces(builder, pad_right, .body);
            try builder.appendSpan(.body, " ");
            try builder.appendSpan(.muted, g.v);
        }
    }
}

pub fn appendTableRule(builder: *Builder, widths: []const usize) !void {
    for (widths, 0..) |width, index| {
        if (index != 0) try builder.appendSpan(.muted, "\u{253c}");
        var count: usize = 0;
        while (count < width + 2) : (count += 1) try builder.appendSpan(.muted, "\u{2500}");
    }
}

pub fn appendTableRow(allocator: std.mem.Allocator, builder: *Builder, row: Block.TableRow, widths: []const usize, alignments: []const Block.Table.Alignment) !void {
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
            try builder.appendSpan(.body, " ");
            if (pad_left != 0) try appendSpaces(builder, pad_left, .body);
            try builder.appendSpan(.body, cell_line);
            if (pad_right != 0) try appendSpaces(builder, pad_right, .body);
            try builder.appendSpan(.body, " ");
            if (index + 1 < widths.len) try builder.appendSpan(.muted, "\u{2502}");
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

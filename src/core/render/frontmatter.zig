const std = @import("std");
const config = @import("../config.zig");
const markdown = @import("../markdown.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const table_mod = @import("table.zig");
const unicode = @import("../../lib/unicode.zig");

const Block = markdown.Block;
const Inline = markdown.Inline;
const Builder = builder_mod.Builder;
const SpanStyle = types.SpanStyle;

/// Leading glyph of the compact one-line style.
const compact_marker = "\u{25C8}"; // ◈

pub fn render(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize, style: config.FrontmatterStyle) !void {
    switch (style) {
        .panel => try renderKeyValues(allocator, builder, fm, width, .panel),
        .dim => try renderKeyValues(allocator, builder, fm, width, .dim),
        .compact => try renderCompact(allocator, builder, fm, width),
        .table => try renderAsTable(allocator, builder, fm, width),
        .raw => try renderRaw(builder, fm),
        // Hidden front matter is skipped in render_model before dispatch so it
        // leaves no blank lines; reaching here emits nothing as a backstop.
        .hidden => {},
    }
}

const KeyValueLook = enum { panel, dim };

/// A display row of the key/value layouts: an optional key cell followed by
/// one wrapped value line. Rows past the first line of a wrapped value (and
/// raw non-`key: value` lines) have an empty key.
const Row = struct {
    key: []const u8,
    value: []const u8,
    owned_value: bool,
};

/// Shared layout of the `panel` and `dim` styles: an aligned key column and
/// wrapped values. `panel` adds the code-block-tinted background and the
/// half-block top/bottom caps; `dim` is the same grid with no chrome.
fn renderKeyValues(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize, look: KeyValueLook) !void {
    var key_width: usize = 0;
    for (fm.entries) |entry| key_width = @max(key_width, unicode.displayWidth(entry.key));

    // One column of padding inside each edge of the panel.
    const inner_width = width -| 2;
    const value_width = @max(inner_width -| (key_width + 2), 8);

    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |row| if (row.owned_value) allocator.free(row.value);
        rows.deinit(allocator);
    }
    try buildRows(allocator, &rows, fm, value_width);

    var panel_width: usize = 0;
    for (rows.items) |row| {
        const row_width = if (row.key.len == 0 and key_width == 0)
            unicode.displayWidth(row.value)
        else
            key_width + 2 + unicode.displayWidth(row.value);
        panel_width = @max(panel_width, row_width + 2);
    }
    panel_width = @min(panel_width, width);

    const key_style: SpanStyle = if (look == .panel) .frontmatter_key else .muted;
    const value_style: SpanStyle = if (look == .panel) .frontmatter_value else .body;

    if (look == .panel) try appendCap(builder, "\u{2584}", panel_width); // ▄

    for (rows.items, 0..) |row, index| {
        if (index != 0 or look == .panel) try builder.newline();
        try builder.appendSpan(value_style, " ");
        var used: usize = 1;
        if (key_width != 0) {
            try builder.appendSpan(key_style, row.key);
            try appendPad(builder, key_style, key_width + 2 - unicode.displayWidth(row.key));
            used += key_width + 2;
        }
        try builder.appendSpan(value_style, row.value);
        used += unicode.displayWidth(row.value);
        if (look == .panel) try appendPad(builder, value_style, panel_width -| used);
    }

    if (look == .panel) {
        try builder.newline();
        try appendCap(builder, "\u{2580}", panel_width); // ▀
    }
}

/// Expand entries into display rows, wrapping long values onto continuation
/// rows with an empty key cell.
fn buildRows(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), fm: Block.FrontMatter, value_width: usize) !void {
    // Raw non-`key: value` lines render in the value column too (the key cell
    // is emitted for every row), so both kinds wrap at value_width.
    for (fm.entries) |entry| {
        try appendWrapped(allocator, rows, entry.key, entry.value, value_width);
    }
}

fn appendWrapped(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), key: []const u8, value: []const u8, value_width: usize) !void {
    if (unicode.displayWidth(value) <= value_width) {
        try rows.append(allocator, .{ .key = key, .value = value, .owned_value = false });
        return;
    }
    const wrapped = try unicode.wrapLine(allocator, value, value_width, "");
    defer allocator.free(wrapped);
    for (wrapped, 0..) |line, index| {
        try rows.append(allocator, .{
            .key = if (index == 0) key else "",
            .value = line,
            .owned_value = true,
        });
    }
}

fn renderCompact(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize) !void {
    try builder.appendSpan(.muted, compact_marker);
    var used: usize = unicode.displayWidth(compact_marker);
    var first = true;
    for (fm.entries) |entry| {
        // The compact line is a summary: raw continuation lines are elided.
        if (entry.key.len == 0) continue;
        const pair_width = unicode.displayWidth(entry.key) + 1 + unicode.displayWidth(entry.value);
        const lead: usize = if (first) 1 else 2;
        if (used + lead + pair_width > width and !first) {
            try builder.newline();
            try builder.appendSpan(.muted, " ");
            used = 1;
        } else {
            try appendPad(builder, .body, lead);
            used += lead;
        }
        const key_text = try std.fmt.allocPrint(allocator, "{s}:", .{entry.key});
        defer allocator.free(key_text);
        try builder.appendSpan(.muted, key_text);
        try builder.appendSpan(.body, entry.value);
        used += pair_width;
        first = false;
    }
}

fn renderAsTable(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize) !void {
    if (fm.entries.len == 0) return;

    // Build a synthetic two-column table over slices borrowed from the block;
    // renderTable only reads, so the scaffolding is freed manually here and
    // Block.deinit is never involved.
    const rows = try allocator.alloc(Block.TableRow, fm.entries.len);
    // Initialize before any fallible work so the cleanup never frees
    // undefined `cells` slices when a mid-loop allocation fails.
    for (rows) |*row| row.cells = &.{};
    defer {
        for (rows) |row| if (row.cells.len != 0) allocator.free(row.cells);
        allocator.free(rows);
    }
    var cell_inlines = try allocator.alloc([2]Inline, fm.entries.len);
    defer allocator.free(cell_inlines);

    for (fm.entries, 0..) |entry, index| {
        cell_inlines[index] = .{ .{ .text = entry.key }, .{ .text = entry.value } };
        const row_cells = try allocator.alloc([]Inline, 2);
        row_cells[0] = cell_inlines[index][0..1];
        row_cells[1] = cell_inlines[index][1..2];
        rows[index] = .{ .cells = row_cells };
    }

    var alignments = [_]Block.Table.Alignment{ .left, .left };
    try table_mod.renderTable(allocator, builder, .{ .rows = rows, .alignments = &alignments }, width);
}

fn renderRaw(builder: *Builder, fm: Block.FrontMatter) !void {
    try builder.appendSpan(.muted, "---");
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, fm.raw, "\n"), '\n');
    while (lines.next()) |line| {
        try builder.newline();
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (trimmed.len != 0) try builder.appendSpan(.muted, trimmed);
    }
    try builder.newline();
    try builder.appendSpan(.muted, "---");
}

fn appendCap(builder: *Builder, glyph: []const u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try builder.appendSpan(.frontmatter_cap, glyph);
}

fn appendPad(builder: *Builder, style: SpanStyle, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try builder.appendSpan(style, " ");
}

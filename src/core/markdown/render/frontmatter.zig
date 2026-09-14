const std = @import("std");
const config = @import("../../config.zig");
const markdown = @import("../parser.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const table = @import("table.zig");
const geometry = @import("geometry.zig");

const Block = markdown.Block;
const Builder = builder_mod.Builder;
const SpanStyle = types.SpanStyle;

/// Leading glyph of the compact one-line style.
const compact_marker = "\u{25C8}";

/// True when this style/front-matter combination renders no output: hidden
/// always, and empty entries for every style except raw (whose verbatim
/// contract still reproduces the fenced lines). render_model consults this before
/// block spacing so a skipped block leaves no blank lines.
pub fn rendersNothing(fm: Block.FrontMatter, style: config.FrontmatterStyle) bool {
    return style == .hidden or (fm.entries.len == 0 and style != .raw);
}

pub fn render(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize, style: config.FrontmatterStyle) !void {
    if (rendersNothing(fm, style)) return;

    switch (style) {
        .panel => try renderKeyValues(allocator, builder, fm, width, .panel),
        .dim => try renderKeyValues(allocator, builder, fm, width, .dim),
        .compact => try renderCompact(allocator, builder, fm, width),
        .raw => try renderRaw(builder, fm),
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
};

/// Shared layout of the `panel` and `dim` styles: an aligned key column and
/// wrapped values. `panel` adds the code-block-tinted background and the
/// half-block top/bottom caps; `dim` is the same grid with no chrome.
fn renderKeyValues(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize, look: KeyValueLook) !void {
    const inner_width = width -| 2;

    const max_key_width = inner_width -| 3;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const content_origin = builder.left_padding;
    const key_start = content_origin + 1;
    const keys = try a.alloc([]const u8, fm.entries.len);
    for (fm.entries, 0..) |entry, index| {
        keys[index] = try truncateToWidth(a, entry.key, max_key_width, key_start);
    }

    var key_width: usize = 0;
    for (keys) |key| key_width = @max(key_width, try geometry.displayWidthFrom(key, key_start));
    const value_width = if (key_width == 0)
        @max(inner_width, 1)
    else
        @max(inner_width -| (key_width + 2), 1);

    var rows: std.ArrayList(Row) = .empty;
    const value_start = content_origin + 1 + if (key_width == 0) 0 else key_width + 2;
    for (fm.entries, keys) |entry, key| {
        try appendWrapped(a, &rows, key, entry.value, value_width, value_start);
    }

    var panel_width: usize = 0;
    for (rows.items) |row| {
        const row_width = if (row.key.len == 0 and key_width == 0)
            try geometry.displayWidthFrom(row.value, value_start)
        else
            key_width + 2 + try geometry.displayWidthFrom(row.value, value_start);
        panel_width = @max(panel_width, row_width + 2);
    }
    panel_width = @min(panel_width, width);

    const key_style: SpanStyle = if (look == .panel) .frontmatter_key else .muted;
    const value_style: SpanStyle = if (look == .panel) .frontmatter_value else .body;

    if (look == .panel) try appendCap(a, builder, "\u{2584}", panel_width);

    for (rows.items, 0..) |row, index| {
        if (index != 0 or look == .panel) try builder.newline();
        try builder.appendSpan(value_style, " ");
        var used: usize = 1;
        if (key_width != 0) {
            try builder.appendSpan(key_style, row.key);
            try table.appendSpaces(builder, key_width + 2 - try geometry.displayWidthFrom(row.key, key_start), key_style);
            used += key_width + 2;
        }
        try builder.appendSpan(value_style, row.value);
        used += try geometry.displayWidthFrom(row.value, content_origin + used);
        if (look == .panel) try table.appendSpaces(builder, panel_width -| used, value_style);
    }

    if (look == .panel) {
        try builder.newline();
        try appendCap(a, builder, "\u{2580}", panel_width);
    }
}

/// Append `value` as display rows, wrapping onto continuation rows with an
/// empty key cell. `a` must be an arena: wrapped lines are allocated from it
/// and never individually freed.
fn appendWrapped(a: std.mem.Allocator, rows: *std.ArrayList(Row), key: []const u8, value: []const u8, value_width: usize, value_start: usize) !void {
    if (try geometry.displayWidthFrom(value, value_start) <= value_width) {
        try rows.append(a, .{ .key = key, .value = value });
        return;
    }
    const wrapped = try wrapValue(a, value, value_width, value_start);
    for (wrapped, 0..) |line, index| {
        try rows.append(a, .{ .key = if (index == 0) key else "", .value = line });
    }
}

/// Wrap `text` into lines no wider than `width` display cells. Prefers
/// breaking at spaces; a single token wider than `width` is hard-split at
/// grapheme boundaries so the width is always respected. `width` must be at
/// least 1. `a` must be an arena: partial allocations on an error path are
/// reclaimed by the arena, not freed here.
fn wrapValue(a: std.mem.Allocator, text: []const u8, width: usize, initial_column: usize) ![][]const u8 {
    std.debug.assert(width >= 1);
    _ = try geometry.displayWidth(text);

    var lines: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var current_width: usize = 0;

    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        var remaining = word;
        while (remaining.len != 0) {
            const sep: usize = if (current.items.len == 0) 0 else 1;
            const word_width = try geometry.displayWidthFrom(remaining, initial_column + current_width + sep);
            if (current_width + sep + word_width <= width) {
                if (sep == 1) {
                    try current.append(a, ' ');
                    current_width += 1;
                }
                try current.appendSlice(a, remaining);
                current_width += word_width;
                remaining = remaining[remaining.len..];
                continue;
            }
            if (current.items.len != 0) {
                try lines.append(a, try current.toOwnedSlice(a));
                current_width = 0;
                continue;
            }
            const take = try takeWidth(remaining, width, initial_column);
            try current.appendSlice(a, remaining[0..take]);
            try lines.append(a, try current.toOwnedSlice(a));
            current_width = 0;
            remaining = remaining[take..];
        }
    }
    if (current.items.len != 0) try lines.append(a, try current.toOwnedSlice(a));
    if (lines.items.len == 0) try lines.append(a, "");
    return lines.toOwnedSlice(a);
}

/// Byte length of the longest prefix of `text` that fits within `width`
/// display cells. Always advances by at least one grapheme so callers make
/// progress even when a single wide glyph exceeds `width`.
fn takeWidth(text: []const u8, width: usize, initial_column: usize) !usize {
    const clipped = try geometry.takeWidth(text, width, initial_column);
    if (clipped == 0 and text.len != 0) return geometry.firstGraphemeLength(text, initial_column);
    return clipped;
}

/// The single-cell ellipsis appended to a truncated key.
const ellipsis = "\u{2026}";

/// Constrain `text` to at most `max` display cells. If `text` already fits it
/// is returned as-is (the source outlives the render call); otherwise an arena
/// copy is cut at a grapheme boundary with a trailing ellipsis so the result
/// never exceeds `max`. Used to keep keys from overflowing the width cap the
/// same way values are wrapped.
fn truncateToWidth(a: std.mem.Allocator, text: []const u8, max: usize, initial_column: usize) ![]const u8 {
    const text_width = try geometry.displayWidthFrom(text, initial_column);
    if (text_width <= max) return text;
    if (max == 0) return "";
    const ellipsis_width = try geometry.displayWidthFrom(ellipsis, initial_column + max - 1);
    if (ellipsis_width > max) return "";
    const kept_len = try geometry.takeWidth(text, max - ellipsis_width, initial_column);
    const kept = text[0..kept_len];
    return std.mem.concat(a, u8, &.{ kept, ellipsis });
}

fn renderCompact(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize) !void {
    const avail = @max(width, 2);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try builder.appendSpan(.muted, compact_marker);
    const content_origin = builder.left_padding;
    var used: usize = try geometry.displayWidthFrom(compact_marker, content_origin);
    var first = true;
    for (fm.entries) |entry| {
        const lead: usize = if (first) 1 else 2;
        var key_start = content_origin + used + lead;
        const formatted_key = if (entry.key.len == 0) "" else try std.fmt.allocPrint(a, "{s}:", .{entry.key});
        var key_text = try truncateToWidth(a, formatted_key, avail -| 2, key_start);
        var key_w = try geometry.displayWidthFrom(key_text, key_start);
        const pair_width = key_w + try geometry.displayWidthFrom(entry.value, key_start + key_w);

        if (!first and used + lead + pair_width > avail) {
            try builder.newline();
            try builder.appendSpan(.muted, " ");
            used = 1;
            key_start = content_origin + used;
            key_text = try truncateToWidth(a, formatted_key, avail -| 2, key_start);
            key_w = try geometry.displayWidthFrom(key_text, key_start);
        } else {
            try table.appendSpaces(builder, lead, .body);
            used += lead;
        }

        if (key_w != 0) {
            try builder.appendSpan(.muted, key_text);
            used += key_w;
        }
        try emitValue(builder, entry.value, avail, content_origin, &used);
        first = false;
    }
}

/// Emit `value` in the `.body` style starting at column `used.*`, wrapping onto
/// one-space-indented continuation lines whenever it would exceed `avail`.
fn emitValue(builder: *Builder, value: []const u8, avail: usize, content_origin: usize, used: *usize) !void {
    if (value.len == 0) return;
    var remaining = value;
    while (true) {
        const budget = if (used.* >= avail) 0 else avail - used.*;
        const remaining_width = try geometry.displayWidthFrom(remaining, content_origin + used.*);
        if (remaining_width <= budget) {
            try builder.appendSpan(.body, remaining);
            used.* += remaining_width;
            return;
        }
        if (budget >= 1) {
            const take = try takeWidth(remaining, budget, content_origin + used.*);
            if (take != 0) {
                try builder.appendSpan(.body, remaining[0..take]);
                remaining = remaining[take..];
            }
        }
        try builder.newline();
        try builder.appendSpan(.muted, " ");
        used.* = 1;
        if (remaining.len != 0 and remaining[0] == ' ') remaining = remaining[1..];
    }
}

fn renderRaw(builder: *Builder, fm: Block.FrontMatter) !void {
    try builder.appendSpan(.muted, "---");
    if (fm.raw.len != 0) {
        const body = if (fm.raw[fm.raw.len - 1] == '\n') fm.raw[0 .. fm.raw.len - 1] else fm.raw;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            try builder.newline();
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len != 0) try builder.appendSpan(.muted, trimmed);
        }
    }
    try builder.newline();
    try builder.appendSpan(.muted, "---");
}

test {
    _ = @import("frontmatter_test2.zig");
}

/// Append a cap line built by repeating `glyph` `count` times as one span.
/// `a` must be an arena; the builder copies the text.
fn appendCap(a: std.mem.Allocator, builder: *Builder, glyph: []const u8, count: usize) !void {
    if (count == 0) return;
    const row = try a.alloc(u8, glyph.len * count);
    for (0..count) |i| @memcpy(row[i * glyph.len ..][0..glyph.len], glyph);
    try builder.appendSpan(.frontmatter_cap, row);
}

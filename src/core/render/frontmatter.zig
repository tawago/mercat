const std = @import("std");
const config = @import("../config.zig");
const markdown = @import("../markdown.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const table = @import("table.zig");
const unicode = @import("../../lib/unicode.zig");

const Block = markdown.Block;
const Builder = builder_mod.Builder;
const SpanStyle = types.SpanStyle;
const Entry = Block.FrontMatter.Entry;

/// Leading glyph of the compact one-line style.
const compact_marker = "\u{25C8}"; // ◈

/// True when this style/front-matter combination renders no output: hidden
/// always, and empty entries for every style except raw (whose verbatim
/// contract still reproduces the fences). render_model consults this before
/// block spacing so a skipped block leaves no blank lines.
pub fn rendersNothing(fm: Block.FrontMatter, style: config.FrontmatterStyle) bool {
    return style == .hidden or (fm.entries.len == 0 and style != .raw);
}

pub fn render(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize, style: config.FrontmatterStyle, for_export: bool) !void {
    if (rendersNothing(fm, style)) return;

    // Front-matter text is copied into an arena with tabs expanded to spaces.
    // The plain and PNG exporters reject tab and other control scalars inside
    // span text, so preserving a literal tab from a quoted YAML scalar would
    // make those exports fail. Sanitizing keeps every backend in sync.
    //
    // The one exception is raw style bound for the terminal (`for_export` is
    // false): its contract is byte-verbatim, so tabs are preserved. On the
    // export path raw is sanitized like every other style so the paired
    // plain/PNG artifacts stay valid.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const clean = if (style == .raw and !for_export)
        fm
    else
        try sanitizeFrontMatter(arena.allocator(), fm);

    switch (style) {
        .panel => try renderKeyValues(allocator, builder, clean, width, .panel),
        .dim => try renderKeyValues(allocator, builder, clean, width, .dim),
        .compact => try renderCompact(allocator, builder, clean, width),
        .raw => try renderRaw(builder, clean),
        .hidden => {},
    }
}

/// Copy the front matter into `a`, expanding tabs to single spaces. Newlines
/// are preserved (the raw style splits the block on them); every other byte is
/// copied verbatim.
fn sanitizeFrontMatter(a: std.mem.Allocator, fm: Block.FrontMatter) !Block.FrontMatter {
    const entries = try a.alloc(Entry, fm.entries.len);
    for (fm.entries, 0..) |entry, index| {
        entries[index] = .{
            .key = try sanitizeText(a, entry.key),
            .value = try sanitizeText(a, entry.value),
        };
    }
    return .{ .raw = try sanitizeText(a, fm.raw), .entries = entries };
}

/// Returns `text` unchanged when it holds no tabs (the source front matter
/// outlives the render call), otherwise an arena copy with tabs replaced.
fn sanitizeText(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '\t') == null) return text;
    const out = try a.dupe(u8, text);
    std.mem.replaceScalar(u8, out, '\t', ' ');
    return out;
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
    // One column of padding inside each edge of the panel.
    const inner_width = width -| 2;

    // Keys are constrained to leave room for the two-column gap after the key
    // and at least one value cell, so an unbroken key can never push a line
    // past the width cap. Truncated keys carry a trailing ellipsis.
    const max_key_width = inner_width -| 3;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try a.alloc([]const u8, fm.entries.len);
    for (fm.entries, 0..) |entry, index| {
        keys[index] = try truncateToWidth(a, entry.key, max_key_width);
    }

    var key_width: usize = 0;
    for (keys) |key| key_width = @max(key_width, unicode.displayWidth(key));
    // The value column takes whatever the key column and edge padding leave,
    // but is never allowed to collapse below a single cell (so wrapping always
    // makes progress). Long tokens are hard-split to fit this width, so the
    // panel honours the requested width instead of forcing a minimum.
    const value_width = if (key_width == 0)
        @max(inner_width, 1)
    else
        @max(inner_width -| (key_width + 2), 1);

    // Rows and wrapped value lines live in the function-scoped arena, so no
    // per-row ownership tracking is needed. Raw non-`key: value` lines render
    // in the value column too (the key cell is emitted for every row), so both
    // kinds wrap at value_width. `keys` holds the width-constrained (possibly
    // ellipsized) key for each entry.
    var rows: std.ArrayList(Row) = .empty;
    for (fm.entries, keys) |entry, key| {
        try appendWrapped(a, &rows, key, entry.value, value_width);
    }

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

    if (look == .panel) try appendCap(a, builder, "\u{2584}", panel_width); // ▄

    for (rows.items, 0..) |row, index| {
        if (index != 0 or look == .panel) try builder.newline();
        try builder.appendSpan(value_style, " ");
        var used: usize = 1;
        if (key_width != 0) {
            try builder.appendSpan(key_style, row.key);
            try table.appendSpaces(builder, key_width + 2 - unicode.displayWidth(row.key), key_style);
            used += key_width + 2;
        }
        try builder.appendSpan(value_style, row.value);
        used += unicode.displayWidth(row.value);
        if (look == .panel) try table.appendSpaces(builder, panel_width -| used, value_style);
    }

    if (look == .panel) {
        try builder.newline();
        try appendCap(a, builder, "\u{2580}", panel_width); // ▀
    }
}

/// Append `value` as display rows, wrapping onto continuation rows with an
/// empty key cell. `a` must be an arena: wrapped lines are allocated from it
/// and never individually freed.
fn appendWrapped(a: std.mem.Allocator, rows: *std.ArrayList(Row), key: []const u8, value: []const u8, value_width: usize) !void {
    if (unicode.displayWidth(value) <= value_width) {
        try rows.append(a, .{ .key = key, .value = value });
        return;
    }
    const wrapped = try wrapValue(a, value, value_width);
    for (wrapped, 0..) |line, index| {
        try rows.append(a, .{ .key = if (index == 0) key else "", .value = line });
    }
}

/// Wrap `text` into lines no wider than `width` display cells. Prefers
/// breaking at spaces; a single token wider than `width` is hard-split at
/// grapheme boundaries so the width is always respected. `width` must be at
/// least 1. `a` must be an arena: partial allocations on an error path are
/// reclaimed by the arena, not freed here.
fn wrapValue(a: std.mem.Allocator, text: []const u8, width: usize) ![][]const u8 {
    std.debug.assert(width >= 1);

    var lines: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var current_width: usize = 0;

    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        var remaining = word;
        while (remaining.len != 0) {
            const sep: usize = if (current.items.len == 0) 0 else 1;
            const word_width = unicode.displayWidth(remaining);
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
                // Flush and retry the word at the start of a fresh line.
                try lines.append(a, try current.toOwnedSlice(a));
                current_width = 0;
                continue;
            }
            // The word alone is wider than the line: hard-split it.
            const take = takeWidth(remaining, width);
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
fn takeWidth(text: []const u8, width: usize) usize {
    const clipped = unicode.clipToWidth(text, width);
    if (clipped.len == 0 and text.len != 0) return unicode.nextGlyph(text, 0).bytes.len;
    return clipped.len;
}

/// The single-cell ellipsis appended to a truncated key.
const ellipsis = "\u{2026}"; // …

/// Constrain `text` to at most `max` display cells. If `text` already fits it
/// is returned as-is (the source outlives the render call); otherwise an arena
/// copy is cut at a grapheme boundary with a trailing ellipsis so the result
/// never exceeds `max`. Used to keep keys from overflowing the width cap the
/// same way values are wrapped.
fn truncateToWidth(a: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (unicode.displayWidth(text) <= max) return text;
    // No room for even the ellipsis: drop the key entirely.
    if (max == 0) return "";
    // Reserve one cell for the ellipsis, then take as much of the key as fits.
    const kept = unicode.clipToWidth(text, max - 1);
    return std.mem.concat(a, u8, &.{ kept, ellipsis });
}

fn renderCompact(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize) !void {
    // Keep at least two columns so a value can always take one cell after the
    // one-column continuation indent.
    const avail = @max(width, 2);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try builder.appendSpan(.muted, compact_marker);
    var used: usize = unicode.displayWidth(compact_marker);
    var first = true;
    for (fm.entries) |entry| {
        // Raw continuation lines have no key; show the value alone rather than
        // silently dropping the entry. The key is constrained (marker + lead +
        // key must fit `avail`) so a single unbroken key can never overflow
        // the width cap. Truncation ellipsizes.
        const key_text = if (entry.key.len == 0)
            ""
        else
            try truncateToWidth(a, try std.fmt.allocPrint(a, "{s}:", .{entry.key}), avail -| 2);

        const key_w = unicode.displayWidth(key_text);
        const pair_width = key_w + unicode.displayWidth(entry.value);
        const lead: usize = if (first) 1 else 2;

        if (!first and used + lead + pair_width > avail) {
            try builder.newline();
            try builder.appendSpan(.muted, " ");
            used = 1;
        } else {
            try table.appendSpaces(builder, lead, .body);
            used += lead;
        }

        if (key_w != 0) {
            try builder.appendSpan(.muted, key_text);
            used += key_w;
        }
        // The value wraps onto continuation lines when it overflows, so even a
        // long first pair is constrained to the requested width.
        try emitValue(builder, entry.value, avail, &used);
        first = false;
    }
}

/// Emit `value` in the `.body` style starting at column `used.*`, wrapping onto
/// one-space-indented continuation lines whenever it would exceed `avail`.
fn emitValue(builder: *Builder, value: []const u8, avail: usize, used: *usize) !void {
    if (value.len == 0) return;
    var remaining = value;
    while (true) {
        const budget = if (used.* >= avail) 0 else avail - used.*;
        const remaining_width = unicode.displayWidth(remaining);
        if (remaining_width <= budget) {
            try builder.appendSpan(.body, remaining);
            used.* += remaining_width;
            return;
        }
        if (budget >= 1) {
            const take = takeWidth(remaining, budget);
            if (take != 0) {
                try builder.appendSpan(.body, remaining[0..take]);
                remaining = remaining[take..];
            }
        }
        try builder.newline();
        try builder.appendSpan(.muted, " ");
        used.* = 1;
        // Drop a leading space so continuation lines start on the next word.
        if (remaining.len != 0 and remaining[0] == ' ') remaining = remaining[1..];
    }
}

fn renderRaw(builder: *Builder, fm: Block.FrontMatter) !void {
    try builder.appendSpan(.muted, "---");
    // Verbatim reproduction of the bytes between the fences. `raw` ends with the
    // newline that separates the last content line from the closing fence; that
    // single trailing newline is a boundary, not a blank line, so it is dropped.
    // Every remaining newline (including genuine blank lines) is preserved.
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

/// Append a cap line built by repeating `glyph` `count` times as one span.
/// `a` must be an arena; the builder copies the text.
fn appendCap(a: std.mem.Allocator, builder: *Builder, glyph: []const u8, count: usize) !void {
    if (count == 0) return;
    const row = try a.alloc(u8, glyph.len * count);
    for (0..count) |i| @memcpy(row[i * glyph.len ..][0..glyph.len], glyph);
    try builder.appendSpan(.frontmatter_cap, row);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// --- render() output helpers -----------------------------------------------

const testing = std.testing;

const cap_top = "\u{2584}"; // ▄
const cap_bottom = "\u{2580}"; // ▀

/// Render `fm` through a fresh Builder and return the finished lines. The
/// caller owns and frees the result. The Builder is torn down on any error so
/// a failing render never leaks its partial spans.
fn renderLines(allocator: std.mem.Allocator, fm: Block.FrontMatter, width: usize, style: config.FrontmatterStyle, for_export: bool) ![]types.Line {
    var builder = Builder.init(allocator);
    render(allocator, &builder, fm, width, style, for_export) catch |err| {
        builder.deinit();
        return err;
    };
    return builder.finish() catch |err| {
        builder.deinit();
        return err;
    };
}

fn freeLines(allocator: std.mem.Allocator, lines: []types.Line) void {
    for (lines) |line| line.deinit(allocator);
    allocator.free(lines);
}

/// Total span count across every line.
fn totalSpans(lines: []types.Line) usize {
    var total: usize = 0;
    for (lines) |line| total += line.spans.len;
    return total;
}

fn countStyle(lines: []types.Line, style: SpanStyle) usize {
    var total: usize = 0;
    for (lines) |line| for (line.spans) |span| {
        if (span.style == style) total += 1;
    };
    return total;
}

/// True when some span has `style` and, after trimming surrounding spaces (the
/// key/value cells are padded), its text equals `want`.
fn hasStyledText(lines: []types.Line, style: SpanStyle, want: []const u8) bool {
    for (lines) |line| for (line.spans) |span| {
        if (span.style != style) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, span.text, " "), want)) return true;
    };
    return false;
}

fn anySpanContains(lines: []types.Line, needle: []const u8) bool {
    for (lines) |line| for (line.spans) |span| {
        if (std.mem.indexOf(u8, span.text, needle) != null) return true;
    };
    return false;
}

fn anySpanHasByte(lines: []types.Line, byte: u8) bool {
    for (lines) |line| for (line.spans) |span| {
        if (std.mem.indexOfScalar(u8, span.text, byte) != null) return true;
    };
    return false;
}

/// Every line's rendered display width must stay within `cap`.
fn allLinesWithin(lines: []types.Line, cap: usize) bool {
    for (lines) |line| if (line.displayWidth() > cap) return false;
    return true;
}

test "frontmatter: panel style emits half-block caps around a key/value grid" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "title", .value = "Test" }};
    const fm = Block.FrontMatter{ .raw = "title: Test\n", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .panel, false);
    defer freeLines(alloc, lines);

    // Three lines: top cap, one content row, bottom cap.
    try testing.expectEqual(@as(usize, 3), lines.len);

    // Top cap: every span is a frontmatter_cap built from the ▄ glyph only.
    try testing.expect(lines[0].spans.len != 0);
    for (lines[0].spans) |span| {
        try testing.expectEqual(SpanStyle.frontmatter_cap, span.style);
        try testing.expect(std.mem.indexOf(u8, span.text, cap_top) != null);
        try testing.expect(std.mem.indexOf(u8, span.text, cap_bottom) == null);
    }

    // Middle row carries the styled key and value.
    try testing.expect(hasStyledText(lines[1..2], .frontmatter_key, "title"));
    try testing.expect(hasStyledText(lines[1..2], .frontmatter_value, "Test"));

    // Bottom cap uses the ▀ glyph.
    for (lines[2].spans) |span| {
        try testing.expectEqual(SpanStyle.frontmatter_cap, span.style);
        try testing.expect(std.mem.indexOf(u8, span.text, cap_bottom) != null);
    }
}

test "frontmatter: dim style is chrome-free with muted key and body value" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "title", .value = "Test" }};
    const fm = Block.FrontMatter{ .raw = "title: Test\n", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .dim, false);
    defer freeLines(alloc, lines);

    // Exactly one content line, no cap lines.
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(@as(usize, 0), countStyle(lines, .frontmatter_cap));
    try testing.expect(hasStyledText(lines, .muted, "title"));
    try testing.expect(hasStyledText(lines, .body, "Test"));
}

test "frontmatter: compact style is a single marker-led line of pairs" {
    const alloc = testing.allocator;
    var entries = [_]Entry{
        .{ .key = "title", .value = "Test" },
        .{ .key = "author", .value = "Foo" },
    };
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };

    const lines = try renderLines(alloc, fm, 60, .compact, false);
    defer freeLines(alloc, lines);

    try testing.expectEqual(@as(usize, 1), lines.len);
    // Leading ◈ marker.
    try testing.expectEqual(SpanStyle.muted, lines[0].spans[0].style);
    try testing.expectEqualStrings(compact_marker, lines[0].spans[0].text);
    // Both keys are muted, both values are body.
    try testing.expect(hasStyledText(lines, .muted, "title:"));
    try testing.expect(hasStyledText(lines, .muted, "author:"));
    try testing.expect(hasStyledText(lines, .body, "Test"));
    try testing.expect(hasStyledText(lines, .body, "Foo"));
}

test "frontmatter: raw style is byte-verbatim between fences without a trailing blank" {
    const alloc = testing.allocator;
    var entries = [_]Entry{
        .{ .key = "title", .value = "Test" },
        .{ .key = "author", .value = "Foo" },
    };
    const fm = Block.FrontMatter{ .raw = "title: Test\nauthor: Foo\n", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .raw, false);
    defer freeLines(alloc, lines);

    // Opening fence, two interior lines, closing fence — the single trailing
    // newline before the closing fence is a boundary, not a blank line.
    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("---", lines[0].spans[0].text);
    try testing.expectEqualStrings("title: Test", lines[1].spans[0].text);
    try testing.expectEqualStrings("author: Foo", lines[2].spans[0].text);
    try testing.expectEqualStrings("---", lines[3].spans[0].text);
    try testing.expectEqual(SpanStyle.muted, lines[0].spans[0].style);
}

test "frontmatter: raw style preserves a genuine blank middle line" {
    const alloc = testing.allocator;
    var no_entries = [_]Entry{};
    const fm = Block.FrontMatter{ .raw = "a: 1\n\nb: 2\n", .entries = &no_entries };

    const lines = try renderLines(alloc, fm, 40, .raw, false);
    defer freeLines(alloc, lines);

    // ---, a: 1, (blank), b: 2, ---
    try testing.expectEqual(@as(usize, 5), lines.len);
    try testing.expectEqualStrings("a: 1", lines[1].spans[0].text);
    try testing.expectEqual(@as(usize, 0), lines[2].spans.len); // blank survives
    try testing.expectEqualStrings("b: 2", lines[3].spans[0].text);
}

test "frontmatter: empty non-raw front matter emits nothing but raw keeps its fences" {
    const alloc = testing.allocator;
    var no_entries = [_]Entry{};
    const empty = Block.FrontMatter{ .raw = "", .entries = &no_entries };

    inline for (.{ config.FrontmatterStyle.panel, .dim, .compact }) |style| {
        const lines = try renderLines(alloc, empty, 40, style, false);
        defer freeLines(alloc, lines);
        try testing.expectEqual(@as(usize, 0), totalSpans(lines));
    }

    // Raw still reproduces the verbatim fences even when empty.
    const raw_lines = try renderLines(alloc, empty, 40, .raw, false);
    defer freeLines(alloc, raw_lines);
    try testing.expectEqual(@as(usize, 2), raw_lines.len);
    try testing.expectEqualStrings("---", raw_lines[0].spans[0].text);
    try testing.expectEqualStrings("---", raw_lines[1].spans[0].text);
}

test "frontmatter: hidden style emits nothing" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "title", .value = "Test" }};
    const fm = Block.FrontMatter{ .raw = "title: Test\n", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .hidden, false);
    defer freeLines(alloc, lines);

    try testing.expectEqual(@as(usize, 0), totalSpans(lines));
}

test "frontmatter: an over-wide key is truncated with an ellipsis inside the width cap" {
    const alloc = testing.allocator;
    const width: usize = 12;
    var entries = [_]Entry{.{ .key = "averylongkeyname", .value = "v" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };

    const lines = try renderLines(alloc, fm, width, .dim, false);
    defer freeLines(alloc, lines);

    // The key column can be at most inner_width - 3 = 7 cells wide.
    const max_key_width: usize = width - 2 - 3;
    var found_key = false;
    for (lines) |line| for (line.spans) |span| {
        if (span.style != .muted) continue;
        const key = std.mem.trimRight(u8, span.text, " ");
        if (key.len == 0) continue;
        found_key = true;
        try testing.expect(std.mem.endsWith(u8, key, ellipsis));
        try testing.expect(unicode.displayWidth(key) <= max_key_width);
    };
    try testing.expect(found_key);
    try testing.expect(allLinesWithin(lines, width));
}

test "frontmatter: a long value wraps onto padded continuation rows within width" {
    const alloc = testing.allocator;
    const width: usize = 20;
    var entries = [_]Entry{.{ .key = "k", .value = "one two three four five" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };

    const lines = try renderLines(alloc, fm, width, .panel, false);
    defer freeLines(alloc, lines);

    // Top and bottom caps plus at least two wrapped content rows.
    try testing.expect(lines.len >= 4);
    try testing.expect(allLinesWithin(lines, width));
    // Words break at spaces across rows.
    try testing.expect(anySpanContains(lines, "one"));
    try testing.expect(anySpanContains(lines, "five"));

    // The first content row carries the key; every continuation row pads the
    // key cell with whitespace so its frontmatter_key span trims to nothing.
    for (lines[1 .. lines.len - 1], 0..) |line, row| {
        for (line.spans) |span| {
            if (span.style != .frontmatter_key) continue;
            const trimmed = std.mem.trim(u8, span.text, " ");
            if (row == 0) {
                try testing.expectEqualStrings("k", trimmed);
            } else {
                try testing.expectEqualStrings("", trimmed);
            }
            break;
        }
    }
}

test "frontmatter: an unbreakable token is hard-split at the value column width" {
    const alloc = testing.allocator;
    const width: usize = 12;
    var entries = [_]Entry{.{ .key = "k", .value = "superlongunbrokentoken" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };

    const lines = try renderLines(alloc, fm, width, .panel, false);
    defer freeLines(alloc, lines);

    // The token cannot break at spaces, so it is split across several rows,
    // every one of which respects the panel width.
    try testing.expect(lines.len >= 4); // caps + >= 2 split rows
    try testing.expect(allLinesWithin(lines, width));
}

test "frontmatter: tabs are sanitized to spaces on the export path" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "k", .value = "a\tb" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .panel, true);
    defer freeLines(alloc, lines);

    try testing.expect(!anySpanHasByte(lines, '\t'));
    try testing.expect(anySpanContains(lines, "a b"));
}

test "frontmatter: raw style keeps a literal tab for the terminal but expands it on export" {
    const alloc = testing.allocator;
    var no_entries = [_]Entry{};
    const fm = Block.FrontMatter{ .raw = "a\tb\n", .entries = &no_entries };

    // Terminal path (for_export=false): byte-verbatim, tab preserved.
    const term = try renderLines(alloc, fm, 40, .raw, false);
    defer freeLines(alloc, term);
    try testing.expect(anySpanHasByte(term, '\t'));

    // Export path (for_export=true): tab expanded to a space.
    const exp = try renderLines(alloc, fm, 40, .raw, true);
    defer freeLines(alloc, exp);
    try testing.expect(!anySpanHasByte(exp, '\t'));
    try testing.expect(anySpanContains(exp, "a b"));
}

test "frontmatter: narrow widths do not underflow and still emit a line" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "k", .value = "v" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };

    inline for (.{ 1, 2 }) |width| {
        const lines = try renderLines(alloc, fm, width, .panel, false);
        defer freeLines(alloc, lines);
        // Reaching here without a panic/underflow is the assertion; the floor
        // guarantees at least one line.
        try testing.expect(lines.len >= 1);
        try testing.expect(anySpanContains(lines, "v"));
    }
}

test "frontmatter: a keyless continuation entry renders its value in the panel" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "", .value = "  - Foo" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .panel, false);
    defer freeLines(alloc, lines);

    // The value is shown (in the value column) rather than dropped.
    try testing.expect(anySpanContains(lines, "- Foo"));
}

const std = @import("std");
const config = @import("../config.zig");
const markdown = @import("../markdown.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const unicode = @import("../../lib/unicode.zig");

const Block = markdown.Block;
const Builder = builder_mod.Builder;
const SpanStyle = types.SpanStyle;
const Entry = Block.FrontMatter.Entry;

/// Leading glyph of the compact one-line style.
const compact_marker = "\u{25C8}"; // ◈

pub fn render(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize, style: config.FrontmatterStyle, for_export: bool) !void {
    // Hidden (and empty) front matter is skipped in render_model before
    // dispatch so it leaves no blank lines; reaching here with either is a
    // backstop that emits nothing. Empty raw front matter is NOT skipped: its
    // verbatim contract still reproduces the fences.
    if (style == .hidden) return;
    if (fm.entries.len == 0 and style != .raw) return;

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

fn sanitizeText(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var has_tab = false;
    for (text) |c| {
        if (c == '\t') {
            has_tab = true;
            break;
        }
    }
    if (!has_tab) return a.dupe(u8, text);
    const out = try a.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = if (c == '\t') ' ' else c;
    return out;
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
    // One column of padding inside each edge of the panel.
    const inner_width = width -| 2;

    // Keys are constrained to leave room for the two-column gap after the key
    // and at least one value cell, so an unbroken key can never push a line
    // past the width cap. Truncated keys carry a trailing ellipsis.
    const max_key_width = inner_width -| 3;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const keys = try arena.allocator().alloc([]const u8, fm.entries.len);
    for (fm.entries, 0..) |entry, index| {
        keys[index] = try truncateToWidth(arena.allocator(), entry.key, max_key_width);
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

    var rows: std.ArrayList(Row) = .empty;
    defer {
        for (rows.items) |row| if (row.owned_value) allocator.free(row.value);
        rows.deinit(allocator);
    }
    try buildRows(allocator, &rows, fm, keys, value_width);

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
fn buildRows(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), fm: Block.FrontMatter, keys: []const []const u8, value_width: usize) !void {
    // Raw non-`key: value` lines render in the value column too (the key cell
    // is emitted for every row), so both kinds wrap at value_width. `keys`
    // holds the width-constrained (possibly ellipsized) key for each entry.
    for (fm.entries, keys) |entry, key| {
        try appendWrapped(allocator, rows, key, entry.value, value_width);
    }
}

fn appendWrapped(allocator: std.mem.Allocator, rows: *std.ArrayList(Row), key: []const u8, value: []const u8, value_width: usize) !void {
    if (unicode.displayWidth(value) <= value_width) {
        try rows.append(allocator, .{ .key = key, .value = value, .owned_value = false });
        return;
    }
    const wrapped = try wrapValue(allocator, value, value_width);
    defer allocator.free(wrapped);
    // Rows already appended own their line via the caller's defer; free only
    // the lines that never made it into `rows` if an append fails partway.
    var appended: usize = 0;
    errdefer for (wrapped[appended..]) |line| allocator.free(line);
    for (wrapped, 0..) |line, index| {
        try rows.append(allocator, .{
            .key = if (index == 0) key else "",
            .value = line,
            .owned_value = true,
        });
        appended = index + 1;
    }
}

/// Wrap `text` into lines no wider than `width` display cells, allocating each
/// line. Prefers breaking at spaces; a single token wider than `width` is
/// hard-split at grapheme boundaries so the width is always respected.
/// `width` must be at least 1.
fn wrapValue(allocator: std.mem.Allocator, text: []const u8, width: usize) ![][]const u8 {
    std.debug.assert(width >= 1);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var current_width: usize = 0;

    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |word| {
        var remaining = word;
        while (remaining.len != 0) {
            const sep: usize = if (current.items.len == 0) 0 else 1;
            const word_width = unicode.displayWidth(remaining);
            if (current_width + sep + word_width <= width) {
                if (sep == 1) {
                    try current.append(allocator, ' ');
                    current_width += 1;
                }
                try current.appendSlice(allocator, remaining);
                current_width += word_width;
                remaining = remaining[remaining.len..];
                continue;
            }
            if (current.items.len != 0) {
                // Flush and retry the word at the start of a fresh line. Bind
                // the owned slice so a failing append frees it instead of
                // orphaning it.
                const flushed = try current.toOwnedSlice(allocator);
                errdefer allocator.free(flushed);
                try lines.append(allocator, flushed);
                current_width = 0;
                continue;
            }
            // The word alone is wider than the line: hard-split it.
            const take = takeWidth(remaining, width);
            try current.appendSlice(allocator, remaining[0..take]);
            const split = try current.toOwnedSlice(allocator);
            errdefer allocator.free(split);
            try lines.append(allocator, split);
            current_width = 0;
            remaining = remaining[take..];
        }
    }
    if (current.items.len != 0) {
        const tail = try current.toOwnedSlice(allocator);
        errdefer allocator.free(tail);
        try lines.append(allocator, tail);
    }
    if (lines.items.len == 0) {
        const empty = try allocator.dupe(u8, "");
        errdefer allocator.free(empty);
        try lines.append(allocator, empty);
    }
    return lines.toOwnedSlice(allocator);
}

/// Byte length of the longest prefix of `text` that fits within `width` display
/// cells. Always advances by at least one grapheme so callers make progress
/// even when a single wide glyph exceeds `width`.
fn takeWidth(text: []const u8, width: usize) usize {
    var index: usize = 0;
    var used: usize = 0;
    while (index < text.len) {
        const glyph = unicode.nextGlyph(text, index);
        if (index != 0 and used + glyph.width > width) break;
        used += glyph.width;
        index += glyph.bytes.len;
        if (used >= width) break;
    }
    return index;
}

/// The single-cell ellipsis appended to a truncated key.
const ellipsis = "\u{2026}"; // …

/// Return an owned copy of `text` constrained to at most `max` display cells.
/// If `text` already fits it is duped verbatim; otherwise it is cut at a
/// grapheme boundary with a trailing ellipsis so the result never exceeds
/// `max`. Reuses the grapheme-aware `takeWidth` machinery so wide glyphs are
/// respected. Used to keep keys from overflowing the width cap the same way
/// values are wrapped.
fn truncateToWidth(allocator: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (unicode.displayWidth(text) <= max) return allocator.dupe(u8, text);
    // No room for even the ellipsis: drop the key entirely.
    if (max == 0) return allocator.dupe(u8, "");
    // Reserve one cell for the ellipsis, then take as much of the key as fits.
    const budget = max - 1;
    const take = if (budget == 0) 0 else takeWidth(text, budget);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, text[0..take]);
    try buf.appendSlice(allocator, ellipsis);
    return buf.toOwnedSlice(allocator);
}

fn renderCompact(allocator: std.mem.Allocator, builder: *Builder, fm: Block.FrontMatter, width: usize) !void {
    // Keep at least two columns so a value can always take one cell after the
    // one-column continuation indent.
    const avail = @max(width, 2);

    try builder.appendSpan(.muted, compact_marker);
    var used: usize = unicode.displayWidth(compact_marker);
    var first = true;
    for (fm.entries) |entry| {
        // Raw continuation lines have no key; show the value alone rather than
        // silently dropping the entry.
        const raw_key = if (entry.key.len != 0)
            try std.fmt.allocPrint(allocator, "{s}:", .{entry.key})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(raw_key);
        // Constrain the key (marker + lead + key must fit `avail`) so a single
        // unbroken key can never overflow the width cap. Truncation ellipsizes.
        const key_text = try truncateToWidth(allocator, raw_key, avail -| 2);
        defer allocator.free(key_text);

        const key_w = unicode.displayWidth(key_text);
        const pair_width = key_w + unicode.displayWidth(entry.value);
        const lead: usize = if (first) 1 else 2;

        if (!first and used + lead + pair_width > avail) {
            try builder.newline();
            try builder.appendSpan(.muted, " ");
            used = 1;
        } else {
            try appendPad(builder, .body, lead);
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

fn appendCap(builder: *Builder, glyph: []const u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try builder.appendSpan(.frontmatter_cap, glyph);
}

fn appendPad(builder: *Builder, style: SpanStyle, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try builder.appendSpan(style, " ");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "wrapValue leaks no lines under injected allocation failure" {
    // Exercises every early-return path in wrapValue (space flush, hard-split,
    // trailing flush) so a failing `lines.append` after a successful
    // `toOwnedSlice` must not orphan the owned slice.
    const Ctx = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const lines = try wrapValue(allocator, "aaaa bbbb superlongunbrokentoken cccc", 5);
            defer {
                for (lines) |line| allocator.free(line);
                allocator.free(lines);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Ctx.run, .{});
}

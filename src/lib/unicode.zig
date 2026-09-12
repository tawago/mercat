//! Unicode 17.0 authority for terminal grapheme segmentation and cell geometry.
//! Input is never normalized. Strict APIs reject malformed UTF-8 and controls;
//! `PreparedLine` additionally expands tabs to four-column stops.

const std = @import("std");
const segmentation = @import("unicode/segmentation.zig");
const tables = @import("unicode/tables.zig");

pub const manifest = @import("unicode/generated/manifest.zig");

pub const MeasureError = error{
    InvalidUtf8,
    DisallowedControl,
    Overflow,
};

pub const CellWidth = u8;

pub const GraphemeSlice = struct {
    bytes: []const u8,
    width: CellWidth,
    byte_start: usize,
    byte_end: usize,
    column_start: usize,
    column_end: usize,
};

pub const Entry = struct {
    byte_start: usize,
    byte_end: usize,
    column_start: usize,
    column_end: usize,
    width: CellWidth,

    pub fn slice(self: Entry, bytes: []const u8) GraphemeSlice {
        return .{
            .bytes = bytes[self.byte_start..self.byte_end],
            .width = self.width,
            .byte_start = self.byte_start,
            .byte_end = self.byte_end,
            .column_start = self.column_start,
            .column_end = self.column_end,
        };
    }
};

/// Stateful whole-string extended-grapheme iterator. The current display
/// column is part of the state because a tab's width depends on its position.
pub const Iterator = struct {
    text: []const u8,
    index: usize = 0,
    column: usize = 0,
    validated: bool = false,

    pub fn init(text: []const u8) Iterator {
        return .{ .text = text };
    }

    /// `text` must begin on an extended-grapheme boundary. Use this to supply
    /// a nonzero terminal column for tab expansion, not to segment a suffix
    /// cut from the middle of a grapheme.
    pub fn initAt(text: []const u8, initial_column: usize) Iterator {
        return .{ .text = text, .column = initial_column };
    }

    pub fn next(self: *Iterator) MeasureError!?GraphemeSlice {
        if (!self.validated) {
            try validateInput(self.text);
            self.validated = true;
        }
        if (self.index == self.text.len) return null;
        const start = self.index;
        const end = segmentation.nextBoundary(self.text, start) catch return error.InvalidUtf8;
        const width: CellWidth = if (end == start + 1 and self.text[start] == '\t')
            @intCast(4 - self.column % 4)
        else
            graphemeWidth(self.text[start..end]);
        const column_end = std.math.add(usize, self.column, width) catch return error.Overflow;
        self.index = end;
        const result = GraphemeSlice{
            .bytes = self.text[start..end],
            .width = width,
            .byte_start = start,
            .byte_end = end,
            .column_start = self.column,
            .column_end = column_end,
        };
        self.column = column_end;
        return result;
    }

    fn initValidated(text: []const u8, initial_column: usize) Iterator {
        return .{ .text = text, .column = initial_column, .validated = true };
    }
};

pub const PreparedLine = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    entries: []const Entry,
    total_columns: usize,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) (MeasureError || std.mem.Allocator.Error)!PreparedLine {
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(allocator);
        var entries: std.ArrayList(Entry) = .empty;
        errdefer entries.deinit(allocator);

        var source = Iterator.init(text);
        var column: usize = 0;
        while (try source.next()) |grapheme| {
            if (grapheme.bytes.len == 1 and grapheme.bytes[0] == '\t') {
                for (0..grapheme.width) |_| {
                    const byte_start = bytes.items.len;
                    try bytes.append(allocator, ' ');
                    const column_end = std.math.add(usize, column, 1) catch return error.Overflow;
                    try entries.append(allocator, .{
                        .byte_start = byte_start,
                        .byte_end = byte_start + 1,
                        .column_start = column,
                        .column_end = column_end,
                        .width = 1,
                    });
                    column = column_end;
                }
                continue;
            }

            const byte_start = bytes.items.len;
            try bytes.appendSlice(allocator, grapheme.bytes);
            const byte_end = bytes.items.len;
            const column_end = std.math.add(usize, column, grapheme.width) catch return error.Overflow;
            try entries.append(allocator, .{
                .byte_start = byte_start,
                .byte_end = byte_end,
                .column_start = column,
                .column_end = column_end,
                .width = grapheme.width,
            });
            column = column_end;
        }

        const owned_bytes = try bytes.toOwnedSlice(allocator);
        errdefer allocator.free(owned_bytes);
        const owned_entries = try entries.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .bytes = owned_bytes,
            .entries = owned_entries,
            .total_columns = column,
        };
    }

    pub fn deinit(self: *PreparedLine) void {
        self.allocator.free(@constCast(self.bytes));
        self.allocator.free(@constCast(self.entries));
        self.* = undefined;
    }

    pub fn iterator(self: *const PreparedLine) PreparedIterator {
        return .{ .line = self };
    }

    /// Longest prefix whose graphemes fit wholly in `width` columns.
    pub fn prefixToWidth(self: PreparedLine, width: usize) []const u8 {
        var byte_end: usize = 0;
        for (self.entries) |entry| {
            if (entry.column_end > width) break;
            byte_end = entry.byte_end;
        }
        return self.bytes[0..byte_end];
    }
};

pub const PreparedIterator = struct {
    line: *const PreparedLine,
    index: usize = 0,

    pub fn next(self: *PreparedIterator) ?GraphemeSlice {
        if (self.index == self.line.entries.len) return null;
        const result = self.line.entries[self.index].slice(self.line.bytes);
        self.index += 1;
        return result;
    }
};

pub fn rawDisplayWidth(text: []const u8) MeasureError!usize {
    return rawDisplayWidthFrom(text, 0);
}

/// Return the ending column when measurement begins at `initial_column`.
pub fn rawDisplayWidthFrom(text: []const u8, initial_column: usize) MeasureError!usize {
    try validateInput(text);
    var iter = Iterator.initValidated(text, initial_column);
    while (try iter.next()) |_| {}
    return iter.column;
}

pub fn rawPrefixToWidth(text: []const u8, width: usize) MeasureError![]const u8 {
    try validateInput(text);
    var iter = Iterator.initValidated(text, 0);
    var byte_end: usize = 0;
    while (try iter.next()) |grapheme| {
        if (grapheme.column_end > width) break;
        byte_end = grapheme.byte_end;
    }
    return text[0..byte_end];
}

fn graphemeWidth(bytes: []const u8) CellWidth {
    return graphemeWidthCounted(bytes, null);
}

fn graphemeWidthCounted(bytes: []const u8, operations: ?*usize) CellWidth {
    var codepoints: [tables.rgi.max_sequence_len]u21 = undefined;
    var count: usize = 0;
    var index: usize = 0;
    var scalar_wide = false;
    var text_presentation = false;
    var emoji_presentation = false;
    while (index < bytes.len) {
        if (operations) |operation_count| operation_count.* +|= 1;
        const decoded = segmentation.decodeAt(bytes, index) catch unreachable;
        if (count < codepoints.len) codepoints[count] = decoded.codepoint;
        count += 1;

        if (decoded.codepoint == 0xfe0e and index != 0) {
            if (operations) |operation_count| operation_count.* +|= 1;
            const previous = segmentation.decodePrevious(bytes, index) catch unreachable;
            if (tables.variation_bases.contains(previous.codepoint)) text_presentation = true;
        } else if (decoded.codepoint == 0xfe0f and index != 0) {
            if (operations) |operation_count| operation_count.* +|= 1;
            const previous = segmentation.decodePrevious(bytes, index) catch unreachable;
            if (tables.variation_bases.contains(previous.codepoint)) emoji_presentation = true;
        }
        if (tables.wide.contains(decoded.codepoint) or
            tables.emoji_presentation.contains(decoded.codepoint) or
            tables.emoji_modifier.contains(decoded.codepoint)) scalar_wide = true;
        index = decoded.end;
    }

    if (text_presentation) return 1;
    if (emoji_presentation) return 2;
    if (count <= codepoints.len and tables.rgi.contains(codepoints[0..count])) return 2;
    if (count == 1 and tables.basic_emoji.contains(codepoints[0])) return 2;
    return if (scalar_wide) 2 else 1;
}

fn validateInput(text: []const u8) MeasureError!void {
    var index: usize = 0;
    while (index < text.len) {
        const end = segmentation.nextBoundary(text, index) catch return error.InvalidUtf8;
        try validateGrapheme(text[index..end]);
        index = end;
    }
}

fn validateGrapheme(bytes: []const u8) MeasureError!void {
    var codepoints: [tables.rgi.max_sequence_len]u21 = undefined;
    var count: usize = 0;
    var has_emoji_tag = false;
    var index: usize = 0;
    while (index < bytes.len) {
        const decoded = segmentation.decodeAt(bytes, index) catch return error.InvalidUtf8;
        const cp = decoded.codepoint;
        if ((cp <= 0x1f and cp != '\t') or
            (cp >= 0x7f and cp <= 0x9f) or
            cp == 0x2028 or cp == 0x2029 or
            (cp != '\t' and segmentation.graphemeBreak(cp) == .control)) return error.DisallowedControl;

        if (tables.emoji_component.contains(cp) and cp >= 0xe0020 and cp <= 0xe007f) {
            has_emoji_tag = true;
        } else if (tables.default_ignorable.contains(cp)) {
            switch (segmentation.graphemeBreak(cp)) {
                .extend, .zwj, .spacing_mark => {},
                else => return error.DisallowedControl,
            }
        }
        if (count < codepoints.len) codepoints[count] = cp;
        count += 1;
        index = decoded.end;
    }
    if (has_emoji_tag and (count > codepoints.len or !tables.rgi.contains(codepoints[0..count]))) {
        return error.DisallowedControl;
    }
}

pub const Glyph = struct { bytes: []const u8, width: usize };

/// Stateless compatibility lookup. It assumes `index` is a grapheme boundary.
/// A tab is measured from column zero; use `LegacyCursor` when its real column
/// matters or when walking more than one grapheme. Malformed UTF-8 after a
/// valid grapheme does not affect that grapheme. At malformed input this returns
/// an empty, width-zero slice anchored at `index`; it never returns invalid UTF-8.
pub fn nextGlyph(text: []const u8, index: usize) Glyph {
    if (index >= text.len) return .{ .bytes = text[text.len..], .width = 0 };
    var operations: usize = 0;
    const result = legacyGlyphAt(text, index, 0, &operations) orelse {
        return .{ .bytes = text[index..index], .width = 0 };
    };
    return result.glyph;
}

/// Linear compatibility iterator. It returns complete valid graphemes up to
/// the first malformed byte, then permanently returns null. Malformed bytes are
/// neither returned nor skipped, so every returned `Glyph.bytes` is valid UTF-8.
pub const LegacyCursor = struct {
    text: []const u8,
    index: usize = 0,
    column: usize = 0,
    scalar_operations: usize = 0,
    stopped: bool = false,

    pub fn init(text: []const u8) LegacyCursor {
        return .{ .text = text };
    }

    pub fn next(self: *LegacyCursor) ?Glyph {
        if (self.stopped or self.index >= self.text.len) return null;
        const result = legacyGlyphAt(self.text, self.index, self.column, &self.scalar_operations) orelse {
            self.stopped = true;
            return null;
        };
        self.index = result.end;
        self.column +|= result.glyph.width;
        return result.glyph;
    }
};

fn legacyGlyphAt(text: []const u8, index: usize, column: usize, operations: *usize) ?struct { glyph: Glyph, end: usize } {
    const end = segmentation.nextBoundaryCounted(text, index, operations) catch return null;
    const bytes = text[index..end];
    const width: usize = if (bytes.len == 1 and bytes[0] == '\t')
        4 - column % 4
    else
        graphemeWidthCounted(bytes, operations);
    return .{ .glyph = .{ .bytes = bytes, .width = width }, .end = end };
}

/// Terminal columns of `text`. Text the strict measure accepts is measured
/// by extended graphemes; text it rejects (malformed UTF-8, a control, a
/// disallowed format character) falls back to the compatibility measure,
/// which walks the same graphemes with `LegacyCursor` and counts every
/// malformed byte as one cell — so `displayWidth(clipToWidth(t, w)) <= w`
/// holds for every input.
pub fn displayWidth(text: []const u8) usize {
    return rawDisplayWidth(text) catch legacyDisplayWidth(text);
}

/// Return the longest complete-grapheme prefix within `width`. When strict
/// validation rejects malformed UTF-8, clipping stops before its first byte;
/// the returned prefix is always valid UTF-8. Valid but disallowed controls use
/// the compatibility width policy. No malformed byte is replaced or skipped.
pub fn clipToWidth(text: []const u8, width: usize) []const u8 {
    return rawPrefixToWidth(text, width) catch legacyClipToWidth(text, width);
}

pub fn codepointWidth(codepoint: u21) usize {
    if (codepoint == '\t') return 4;
    if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return 0;
    if (tables.wide.contains(codepoint) or
        tables.emoji_presentation.contains(codepoint) or
        tables.emoji_modifier.contains(codepoint)) return 2;
    return 1;
}

/// Compatibility measure: the graphemes `LegacyCursor` yields, at the
/// widths it assigns them, plus one cell for every malformed byte — the
/// cursor stops at such a byte, the byte is charged, and a fresh cursor
/// resumes at the next one. The same walk `legacyClipToWidth` cuts on, so
/// a clipped prefix never measures wider than the width it was cut to.
/// Unlike slice-returning APIs, no source bytes escape.
fn legacyDisplayWidth(text: []const u8) usize {
    var width: usize = 0;
    var rest = text;
    while (rest.len > 0) {
        var cursor = LegacyCursor.init(rest);
        while (cursor.next()) |glyph| width +|= glyph.width;
        if (cursor.index >= rest.len) break;
        width +|= 1;
        rest = rest[cursor.index + 1 ..];
    }
    return width;
}

fn legacyClipToWidth(text: []const u8, width: usize) []const u8 {
    var used: usize = 0;
    var byte_end: usize = 0;
    var cursor = LegacyCursor.init(text);
    while (cursor.next()) |glyph| {
        if (used +| glyph.width > width) break;
        used +|= glyph.width;
        byte_end = cursor.index;
    }
    return text[0..byte_end];
}

pub fn wrapLine(allocator: std.mem.Allocator, text: []const u8, width: usize, indent: []const u8) ![][]const u8 {
    const valid_text = legacyValidPrefix(text);
    const valid_indent = legacyValidPrefix(indent);
    if (width == 0 or displayWidth(valid_text) <= width) {
        const lines = try allocator.alloc([]const u8, 1);
        lines[0] = try allocator.dupe(u8, valid_text);
        return lines;
    }

    var words = std.mem.tokenizeScalar(u8, valid_text, ' ');
    var output: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (output.items) |line| allocator.free(line);
        output.deinit(allocator);
    }
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(allocator);
    var current_width: usize = 0;
    while (words.next()) |word| {
        const word_width = displayWidth(word);
        const extra: usize = if (current.items.len == 0) 0 else 1;
        const target_width = if (output.items.len == 0) width else width -| displayWidth(valid_indent);
        if (current.items.len != 0 and current_width + extra + word_width > target_width) {
            try output.append(allocator, try allocator.dupe(u8, current.items));
            current.clearRetainingCapacity();
            try current.appendSlice(allocator, valid_indent);
            try current.appendSlice(allocator, word);
            current_width = displayWidth(current.items);
            continue;
        }
        if (extra == 1) try current.append(allocator, ' ');
        try current.appendSlice(allocator, word);
        current_width += extra + word_width;
    }
    if (current.items.len != 0) try output.append(allocator, try allocator.dupe(u8, current.items));
    return output.toOwnedSlice(allocator);
}

fn legacyValidPrefix(text: []const u8) []const u8 {
    var cursor = LegacyCursor.init(text);
    while (cursor.next()) |_| {}
    return text[0..cursor.index];
}

test {
    _ = @import("unicode/tests.zig");
}

const std = @import("std");

/// A single decoded grapheme: its byte slice within the source text and its
/// terminal display width.
pub const Glyph = struct { bytes: []const u8, width: usize };

/// Decode the glyph beginning at `text[index]`. Invalid or truncated UTF-8 is
/// treated as a single width-1 byte so callers can always advance safely.
pub fn nextGlyph(text: []const u8, index: usize) Glyph {
    const one: Glyph = .{ .bytes = text[index .. index + 1], .width = 1 };
    const sequence_len = std.unicode.utf8ByteSequenceLength(text[index]) catch return one;
    if (index + sequence_len > text.len) return one;
    const char = std.unicode.utf8Decode(text[index .. index + sequence_len]) catch return one;
    return .{ .bytes = text[index .. index + sequence_len], .width = codepointWidth(char) };
}

pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const glyph = nextGlyph(text, index);
        width += glyph.width;
        index += glyph.bytes.len;
    }
    return width;
}

pub fn wrapLine(allocator: std.mem.Allocator, text: []const u8, width: usize, indent: []const u8) ![][]const u8 {
    if (width == 0 or displayWidth(text) <= width) {
        const lines = try allocator.alloc([]const u8, 1);
        lines[0] = try allocator.dupe(u8, text);
        return lines;
    }

    var words = std.mem.tokenizeScalar(u8, text, ' ');
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
        const target_width = if (output.items.len == 0) width else width -| displayWidth(indent);
        if (current.items.len != 0 and current_width + extra + word_width > target_width) {
            try output.append(allocator, try allocator.dupe(u8, current.items));
            current.clearRetainingCapacity();
            try current.appendSlice(allocator, indent);
            try current.appendSlice(allocator, word);
            current_width = displayWidth(current.items);
            continue;
        }

        if (extra == 1) try current.append(allocator, ' ');
        try current.appendSlice(allocator, word);
        current_width += extra + word_width;
    }

    if (current.items.len != 0) {
        try output.append(allocator, try allocator.dupe(u8, current.items));
    }

    return try output.toOwnedSlice(allocator);
}

pub fn codepointWidth(codepoint: u21) usize {
    if (codepoint == '\t') return 4;
    if (codepoint < 0x20) return 0;
    if (codepoint >= 0x1100 and (codepoint <= 0x115f or codepoint == 0x2329 or codepoint == 0x232a or (codepoint >= 0x2e80 and codepoint <= 0xa4cf) or (codepoint >= 0xac00 and codepoint <= 0xd7a3) or (codepoint >= 0xf900 and codepoint <= 0xfaff) or (codepoint >= 0xfe10 and codepoint <= 0xfe19) or (codepoint >= 0xfe30 and codepoint <= 0xfe6f) or (codepoint >= 0xff00 and codepoint <= 0xff60) or (codepoint >= 0xffe0 and codepoint <= 0xffe6))) {
        return 2;
    }
    return 1;
}

test "nextGlyph decodes ascii, wide, and invalid bytes" {
    const ascii = nextGlyph("a", 0);
    try std.testing.expectEqualStrings("a", ascii.bytes);
    try std.testing.expectEqual(@as(usize, 1), ascii.width);

    const wide = nextGlyph("日", 0);
    try std.testing.expectEqualStrings("日", wide.bytes);
    try std.testing.expectEqual(@as(usize, 2), wide.width);

    // A lone continuation byte is not a valid start byte: one width-1 byte.
    const invalid = nextGlyph("\x80", 0);
    try std.testing.expectEqual(@as(usize, 1), invalid.bytes.len);
    try std.testing.expectEqual(@as(usize, 1), invalid.width);
}

test "nextGlyph advances across a mixed string" {
    const text = "a日b";
    var index: usize = 0;
    const g0 = nextGlyph(text, index);
    index += g0.bytes.len;
    const g1 = nextGlyph(text, index);
    index += g1.bytes.len;
    const g2 = nextGlyph(text, index);
    index += g2.bytes.len;

    try std.testing.expectEqualStrings("a", g0.bytes);
    try std.testing.expectEqualStrings("日", g1.bytes);
    try std.testing.expectEqualStrings("b", g2.bytes);
    try std.testing.expectEqual(text.len, index);
}

test "wraps text with indent" {
    const allocator = std.testing.allocator;
    const wrapped = try wrapLine(allocator, "alpha beta gamma delta", 10, "  ");
    defer {
        for (wrapped) |line| allocator.free(line);
        allocator.free(wrapped);
    }

    try std.testing.expectEqual(@as(usize, 3), wrapped.len);
    try std.testing.expectEqualStrings("alpha beta", wrapped[0]);
    try std.testing.expectEqualStrings("  gamma", wrapped[1]);
}

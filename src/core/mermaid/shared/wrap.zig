const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode");

pub const Line = struct { bytes: []const u8, width: u32 };

const breaks = [_][]const u8{ "<br/>", "<br>" };

/// Word wrap to `width` display columns. `<br>` and `<br/>` force a break; a word wider than
/// `width` is split at grapheme boundaries. Lines borrow from `text`.
pub fn wrap(allocator: Allocator, text: []const u8, width: u32) ![]Line {
    const limit = @max(width, 1);
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    var rest = text;
    while (true) {
        const cut = nextBreak(rest);
        try packSegment(allocator, &lines, rest[0..cut.start], limit);
        if (cut.start == rest.len) break;
        rest = rest[cut.end..];
    }
    return lines.toOwnedSlice(allocator);
}

/// The display width of the widest word, breaks and spaces separating words.
pub fn longestWord(text: []const u8) !u32 {
    var widest: u32 = 0;
    var rest = text;
    while (true) {
        const cut = nextBreak(rest);
        var words = std.mem.tokenizeScalar(u8, rest[0..cut.start], ' ');
        while (words.next()) |word| widest = @max(widest, try displayWidth(word));
        if (cut.start == rest.len) break;
        rest = rest[cut.end..];
    }
    return widest;
}

const Cut = struct { start: usize, end: usize };

fn nextBreak(text: []const u8) Cut {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        for (breaks) |tag| {
            if (std.mem.startsWith(u8, text[i..], tag)) return .{ .start = i, .end = i + tag.len };
        }
    }
    return .{ .start = text.len, .end = text.len };
}

fn displayWidth(text: []const u8) !u32 {
    return @intCast(try unicode.rawDisplayWidth(text));
}

fn packSegment(allocator: Allocator, lines: *std.ArrayList(Line), segment: []const u8, limit: u32) !void {
    var start: ?usize = null;
    var end: usize = 0;
    var used: u32 = 0;
    var words = std.mem.tokenizeScalar(u8, segment, ' ');
    while (words.next()) |whole| {
        var word = whole;
        var word_start = words.index - word.len;
        var word_width = try displayWidth(word);
        const gap: u32 = @intCast(word_start - end);
        if (start != null and used + gap + word_width <= limit) {
            end = word_start + word.len;
            used += gap + word_width;
            continue;
        }
        if (start) |s| try lines.append(allocator, .{ .bytes = segment[s..end], .width = used });
        while (word_width > limit) {
            const piece = try splitPrefix(word, limit);
            const piece_width = try displayWidth(piece);
            try lines.append(allocator, .{ .bytes = piece, .width = piece_width });
            word = word[piece.len..];
            word_start += piece.len;
            word_width -= piece_width;
        }
        if (word.len == 0) {
            start = null;
            continue;
        }
        start = word_start;
        end = word_start + word.len;
        used = word_width;
    }
    if (start) |s| {
        if (end > s) try lines.append(allocator, .{ .bytes = segment[s..end], .width = used });
    }
}

/// The longest prefix of `word` within `limit` columns, at least one grapheme.
fn splitPrefix(word: []const u8, limit: u32) ![]const u8 {
    const prefix = try unicode.rawPrefixToWidth(word, limit);
    if (prefix.len > 0) return prefix;
    var it = unicode.Iterator.init(word);
    return (try it.next()).?.bytes;
}

fn expectLines(expected: []const []const u8, text: []const u8, width: u32) !void {
    const lines = try wrap(std.testing.allocator, text, width);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, line| {
        try std.testing.expectEqualStrings(want, line.bytes);
        try std.testing.expectEqual(try displayWidth(want), line.width);
        try std.testing.expect(line.width <= width);
    }
}

test "words pack greedily up to the width" {
    try expectLines(&.{ "Transaction:", "dedupe +", "minimized", "record +", "event + task" }, "Transaction: dedupe + minimized record + event + task", 12);
    try expectLines(&.{"fits on one line"}, "fits on one line", 16);
    try expectLines(&.{ "a  b", "c" }, "a  b   c", 4);
    try expectLines(&.{ "a", "b", "c" }, "a  b   c", 3);
}

test "wide characters count two columns" {
    try std.testing.expectEqual(@as(u32, 6), try longestWord("日本語"));
    try expectLines(&.{ "日本", "語" }, "日本語", 5);
    try expectLines(&.{ "日", "本", "語" }, "日本語", 2);
}

test "a word wider than the width splits at graphemes" {
    try expectLines(&.{ "abcd", "efgh", "ij k" }, "abcdefghij k", 4);
}

test "br tags force a break" {
    try expectLines(&.{ "one", "two", "three" }, "one<br>two<br/>three", 20);
    try expectLines(&.{ "end", "start" }, "<br>end<br/>start<br>", 20);
}

test "empty text has no lines" {
    try expectLines(&.{}, "", 10);
    try expectLines(&.{}, "   ", 10);
    try std.testing.expectEqual(@as(u32, 0), try longestWord(""));
}

test "no line is wider than the width" {
    const text = "Fetch authoritative current value when needed 日本語のラベル supercalifragilistic";
    var width: u32 = 1;
    while (width <= 30) : (width += 1) {
        const lines = try wrap(std.testing.allocator, text, width);
        defer std.testing.allocator.free(lines);
        for (lines) |line| {
            try std.testing.expect(line.width <= @max(width, 2));
            try std.testing.expectEqual(try displayWidth(line.bytes), line.width);
        }
    }
}

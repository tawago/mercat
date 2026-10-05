const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode");

pub const Line = struct { bytes: []const u8, width: u32 };

const breaks = [_][]const u8{ "<br/>", "<br>" };

/// Word wrap to `width` display columns. A line breaks only at a space or between two East
/// Asian wide characters; `<br>` and `<br/>` force a break. A word wider than `width` is never
/// split: it takes a line of its own, wider than `width`. Lines borrow from `text`.
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

/// The display width of the widest word `wrap` never splits.
pub fn longestWord(text: []const u8) !u32 {
    var widest: u32 = 0;
    var rest = text;
    while (true) {
        const cut = nextBreak(rest);
        var units = Units.init(rest[0..cut.start]);
        while (try units.next()) |unit| widest = @max(widest, unit.width);
        if (cut.start == rest.len) break;
        rest = rest[cut.end..];
    }
    return widest;
}

/// The display width of the widest run between spaces and breaks.
pub fn longestToken(text: []const u8) !u32 {
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

const Unit = struct { start: usize, end: usize, width: u32 };

/// The unbreakable units of a segment, in order: space-delimited words, cut between two
/// adjacent East Asian wide graphemes.
const Units = struct {
    segment: []const u8,
    words: std.mem.TokenIterator(u8, .scalar),
    word_start: usize = 0,
    graphemes: unicode.Iterator = unicode.Iterator.init(""),
    pending: ?unicode.GraphemeSlice = null,

    fn init(segment: []const u8) Units {
        return .{ .segment = segment, .words = std.mem.tokenizeScalar(u8, segment, ' ') };
    }

    fn next(self: *Units) !?Unit {
        const first = self.pending orelse try self.graphemes.next() orelse blk: {
            const word = self.words.next() orelse return null;
            self.word_start = self.words.index - word.len;
            self.graphemes = unicode.Iterator.init(word);
            break :blk (try self.graphemes.next()).?;
        };
        self.pending = null;
        var last = first;
        while (try self.graphemes.next()) |grapheme| {
            if (eastAsianWide(last.bytes) and eastAsianWide(grapheme.bytes)) {
                self.pending = grapheme;
                break;
            }
            last = grapheme;
        }
        const start = self.word_start + first.byte_start;
        const end = self.word_start + last.byte_end;
        return .{ .start = start, .end = end, .width = try displayWidth(self.segment[start..end]) };
    }
};

fn eastAsianWide(grapheme: []const u8) bool {
    const len = std.unicode.utf8ByteSequenceLength(grapheme[0]) catch return false;
    if (len > grapheme.len) return false;
    const cp = std.unicode.utf8Decode(grapheme[0..len]) catch return false;
    return unicode.isEastAsianWide(cp);
}

fn packSegment(allocator: Allocator, lines: *std.ArrayList(Line), segment: []const u8, limit: u32) !void {
    var start: ?usize = null;
    var end: usize = 0;
    var used: u32 = 0;
    var units = Units.init(segment);
    while (try units.next()) |unit| {
        if (start) |s| {
            const joined = try displayWidth(segment[s..unit.end]);
            if (joined <= limit) {
                end = unit.end;
                used = joined;
                continue;
            }
        }
        if (start) |s| try lines.append(allocator, .{ .bytes = segment[s..end], .width = used });
        start = unit.start;
        end = unit.end;
        used = unit.width;
    }
    if (start) |s| try lines.append(allocator, .{ .bytes = segment[s..end], .width = used });
}

fn expectLines(expected: []const []const u8, text: []const u8, width: u32) !void {
    const lines = try wrap(std.testing.allocator, text, width);
    defer std.testing.allocator.free(lines);
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, line| {
        try std.testing.expectEqualStrings(want, line.bytes);
        try std.testing.expectEqual(try displayWidth(want), line.width);
    }
}

test "words pack greedily up to the width" {
    try expectLines(&.{ "Transaction:", "dedupe +", "minimized", "record +", "event + task" }, "Transaction: dedupe + minimized record + event + task", 12);
    try expectLines(&.{"fits on one line"}, "fits on one line", 16);
    try expectLines(&.{ "a  b", "c" }, "a  b   c", 4);
    try expectLines(&.{ "a", "b", "c" }, "a  b   c", 3);
}

test "a word wider than the width takes its own line whole" {
    try expectLines(&.{ "abcdefghij", "k" }, "abcdefghij k", 4);
    try expectLines(&.{ "Transaction:", "dedupe" }, "Transaction: dedupe", 9);
    try expectLines(&.{ "a", "Acknowledge", "b" }, "a Acknowledge b", 9);
    try std.testing.expectEqual(@as(u32, 12), try longestWord("Transaction: dedupe"));
}

test "East Asian wide characters break between each other" {
    try std.testing.expectEqual(@as(u32, 2), try longestWord("日本語"));
    try std.testing.expectEqual(@as(u32, 6), try longestToken("日本語"));
    try expectLines(&.{ "日本", "語" }, "日本語", 5);
    try expectLines(&.{ "日", "本", "語" }, "日本語", 2);
    try expectLines(&.{ "日本語の", "ラベル" }, "日本語のラベル", 8);
    try expectLines(&.{ "日本", "語abc" }, "日本語abc", 5);
    try std.testing.expectEqual(@as(u32, 5), try longestWord("日本語abc"));
}

test "an emoji grapheme is never split" {
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    try expectLines(&.{family}, family, 1);
    try expectLines(&.{ "a", family ++ family, "b" }, "a " ++ family ++ family ++ " b", 3);
    try std.testing.expectEqual(@as(u32, 4), try longestWord(family ++ family));
    try expectLines(&.{ "\u{1F600}\u{1F600}" }, "\u{1F600}\u{1F600}", 2);
}

test "a tab is measured from the start of the line it lands on" {
    try expectLines(&.{"x ab\tcd"}, "x ab\tcd", 10);
    try expectLines(&.{ "x", "ab\tcd" }, "x ab\tcd", 9);
    try expectLines(&.{ "日本", "語\tx" }, "日本語\tx", 5);
    try std.testing.expectEqual(@as(u32, 6), try longestWord("ab\tcd"));
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

test "no line is wider than the width or the longest word, and no word is split" {
    const text = "Fetch authoritative current value when needed 日本語のラベル supercalifragilistic";
    const longest = try longestWord(text);
    var width: u32 = 1;
    while (width <= 30) : (width += 1) {
        const lines = try wrap(std.testing.allocator, text, width);
        defer std.testing.allocator.free(lines);
        for (lines) |line| {
            try std.testing.expect(line.width <= @max(width, longest));
            try std.testing.expectEqual(try displayWidth(line.bytes), line.width);
        }
        var words = std.mem.tokenizeScalar(u8, text, ' ');
        while (words.next()) |word| {
            if (eastAsianWide(word)) continue;
            var whole = false;
            for (lines) |line| whole = whole or std.mem.indexOf(u8, line.bytes, word) != null;
            try std.testing.expect(whole);
        }
    }
}

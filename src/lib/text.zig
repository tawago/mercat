//! Domain-free byte-level text primitives: BOM stripping and line iteration.
//! Shared by the cli input classifier and core/mermaid's source scanning.

const std = @import("std");

/// UTF-8 byte-order mark, emitted by several Windows editors.
const bom = "\xEF\xBB\xBF";

/// Strip a leading UTF-8 BOM, if present.
pub fn stripBom(content: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, content, bom)) content[bom.len..] else content;
}

/// Line iterator that accepts LF, CRLF and CR-only line endings.
pub const LineIter = struct {
    rest: []const u8,
    done: bool = false,

    pub fn init(content: []const u8) LineIter {
        return .{ .rest = content };
    }

    pub fn next(self: *LineIter) ?[]const u8 {
        if (self.done) return null;
        const idx = std.mem.indexOfAny(u8, self.rest, "\r\n") orelse {
            self.done = true;
            return self.rest;
        };
        const line = self.rest[0..idx];
        var skip: usize = 1;
        if (self.rest[idx] == '\r' and idx + 1 < self.rest.len and self.rest[idx + 1] == '\n') skip = 2;
        self.rest = self.rest[idx + skip ..];
        return line;
    }
};

/// First line that is neither blank nor opens with `comment_prefix`, fully
/// trimmed. Returns "" when there is no such line.
pub fn firstMeaningfulLine(source: []const u8, comment_prefix: []const u8) []const u8 {
    var lines = LineIter.init(stripBom(source));
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len != 0 and !std.mem.startsWith(u8, line, comment_prefix)) return line;
    }
    return "";
}

test "firstMeaningfulLine skips blanks, BOM and comment lines" {
    try std.testing.expectEqualStrings("flowchart TD", firstMeaningfulLine("\xEF\xBB\xBF\n%% legend\nflowchart TD\n  A-->B\n", "%%"));
    try std.testing.expectEqualStrings("graph LR", firstMeaningfulLine("graph LR\r  A-->B\r", "%%"));
    try std.testing.expectEqualStrings("", firstMeaningfulLine("\n%% only comments\n", "%%"));
}

test "stripBom" {
    try std.testing.expectEqualStrings("abc", stripBom("\xEF\xBB\xBFabc"));
    try std.testing.expectEqualStrings("abc", stripBom("abc"));
}

test "LineIter handles LF, CRLF and CR-only endings" {
    var it = LineIter.init("a\nb\r\nc\rd");
    try std.testing.expectEqualStrings("a", it.next().?);
    try std.testing.expectEqualStrings("b", it.next().?);
    try std.testing.expectEqualStrings("c", it.next().?);
    try std.testing.expectEqualStrings("d", it.next().?);
    try std.testing.expect(it.next() == null);
}

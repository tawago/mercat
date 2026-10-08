const std = @import("std");
const Allocator = std.mem.Allocator;
const Direction = @import("types.zig").Direction;

pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r';
}

pub fn isIdChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn isNameChar(c: u8) bool {
    return isIdChar(c) or c == '-';
}

/// The line scanner the sequence, class, ER and state parsers share.
pub const Scanner = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize = 0,

    pub fn init(allocator: Allocator, source: []const u8) Scanner {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn parseDirection(self: *Scanner) Direction {
        if (self.consumeKeyword("LR")) return .LR;
        if (self.consumeKeyword("RL")) return .RL;
        if (self.consumeKeyword("TD")) return .TD;
        if (self.consumeKeyword("TB")) return .TB;
        if (self.consumeKeyword("BT")) return .BT;
        return .TD;
    }

    pub fn current(self: *Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.source[self.pos];
    }

    pub fn peek(self: *Scanner, offset: usize) u8 {
        if (self.pos + offset >= self.source.len) return 0;
        return self.source[self.pos + offset];
    }

    pub fn advance(self: *Scanner) void {
        if (!self.isAtEnd()) self.pos += 1;
    }

    pub fn isAtEnd(self: *Scanner) bool {
        return self.pos >= self.source.len;
    }

    pub fn isLineEnd(self: *Scanner) bool {
        return self.isAtEnd() or self.current() == '\n';
    }

    pub fn skipWhitespace(self: *Scanner) void {
        while (!self.isAtEnd() and isWhitespace(self.current())) {
            self.advance();
        }
    }

    pub fn skipWhitespaceAndComments(self: *Scanner) void {
        while (!self.isAtEnd()) {
            self.skipWhitespace();
            if (self.current() == '\n') {
                self.advance();
                continue;
            }
            if (self.current() == '%' and self.peek(1) == '%') {
                self.skipToNextLine();
                continue;
            }
            break;
        }
    }

    pub fn skipToNextLine(self: *Scanner) void {
        while (!self.isAtEnd() and self.current() != '\n') {
            self.advance();
        }
        if (!self.isAtEnd()) {
            self.advance();
        }
    }

    pub fn matchChar(self: *Scanner, c: u8) bool {
        if (self.current() == c) {
            self.advance();
            return true;
        }
        return false;
    }

    pub fn matchString(self: *Scanner, s: []const u8) bool {
        if (self.pos + s.len > self.source.len) return false;
        if (std.mem.eql(u8, self.source[self.pos .. self.pos + s.len], s)) {
            self.pos += s.len;
            return true;
        }
        return false;
    }

    /// Consume `keyword` when it stands as a whole word.
    pub fn consumeKeyword(self: *Scanner, keyword: []const u8) bool {
        if (!self.peekKeyword(keyword)) return false;
        self.pos += keyword.len;
        return true;
    }

    pub fn peekKeyword(self: *Scanner, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword)) return false;

        if (self.pos + keyword.len < self.source.len) {
            const next = self.source[self.pos + keyword.len];
            if (isIdChar(next)) return false;
        }

        return true;
    }

    /// A run of letters, digits and underscores; empty when none is next.
    pub fn identifier(self: *Scanner) []const u8 {
        return self.takeWhile(isIdChar);
    }

    /// An identifier that may also contain hyphens (class and entity names).
    pub fn name(self: *Scanner) []const u8 {
        return self.takeWhile(isNameChar);
    }

    /// The text up to the first byte of `stops` or the end of the source, without trailing
    /// blanks. The stop byte is left unread.
    pub fn textUntil(self: *Scanner, comptime stops: []const u8) []const u8 {
        const start = self.pos;
        while (!self.isAtEnd() and std.mem.indexOfScalar(u8, stops, self.current()) == null) {
            self.advance();
        }
        return std.mem.trimRight(u8, self.source[start..self.pos], " \t\r");
    }

    pub fn restOfLine(self: *Scanner) []const u8 {
        return self.textUntil("\n");
    }

    /// The text of a `: text` tail, null when no colon is next.
    pub fn labelAfterColon(self: *Scanner) ?[]const u8 {
        if (!self.matchChar(':')) return null;
        self.skipWhitespace();
        return self.restOfLine();
    }

    fn takeWhile(self: *Scanner, comptime pred: fn (u8) bool) []const u8 {
        const start = self.pos;
        while (!self.isAtEnd() and pred(self.current())) {
            self.advance();
        }
        return self.source[start..self.pos];
    }
};

test "textUntil trims trailing blanks and leaves the stop unread" {
    var s = Scanner.init(std.testing.allocator, "go on \t\r\nnext");
    try std.testing.expectEqualStrings("go on", s.restOfLine());
    try std.testing.expectEqual(@as(u8, '\n'), s.current());
    var t = Scanner.init(std.testing.allocator, "label {body");
    try std.testing.expectEqualStrings("label", t.textUntil("\n{"));
    try std.testing.expectEqual(@as(u8, '{'), t.current());
}

test "keywords match whole words only" {
    var s = Scanner.init(std.testing.allocator, "endgame end");
    try std.testing.expect(!s.consumeKeyword("end"));
    try std.testing.expect(s.peekKeyword("endgame"));
    s.pos = 8;
    try std.testing.expect(s.consumeKeyword("end"));
    try std.testing.expect(s.isAtEnd());
}

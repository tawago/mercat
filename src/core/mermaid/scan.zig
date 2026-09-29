const std = @import("std");
const Allocator = std.mem.Allocator;
const Direction = @import("types.zig").Direction;

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

    pub fn isWhitespace(self: *Scanner, c: u8) bool {
        _ = self;
        return c == ' ' or c == '\t' or c == '\r';
    }

    pub fn isIdChar(self: *Scanner, c: u8) bool {
        _ = self;
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_';
    }

    pub fn skipWhitespace(self: *Scanner) void {
        while (!self.isAtEnd() and self.isWhitespace(self.current())) {
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

    pub fn consumeKeyword(self: *Scanner, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword)) return false;

        if (self.pos + keyword.len < self.source.len) {
            const next = self.source[self.pos + keyword.len];
            if (self.isIdChar(next)) return false;
        }

        self.pos += keyword.len;
        return true;
    }

    pub fn peekKeyword(self: *Scanner, keyword: []const u8) bool {
        if (self.pos + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.pos .. self.pos + keyword.len], keyword)) return false;

        if (self.pos + keyword.len < self.source.len) {
            const next = self.source[self.pos + keyword.len];
            if (self.isIdChar(next)) return false;
        }

        return true;
    }
};

const std = @import("std");

pub const TokenStyle = enum {
    plain,
    keyword,
    string,
    number,
    comment,
};

pub const Token = struct {
    text: []const u8,
    style: TokenStyle,
};

pub fn supported(language: []const u8) bool {
    return std.mem.eql(u8, language, "zig") or std.mem.eql(u8, language, "javascript") or std.mem.eql(u8, language, "js") or std.mem.eql(u8, language, "typescript") or std.mem.eql(u8, language, "ts") or std.mem.eql(u8, language, "sh") or std.mem.eql(u8, language, "bash");
}

pub fn tokenizeLine(allocator: std.mem.Allocator, language: []const u8, line: []const u8) ![]Token {
    if (!supported(language)) {
        const tokens = try allocator.alloc(Token, 1);
        tokens[0] = .{ .text = try allocator.dupe(u8, line), .style = .plain };
        return tokens;
    }

    var items: std.ArrayList(Token) = .empty;
    errdefer {
        for (items.items) |token| allocator.free(token.text);
        items.deinit(allocator);
    }

    var index: usize = 0;
    while (index < line.len) {
        const char = line[index];
        if (char == '"') {
            const end = scanQuoted(line, index + 1);
            try appendToken(allocator, &items, line[index..end], .string);
            index = end;
            continue;
        }

        if (std.ascii.isDigit(char)) {
            const end = scanWhile(line, index, isNumberByte);
            try appendToken(allocator, &items, line[index..end], .number);
            index = end;
            continue;
        }

        if (startsComment(language, line[index..])) {
            try appendToken(allocator, &items, line[index..], .comment);
            break;
        }

        if (isIdentStart(char)) {
            const end = scanWhile(line, index, isIdentByte);
            const word = line[index..end];
            try appendToken(allocator, &items, word, if (isKeyword(language, word)) .keyword else .plain);
            index = end;
            continue;
        }

        try appendToken(allocator, &items, line[index .. index + 1], .plain);
        index += 1;
    }

    return try items.toOwnedSlice(allocator);
}

pub fn freeTokens(allocator: std.mem.Allocator, tokens: []Token) void {
    for (tokens) |token| allocator.free(token.text);
    allocator.free(tokens);
}

fn appendToken(allocator: std.mem.Allocator, items: *std.ArrayList(Token), text: []const u8, style: TokenStyle) !void {
    try items.append(allocator, .{ .text = try allocator.dupe(u8, text), .style = style });
}

fn scanQuoted(line: []const u8, start: usize) usize {
    var index = start;
    while (index < line.len) : (index += 1) {
        if (line[index] == '\\' and index + 1 < line.len) {
            index += 1;
            continue;
        }
        if (line[index] == '"') return index + 1;
    }
    return line.len;
}

fn scanWhile(line: []const u8, start: usize, predicate: fn (u8) bool) usize {
    var index = start;
    while (index < line.len and predicate(line[index])) : (index += 1) {}
    return index;
}

fn isIdentStart(char: u8) bool {
    return std.ascii.isAlphabetic(char) or char == '_';
}

fn isIdentByte(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

fn isNumberByte(char: u8) bool {
    return std.ascii.isDigit(char) or char == '_';
}

fn startsComment(language: []const u8, text: []const u8) bool {
    if (text.len < 2) return false;
    if (std.mem.eql(u8, language, "zig") or std.mem.eql(u8, language, "javascript") or std.mem.eql(u8, language, "js") or std.mem.eql(u8, language, "typescript") or std.mem.eql(u8, language, "ts")) {
        return text[0] == '/' and text[1] == '/';
    }
    if (std.mem.eql(u8, language, "sh") or std.mem.eql(u8, language, "bash")) {
        return text[0] == '#';
    }
    return false;
}

fn isKeyword(language: []const u8, word: []const u8) bool {
    if (std.mem.eql(u8, language, "zig")) {
        return eqlAny(word, &.{ "const", "var", "fn", "pub", "return", "if", "else", "try", "catch", "defer", "struct" });
    }
    if (std.mem.eql(u8, language, "javascript") or std.mem.eql(u8, language, "js") or std.mem.eql(u8, language, "typescript") or std.mem.eql(u8, language, "ts")) {
        return eqlAny(word, &.{ "const", "let", "var", "function", "return", "if", "else", "class", "export", "import" });
    }
    if (std.mem.eql(u8, language, "sh") or std.mem.eql(u8, language, "bash")) {
        return eqlAny(word, &.{ "if", "then", "else", "fi", "for", "do", "done", "case", "esac" });
    }
    return false;
}

fn eqlAny(word: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, word, candidate)) return true;
    }
    return false;
}

test "tokenizes simple zig line" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeLine(allocator, "zig", "const n = 42; // comment");
    defer freeTokens(allocator, tokens);

    try std.testing.expect(tokens.len >= 5);
    try std.testing.expectEqual(TokenStyle.keyword, tokens[0].style);
}

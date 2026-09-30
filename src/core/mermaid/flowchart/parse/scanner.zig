//! Byte scanner under the flowchart parser: blanks and `%%` comments, words, strings,
//! punctuation, raw spans and line-break markers. It knows no grammar.

const std = @import("std");
const prim = @import("prim");

pub const Kind = enum { word, string, open, close, pipe, semicolon, comma, colon, amp, newline, eof, other };

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    /// The bracket byte of an `open` or `close` token.
    bracket: u8 = 0,
};

pub const Scanner = struct {
    src: []const u8,
    pos: usize = 0,

    pub fn init(src: []const u8) Scanner {
        return .{ .src = src };
    }

    pub fn at(sc: Scanner, offset: usize) u8 {
        const i = sc.pos + offset;
        return if (i < sc.src.len) sc.src[i] else 0;
    }

    pub fn done(sc: Scanner) bool {
        return sc.pos >= sc.src.len;
    }

    pub fn skip(sc: *Scanner, n: usize) void {
        sc.pos = @min(sc.src.len, sc.pos + n);
    }

    /// Skips spaces, tabs and `%%` comments, not newlines.
    pub fn skipBlank(sc: *Scanner) void {
        while (!sc.done()) {
            const c = sc.at(0);
            if (c == ' ' or c == '\t') {
                sc.skip(1);
            } else if (c == '%' and sc.at(1) == '%') {
                while (!sc.done() and sc.at(0) != '\n') sc.skip(1);
            } else break;
        }
    }

    pub fn next(sc: *Scanner) Token {
        sc.skipBlank();
        const start = sc.pos;
        if (sc.done()) return .{ .kind = .eof, .text = "" };
        const c = sc.src[start];
        const kind: Kind = switch (c) {
            '\n' => .newline,
            '\r' => return sc.take(.newline, start, if (sc.at(1) == '\n') 2 else 1),
            '|' => .pipe,
            ';' => .semicolon,
            ',' => .comma,
            ':' => .colon,
            '&' => .amp,
            '[', '(', '{' => .open,
            ']', ')', '}' => .close,
            '"' => return sc.string(),
            else => if (isWordByte(c)) return sc.word() else .other,
        };
        var t = sc.take(kind, start, 1);
        if (kind == .open or kind == .close) t.bracket = c;
        return t;
    }

    fn take(sc: *Scanner, kind: Kind, start: usize, n: usize) Token {
        sc.pos = start + n;
        return .{ .kind = kind, .text = sc.src[start..sc.pos] };
    }

    fn string(sc: *Scanner) Token {
        sc.skip(1);
        const inner = sc.pos;
        while (!sc.done() and sc.at(0) != '"' and sc.at(0) != '\n') sc.skip(1);
        const text = sc.src[inner..sc.pos];
        if (sc.at(0) == '"') sc.skip(1);
        return .{ .kind = .string, .text = text };
    }

    fn word(sc: *Scanner) Token {
        const start = sc.pos;
        while (!sc.done() and isWordByte(sc.at(0))) sc.skip(1);
        return .{ .kind = .word, .text = sc.src[start..sc.pos] };
    }

    /// Raw text up to `close` or the end of the line, `"..."` spans opaque; consumes `close`.
    pub fn rawUntil(sc: *Scanner, close: u8) []const u8 {
        const start = sc.pos;
        while (!sc.done()) {
            const c = sc.at(0);
            if (c == '"') {
                sc.skipQuoted();
            } else if (c == close or c == '\n') {
                break;
            } else sc.skip(1);
        }
        const text = unquote(sc.src[start..sc.pos]);
        if (sc.at(0) == close and !sc.done()) sc.skip(1);
        return text;
    }

    /// Raw text up to the terminator or the end of the line, then skips `close.len` bytes.
    pub fn rawUntilStr(sc: *Scanner, close: []const u8) []const u8 {
        const start = sc.pos;
        while (!sc.done()) {
            if (sc.at(0) == '"') {
                sc.skipQuoted();
                continue;
            }
            if (std.mem.startsWith(u8, sc.src[sc.pos..], close) or sc.at(0) == '\n') break;
            sc.skip(1);
        }
        const text = unquote(sc.src[start..sc.pos]);
        sc.skip(close.len);
        return text;
    }

    pub fn skipQuoted(sc: *Scanner) void {
        sc.skip(1);
        while (!sc.done()) {
            const c = sc.at(0);
            if (c == '\n') return;
            sc.skip(1);
            if (c == '"') return;
        }
    }

    /// The rest of the line up to `\n` or `;`, trimmed; the terminator is not consumed.
    pub fn restOfLine(sc: *Scanner) []const u8 {
        while (sc.at(0) == ' ' or sc.at(0) == '\t') sc.skip(1);
        const start = sc.pos;
        while (!sc.done() and sc.at(0) != '\n' and sc.at(0) != ';') sc.skip(1);
        return std.mem.trimRight(u8, sc.src[start..sc.pos], " \t\r");
    }
};

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Trims blanks and one pair of matching `"` or `'` quotes.
pub fn unquote(text: []const u8) []const u8 {
    const t = std.mem.trimRight(u8, std.mem.trimLeft(u8, text, " \t"), " \t\r");
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

/// `text` with every line-break marker (`<br>`, `<br/>`, `<BR />`, literal `\n`) replaced by
/// the label line break; the same slice when there is none.
pub fn breaks(a: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var first: usize = 0;
    while (first < text.len and breakAt(text, first) == null) first += 1;
    if (first == text.len) return text;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text[0..first]);
    var i = first;
    while (i < text.len) {
        if (breakAt(text, i)) |n| {
            try out.append(a, prim.LINE_BREAK);
            i += n;
        } else {
            try out.append(a, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn breakAt(text: []const u8, i: usize) ?usize {
    if (i + 1 < text.len and text[i] == '\\' and text[i + 1] == 'n') return 2;
    if (i + 3 >= text.len or text[i] != '<') return null;
    if (std.ascii.toLower(text[i + 1]) != 'b' or std.ascii.toLower(text[i + 2]) != 'r') return null;
    var j = i + 3;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    if (j < text.len and text[j] == '/') {
        j += 1;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    }
    if (j < text.len and text[j] == '>') return j - i + 1;
    return null;
}

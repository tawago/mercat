const std = @import("std");

pub const TokenKind = enum {
    kw_flowchart,
    dir_td,
    dir_bt,
    dir_lr,
    dir_rl,
    kw_subgraph,
    kw_end,
    kw_classdef,
    kw_class,
    kw_direction,
    identifier,
    string,
    shape_open,
    shape_close,
    edge_solid,
    edge_dotted,
    edge_thick,
    edge_invisible,
    pipe,
    semicolon,
    comma,
    colon,
    ampersand,
    newline,
    eof,
    err,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
    col: u32,
    bracket: u8 = 0,
    bracket_len: u8 = 0,
    edge_label: ?[]const u8 = null,
};

pub const Lexer = struct {
    source: []const u8,
    pos: usize,
    line: u32,
    col: u32,

    pub fn init(source: []const u8) Lexer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
        };
    }

    pub fn next(self: *Lexer) Token {
        self.skipSpacesAndComments();
        if (self.pos >= self.source.len) return self.makeToken(.eof, self.pos, self.pos);

        const sl = self.line;
        const sc = self.col;
        const start = self.pos;
        const c = self.source[self.pos];

        if (c == '\n' or c == '\r') {
            if (c == '\r' and self.peekAt(1) == '\n') self.advanceRaw();
            self.advanceRaw();
            return .{ .kind = .newline, .text = self.source[start..self.pos], .line = sl, .col = sc };
        }

        const punct: ?TokenKind = switch (c) {
            '|' => .pipe,
            ';' => .semicolon,
            ',' => .comma,
            ':' => .colon,
            '&' => .ampersand,
            else => null,
        };
        if (punct) |k| {
            self.advanceRaw();
            return self.makeTokenAt(k, start, self.pos, sl, sc);
        }

        // @guarded-by: lexer_test.zig "leading '>' lexes as shape_open, not an edge/arrow char"
        if (c == '[' or c == '(' or c == '{' or c == '>') {
            self.advanceRaw();
            var tok = self.makeTokenAt(.shape_open, start, self.pos, sl, sc);
            tok.bracket = c;
            tok.bracket_len = 1;
            return tok;
        }
        if (c == ']' or c == ')' or c == '}') {
            self.advanceRaw();
            var tok = self.makeTokenAt(.shape_close, start, self.pos, sl, sc);
            tok.bracket = c;
            tok.bracket_len = 1;
            return tok;
        }

        if (c == '-' or c == '=' or c == '~' or c == '<') {
            if (self.tryEdge(start, sl, sc)) |tok| return tok;
        }

        // @guarded-by: lexer_test.zig "leading o/x is an edge marker only when glued to a connector"
        if (c == 'o' or c == 'x') {
            if (self.tryEdge(start, sl, sc)) |tok| return tok;
        }

        if (c == '"') return self.readString(sl, sc);
        if (isIdStart(c)) return self.readIdentifier(start, sl, sc);

        self.advanceRaw();
        return .{ .kind = .err, .text = self.source[start..self.pos], .line = sl, .col = sc };
    }

    pub fn peek(self: *Lexer) Token {
        const saved_pos = self.pos;
        const saved_line = self.line;
        const saved_col = self.col;
        const tok = self.next();
        self.pos = saved_pos;
        self.line = saved_line;
        self.col = saved_col;
        return tok;
    }

    fn makeToken(self: *Lexer, kind: TokenKind, lo: usize, hi: usize) Token {
        return .{
            .kind = kind,
            .text = self.source[lo..hi],
            .line = self.line,
            .col = self.col,
        };
    }

    fn makeTokenAt(self: *Lexer, kind: TokenKind, lo: usize, hi: usize, line: u32, col: u32) Token {
        return .{
            .kind = kind,
            .text = self.source[lo..hi],
            .line = line,
            .col = col,
        };
    }

    fn peekAt(self: *Lexer, offset: usize) u8 {
        if (self.pos + offset >= self.source.len) return 0;
        return self.source[self.pos + offset];
    }

    fn advanceRaw(self: *Lexer) void {
        if (self.pos >= self.source.len) return;
        const ch = self.source[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.col = 1;
        } else if (ch == '\r') {
            // @guarded-by: lexer_test.zig "solo CR (old Mac line ending) emits a newline token but does not bump the line counter"
            self.col = 1;
        } else {
            self.col += 1;
        }
    }

    fn skipSpacesAndComments(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t') {
                self.advanceRaw();
                continue;
            }
            if (c == '%' and self.peekAt(1) == '%') {
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.advanceRaw();
                }
                continue;
            }
            break;
        }
    }

    fn readString(self: *Lexer, sl: u32, sc: u32) Token {
        self.advanceRaw();
        const inner_start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '"' and self.source[self.pos] != '\n') {
            self.advanceRaw();
        }
        const inner_end = self.pos;
        if (self.pos < self.source.len and self.source[self.pos] == '"') self.advanceRaw();
        return .{ .kind = .string, .text = self.source[inner_start..inner_end], .line = sl, .col = sc };
    }

    fn readIdentifier(self: *Lexer, start: usize, sl: u32, sc: u32) Token {
        while (self.pos < self.source.len and isIdContinue(self.source[self.pos])) self.advanceRaw();
        const text = self.source[start..self.pos];
        return .{ .kind = classifyIdentifier(text), .text = text, .line = sl, .col = sc };
    }

    fn tryEdge(self: *Lexer, start: usize, start_line: u32, start_col: u32) ?Token {
        const saved_pos = self.pos;
        const saved_line = self.line;
        const saved_col = self.col;

        // @guarded-by: lexer_test.zig "leading '<' on an edge requires -/=/~ or tryEdge bails"
        const m0 = self.source[self.pos];
        if (m0 == '<' or m0 == 'o' or m0 == 'x') {
            const n = self.peekAt(1);
            if (n != '-' and n != '=' and n != '~') return null;
            self.advanceRaw();
        }

        const lead = if (self.pos < self.source.len) self.source[self.pos] else 0;
        var kind: TokenKind = .err;

        var inline_label: ?[]const u8 = null;

        if (lead == '~') {
            var count: usize = 0;
            while (self.pos < self.source.len and self.source[self.pos] == '~') : (count += 1) self.advanceRaw();
            if (count < 3) return self.restore(saved_pos, saved_line, saved_col);
            kind = .edge_invisible;
        } else if (lead == '-') {
            var saw_dot = false;
            var saw_dash = false;
            const run_start = self.pos;
            var last_run_char: u8 = 0;
            while (self.pos < self.source.len) {
                const ch = self.source[self.pos];
                if (ch == '-') {
                    saw_dash = true;
                    last_run_char = ch;
                    self.advanceRaw();
                } else if (ch == '.') {
                    saw_dot = true;
                    last_run_char = ch;
                    self.advanceRaw();
                } else break;
            }
            if (!saw_dash) return self.restore(saved_pos, saved_line, saved_col);
            // @guarded-by: lexer_test.zig "tight inline label on a dotted edge"
            const run_complete = last_run_char == '-' and self.pos - run_start >= 2;
            const had_arrow = self.resolveTail(run_complete);
            // @guarded-by: parse_test.zig "inline-label edge keeps bare links intact"
            if (!had_arrow and self.pos - start < 3) {
                if (!self.atInlineLabel()) return self.restore(saved_pos, saved_line, saved_col);
                inline_label = self.scanInlineLabel('-', &saw_dot) orelse
                    return self.restore(saved_pos, saved_line, saved_col);
            }
            kind = if (saw_dot) .edge_dotted else .edge_solid;
        } else if (lead == '=') {
            var count: usize = 0;
            while (self.pos < self.source.len and self.source[self.pos] == '=') : (count += 1) self.advanceRaw();
            if (count == 0) return self.restore(saved_pos, saved_line, saved_col);
            const had_arrow = self.resolveTail(count >= 2);
            if (!had_arrow and self.pos - start < 3) {
                if (!self.atInlineLabel()) return self.restore(saved_pos, saved_line, saved_col);
                var ignore_dot = false;
                inline_label = self.scanInlineLabel('=', &ignore_dot) orelse
                    return self.restore(saved_pos, saved_line, saved_col);
            }
            kind = .edge_thick;
        } else {
            return self.restore(saved_pos, saved_line, saved_col);
        }

        var tok = self.makeTokenAt(kind, start, self.pos, start_line, start_col);
        tok.edge_label = inline_label;
        return tok;
    }

    /// @guarded-by: lexer_test.zig "tight inline label on a dotted edge"
    fn atInlineLabel(self: *Lexer) bool {
        if (self.pos >= self.source.len) return false;
        const c = self.source[self.pos];
        return c != '\n' and c != '\r' and c != '|';
    }

    fn scanInlineLabel(self: *Lexer, connector: u8, saw_dot: *bool) ?[]const u8 {
        while (self.pos < self.source.len and
            (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.advanceRaw();
        const label_start = self.pos;
        var label_end = self.pos;
        // @guarded-by: lexer_test.zig "inline edge label keeps an embedded dash intact"
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '\r') return null;
            if (c == connector or (connector == '-' and c == '.')) {
                const n = self.peekAt(1);
                if (n == connector or n == '.' or n == '>' or n == 'o' or n == 'x') break;
            }
            self.advanceRaw();
            if (c != ' ' and c != '\t') label_end = self.pos;
        }
        if (self.pos >= self.source.len) return null;
        var closed = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == connector) {
                closed = true;
                self.advanceRaw();
            } else if (connector == '-' and c == '.') {
                saw_dot.* = true;
                self.advanceRaw();
            } else break;
        }
        if (!closed) return null;
        _ = self.consumeArrowTail();
        return std.mem.trim(u8, self.source[label_start..label_end], " \t");
    }

    /// @guarded-by: lexer_test.zig "glued o/x on a complete run is an arrow end whatever follows"
    fn resolveTail(self: *Lexer, run_complete: bool) bool {
        const tail = if (self.pos < self.source.len) self.source[self.pos] else 0;
        if (tail == '>') return self.consumeArrowTail();
        if (tail != 'o' and tail != 'x') return false;
        if (!run_complete) return false;
        return self.consumeArrowTail();
    }

    fn consumeArrowTail(self: *Lexer) bool {
        if (self.pos >= self.source.len) return false;
        const tail = self.source[self.pos];
        if (tail == '>' or tail == 'o' or tail == 'x') {
            self.advanceRaw();
            return true;
        }
        return false;
    }

    fn restore(self: *Lexer, p: usize, l: u32, c: u32) ?Token {
        self.pos = p;
        self.line = l;
        self.col = c;
        return null;
    }
};

fn isIdStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn isIdContinue(c: u8) bool {
    return isIdStart(c);
}

fn classifyIdentifier(text: []const u8) TokenKind {
    if (eq(text, "TD") or eq(text, "TB")) return .dir_td;
    if (eq(text, "BT")) return .dir_bt;
    if (eq(text, "LR")) return .dir_lr;
    if (eq(text, "RL")) return .dir_rl;

    if (eq(text, "flowchart") or eq(text, "graph")) return .kw_flowchart;
    if (eq(text, "subgraph")) return .kw_subgraph;
    if (eq(text, "end")) return .kw_end;
    if (eq(text, "classDef") or eq(text, "classdef")) return .kw_classdef;
    if (eq(text, "class")) return .kw_class;
    if (eq(text, "direction")) return .kw_direction;

    return .identifier;
}

inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    _ = @import("lexer_test.zig");
}

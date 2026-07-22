//! Flowchart-only lexer for mermaid_v2. Forward-only, std-only.
//!
//! Bracket scheme: each opening bracket char emits one `shape_open`
//! (bracket_len = 1); composites like `[[`, `((`, `[(` emit two tokens.
//! Closes mirror symmetrically. Slashes in `[/.../]` are not bracket
//! tokens — the parser handles label interiors itself.
//!
//! Edges match greedily as full operators (`-->`, `---`, `==>`, `===`,
//! `-.->`, `-.-`, `~~~`); the inline-label form `-- text -->` is handled too.

const std = @import("std");

pub const TokenKind = enum {
    // Diagram opener
    kw_flowchart, // "flowchart" or "graph"
    dir_td, // "TD" or "TB"
    dir_bt, // "BT"
    dir_lr, // "LR"
    dir_rl, // "RL"
    // Structural keywords
    kw_subgraph,
    kw_end,
    kw_classdef,
    kw_class,
    kw_direction,
    // Identifiers and literals
    identifier,
    string,
    // Shape brackets (single-char tokens; see scheme note above)
    shape_open,
    shape_close,
    // Edges
    edge_solid,
    edge_dotted,
    edge_thick,
    edge_invisible,
    // Edge label delimiter
    pipe,
    // Punctuation
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
    /// For shape_open / shape_close, the bracket character. Zero otherwise.
    bracket: u8 = 0,
    /// Always 1 for shape tokens under the single-char scheme. Zero for others.
    bracket_len: u8 = 0,
    /// For edge_* tokens written in the inline-label form `-- text -->`
    /// (label embedded between the connector and the arrow), the label
    /// text. Null for the bare `-->` form (whose label, if any, arrives
    /// via a following `|...|` pipe pair).
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

    /// Returns the next token, advancing the cursor. Returns `eof`
    /// repeatedly at end of input.
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

        // Bracket opens. '>' routes to shape_open since edges starting with '<'/'-' are ruled out above. // guarded-by: lexer_test.zig "leading '>' lexes as shape_open, not an edge/arrow char"
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

        // o/x are id-start chars, so like the '<' gate above they need a
        // pre-identifier dispatch hook. tryEdge performs the glued-connector
        // check internally (a circle/cross end-marker like `o--o`/`x==x` only
        // starts an edge when GLUED to `-`/`=`/`~`) and fully restores the
        // cursor on bail, so a bare `o`/`x` or a word like `order` falls
        // through to readIdentifier and stays a node id (`o --> p` keeps `o`).
        // // guarded-by: lexer_test.zig "leading o/x is an edge marker only when glued to a connector"
        if (c == 'o' or c == 'x') {
            if (self.tryEdge(start, sl, sc)) |tok| return tok;
        }

        if (c == '"') return self.readString(sl, sc);
        if (isIdStart(c)) return self.readIdentifier(start, sl, sc);

        self.advanceRaw();
        return .{ .kind = .err, .text = self.source[start..self.pos], .line = sl, .col = sc };
    }

    /// Returns the next token without advancing the cursor.
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

    /// Advance one byte. Maintains line/col counters; '\n' resets col and
    /// increments line. '\r' is treated as column-resetting too so
    /// `\r\n` doesn't double-increment line.
    fn advanceRaw(self: *Lexer) void {
        if (self.pos >= self.source.len) return;
        const ch = self.source[self.pos];
        self.pos += 1;
        if (ch == '\n') {
            self.line += 1;
            self.col = 1;
        } else if (ch == '\r') {
            // Don't bump line for \r alone; \r\n collapses via outer logic. // guarded-by: lexer_test.zig "solo CR (old Mac line ending) emits a newline token but does not bump the line counter"
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
        self.advanceRaw(); // opening quote
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

    /// Try to lex an edge starting at the current cursor. Returns null and
    /// restores the cursor if the prefix doesn't form a known edge.
    fn tryEdge(self: *Lexer, start: usize, start_line: u32, start_col: u32) ?Token {
        const saved_pos = self.pos;
        const saved_line = self.line;
        const saved_col = self.col;

        // Optional leading modifier: '<' (open) or a glued 'o'/'x' (circle/
        // cross end); each must be followed by '-', '=', '~', or tryEdge bails.
        // guarded-by: lexer_test.zig "leading '<' on an edge requires -/=/~ or tryEdge bails"
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
            while (self.pos < self.source.len) {
                const ch = self.source[self.pos];
                if (ch == '-') { saw_dash = true; self.advanceRaw(); }
                else if (ch == '.') { saw_dot = true; self.advanceRaw(); }
                else break;
            }
            if (!saw_dash) return self.restore(saved_pos, saved_line, saved_col);
            const had_arrow = self.consumeArrowTail();
            // A short dash run with no arrow tail (e.g. bare "--") is only valid as the
            // OPENING of an inline-label edge like "-- text -->"; probe for the label
            // before bailing so a valid inline-label edge is not rejected as a stray link.
            // guarded-by: parse_test.zig "inline-label edge keeps bare links intact"
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
            const had_arrow = self.consumeArrowTail();
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

    /// True when the cursor sits on whitespace that could precede an
    /// inline edge label (`-- text -->`). Requires at least one space and
    /// then a non-newline, non-connector character.
    fn atInlineLabel(self: *Lexer) bool {
        if (self.pos >= self.source.len) return false;
        return self.source[self.pos] == ' ' or self.source[self.pos] == '\t';
    }

    /// Consume `   label   <connector-run><arrow>` for the inline-label
    /// edge form. `connector` is '-' or '='. Sets `saw_dot` if the closing
    /// run contains a '.' (dotted). Returns the trimmed label slice, or
    /// null (leaving the cursor untouched-enough for the caller to restore)
    /// if no closing connector+arrow is found before end-of-line.
    fn scanInlineLabel(self: *Lexer, connector: u8, saw_dot: *bool) ?[]const u8 {
        // Skip leading whitespace.
        while (self.pos < self.source.len and
            (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.advanceRaw();
        const label_start = self.pos;
        var label_end = self.pos;
        // The closing-connector lookahead (peekAt below) only ends the label on a
        // SECOND connector/arrow char, so a lone '-' embedded in the label text
        // (e.g. "well-formed") stays content, not mistaken for the closing run.
        // guarded-by: lexer_test.zig "inline edge label keeps an embedded dash intact"
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
        // Consume the closing connector run.
        var closed = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == connector) { closed = true; self.advanceRaw(); }
            else if (connector == '-' and c == '.') { saw_dot.* = true; self.advanceRaw(); }
            else break;
        }
        if (!closed) return null;
        _ = self.consumeArrowTail();
        return std.mem.trim(u8, self.source[label_start..label_end], " \t");
    }

    fn consumeArrowTail(self: *Lexer) bool {
        if (self.pos >= self.source.len) return false;
        const tail = self.source[self.pos];
        if (tail == '>' or tail == 'o' or tail == 'x') { self.advanceRaw(); return true; }
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
    // Direction keywords (matched as identifiers; parser context decides
    // whether to honour them — the lexer always emits dir_* for these).
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

//! Raw-text shape and label readers used by `parse.zig`. Bypass
//! tokenization on purpose: mermaid label interiors are free text
//! (brackets, operators and quotes inside a shape are literal until the
//! matching close), so they walk the source bytes directly through the
//! lexer's cursor. No parser state; every function takes the `*Lexer`
//! whose `pos`/`line`/`col` it advances.
//!
//! Imports: `std`, `../sem_graph.zig`, `lexer.zig`, `token_helpers.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const lex = @import("lexer.zig");
const th = @import("token_helpers.zig");

const Lexer = lex.Lexer;
const NodeShape = sg.NodeShape;
const stripQuotes = th.stripQuotes;

pub const ShapeInfo = struct { shape: NodeShape, label: []const u8 };

pub const Error = error{UnexpectedToken};

/// Parse a full shape declaration starting at its opening `shape_open`
/// token. Consumes through the matching close and returns the shape kind
/// plus the raw (quote-stripped) label slice.
pub fn parseShape(lx: *Lexer) Error!ShapeInfo {
    const open1 = lx.next();
    const c1 = open1.bracket;
    const second = lx.peek();
    const has_double = second.kind == .shape_open;
    if (c1 == '[' and has_double) {
        const c2 = second.bracket;
        _ = lx.next();
        return switch (c2) {
            '[' => readShapeDouble(lx, .subroutine, "]]"),
            '(' => readShapeDouble(lx, .cylinder, ")]"),
            else => readShapeDouble(lx, .rect, "]"),
        };
    } else if (c1 == '(' and has_double) {
        const c2 = second.bracket;
        _ = lx.next();
        if (c2 == '(') {
            // Triple paren `(((label)))` is the double-circle shape.
            const third = lx.peek();
            if (third.kind == .shape_open and third.bracket == '(') {
                _ = lx.next();
                return readShapeDouble(lx, .double_circle, ")))");
            }
            return readShapeDouble(lx, .circle, "))");
        }
        return switch (c2) {
            '[' => readShapeDouble(lx, .stadium, "])"),
            else => readShapeDouble(lx, .round, ")"),
        };
    } else if (c1 == '{' and has_double) {
        _ = lx.next();
        return readShapeDouble(lx, .hexagon, "}}");
    }
    switch (c1) {
        '[' => {
            if (peekRawChar(lx) == '/') { advanceRaw(lx, 1); return readSlashShape(lx, true); }
            if (peekRawChar(lx) == '\\') { advanceRaw(lx, 1); return readSlashShape(lx, false); }
            return .{ .shape = .rect, .label = readRawUntilCloseChar(lx, ']') };
        },
        '(' => return .{ .shape = .round, .label = readRawUntilCloseChar(lx, ')') },
        '{' => return .{ .shape = .rhombus, .label = readRawUntilCloseChar(lx, '}') },
        '>' => return .{ .shape = .asymmetric_right, .label = readRawUntilCloseChar(lx, ']') },
        else => return Error.UnexpectedToken,
    }
}

fn readSlashShape(lx: *Lexer, started_slash: bool) ShapeInfo {
    const start = lx.pos;
    while (lx.pos < lx.source.len) {
        const c = lx.source[lx.pos];
        if (c == '"') { skipQuotedSpan(lx); continue; }
        if ((c == '/' or c == '\\') and lx.pos + 1 < lx.source.len and
            lx.source[lx.pos + 1] == ']') break;
        if (c == '\n') break;
        advanceRaw(lx, 1);
    }
    const label = stripQuotes(lx.source[start..lx.pos]);
    var shape: NodeShape = .rect;
    if (lx.pos < lx.source.len) {
        const c = lx.source[lx.pos];
        if (started_slash and c == '/') shape = .parallelogram;
        if (started_slash and c == '\\') shape = .trapezoid;
        if (!started_slash and c == '\\') shape = .parallelogram_alt;
        if (!started_slash and c == '/') shape = .trapezoid_alt;
        advanceRaw(lx, 1);
        if (lx.pos < lx.source.len and lx.source[lx.pos] == ']') advanceRaw(lx, 1);
    }
    return .{ .shape = shape, .label = label };
}

fn readShapeDouble(lx: *Lexer, shape: NodeShape, close: []const u8) ShapeInfo {
    const start = lx.pos;
    while (lx.pos < lx.source.len) {
        if (lx.source[lx.pos] == '"') { skipQuotedSpan(lx); continue; }
        if (lx.pos + close.len <= lx.source.len and
            std.mem.eql(u8, lx.source[lx.pos .. lx.pos + close.len], close)) break;
        if (lx.source[lx.pos] == '\n') break;
        advanceRaw(lx, 1);
    }
    const label = stripQuotes(lx.source[start..lx.pos]);
    var i: usize = 0;
    while (i < close.len and lx.pos < lx.source.len) : (i += 1) advanceRaw(lx, 1);
    return .{ .shape = shape, .label = label };
}

pub fn readRawUntilCloseChar(lx: *Lexer, close: u8) []const u8 {
    const start = lx.pos;
    while (lx.pos < lx.source.len) {
        const c = lx.source[lx.pos];
        // Quoted span is opaque (close char literal inside it). guarded-by: parse_test.zig "quoted label with brackets and operators is opaque"
        if (c == '"') { skipQuotedSpan(lx); continue; }
        if (c == close or c == '\n') break;
        advanceRaw(lx, 1);
    }
    const text = stripQuotes(lx.source[start..lx.pos]);
    if (lx.pos < lx.source.len and lx.source[lx.pos] == close) advanceRaw(lx, 1);
    return text;
}

/// Advance past a `"..."` span starting at the opening quote. Stops
/// after the closing quote, or at end-of-line if unterminated.
fn skipQuotedSpan(lx: *Lexer) void {
    advanceRaw(lx, 1); // opening quote
    while (lx.pos < lx.source.len) {
        const c = lx.source[lx.pos];
        if (c == '\n') return;
        advanceRaw(lx, 1);
        if (c == '"') return;
    }
}

pub fn readRestOfLine(lx: *Lexer) []const u8 {
    while (lx.pos < lx.source.len) {
        const c = lx.source[lx.pos];
        if (c == ' ' or c == '\t') advanceRaw(lx, 1) else break;
    }
    const start = lx.pos;
    while (lx.pos < lx.source.len) {
        const c = lx.source[lx.pos];
        if (c == '\n' or c == ';') break;
        advanceRaw(lx, 1);
    }
    var text = lx.source[start..lx.pos];
    while (text.len > 0 and (text[text.len - 1] == ' ' or text[text.len - 1] == '\t' or text[text.len - 1] == '\r'))
        text = text[0 .. text.len - 1];
    return text;
}

fn peekRawChar(lx: *Lexer) u8 {
    return if (lx.pos >= lx.source.len) 0 else lx.source[lx.pos];
}

fn advanceRaw(lx: *Lexer, n: usize) void {
    var i: usize = 0;
    while (i < n and lx.pos < lx.source.len) : (i += 1) {
        const ch = lx.source[lx.pos];
        lx.pos += 1;
        if (ch == '\n') { lx.line += 1; lx.col = 1; }
        else if (ch == '\r') lx.col = 1
        else lx.col += 1;
    }
}

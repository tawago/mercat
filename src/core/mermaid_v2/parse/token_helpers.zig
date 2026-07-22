//! Pure token-classification and text-decoding helpers for `parse.zig`.
//! No parser state. Mostly allocation-free; `normalizeLineBreaks` is the one
//! allocating helper (and only when an author break marker is present).
//!
//! Imports: `std`, `prim`, `../sem_graph.zig`, `lexer.zig`.

const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const lex = @import("lexer.zig");

const TokenKind = lex.TokenKind;
const EdgeKind = sg.EdgeKind;
const ArrowEnd = sg.ArrowEnd;

pub const ArrowPair = struct { from: ArrowEnd, to: ArrowEnd };

/// Decode the arrow-end markers from a raw edge-token text. The first byte
/// encodes the source-end marker (`<`, `o`, `x` → open/circle/cross);
/// the last byte encodes the target-end marker. Anything else → `.none`.
pub fn decodeArrows(text: []const u8) ArrowPair {
    var ap: ArrowPair = .{ .from = .none, .to = .none };
    if (text.len == 0) return ap;
    switch (text[0]) {
        '<' => ap.from = .open, 'o' => ap.from = .circle, 'x' => ap.from = .cross, else => {},
    }
    switch (text[text.len - 1]) {
        '>' => ap.to = .open, 'o' => ap.to = .circle, 'x' => ap.to = .cross, else => {},
    }
    return ap;
}

/// True when `k` is one of the four direction keywords.
pub fn isDirectionKw(k: TokenKind) bool {
    return k == .dir_td or k == .dir_bt or k == .dir_lr or k == .dir_rl;
}

/// True when the token that follows a node identifier starts a shape
/// declaration or an inline class annotation.
pub fn isNodeDeclarationTail(k: TokenKind) bool {
    return k == .shape_open or k == .colon;
}

/// Map an edge token kind to its `EdgeKind`, or null if not an edge token.
pub fn edgeKind(k: TokenKind) ?EdgeKind {
    return switch (k) {
        .edge_solid => .solid,
        .edge_dotted => .dotted,
        .edge_thick => .thick,
        .edge_invisible => .invisible,
        else => null,
    };
}

/// True when `text` (an identifier at statement start) opens a known
/// non-graph directive line — interaction/styling statements mermaid
/// accepts but that carry no ASCII-renderable semantics. The parser
/// consumes such lines without effect ("parse and ignore"). `classDef`,
/// `class`, and `direction` are NOT here: the lexer keywords them and the
/// parser handles them explicitly.
pub fn isSkippableDirective(text: []const u8) bool {
    const names = [_][]const u8{ "click", "style", "linkStyle", "call" };
    for (names) |n| if (std.mem.eql(u8, text, n)) return true;
    return false;
}

/// True if `label` contains any author hard-line-break marker that
/// `normalizeLabel` would rewrite (`<br>` family or literal `\n`). Lets the
/// parser skip allocation entirely for the common no-marker case.
pub fn hasLineBreakMarker(label: []const u8) bool {
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        if (lineBreakMarkerAt(label, i) != null) return true;
    }
    return false;
}

/// If a hard-line-break marker begins at `label[i]`, return its byte length
/// (so the caller advances past it and emits one sentinel); else null.
/// Recognizes `<br>`, `<br/>`, `<br />` (case-insensitive, optional inner
/// whitespace before `/` and `>`) and the two-byte literal `\` + `n`.
pub fn lineBreakMarkerAt(label: []const u8, i: usize) ?usize {
    if (i + 1 < label.len and label[i] == '\\' and label[i + 1] == 'n') return 2;
    if (i + 3 < label.len and label[i] == '<' and
        toLower(label[i + 1]) == 'b' and toLower(label[i + 2]) == 'r')
    {
        var j = i + 3;
        while (j < label.len and (label[j] == ' ' or label[j] == '\t')) j += 1;
        if (j < label.len and label[j] == '/') {
            j += 1;
            while (j < label.len and (label[j] == ' ' or label[j] == '\t')) j += 1;
        }
        if (j < label.len and label[j] == '>') return (j - i) + 1;
    }
    return null;
}

fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Rewrite author hard line-breaks (`<br>` family, literal `\n`) in `label`
/// to the single `prim.LINE_BREAK` sentinel byte. Allocates into `a` only
/// when a marker is present; otherwise returns the input sub-slice unchanged
/// (zero allocation, byte-identical).
pub fn normalizeLineBreaks(a: std.mem.Allocator, label: []const u8) error{OutOfMemory}![]const u8 {
    if (!hasLineBreakMarker(label)) return label;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < label.len) {
        if (lineBreakMarkerAt(label, i)) |adv| {
            try out.append(a, prim.LINE_BREAK);
            i += adv;
        } else {
            try out.append(a, label[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(a);
}

/// Trim surrounding whitespace and optionally a matching outer quote pair
/// from a raw label slice. Returns a sub-slice of the input (zero allocation).
pub fn stripQuotes(label: []const u8) []const u8 {
    var out = label;
    while (out.len > 0 and (out[0] == ' ' or out[0] == '\t')) out = out[1..];
    while (out.len > 0 and (out[out.len - 1] == ' ' or out[out.len - 1] == '\t' or out[out.len - 1] == '\r'))
        out = out[0 .. out.len - 1];
    if (out.len >= 2) {
        const f = out[0];
        const l = out[out.len - 1];
        if ((f == '"' and l == '"') or (f == '\'' and l == '\'')) return out[1 .. out.len - 1];
    }
    return out;
}

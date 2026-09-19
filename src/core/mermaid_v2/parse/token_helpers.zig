const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const lex = @import("lexer.zig");

const TokenKind = lex.TokenKind;
const EdgeKind = sg.EdgeKind;
const ArrowEnd = sg.ArrowEnd;

pub const ArrowPair = struct { from: ArrowEnd, to: ArrowEnd };

pub fn decodeArrows(text: []const u8) ArrowPair {
    var ap: ArrowPair = .{ .from = .none, .to = .none };
    if (text.len == 0) return ap;
    switch (text[0]) {
        '<' => ap.from = .filled,
        'o' => ap.from = .circle,
        'x' => ap.from = .cross,
        else => {},
    }
    switch (text[text.len - 1]) {
        '>' => ap.to = .filled,
        'o' => ap.to = .circle,
        'x' => ap.to = .cross,
        else => {},
    }
    return ap;
}

pub fn isDirectionKw(k: TokenKind) bool {
    return k == .dir_td or k == .dir_bt or k == .dir_lr or k == .dir_rl;
}

pub fn isNodeDeclarationTail(k: TokenKind) bool {
    return k == .shape_open or k == .colon;
}

pub fn edgeKind(k: TokenKind) ?EdgeKind {
    return switch (k) {
        .edge_solid => .solid,
        .edge_dotted => .dotted,
        .edge_thick => .thick,
        .edge_invisible => .invisible,
        else => null,
    };
}

pub fn isSkippableDirective(text: []const u8) bool {
    const names = [_][]const u8{ "click", "style", "linkStyle", "call" };
    for (names) |n| if (std.mem.eql(u8, text, n)) return true;
    return false;
}

pub fn hasLineBreakMarker(label: []const u8) bool {
    var i: usize = 0;
    while (i < label.len) : (i += 1) {
        if (lineBreakMarkerAt(label, i) != null) return true;
    }
    return false;
}

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

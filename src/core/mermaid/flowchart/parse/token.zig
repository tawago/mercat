//! Flowchart tokens over the byte scanner: keywords, directions and link operators.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const scanner = @import("scanner.zig");

const Scanner = scanner.Scanner;

pub const Kind = enum {
    header,
    dir,
    subgraph,
    end,
    class_def,
    class,
    direction,
    id,
    string,
    open,
    close,
    link,
    pipe,
    semicolon,
    comma,
    colon,
    amp,
    newline,
    eof,
    other,
};

/// A link operator as read: its stroke, both ends and an inline label (`-- text -->`).
pub const Link = struct {
    kind: sg.EdgeKind,
    from: sg.ArrowEnd,
    to: sg.ArrowEnd,
    label: ?[]const u8,
};

pub const Token = struct {
    kind: Kind,
    text: []const u8,
    /// The bracket byte of an `open` or `close` token.
    bracket: u8 = 0,
    link: ?Link = null,
};

pub fn next(sc: *Scanner) Token {
    sc.skipBlank();
    switch (sc.at(0)) {
        '-', '=', '~', '<', 'o', 'x' => if (readLink(sc)) |t| return t,
        else => {},
    }
    const t = sc.next();
    return switch (t.kind) {
        .word => .{ .kind = keyword(t.text), .text = t.text },
        .other => if (t.text[0] == '>')
            .{ .kind = .open, .text = t.text, .bracket = '>' }
        else
            .{ .kind = .other, .text = t.text },
        inline else => |k| .{ .kind = @field(Kind, @tagName(k)), .text = t.text, .bracket = t.bracket },
    };
}

pub fn peek(sc: Scanner) Token {
    var copy = sc;
    return next(&copy);
}

fn keyword(text: []const u8) Kind {
    const table = [_]struct { []const u8, Kind }{
        .{ "TD", .dir },              .{ "TB", .dir },             .{ "BT", .dir },             .{ "LR", .dir },
        .{ "RL", .dir },              .{ "flowchart", .header },   .{ "graph", .header },       .{ "subgraph", .subgraph },
        .{ "end", .end },             .{ "classDef", .class_def }, .{ "classdef", .class_def }, .{ "class", .class },
        .{ "direction", .direction },
    };
    for (table) |entry| if (std.mem.eql(u8, text, entry[0])) return entry[1];
    return .id;
}

/// The direction a `dir` token names; `TB` is `TD`.
pub fn direction(text: []const u8) sg.Direction {
    if (std.mem.eql(u8, text, "BT")) return .BT;
    if (std.mem.eql(u8, text, "LR")) return .LR;
    if (std.mem.eql(u8, text, "RL")) return .RL;
    return .TD;
}

/// A link operator: `-->`, `-.->`, `==>`, `~~~`, optional `<`/`o`/`x` ends, or an inline label
/// `-- text -->`. On failure the scanner is left where it was.
fn readLink(sc: *Scanner) ?Token {
    const start = sc.pos;
    const first = sc.at(0);
    if (first == '<' or first == 'o' or first == 'x') {
        const n = sc.at(1);
        if (n != '-' and n != '=' and n != '~') return null;
        sc.skip(1);
    }
    var kind: sg.EdgeKind = undefined;
    var label: ?[]const u8 = null;
    switch (sc.at(0)) {
        '~' => {
            if (run(sc, "~") < 3) return reset(sc, start);
            kind = .invisible;
        },
        '-' => {
            const run_start = sc.pos;
            var dotted = false;
            var last: u8 = 0;
            while (sc.at(0) == '-' or sc.at(0) == '.') {
                if (sc.at(0) == '.') dotted = true;
                last = sc.at(0);
                sc.skip(1);
            }
            if (std.mem.indexOfScalar(u8, sc.src[run_start..sc.pos], '-') == null) return reset(sc, start);
            const complete = last == '-' and sc.pos - run_start >= 2;
            if (!tail(sc, complete) and sc.pos - start < 3) {
                label = inlineLabel(sc, '-', &dotted) orelse return reset(sc, start);
            }
            kind = if (dotted) .dotted else .solid;
        },
        '=' => {
            const n = run(sc, "=");
            if (!tail(sc, n >= 2) and sc.pos - start < 3) {
                var ignored = false;
                label = inlineLabel(sc, '=', &ignored) orelse return reset(sc, start);
            }
            kind = .thick;
        },
        else => return reset(sc, start),
    }
    const text = sc.src[start..sc.pos];
    return .{ .kind = .link, .text = text, .link = .{
        .kind = kind,
        .from = endMarker(text[0], '<'),
        .to = endMarker(text[text.len - 1], '>'),
        .label = label,
    } };
}

fn reset(sc: *Scanner, pos: usize) ?Token {
    sc.pos = pos;
    return null;
}

fn run(sc: *Scanner, chars: []const u8) usize {
    const start = sc.pos;
    while (!sc.done() and std.mem.indexOfScalar(u8, chars, sc.at(0)) != null) sc.skip(1);
    return sc.pos - start;
}

/// Consumes the arrow end after a connector run: `>` always, `o` and `x` only when the run is complete.
fn tail(sc: *Scanner, complete: bool) bool {
    const c = sc.at(0);
    if (c == '>' or ((c == 'o' or c == 'x') and complete)) {
        sc.skip(1);
        return true;
    }
    return false;
}

fn inlineLabel(sc: *Scanner, connector: u8, dotted: *bool) ?[]const u8 {
    const c0 = sc.at(0);
    if (sc.done() or c0 == '\n' or c0 == '\r' or c0 == '|') return null;
    while (sc.at(0) == ' ' or sc.at(0) == '\t') sc.skip(1);
    const start = sc.pos;
    var end = sc.pos;
    while (!sc.done()) {
        const c = sc.at(0);
        if (c == '\n' or c == '\r') return null;
        if (c == connector or (connector == '-' and c == '.')) {
            const n = sc.at(1);
            if (n == connector or n == '.' or n == '>' or n == 'o' or n == 'x') break;
        }
        sc.skip(1);
        if (c != ' ' and c != '\t') end = sc.pos;
    }
    if (sc.done()) return null;
    var closed = false;
    while (true) {
        const c = sc.at(0);
        if (c == connector and !sc.done()) {
            closed = true;
        } else if (connector == '-' and c == '.') {
            dotted.* = true;
        } else break;
        sc.skip(1);
    }
    if (!closed) return null;
    const c = sc.at(0);
    if (c == '>' or c == 'o' or c == 'x') sc.skip(1);
    return std.mem.trim(u8, sc.src[start..end], " \t");
}

fn endMarker(c: u8, arrow: u8) sg.ArrowEnd {
    if (c == arrow) return .filled;
    if (c == 'o') return .circle;
    if (c == 'x') return .cross;
    return .none;
}

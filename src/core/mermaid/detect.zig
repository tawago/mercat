//! Which diagram a source names, from one keyword table: the kind for rendering, and the
//! stricter test that decides whether piped input is a bare diagram rather than markdown.

const std = @import("std");
const text = @import("text");

pub const Kind = enum {
    flowchart,
    sequence,
    class_diagram,
    state,
    er,
    unsupported,

    /// The kind named by the first line that is neither blank nor a `%%` comment; the keyword
    /// is a prefix match.
    pub fn fromSource(src: []const u8) Kind {
        return if (head(src)) |h| h.kind else .unsupported;
    }
};

const keywords = [_]struct { []const u8, Kind }{
    .{ "graph", .flowchart },
    .{ "flowchart", .flowchart },
    .{ "sequenceDiagram", .sequence },
    .{ "classDiagram", .class_diagram },
    .{ "stateDiagram", .state },
    .{ "erDiagram", .er },
};

const directions = [_][]const u8{ "TB", "TD", "BT", "LR", "RL" };

const Head = struct { kind: Kind, indented: bool, rest: []const u8 };

fn head(src: []const u8) ?Head {
    const line = firstLine(text.stripBom(src)) orelse return null;
    const body = std.mem.trimLeft(u8, line, " \t");
    for (keywords) |k| {
        if (std.mem.startsWith(u8, body, k[0])) {
            return .{ .kind = k[1], .indented = body.len != line.len, .rest = body[k[0].len..] };
        }
    }
    return null;
}

/// Whether piped input is a bare diagram: the keyword sits at column 0 as a whole word (an
/// optional `-v2` suffix allowed), a flowchart names a direction, and no mermaid fence appears.
pub fn looksLikeBareMermaid(src: []const u8) bool {
    const h = head(src) orelse return false;
    if (h.indented) return false;
    const rest = if (std.mem.startsWith(u8, h.rest, "-v2")) h.rest[3..] else h.rest;
    if (!endsWord(rest)) return false;
    if (h.kind == .flowchart and !startsWithDirection(std.mem.trim(u8, rest, " \t;:"))) return false;
    return !hasMermaidFence(text.stripBom(src));
}

fn startsWithDirection(s: []const u8) bool {
    for (directions) |d| {
        if (std.mem.startsWith(u8, s, d) and endsWord(s[d.len..])) return true;
    }
    return false;
}

fn endsWord(rest: []const u8) bool {
    return rest.len == 0 or std.mem.indexOfScalar(u8, " \t;:", rest[0]) != null;
}

/// Right-trimmed, leading whitespace kept. Lines end at `\n`, `\r` or `\r\n`.
fn firstLine(src: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, src, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t");
        const body = std.mem.trimLeft(u8, line, " \t");
        if (body.len == 0 or std.mem.startsWith(u8, body, "%%")) continue;
        return line;
    }
    return null;
}

/// A line opening with a fence (3+ of ` or ~, in any mix) whose info string starts with `mermaid`.
fn hasMermaidFence(src: []const u8) bool {
    var lines = std.mem.tokenizeAny(u8, src, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "```") and !std.mem.startsWith(u8, line, "~~~")) continue;
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, "`~ \t"), "mermaid")) return true;
    }
    return false;
}

test "fromSource reads the first meaningful line" {
    try std.testing.expectEqual(Kind.flowchart, Kind.fromSource("\xEF\xBB\xBF%% note\r\n\r\n  graph LR\r\nA-->B"));
    try std.testing.expectEqual(Kind.flowchart, Kind.fromSource("graphviz"));
    try std.testing.expectEqual(Kind.state, Kind.fromSource("stateDiagram-v2\n"));
    try std.testing.expectEqual(Kind.class_diagram, Kind.fromSource("classDiagram"));
    try std.testing.expectEqual(Kind.unsupported, Kind.fromSource("---\ntitle: x\n---\ngraph TD"));
    try std.testing.expectEqual(Kind.unsupported, Kind.fromSource("%% only\n"));
    try std.testing.expectEqual(Kind.unsupported, Kind.fromSource("pie"));
}

test "looksLikeBareMermaid is stricter than fromSource" {
    try std.testing.expect(looksLikeBareMermaid("graph LR\nA-->B"));
    try std.testing.expect(looksLikeBareMermaid("flowchart;TD"));
    try std.testing.expect(looksLikeBareMermaid("sequenceDiagram"));
    try std.testing.expect(!looksLikeBareMermaid("graph\nA-->B"));
    try std.testing.expect(!looksLikeBareMermaid("  graph LR"));
    try std.testing.expect(!looksLikeBareMermaid("graphviz LR"));
    try std.testing.expect(!looksLikeBareMermaid("graph LR\n```mermaid\n```"));
}

test "fromSource names every diagram kind by its keyword" {
    try std.testing.expectEqual(Kind.flowchart, Kind.fromSource("graph LR"));
    try std.testing.expectEqual(Kind.flowchart, Kind.fromSource("flowchart TD"));
    try std.testing.expectEqual(Kind.flowchart, Kind.fromSource("  graph LR\n  A --> B"));
    try std.testing.expectEqual(Kind.sequence, Kind.fromSource("sequenceDiagram"));
    try std.testing.expectEqual(Kind.class_diagram, Kind.fromSource("classDiagram"));
    try std.testing.expectEqual(Kind.state, Kind.fromSource("stateDiagram"));
    try std.testing.expectEqual(Kind.state, Kind.fromSource("stateDiagram-v2"));
    try std.testing.expectEqual(Kind.er, Kind.fromSource("erDiagram"));
    try std.testing.expectEqual(Kind.unsupported, Kind.fromSource("pie"));
    try std.testing.expectEqual(Kind.unsupported, Kind.fromSource("gantt"));
}

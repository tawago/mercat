//! Input acquisition policy and content classification for the entry points.
//!
//! Owns the two decisions the app must make before any parsing:
//!   1. Should stdin be read implicitly? (`cat file.md | mercat` needs no `-`.)
//!   2. Is this input a mermaid diagram source rather than a markdown document?
//!
//! `cat diagram.mmd | mercat` and `mercat diagram.mmd` should both render a
//! diagram, but only the file path carries an extension. For piped input the
//! only signal is the bytes themselves, so they are sniffed: an input that
//! carries no mermaid code fence and whose first meaningful line opens with a
//! mermaid diagram keyword is treated as one bare diagram.
//!
//! The sniff is deliberately conservative — prose that merely starts with the
//! word "graph" must stay markdown — so it is STRICTER than
//! `DiagramType.fromSource` (which classifies content already known to be
//! mermaid): keywords must sit at column 0 (an indented line is a markdown
//! code block), match at a word boundary, and the keywords that read as
//! ordinary English (`graph`, `flowchart`) additionally require an explicit
//! layout direction after them. The keyword list here is cli-level routing
//! vocabulary; a consistency test in input_test.zig pins it to
//! `DiagramType.fromSource` so the two cannot drift.

const std = @import("std");
const text = @import("text");
const terminal = @import("../platform/terminal.zig");

pub const stripBom = text.stripBom;

/// With no file argument, stdin is read implicitly when it is a pipe or
/// redirect; an interactive terminal on stdin means there is nothing to read.
pub fn shouldReadImplicitStdin() bool {
    return !terminal.stdinIsTty();
}

/// File extensions that mean "this file is a mermaid diagram, not markdown".
const mermaid_extensions = [_][]const u8{ ".mmd", ".mermaid" };

/// Diagram keywords whose spelling is distinctive enough to stand alone.
/// `stateDiagram` also covers `stateDiagram-v2` (see `matchesKeyword`).
const distinct_keywords = [_][]const u8{
    "sequenceDiagram",
    "classDiagram",
    "erDiagram",
    "stateDiagram",
};

/// Diagram keywords that are also ordinary English words; these only count
/// when followed by an explicit layout direction.
const ambiguous_keywords = [_][]const u8{ "flowchart", "graph" };

/// Layout directions accepted after `flowchart`/`graph`.
const directions = [_][]const u8{ "TB", "TD", "BT", "LR", "RL" };

/// The one classification decision shared by the CLI and TUI entry points:
/// a `.mmd`/`.mermaid` path is a diagram by extension; pathless input
/// (stdin/pipe) is sniffed from its bytes.
pub fn isMermaidSource(path: ?[]const u8, content: []const u8) bool {
    if (path) |p| return isMermaidExtension(p);
    return looksLikeBareMermaid(content);
}

/// True when `path` names a mermaid diagram file by extension.
pub fn isMermaidExtension(path: []const u8) bool {
    for (mermaid_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

/// True when `content` should be treated as one bare mermaid diagram instead
/// of being handed to the markdown parser.
pub fn looksLikeBareMermaid(raw_content: []const u8) bool {
    const content = stripBom(raw_content);
    if (hasMermaidFence(content)) return false;
    const line = firstColumnZeroLine(content) orelse return false;
    return startsWithDiagramKeyword(line);
}

/// True when `content` contains an opening ```mermaid / ~~~mermaid fence.
pub fn hasMermaidFence(raw_content: []const u8) bool {
    var lines = text.LineIter.init(stripBom(raw_content));
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const rest = if (std.mem.startsWith(u8, line, "```"))
            line[3..]
        else if (std.mem.startsWith(u8, line, "~~~"))
            line[3..]
        else
            continue;
        const info = std.mem.trimLeft(u8, rest, "`~ \t");
        if (std.mem.startsWith(u8, info, "mermaid")) return true;
    }
    return false;
}

/// First line that is neither blank nor a `%%` mermaid comment. Leading
/// whitespace is NOT trimmed away: in markdown an indented line is a code
/// block, so an indented first line ends the scan with `null` rather than
/// being skipped or trimmed.
fn firstColumnZeroLine(content: []const u8) ?[]const u8 {
    var lines = text.LineIter.init(content);
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "%%")) continue;
        if (line[0] == ' ' or line[0] == '\t') return null;
        return line;
    }
    return null;
}

fn startsWithDiagramKeyword(line: []const u8) bool {
    for (distinct_keywords) |keyword| {
        if (matchesKeyword(line, keyword)) |_| return true;
    }
    for (ambiguous_keywords) |keyword| {
        const rest = matchesKeyword(line, keyword) orelse continue;
        const tail = std.mem.trim(u8, rest, " \t;:");
        if (hasDirectionPrefix(tail)) return true;
    }
    return false;
}

/// When `line` opens with `keyword` at a word boundary, return the remainder.
/// A trailing `-v2` (as in `stateDiagram-v2`) is consumed as part of the
/// keyword; any other alphanumeric continuation is rejected.
fn matchesKeyword(line: []const u8, keyword: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, keyword)) return null;
    var rest = line[keyword.len..];
    if (std.mem.startsWith(u8, rest, "-v2")) rest = rest[3..];
    if (rest.len == 0) return rest;
    return switch (rest[0]) {
        ' ', '\t', ';', ':' => rest,
        else => null,
    };
}

fn hasDirectionPrefix(tail: []const u8) bool {
    for (directions) |dir| {
        if (!std.mem.startsWith(u8, tail, dir)) continue;
        const rest = tail[dir.len..];
        if (rest.len == 0) return true;
        switch (rest[0]) {
            ' ', '\t', ';', ':' => return true,
            else => {},
        }
    }
    return false;
}

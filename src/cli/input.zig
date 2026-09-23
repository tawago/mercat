const std = @import("std");
const text = @import("text");
const terminal = @import("../platform/terminal.zig");

pub const stripBom = text.stripBom;

pub fn shouldReadImplicitStdin() bool {
    return !terminal.stdinIsTty();
}

const mermaid_extensions = [_][]const u8{ ".mmd", ".mermaid" };

const distinct_keywords = [_][]const u8{
    "sequenceDiagram",
    "classDiagram",
    "erDiagram",
    "stateDiagram",
};

const ambiguous_keywords = [_][]const u8{ "flowchart", "graph" };

const directions = [_][]const u8{ "TB", "TD", "BT", "LR", "RL" };

pub fn isMermaidSource(path: ?[]const u8, content: []const u8) bool {
    if (path) |p| return isMermaidExtension(p);
    return looksLikeBareMermaid(content);
}

pub fn isMermaidExtension(path: []const u8) bool {
    for (mermaid_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

pub fn looksLikeBareMermaid(raw_content: []const u8) bool {
    const content = stripBom(raw_content);
    if (hasMermaidFence(content)) return false;
    const line = firstColumnZeroLine(content) orelse return false;
    return startsWithDiagramKeyword(line);
}

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

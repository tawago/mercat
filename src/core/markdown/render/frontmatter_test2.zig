const std = @import("std");
const config = @import("../../config.zig");
const markdown = @import("../parser.zig");
const types = @import("types.zig");
const Builder = @import("builder.zig").Builder;
const geometry = @import("geometry.zig");
const frontmatter = @import("frontmatter.zig");

const Block = markdown.Block;
const Entry = Block.FrontMatter.Entry;
const testing = std.testing;
const ellipsis = "\u{2026}";

fn renderLines(allocator: std.mem.Allocator, fm: Block.FrontMatter, width: usize, style: config.FrontmatterStyle, for_export: bool) ![]types.Line {
    var builder = Builder.init(allocator);
    frontmatter.render(allocator, &builder, fm, width, style, for_export) catch |err| {
        builder.deinit();
        return err;
    };
    return builder.finish() catch |err| {
        builder.deinit();
        return err;
    };
}

fn freeLines(allocator: std.mem.Allocator, lines: []types.Line) void {
    for (lines) |line| line.deinit(allocator);
    allocator.free(lines);
}

fn totalSpans(lines: []types.Line) usize {
    var total: usize = 0;
    for (lines) |line| total += line.spans.len;
    return total;
}

fn anySpanContains(lines: []types.Line, needle: []const u8) bool {
    for (lines) |line| for (line.spans) |span| {
        if (std.mem.indexOf(u8, span.text, needle) != null) return true;
    };
    return false;
}

fn anySpanHasByte(lines: []types.Line, byte: u8) bool {
    for (lines) |line| for (line.spans) |span| {
        if (std.mem.indexOfScalar(u8, span.text, byte) != null) return true;
    };
    return false;
}

fn allLinesWithin(lines: []types.Line, cap: usize) bool {
    for (lines) |line| if (line.displayWidth() > cap) return false;
    return true;
}

test "frontmatter: raw style preserves a genuine blank middle line" {
    const alloc = testing.allocator;
    var no_entries = [_]Entry{};
    const fm = Block.FrontMatter{ .raw = "a: 1\n\nb: 2\n", .entries = &no_entries };
    const lines = try renderLines(alloc, fm, 40, .raw, false);
    defer freeLines(alloc, lines);
    try testing.expectEqual(@as(usize, 5), lines.len);
    try testing.expectEqualStrings("a: 1", lines[1].spans[0].text);
    try testing.expectEqual(@as(usize, 0), lines[2].spans.len);
    try testing.expectEqualStrings("b: 2", lines[3].spans[0].text);
}

test "frontmatter: empty non-raw front matter emits nothing but raw keeps its fences" {
    const alloc = testing.allocator;
    var no_entries = [_]Entry{};
    const empty = Block.FrontMatter{ .raw = "", .entries = &no_entries };
    inline for (.{ config.FrontmatterStyle.panel, .dim, .compact }) |style| {
        const lines = try renderLines(alloc, empty, 40, style, false);
        defer freeLines(alloc, lines);
        try testing.expectEqual(@as(usize, 0), totalSpans(lines));
    }
    const raw_lines = try renderLines(alloc, empty, 40, .raw, false);
    defer freeLines(alloc, raw_lines);
    try testing.expectEqual(@as(usize, 2), raw_lines.len);
    try testing.expectEqualStrings("---", raw_lines[0].spans[0].text);
    try testing.expectEqualStrings("---", raw_lines[1].spans[0].text);
}

test "frontmatter: hidden style emits nothing" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "title", .value = "Test" }};
    const fm = Block.FrontMatter{ .raw = "title: Test\n", .entries = &entries };
    const lines = try renderLines(alloc, fm, 40, .hidden, false);
    defer freeLines(alloc, lines);
    try testing.expectEqual(@as(usize, 0), totalSpans(lines));
}

test "frontmatter: an over-wide key is truncated with an ellipsis inside the width cap" {
    const alloc = testing.allocator;
    const width: usize = 12;
    var entries = [_]Entry{.{ .key = "averylongkeyname", .value = "v" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    const lines = try renderLines(alloc, fm, width, .dim, false);
    defer freeLines(alloc, lines);
    const max_key_width: usize = width - 2 - 3;
    var found_key = false;
    for (lines) |line| for (line.spans) |span| {
        if (span.style != .muted) continue;
        const key = std.mem.trimRight(u8, span.text, " ");
        if (key.len == 0) continue;
        found_key = true;
        try testing.expect(std.mem.endsWith(u8, key, ellipsis));
        try testing.expect(try geometry.displayWidth(key) <= max_key_width);
    };
    try testing.expect(found_key);
    try testing.expect(allLinesWithin(lines, width));
}

test "frontmatter: a long value wraps onto padded continuation rows within width" {
    const alloc = testing.allocator;
    const width: usize = 20;
    var entries = [_]Entry{.{ .key = "k", .value = "one two three four five" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    const lines = try renderLines(alloc, fm, width, .panel, false);
    defer freeLines(alloc, lines);
    try testing.expect(lines.len >= 4);
    try testing.expect(allLinesWithin(lines, width));
    try testing.expect(anySpanContains(lines, "one"));
    try testing.expect(anySpanContains(lines, "five"));
}

test "frontmatter: an unbreakable token is hard-split at the value column width" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "k", .value = "superlongunbrokentoken" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    const lines = try renderLines(alloc, fm, 12, .panel, false);
    defer freeLines(alloc, lines);
    try testing.expect(lines.len >= 4);
    try testing.expect(allLinesWithin(lines, 12));
}

test "frontmatter: tabs expand to four-column stops" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "k", .value = "a\tb" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    const lines = try renderLines(alloc, fm, 40, .panel, true);
    defer freeLines(alloc, lines);
    try testing.expect(!anySpanHasByte(lines, '\t'));
    try testing.expect(anySpanContains(lines, "a   b"));
    for (lines) |line| try testing.expect(line.displayWidth() <= 40);
}

test "frontmatter: raw tabs expand identically for terminal and export" {
    const alloc = testing.allocator;
    var no_entries = [_]Entry{};
    const fm = Block.FrontMatter{ .raw = "a\tb\n", .entries = &no_entries };
    const term = try renderLines(alloc, fm, 40, .raw, false);
    defer freeLines(alloc, term);
    try testing.expect(!anySpanHasByte(term, '\t'));
    try testing.expect(anySpanContains(term, "a   b"));
    const exp = try renderLines(alloc, fm, 40, .raw, true);
    defer freeLines(alloc, exp);
    try testing.expect(!anySpanHasByte(exp, '\t'));
    try testing.expect(anySpanContains(exp, "a   b"));
}

test "frontmatter: narrow widths do not underflow and still emit a line" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "k", .value = "v" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    inline for (.{ 1, 2 }) |width| {
        const lines = try renderLines(alloc, fm, width, .panel, false);
        defer freeLines(alloc, lines);
        try testing.expect(lines.len >= 1);
        try testing.expect(anySpanContains(lines, "v"));
    }
}

test "frontmatter: a keyless continuation entry renders its value in the panel" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "", .value = "  - Foo" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    const lines = try renderLines(alloc, fm, 40, .panel, false);
    defer freeLines(alloc, lines);
    try testing.expect(anySpanContains(lines, "- Foo"));
}

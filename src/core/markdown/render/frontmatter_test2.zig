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

fn renderLines(allocator: std.mem.Allocator, fm: Block.FrontMatter, width: usize, style: config.FrontmatterStyle) ![]types.Line {
    var builder = Builder.init(allocator);
    frontmatter.render(allocator, &builder, fm, width, style) catch |err| {
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
    const lines = try renderLines(alloc, fm, 40, .raw);
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
        const lines = try renderLines(alloc, empty, 40, style);
        defer freeLines(alloc, lines);
        try testing.expectEqual(@as(usize, 0), totalSpans(lines));
    }
    const raw_lines = try renderLines(alloc, empty, 40, .raw);
    defer freeLines(alloc, raw_lines);
    try testing.expectEqual(@as(usize, 2), raw_lines.len);
    try testing.expectEqualStrings("---", raw_lines[0].spans[0].text);
    try testing.expectEqualStrings("---", raw_lines[1].spans[0].text);
}

test "frontmatter: hidden style emits nothing" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "title", .value = "Test" }};
    const fm = Block.FrontMatter{ .raw = "title: Test\n", .entries = &entries };
    const lines = try renderLines(alloc, fm, 40, .hidden);
    defer freeLines(alloc, lines);
    try testing.expectEqual(@as(usize, 0), totalSpans(lines));
}

test "frontmatter: an over-wide key is truncated with an ellipsis inside the width cap" {
    const alloc = testing.allocator;
    const width: usize = 12;
    var entries = [_]Entry{.{ .key = "averylongkeyname", .value = "v" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    const lines = try renderLines(alloc, fm, width, .dim);
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
    const lines = try renderLines(alloc, fm, width, .panel);
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
    const lines = try renderLines(alloc, fm, 12, .panel);
    defer freeLines(alloc, lines);
    try testing.expect(lines.len >= 4);
    try testing.expect(allLinesWithin(lines, 12));
}

test "frontmatter: tabs expand to four-column stops" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "k", .value = "a\tb" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    const lines = try renderLines(alloc, fm, 40, .panel);
    defer freeLines(alloc, lines);
    try testing.expect(!anySpanHasByte(lines, '\t'));
    try testing.expect(anySpanContains(lines, "a   b"));
    for (lines) |line| try testing.expect(line.displayWidth() <= 40);
}

test "frontmatter: raw tabs expand to four-column stops" {
    const alloc = testing.allocator;
    var no_entries = [_]Entry{};
    const fm = Block.FrontMatter{ .raw = "a\tb\n", .entries = &no_entries };
    const lines = try renderLines(alloc, fm, 40, .raw);
    defer freeLines(alloc, lines);
    try testing.expect(!anySpanHasByte(lines, '\t'));
    try testing.expect(anySpanContains(lines, "a   b"));
}

test "frontmatter: narrow widths do not underflow and still emit a line" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "k", .value = "v" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    inline for (.{ 1, 2 }) |width| {
        const lines = try renderLines(alloc, fm, width, .panel);
        defer freeLines(alloc, lines);
        try testing.expect(lines.len >= 1);
        try testing.expect(anySpanContains(lines, "v"));
    }
}

test "frontmatter: a keyless continuation entry renders its value in the panel" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "", .value = "  - Foo" }};
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };
    const lines = try renderLines(alloc, fm, 40, .panel);
    defer freeLines(alloc, lines);
    try testing.expect(anySpanContains(lines, "- Foo"));
}

const compact_marker = "\u{25C8}";
const cap_top = "\u{2584}";
const cap_bottom = "\u{2580}";

fn countStyle(lines: []types.Line, style: types.SpanStyle) usize {
    var total: usize = 0;
    for (lines) |line| for (line.spans) |span| {
        if (span.style == style) total += 1;
    };
    return total;
}

fn hasStyledText(lines: []types.Line, style: types.SpanStyle, want: []const u8) bool {
    for (lines) |line| for (line.spans) |span| {
        if (span.style != style) continue;
        if (std.mem.eql(u8, std.mem.trim(u8, span.text, " "), want)) return true;
    };
    return false;
}

test "frontmatter: panel style emits half-block caps around a key/value grid" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "title", .value = "Test" }};
    const fm = Block.FrontMatter{ .raw = "title: Test\n", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .panel);
    defer freeLines(alloc, lines);

    try testing.expectEqual(@as(usize, 3), lines.len);

    try testing.expect(lines[0].spans.len != 0);
    for (lines[0].spans) |span| {
        try testing.expectEqual(types.SpanStyle.frontmatter_cap, span.style);
        try testing.expect(std.mem.indexOf(u8, span.text, cap_top) != null);
        try testing.expect(std.mem.indexOf(u8, span.text, cap_bottom) == null);
    }

    try testing.expect(hasStyledText(lines[1..2], .frontmatter_key, "title"));
    try testing.expect(hasStyledText(lines[1..2], .frontmatter_value, "Test"));

    for (lines[2].spans) |span| {
        try testing.expectEqual(types.SpanStyle.frontmatter_cap, span.style);
        try testing.expect(std.mem.indexOf(u8, span.text, cap_bottom) != null);
    }
}

test "frontmatter: dim style is chrome-free with muted key and body value" {
    const alloc = testing.allocator;
    var entries = [_]Entry{.{ .key = "title", .value = "Test" }};
    const fm = Block.FrontMatter{ .raw = "title: Test\n", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .dim);
    defer freeLines(alloc, lines);

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(@as(usize, 0), countStyle(lines, .frontmatter_cap));
    try testing.expect(hasStyledText(lines, .muted, "title"));
    try testing.expect(hasStyledText(lines, .body, "Test"));
}

test "frontmatter: compact style is a single marker-led line of pairs" {
    const alloc = testing.allocator;
    var entries = [_]Entry{
        .{ .key = "title", .value = "Test" },
        .{ .key = "author", .value = "Foo" },
    };
    const fm = Block.FrontMatter{ .raw = "", .entries = &entries };

    const lines = try renderLines(alloc, fm, 60, .compact);
    defer freeLines(alloc, lines);

    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqual(types.SpanStyle.muted, lines[0].spans[0].style);
    try testing.expectEqualStrings(compact_marker, lines[0].spans[0].text);
    try testing.expect(hasStyledText(lines, .muted, "title:"));
    try testing.expect(hasStyledText(lines, .muted, "author:"));
    try testing.expect(hasStyledText(lines, .body, "Test"));
    try testing.expect(hasStyledText(lines, .body, "Foo"));
}

test "frontmatter: raw style is byte-verbatim between fences without a trailing blank" {
    const alloc = testing.allocator;
    var entries = [_]Entry{
        .{ .key = "title", .value = "Test" },
        .{ .key = "author", .value = "Foo" },
    };
    const fm = Block.FrontMatter{ .raw = "title: Test\nauthor: Foo\n", .entries = &entries };

    const lines = try renderLines(alloc, fm, 40, .raw);
    defer freeLines(alloc, lines);

    try testing.expectEqual(@as(usize, 4), lines.len);
    try testing.expectEqualStrings("---", lines[0].spans[0].text);
    try testing.expectEqualStrings("title: Test", lines[1].spans[0].text);
    try testing.expectEqualStrings("author: Foo", lines[2].spans[0].text);
    try testing.expectEqualStrings("---", lines[3].spans[0].text);
    try testing.expectEqual(types.SpanStyle.muted, lines[0].spans[0].style);
}

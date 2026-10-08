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

test "frontmatter fits any width without losing text" {
    const alloc = testing.allocator;
    const values = [_][]const u8{ "v", "one two three four five", "superlongunbrokentoken" };
    for (values) |value| for (1..41) |width| {
        errdefer std.debug.print("value '{s}' at width {d}\n", .{ value, width });
        var entries = [_]Entry{.{ .key = "k", .value = value }};
        const lines = try renderLines(alloc, .{ .raw = "", .entries = &entries }, width, .panel);
        defer freeLines(alloc, lines);
        try testing.expect(lines.len >= 1);
        // Width 1 cannot hold the panel's one-column margin and a value.
        if (width >= 2) try testing.expect(allLinesWithin(lines, width));
        // Wrapping and hard splits move text between rows but drop none.
        var shown: std.ArrayList(u8) = .empty;
        defer shown.deinit(alloc);
        for (lines) |line| for (line.spans) |span| if (span.style == .frontmatter_value) {
            for (span.text) |byte| if (byte != ' ') try shown.append(alloc, byte);
        };
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(alloc);
        for (value) |byte| if (byte != ' ') try want.append(alloc, byte);
        try testing.expectEqualStrings(want.items, shown.items);
    };
    // Panel tabs expand to four-column stops.
    var tabbed = [_]Entry{.{ .key = "k", .value = "a\tb" }};
    const tab_lines = try renderLines(alloc, .{ .raw = "", .entries = &tabbed }, 40, .panel);
    defer freeLines(alloc, tab_lines);
    try testing.expect(!anySpanHasByte(tab_lines, '\t'));
    try testing.expect(anySpanContains(tab_lines, "a   b"));
    try testing.expect(allLinesWithin(tab_lines, 40));

    // An over-wide key is truncated with an ellipsis inside the width cap.
    const width: usize = 12;
    var long_key = [_]Entry{.{ .key = "averylongkeyname", .value = "v" }};
    const lines = try renderLines(alloc, .{ .raw = "", .entries = &long_key }, width, .dim);
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
    var no_entries = [_]Entry{};
    const cases = [_]struct { raw: []const u8, want: []const []const u8 }{
        .{ .raw = "title: Test\nauthor: Foo\n", .want = &.{ "title: Test", "author: Foo" } },
        // A genuine blank middle line stays; tabs expand to four-column stops.
        .{ .raw = "a: 1\n\nb: 2\n", .want = &.{ "a: 1", "", "b: 2" } },
        .{ .raw = "a\tb\n", .want = &.{"a   b"} },
    };
    for (cases) |case| {
        const lines = try renderLines(alloc, .{ .raw = case.raw, .entries = &no_entries }, 40, .raw);
        defer freeLines(alloc, lines);
        try testing.expectEqual(case.want.len + 2, lines.len);
        try testing.expectEqualStrings("---", lines[0].spans[0].text);
        try testing.expectEqualStrings("---", lines[lines.len - 1].spans[0].text);
        try testing.expectEqual(types.SpanStyle.muted, lines[0].spans[0].style);
        for (case.want, lines[1 .. lines.len - 1]) |want, line| {
            const got = try line.joinedText(alloc);
            defer alloc.free(got);
            try testing.expectEqualStrings(want, got);
        }
    }
}

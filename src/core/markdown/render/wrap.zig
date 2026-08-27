const std = @import("std");
const unicode = @import("unicode");
const markdown = @import("../parser.zig");
const line_mod = @import("line.zig");
const builder_mod = @import("builder.zig");
const inline_mod = @import("inline.zig");

const Inline = markdown.Inline;
const SpanStyle = line_mod.SpanStyle;
const Builder = builder_mod.Builder;
const Decor = @import("decor.zig").Decor;

const TokenRange = struct {
    start: usize,
    end: usize,
    token: inline_mod.InlineToken,
};

pub fn renderWrappedInlines(allocator: std.mem.Allocator, builder: *Builder, inlines: []const Inline, width: usize, first_prefix_style: SpanStyle, first_prefix: []const u8, rest_prefix_style: SpanStyle, rest_prefix: []const u8, default_style: SpanStyle, decor: *const Decor) !void {
    const tokens = try inline_mod.inlinesToTokens(allocator, inlines, decor);
    defer inline_mod.freeTokens(allocator, tokens);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    const ranges = try allocator.alloc(TokenRange, tokens.len);
    defer allocator.free(ranges);
    for (tokens, ranges) |token, *range| {
        const start = text.items.len;
        try text.appendSlice(allocator, token.text);
        range.* = .{ .start = start, .end = text.items.len, .token = token };
    }

    var content_start: usize = 0;
    var first_line = true;
    while (content_start < text.items.len or first_line) {
        while (content_start < text.items.len and isWhitespaceByte(text.items[content_start])) content_start += 1;
        const prefix = if (first_line) first_prefix else rest_prefix;
        const prefix_style = if (first_line) first_prefix_style else rest_prefix_style;
        const content_end = try lineEnd(allocator, builder.left_padding, prefix, text.items, ranges, content_start, width);

        if (prefix.len != 0) try builder.appendSpan(prefix_style, prefix);
        try appendRange(builder, ranges, content_start, content_end, default_style);
        if (content_end == text.items.len) break;

        content_start = content_end;
        while (content_start < text.items.len and isWhitespaceByte(text.items[content_start])) content_start += 1;
        try builder.newline();
        first_line = false;
    }
}

/// Preserve the historical token-boundary wrapping policy, but admit a token
/// boundary only when it is also a whole-line grapheme boundary. Adjacent style
/// tokens that form one grapheme therefore wrap as one indivisible group.
fn lineEnd(allocator: std.mem.Allocator, initial_column: usize, prefix: []const u8, text: []const u8, ranges: []const TokenRange, content_start: usize, width: usize) !usize {
    const candidate = try std.mem.concat(allocator, u8, &.{ prefix, text[content_start..] });
    defer allocator.free(candidate);

    var iterator = unicode.Iterator.initAt(candidate, initial_column);
    const limit = std.math.add(usize, initial_column, width) catch return error.Overflow;
    var boundaries: std.ArrayList(struct { source_end: usize, column_end: usize }) = .empty;
    defer boundaries.deinit(allocator);
    while (try iterator.next()) |grapheme| {
        if (grapheme.byte_end >= prefix.len) try boundaries.append(allocator, .{
            .source_end = content_start + grapheme.byte_end - prefix.len,
            .column_end = grapheme.column_end,
        });
    }

    var range_index: usize = 0;
    while (range_index < ranges.len and ranges[range_index].end <= content_start) range_index += 1;
    var boundary_index: usize = 0;
    var have_group = false;
    while (range_index < ranges.len) {
        const group_start = @max(content_start, ranges[range_index].start);
        var group_end = ranges[range_index].end;
        range_index += 1;

        while (true) {
            while (boundary_index < boundaries.items.len and boundaries.items[boundary_index].source_end < group_end) boundary_index += 1;
            if (boundary_index < boundaries.items.len and boundaries.items[boundary_index].source_end == group_end) break;
            if (range_index == ranges.len) return text.len;
            group_end = ranges[range_index].end;
            range_index += 1;
        }

        if (boundaries.items[boundary_index].column_end > limit) {
            return if (have_group) group_start else group_end;
        }
        have_group = true;
        if (group_end == text.len) return text.len;
    }
    return text.len;
}

fn appendRange(builder: *Builder, ranges: []const TokenRange, start: usize, end: usize, default_style: SpanStyle) !void {
    for (ranges) |range| {
        const part_start = @max(start, range.start);
        const part_end = @min(end, range.end);
        if (part_start >= part_end) continue;
        const token = range.token;
        try builder.appendSpanWithUrl(
            if (token.style == .body) default_style else token.style,
            token.text[part_start - range.start .. part_end - range.start],
            token.url,
        );
    }
}

fn isWhitespaceByte(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

pub fn isWhitespace(text: []const u8) bool {
    for (text) |byte| if (!isWhitespaceByte(byte)) return false;
    return text.len != 0;
}

test "wrapping measures a variation-selector grapheme across style spans" {
    const allocator = std.testing.allocator;
    var base = [_]Inline{.{ .text = "©" }};
    var selector = [_]Inline{.{ .text = "\u{fe0f}" }};
    var inlines = [_]Inline{
        .{ .text = "x " },
        .{ .emphasis = &base },
        .{ .strong = &selector },
    };

    inline for (.{ .{ 2, 2 }, .{ 3, 2 }, .{ 4, 1 } }) |case| {
        var builder = Builder.init(allocator);
        defer builder.deinit();
        try renderWrappedInlines(allocator, &builder, &inlines, case[0], .body, "", .body, "", .body, &@import("decor.zig").legacy);
        const lines = try builder.finish();
        defer {
            for (lines) |line| line.deinit(allocator);
            allocator.free(lines);
        }
        try std.testing.expectEqual(@as(usize, case[1]), lines.len);
        const emoji_line = lines[lines.len - 1];
        try std.testing.expect(emoji_line.displayWidth() >= 2);
        try std.testing.expectEqualStrings("©", emoji_line.spans[emoji_line.spans.len - 2].text);
        try std.testing.expectEqualStrings("\u{fe0f}", emoji_line.spans[emoji_line.spans.len - 1].text);
    }
}

test "wrapping breaks before or after a width-two grapheme but never inside it" {
    const allocator = std.testing.allocator;
    var wide = [_]Inline{.{ .text = "日" }};
    var suffix = [_]Inline{.{ .text = "B" }};
    var inlines = [_]Inline{
        .{ .text = "A" },
        .{ .emphasis = &wide },
        .{ .strong = &suffix },
    };

    inline for (.{ .{ 1, 3 }, .{ 2, 3 }, .{ 3, 2 }, .{ 4, 1 } }) |case| {
        var builder = Builder.init(allocator);
        defer builder.deinit();
        try renderWrappedInlines(allocator, &builder, &inlines, case[0], .body, "", .body, "", .body, &@import("decor.zig").legacy);
        const lines = try builder.finish();
        defer {
            for (lines) |line| line.deinit(allocator);
            allocator.free(lines);
        }
        try std.testing.expectEqual(@as(usize, case[1]), lines.len);

        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(allocator);
        for (lines) |rendered_line| for (rendered_line.spans) |span| try joined.appendSlice(allocator, span.text);
        try std.testing.expectEqualStrings("A日B", joined.items);
    }
}

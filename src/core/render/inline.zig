const std = @import("std");
const markdown = @import("../markdown.zig");
const types = @import("types.zig");
const unicode = @import("../../lib/unicode.zig");

const Inline = markdown.Inline;
const SpanStyle = types.SpanStyle;

pub const InlineToken = struct {
    text: []const u8,
    style: SpanStyle,
};

pub fn inlinesToTokens(allocator: std.mem.Allocator, inlines: []const Inline) ![]InlineToken {
    var tokens: std.ArrayList(InlineToken) = .empty;
    errdefer {
        for (tokens.items) |token| allocator.free(token.text);
        tokens.deinit(allocator);
    }

    for (inlines) |inline_| {
        try appendInlineTokens(allocator, &tokens, inline_, .body);
    }

    return try tokens.toOwnedSlice(allocator);
}

pub fn appendInlineTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList(InlineToken), inline_: Inline, parent_style: SpanStyle) !void {
    switch (inline_) {
        .text => |text| try splitAndAppendTokens(allocator, tokens, text, parent_style),
        .code => |text| try tokens.append(allocator, .{ .text = try allocator.dupe(u8, text), .style = .code }),
        .html => |text| try tokens.append(allocator, .{ .text = try allocator.dupe(u8, text), .style = .muted }),
        .emphasis => |children| {
            for (children) |child| try appendInlineTokens(allocator, tokens, child, .emphasis);
        },
        .strong => |children| {
            for (children) |child| try appendInlineTokens(allocator, tokens, child, .strong);
        },
        .strikethrough => |children| {
            for (children) |child| try appendInlineTokens(allocator, tokens, child, .muted);
        },
        .link => |link| {
            // Render link text, then URL in angle brackets
            for (link.text) |child| try appendInlineTokens(allocator, tokens, child, .body);
            const url_text = try std.fmt.allocPrint(allocator, " <{s}>", .{link.url});
            try tokens.append(allocator, .{ .text = url_text, .style = .link });
        },
        .image => |image| {
            // Render as ![alt](url)
            try tokens.append(allocator, .{ .text = try allocator.dupe(u8, "!["), .style = .muted });
            for (image.alt) |child| try appendInlineTokens(allocator, tokens, child, .body);
            const url_part = try std.fmt.allocPrint(allocator, "]({s})", .{image.url});
            try tokens.append(allocator, .{ .text = url_part, .style = .muted });
        },
        .soft_break, .line_break => {
            try tokens.append(allocator, .{ .text = try allocator.dupe(u8, " "), .style = parent_style });
        },
    }
}

pub fn splitAndAppendTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList(InlineToken), text: []const u8, style: SpanStyle) !void {
    var start: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != ' ') continue;
        if (start < index) {
            try tokens.append(allocator, .{ .text = try allocator.dupe(u8, text[start..index]), .style = style });
        }
        try tokens.append(allocator, .{ .text = try allocator.dupe(u8, " "), .style = style });
        start = index + 1;
    }
    if (start < text.len) {
        try tokens.append(allocator, .{ .text = try allocator.dupe(u8, text[start..]), .style = style });
    }
}

pub fn inlinesDisplayWidth(inlines: []const Inline) usize {
    var width: usize = 0;
    for (inlines) |inline_| {
        width += inlineDisplayWidth(inline_);
    }
    return width;
}

pub fn inlineDisplayWidth(inline_: Inline) usize {
    return switch (inline_) {
        .text => |text| unicode.displayWidth(text),
        .code => |text| unicode.displayWidth(text),
        .html => |text| unicode.displayWidth(text),
        .emphasis => |children| inlinesDisplayWidth(children),
        .strong => |children| inlinesDisplayWidth(children),
        .strikethrough => |children| inlinesDisplayWidth(children),
        .link => |link| inlinesDisplayWidth(link.text) + 3 + link.url.len, // " <url>"
        .image => |image| 2 + inlinesDisplayWidth(image.alt) + 2 + image.url.len, // "![alt](url)"
        .soft_break, .line_break => 1,
    };
}

pub fn inlinesToText(allocator: std.mem.Allocator, inlines: []const Inline) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    for (inlines) |inline_| {
        try appendInlineText(allocator, &buffer, inline_);
    }

    return try buffer.toOwnedSlice(allocator);
}

pub fn appendInlineText(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), inline_: Inline) !void {
    switch (inline_) {
        .text => |text| try buffer.appendSlice(allocator, text),
        .code => |text| try buffer.appendSlice(allocator, text),
        .html => |text| try buffer.appendSlice(allocator, text),
        .emphasis => |children| {
            for (children) |child| try appendInlineText(allocator, buffer, child);
        },
        .strong => |children| {
            for (children) |child| try appendInlineText(allocator, buffer, child);
        },
        .strikethrough => |children| {
            for (children) |child| try appendInlineText(allocator, buffer, child);
        },
        .link => |link| {
            for (link.text) |child| try appendInlineText(allocator, buffer, child);
        },
        .image => |image| {
            for (image.alt) |child| try appendInlineText(allocator, buffer, child);
        },
        .soft_break, .line_break => try buffer.append(allocator, ' '),
    }
}

pub fn freeTokens(allocator: std.mem.Allocator, tokens: []const InlineToken) void {
    for (tokens) |token| allocator.free(token.text);
    allocator.free(tokens);
}

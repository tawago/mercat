const std = @import("std");
const markdown = @import("../markdown.zig");
const types = @import("types.zig");
const unicode = @import("../../lib/unicode.zig");

const Inline = markdown.Inline;
const SpanStyle = types.SpanStyle;

pub const InlineToken = struct {
    text: []const u8,
    style: SpanStyle,
    url: ?[]const u8 = null,
};

pub fn inlinesToTokens(allocator: std.mem.Allocator, inlines: []const Inline) ![]InlineToken {
    var tokens: std.ArrayList(InlineToken) = .empty;
    errdefer {
        for (tokens.items) |token| {
            allocator.free(token.text);
            if (token.url) |url| allocator.free(url);
        }
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
            const style: SpanStyle = if (parent_style == .strong) .strong_emphasis else .emphasis;
            for (children) |child| try appendInlineTokens(allocator, tokens, child, style);
        },
        .strong => |children| {
            const style: SpanStyle = if (parent_style == .emphasis) .strong_emphasis else .strong;
            for (children) |child| try appendInlineTokens(allocator, tokens, child, style);
        },
        .strikethrough => |children| {
            for (children) |child| try appendInlineTokens(allocator, tokens, child, .strikethrough);
        },
        .link => |link| {
            // Collect link text tokens, then attach the URL so the text itself is
            // the OSC 8 hyperlink anchor in capable terminals.
            const start = tokens.items.len;
            for (link.text) |child| try appendInlineTokens(allocator, tokens, child, .link);
            // Attach URL to every link-text token so the full text is clickable.
            for (tokens.items[start..]) |*tok| {
                tok.url = try allocator.dupe(u8, link.url);
            }
            // Append visible " <url>" suffix as fallback for non-OSC-8 terminals.
            const url_text = try std.fmt.allocPrint(allocator, " <{s}>", .{link.url});
            try tokens.append(allocator, .{ .text = url_text, .style = .link, .url = try allocator.dupe(u8, link.url) });
        },
        .image => |image| {
            // Render as [Image: alt]
            try tokens.append(allocator, .{ .text = try allocator.dupe(u8, "[Image: "), .style = .image_alt });
            for (image.alt) |child| try appendInlineTokens(allocator, tokens, child, .image_alt);
            try tokens.append(allocator, .{ .text = try allocator.dupe(u8, "]"), .style = .image_alt });
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
        .image => |image| 8 + inlinesDisplayWidth(image.alt) + 1, // "[Image: alt]"
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
    for (tokens) |token| {
        allocator.free(token.text);
        if (token.url) |url| allocator.free(url);
    }
    allocator.free(tokens);
}

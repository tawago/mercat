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

    try appendInlineSliceTokens(allocator, &tokens, inlines, .body);

    return try tokens.toOwnedSlice(allocator);
}

/// Process a slice of inlines, consuming HTML tag sequences as style spans.
/// When we encounter an opening HTML tag for a known semantic element, we
/// consume subsequent inlines until the matching closing tag and apply the
/// appropriate style to all content in between.
fn appendInlineSliceTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList(InlineToken), inlines: []const Inline, parent_style: SpanStyle) anyerror!void {
    var i: usize = 0;
    while (i < inlines.len) {
        const inline_ = inlines[i];

        // Check if this is an opening HTML tag for a known semantic element.
        if (inline_ == .html) {
            const tag_text = inline_.html;

            // Handle footnote navigation tags: <fnref id="N"> and <fndef id="N">
            if (try footnoteNavUrl(allocator, tag_text)) |nav_url| {
                const close_tag = footnoteNavCloseTag(tag_text).?;
                // Collect inlines until the matching close tag.
                var j = i + 1;
                while (j < inlines.len) : (j += 1) {
                    if (inlines[j] == .html and std.mem.eql(u8, inlines[j].html, close_tag)) break;
                }
                // Render content between the tags with superscript style and nav URL.
                const content = inlines[i + 1 .. j];
                const start = tokens.items.len;
                try appendInlineSliceTokens(allocator, tokens, content, .superscript);
                for (tokens.items[start..]) |*tok| {
                    if (tok.url == null) {
                        tok.url = try allocator.dupe(u8, nav_url);
                    }
                }
                allocator.free(nav_url);
                i = if (j < inlines.len) j + 1 else j;
                continue;
            }

            if (htmlOpenTagStyle(tag_text)) |span_style| {
                const close_tag = htmlCloseTagFor(tag_text);
                // Collect inlines until the matching close tag.
                var j = i + 1;
                while (j < inlines.len) : (j += 1) {
                    if (inlines[j] == .html and std.mem.eql(u8, inlines[j].html, close_tag)) break;
                }
                // Render content between the tags with span_style.
                const content = inlines[i + 1 .. j];
                try appendInlineSliceTokens(allocator, tokens, content, span_style);
                // Skip past the closing tag (if found).
                i = if (j < inlines.len) j + 1 else j;
                continue;
            }
        }

        try appendInlineTokens(allocator, tokens, inline_, parent_style);
        i += 1;
    }
}

pub fn appendInlineTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList(InlineToken), inline_: Inline, parent_style: SpanStyle) !void {
    switch (inline_) {
        .text => |text| try splitAndAppendTokens(allocator, tokens, text, parent_style),
        .code => |text| try tokens.append(allocator, .{ .text = try allocator.dupe(u8, text), .style = .code }),
        .html => |text| try tokens.append(allocator, .{ .text = try allocator.dupe(u8, text), .style = .muted }),
        .emphasis => |children| {
            const style: SpanStyle = if (parent_style == .strong) .strong_emphasis else .emphasis;
            try appendInlineSliceTokens(allocator, tokens, children, style);
        },
        .strong => |children| {
            const style: SpanStyle = if (parent_style == .emphasis) .strong_emphasis else .strong;
            try appendInlineSliceTokens(allocator, tokens, children, style);
        },
        .strikethrough => |children| {
            try appendInlineSliceTokens(allocator, tokens, children, .strikethrough);
        },
        .link => |link| {
            // Collect link text tokens, then attach the URL so the text itself is
            // the OSC 8 hyperlink anchor in capable terminals.
            const start = tokens.items.len;
            try appendInlineSliceTokens(allocator, tokens, link.text, .link);
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
            try appendInlineSliceTokens(allocator, tokens, image.alt, .image_alt);
            try tokens.append(allocator, .{ .text = try allocator.dupe(u8, "]"), .style = .image_alt });
        },
        .soft_break, .line_break => {
            try tokens.append(allocator, .{ .text = try allocator.dupe(u8, " "), .style = parent_style });
        },
    }
}

const HtmlTagEntry = struct { open: []const u8, close: []const u8, style: SpanStyle };

const known_html_tags = [_]HtmlTagEntry{
    .{ .open = "<sup>", .close = "</sup>", .style = .superscript },
    .{ .open = "<sub>", .close = "</sub>", .style = .subscript },
    .{ .open = "<mark>", .close = "</mark>", .style = .highlight },
};

/// If `tag` is a known opening HTML tag, return the associated SpanStyle.
fn htmlOpenTagStyle(tag: []const u8) ?SpanStyle {
    for (known_html_tags) |entry| {
        if (std.mem.eql(u8, tag, entry.open)) return entry.style;
    }
    return null;
}

/// Return the closing tag string for a known opening tag.
/// Caller must have verified tag is a known opener first.
fn htmlCloseTagFor(open_tag: []const u8) []const u8 {
    for (known_html_tags) |entry| {
        if (std.mem.eql(u8, open_tag, entry.open)) return entry.close;
    }
    return "";
}

/// Parse `id="N"` attribute from a custom HTML tag like `<fnref id="3">`.
/// Returns the numeric id string slice (pointing into `tag`), or null.
fn parseHtmlIdAttr(tag: []const u8) ?[]const u8 {
    const marker = "id=\"";
    const id_start_idx = std.mem.indexOf(u8, tag, marker) orelse return null;
    const val_start = id_start_idx + marker.len;
    const val_end = std.mem.indexOfPos(u8, tag, val_start, "\"") orelse return null;
    return tag[val_start..val_end];
}

/// If `tag` is a `<fnref id="N">` or `<fndef id="N">` opening tag, return
/// a heap-allocated pseudo-URL `#fn:N` or `#fnref:N` respectively.
/// Caller owns the returned slice.
fn footnoteNavUrl(allocator: std.mem.Allocator, tag: []const u8) !?[]u8 {
    if (std.mem.startsWith(u8, tag, "<fnref ")) {
        const id = parseHtmlIdAttr(tag) orelse return null;
        return try std.fmt.allocPrint(allocator, "#fn:{s}", .{id});
    }
    if (std.mem.startsWith(u8, tag, "<fndef ")) {
        const id = parseHtmlIdAttr(tag) orelse return null;
        return try std.fmt.allocPrint(allocator, "#fnref:{s}", .{id});
    }
    return null;
}

/// Return the closing tag string for `<fnref ...>` or `<fndef ...>` openers.
fn footnoteNavCloseTag(tag: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, tag, "<fnref ")) return "</fnref>";
    if (std.mem.startsWith(u8, tag, "<fndef ")) return "</fndef>";
    return null;
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

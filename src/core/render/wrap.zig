const std = @import("std");
const markdown = @import("../markdown.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const inline_mod = @import("inline.zig");
const unicode = @import("../../lib/unicode.zig");

const Inline = markdown.Inline;
const SpanStyle = types.SpanStyle;
const Builder = builder_mod.Builder;

pub fn renderWrappedInlines(allocator: std.mem.Allocator, builder: *Builder, inlines: []const Inline, width: usize, first_prefix_style: SpanStyle, first_prefix: []const u8, rest_prefix_style: SpanStyle, rest_prefix: []const u8, default_style: SpanStyle) !void {
    const tokens = try inline_mod.inlinesToTokens(allocator, inlines);
    defer {
        for (tokens) |token| allocator.free(token.text);
        allocator.free(tokens);
    }

    var current_width = unicode.displayWidth(first_prefix);
    var first_token_on_line = true;
    var current_prefix = first_prefix;
    var current_prefix_style = first_prefix_style;

    if (current_prefix.len != 0) try builder.appendSpan(current_prefix_style, current_prefix);

    for (tokens) |token| {
        if (first_token_on_line and isWhitespace(token.text)) continue;
        const token_width = unicode.displayWidth(token.text);
        if (!first_token_on_line and current_width + token_width > width) {
            try builder.newline();
            current_prefix = rest_prefix;
            current_prefix_style = rest_prefix_style;
            current_width = unicode.displayWidth(current_prefix);
            first_token_on_line = true;
            if (current_prefix.len != 0) try builder.appendSpan(current_prefix_style, current_prefix);
            if (isWhitespace(token.text)) continue;
        }
        try builder.appendSpan(if (token.style == .body) default_style else token.style, token.text);
        current_width += token_width;
        first_token_on_line = false;
    }
}

pub fn isWhitespace(text: []const u8) bool {
    for (text) |char| if (char != ' ' and char != '\t') return false;
    return text.len != 0;
}

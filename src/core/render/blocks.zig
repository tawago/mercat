const std = @import("std");
const markdown = @import("../markdown.zig");
const highlight = @import("../highlight.zig");
const mermaid = @import("../mermaid/render.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const wrap = @import("wrap.zig");
const table_mod = @import("table.zig");
const unicode = @import("../../lib/unicode.zig");

const Block = markdown.Block;
const Inline = markdown.Inline;
const Options = types.Options;
const SpanStyle = types.SpanStyle;
const Builder = builder_mod.Builder;

pub fn renderBlock(allocator: std.mem.Allocator, builder: *Builder, block: Block, options: Options) !void {
    const content_width = options.width -| options.left_padding;
    switch (block) {
        .heading => |h| try renderHeading(allocator, builder, h, content_width, options.show_heading_markers),
        .paragraph => |inlines| try renderParagraph(allocator, builder, inlines, content_width, .body),
        .unordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, "\u{2022} "),
        .ordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, item.marker),
        .task_list_item => |item| {
            const marker = if (item.checked) "[x] " else "[ ] ";
            try renderTaskItem(allocator, builder, item.content, content_width, marker);
        },
        .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width),
        .html_block => |html| try builder.appendSpan(.muted, html),
        .thematic_break => try builder.appendSpan(.muted, "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}"),
        .table => |table| try table_mod.renderTable(allocator, builder, table, content_width),
        .blockquote => |inlines| try renderBlockQuote(allocator, builder, inlines, content_width),
    }
}

pub fn renderHeading(allocator: std.mem.Allocator, builder: *Builder, heading: Block.Heading, width: usize, show_markers: bool) !void {
    const heading_style: SpanStyle = switch (heading.level) {
        1 => .heading1,
        2 => .heading2,
        3 => .heading3,
        4 => .heading4,
        5 => .heading5,
        else => .heading6,
    };

    if (!show_markers) {
        try wrap.renderWrappedInlines(allocator, builder, heading.content, width, heading_style, "", heading_style, "", heading_style);
        return;
    }
    var prefix_buf: [8]u8 = undefined;
    const prefix_len = @min(heading.level, 6);
    @memset(prefix_buf[0..prefix_len], '#');
    prefix_buf[prefix_len] = ' ';
    const prefix = prefix_buf[0 .. prefix_len + 1];
    try wrap.renderWrappedInlines(allocator, builder, heading.content, width, heading_style, prefix, heading_style, prefix, heading_style);
}

pub fn renderParagraph(allocator: std.mem.Allocator, builder: *Builder, inlines: []const Inline, width: usize, prefix_style: SpanStyle) !void {
    // Split by soft_break/line_break for multi-line paragraphs
    var start: usize = 0;
    for (inlines, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (start > 0) try builder.newline();
                try wrap.renderWrappedInlines(allocator, builder, inlines[start..i], width, .body, "", prefix_style, "", prefix_style);
            }
            start = i + 1;
        }
    }
    if (start < inlines.len) {
        if (start > 0) try builder.newline();
        try wrap.renderWrappedInlines(allocator, builder, inlines[start..], width, .body, "", prefix_style, "", prefix_style);
    } else if (start == 0 and inlines.len == 0) {
        // Empty paragraph
    }
}

pub fn renderListItem(allocator: std.mem.Allocator, builder: *Builder, item: Block.ListItem, width: usize, display_marker: []const u8) !void {
    const continuation = try repeatSpaces(allocator, unicode.displayWidth(display_marker));
    defer allocator.free(continuation);

    // Render main content
    var start: usize = 0;
    var first = true;
    for (item.content, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (!first) try builder.newline();
                const prefix = if (first) display_marker else continuation;
                try wrap.renderWrappedInlines(allocator, builder, item.content[start..i], width, .body, prefix, .muted, continuation, .muted);
                first = false;
            }
            start = i + 1;
        }
    }
    if (start < item.content.len) {
        if (!first) try builder.newline();
        const prefix = if (first) display_marker else continuation;
        try wrap.renderWrappedInlines(allocator, builder, item.content[start..], width, .body, prefix, .muted, continuation, .muted);
    } else if (first and item.content.len == 0) {
        try builder.appendSpan(.muted, display_marker);
    }

    // Render nested items
    for (item.nested) |nested| {
        try builder.newline();
        const nested_indent = try std.fmt.allocPrint(allocator, "  {s}", .{display_marker});
        defer allocator.free(nested_indent);
        switch (nested) {
            .unordered_list_item => |n| try renderListItem(allocator, builder, n, width -| 2, "\u{2022} "),
            .ordered_list_item => |n| try renderListItem(allocator, builder, n, width -| 2, n.marker),
            else => {},
        }
    }
}

pub fn renderTaskItem(allocator: std.mem.Allocator, builder: *Builder, content: []const Inline, width: usize, marker: []const u8) !void {
    const continuation = try repeatSpaces(allocator, unicode.displayWidth(marker));
    defer allocator.free(continuation);

    var start: usize = 0;
    var first = true;
    for (content, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (!first) try builder.newline();
                const prefix = if (first) marker else continuation;
                try wrap.renderWrappedInlines(allocator, builder, content[start..i], width, .body, prefix, .muted, continuation, .muted);
                first = false;
            }
            start = i + 1;
        }
    }
    if (start < content.len) {
        if (!first) try builder.newline();
        const prefix = if (first) marker else continuation;
        try wrap.renderWrappedInlines(allocator, builder, content[start..], width, .body, prefix, .muted, continuation, .muted);
    } else if (first) {
        try builder.appendSpan(.muted, marker);
    }
}

pub fn renderBlockQuote(allocator: std.mem.Allocator, builder: *Builder, inlines: []const Inline, width: usize) !void {
    var start: usize = 0;
    var first = true;
    for (inlines, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (!first) try builder.newline();
                const prefix = if (first) "> " else "  ";
                try wrap.renderWrappedInlines(allocator, builder, inlines[start..i], width, .quote, prefix, .quote, prefix, .quote);
                first = false;
            }
            start = i + 1;
        }
    }
    if (start < inlines.len) {
        if (!first) try builder.newline();
        const prefix = if (first) "> " else "  ";
        try wrap.renderWrappedInlines(allocator, builder, inlines[start..], width, .quote, prefix, .quote, prefix, .quote);
    }
}

pub fn renderCodeBlock(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize) !void {
    // Check if this is a mermaid block
    if (std.mem.eql(u8, code.language, "mermaid")) {
        try renderMermaidBlock(allocator, builder, code.code, content_width);
        return;
    }

    // Render header
    if (code.language.len == 0) {
        try builder.appendSpan(.muted, "```");
    } else {
        const header = try std.fmt.allocPrint(allocator, "```{s}", .{code.language});
        defer allocator.free(header);
        try builder.appendSpan(.muted, header);
    }

    const max_line_width = maxCodeBlockLineWidth(code.code);

    // Render code lines
    var lines = std.mem.splitScalar(u8, code.code, '\n');
    while (lines.next()) |line| {
        try builder.newline();
        const trimmed = std.mem.trimRight(u8, line, "\r");
        const line_width = unicode.displayWidth(trimmed);
        if (trimmed.len == 0) {
            try appendCodeBlockPadding(builder, max_line_width + 2);
            continue;
        }
        try appendCodeBlockPadding(builder, 1);
        const tokens = try highlight.tokenizeLine(allocator, code.language, trimmed);
        defer highlight.freeTokens(allocator, tokens);
        for (tokens) |token| try builder.appendSpan(tokenStyle(token.style), token.text);
        try appendCodeBlockPadding(builder, max_line_width - line_width + 1);
    }

    try builder.newline();
    try builder.appendSpan(.muted, "```");
}

pub fn renderMermaidBlock(allocator: std.mem.Allocator, builder: *Builder, source: []const u8, content_width: usize) !void {
    const result = mermaid.render(allocator, source, .{
        .max_width = @intCast(content_width),
        .unicode_mode = true,
    }) catch {
        try renderCodeBlockFallback(allocator, builder, "mermaid", source);
        return;
    };

    if (result.is_fallback) {
        try renderCodeBlockFallback(allocator, builder, "mermaid", source);
        return;
    }

    defer allocator.free(result.output);

    var diagram_lines = std.mem.splitScalar(u8, result.output, '\n');
    var first = true;
    while (diagram_lines.next()) |line| {
        if (!first) try builder.newline();
        first = false;
        try builder.appendSpan(.code, line);
    }
}

pub fn renderCodeBlockFallback(allocator: std.mem.Allocator, builder: *Builder, language: []const u8, source: []const u8) !void {
    if (language.len == 0) {
        try builder.appendSpan(.muted, "```");
    } else {
        const header = try std.fmt.allocPrint(allocator, "```{s}", .{language});
        defer allocator.free(header);
        try builder.appendSpan(.muted, header);
    }

    const max_line_width = maxCodeBlockLineWidth(source);

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        try builder.newline();
        const trimmed = std.mem.trimRight(u8, line, "\r");
        try appendCodeBlockPadding(builder, 1);
        try builder.appendSpan(.code_block, trimmed);
        try appendCodeBlockPadding(builder, max_line_width - unicode.displayWidth(trimmed) + 1);
    }

    try builder.newline();
    try builder.appendSpan(.muted, "```");
}

fn repeatSpaces(allocator: std.mem.Allocator, count: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, count);
    @memset(buffer, ' ');
    return buffer;
}

fn tokenStyle(style: highlight.TokenStyle) SpanStyle {
    return switch (style) {
        .plain => .code_block,
        .keyword => .code_block_keyword,
        .string => .code_block_string,
        .number => .code_block_number,
        .comment => .code_block_comment,
    };
}

fn maxCodeBlockLineWidth(source: []const u8) usize {
    var max_width: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        max_width = @max(max_width, unicode.displayWidth(trimmed));
    }
    return max_width;
}

fn appendCodeBlockPadding(builder: *Builder, count: usize) !void {
    if (count == 0) return;
    try table_mod.appendSpaces(builder, count, .code_block);
}

pub fn isCompactBlockPair(previous: Block, current: Block) bool {
    const prev_is_list = switch (previous) {
        .unordered_list_item, .ordered_list_item, .task_list_item => true,
        else => false,
    };
    const curr_is_list = switch (current) {
        .unordered_list_item, .ordered_list_item, .task_list_item => true,
        else => false,
    };
    return prev_is_list and curr_is_list;
}

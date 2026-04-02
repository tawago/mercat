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
        .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent),
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
        .blockquote => |bq| try renderBlockQuote(allocator, builder, bq, content_width, options.left_padding),
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

pub fn renderParagraph(allocator: std.mem.Allocator, builder: *Builder, inlines: []const Inline, width: usize, prefix_style: SpanStyle, indent: u8) !void {
    // Create indent prefix if needed
    const indent_prefix = if (indent > 0)
        try repeatSpaces(allocator, indent)
    else
        "";
    defer if (indent > 0) allocator.free(indent_prefix);

    // Split by soft_break/line_break for multi-line paragraphs
    var start: usize = 0;
    for (inlines, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (start > 0) try builder.newline();
                try wrap.renderWrappedInlines(allocator, builder, inlines[start..i], width, .body, indent_prefix, prefix_style, "", prefix_style);
            }
            start = i + 1;
        }
    }
    if (start < inlines.len) {
        if (start > 0) try builder.newline();
        try wrap.renderWrappedInlines(allocator, builder, inlines[start..], width, .body, indent_prefix, prefix_style, "", prefix_style);
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

pub fn renderBlockQuote(allocator: std.mem.Allocator, builder: *Builder, bq: Block.BlockQuote, width: usize, left_padding: usize) !void {
    // Build the prefix with left padding, then stacked "▎" characters (U+258E, 3 bytes UTF-8)
    const prefix_bytes = left_padding + bq.depth * 3 + 1; // left_padding + 3 bytes per "▎" + 1 for space
    const prefix = try allocator.alloc(u8, prefix_bytes);
    defer allocator.free(prefix);

    // Add left padding first
    @memset(prefix[0..left_padding], ' ');

    // Then add the "▎" characters
    for (0..bq.depth) |i| {
        @memcpy(prefix[left_padding + i*3..][0..3], "\u{258E}");
    }
    prefix[left_padding + bq.depth * 3] = ' ';

    const content_width = width -| (prefix.len);

    // Render each block inside the blockquote with the prefix
    var first_block = true;
    for (bq.blocks) |block| {
        if (!first_block) try builder.newline();
        first_block = false;

        // Check if this is a blockquote - nested blockquotes handle their own prefixing
        if (block == .blockquote) {
            const nested_bq = block.blockquote;
            try renderBlockQuote(allocator, builder, nested_bq, width, left_padding);
            continue;
        }

        // Record the starting line count
        const initial_line_count = builder.lines.items.len;

        // Render the block - this adds new lines to builder
        switch (block) {
            .heading => |h| try renderHeading(allocator, builder, h, content_width, true),
            .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent),
            .unordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, "\u{2022} "),
            .ordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, item.marker),
            .task_list_item => |item| {
                const marker = if (item.checked) "[x] " else "[ ] ";
                try renderTaskItem(allocator, builder, item.content, content_width, marker);
            },
            .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width),
            .html_block => |html| try builder.appendSpan(.muted, html),
            .thematic_break => {
                const hr_text = try repeatChar(allocator, content_width);
                defer allocator.free(hr_text);
                try builder.appendSpan(.muted, hr_text);
            },
            .table => |table| try table_mod.renderTable(allocator, builder, table, content_width),
            else => {},
        }

        // Finalize current line if it has content
        if (builder.current.items.len > 0) {
            try builder.newline();
        }

        // Prefix the newly added lines
        const final_line_count = builder.lines.items.len;
        for (initial_line_count..final_line_count) |line_idx| {
            var line = &builder.lines.items[line_idx];

            // Create a new spans array with the blockquote prefix replacing the left padding
            var new_spans: std.ArrayList(types.Span) = .empty;
            defer new_spans.deinit(allocator);

            // Check if the first span is just padding (spaces) - if so, replace it with the blockquote prefix
            const is_padding_span = blk: {
                if (line.spans.len == 0) break :blk false;
                const first_span_text = line.spans[0].text;
                for (first_span_text) |ch| {
                    if (ch != ' ') break :blk false;
                }
                break :blk true;
            };

            if (is_padding_span) {
                // Replace the padding span with the blockquote prefix
                try new_spans.append(allocator, .{ .style = .quote, .text = try allocator.dupe(u8, prefix) });
                // Add remaining spans
                for (line.spans[1..]) |span| {
                    try new_spans.append(allocator, .{ .style = span.style, .text = try allocator.dupe(u8, span.text), .url = if (span.url) |url| try allocator.dupe(u8, url) else null });
                }
            } else {
                // No padding span found, just prepend the blockquote prefix
                try new_spans.append(allocator, .{ .style = .quote, .text = try allocator.dupe(u8, prefix) });
                for (line.spans) |span| {
                    try new_spans.append(allocator, .{ .style = span.style, .text = try allocator.dupe(u8, span.text), .url = if (span.url) |url| try allocator.dupe(u8, url) else null });
                }
            }

            // Free the old spans and assign the new ones
            for (line.spans) |span| {
                allocator.free(span.text);
                if (span.url) |url| allocator.free(url);
            }
            allocator.free(line.spans);
            line.spans = try new_spans.toOwnedSlice(allocator);
        }
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

fn repeatChar(allocator: std.mem.Allocator, count: usize) ![]u8 {
    const dash = "\u{2500}"; // "─" character (3 bytes in UTF-8: E2 94 80)
    const buffer = try allocator.alloc(u8, count * dash.len);
    var offset: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(buffer[offset .. offset + dash.len], dash);
        offset += dash.len;
    }
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

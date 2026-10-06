const std = @import("std");
const markdown = @import("../parser.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const wrap = @import("wrap.zig");
const table_mod = @import("table.zig");
const frontmatter_mod = @import("frontmatter.zig");
const code_mod = @import("code.zig");
const rules = @import("rules.zig");
const geometry = @import("geometry.zig");
const decor_mod = @import("decor.zig");
const html_mod = @import("html.zig");

const Decor = decor_mod.Decor;
const Block = markdown.Block;
const Inline = markdown.Inline;
const Options = types.Options;
const SpanStyle = types.SpanStyle;
const Builder = builder_mod.Builder;
const SubgraphEdges = @import("../../mermaid/mermaid.zig").SubgraphEdges;

fn bulletMarker(allocator: std.mem.Allocator, decor: *const Decor, depth: usize) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ decor.glyphs.bulletAt(depth), " " });
}

fn taskMarker(allocator: std.mem.Allocator, decor: *const Decor, checked: bool) ![]u8 {
    const g = if (checked) decor.glyphs.task_ticked else decor.glyphs.task_unticked;
    return std.mem.concat(allocator, u8, &.{ g, " " });
}

fn orderedMarker(allocator: std.mem.Allocator, decor: *const Decor, base: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ decor.glyphs.ordered_prefix, base });
}

pub fn renderBlock(allocator: std.mem.Allocator, builder: *Builder, block: Block, options: Options) anyerror!void {
    const content_width = options.width -| options.left_padding;
    const decor = options.decor;
    switch (block) {
        .frontmatter => |fm| try frontmatter_mod.render(allocator, builder, fm, content_width, options.frontmatter_style),
        .heading => |h| try renderHeading(allocator, builder, h, content_width, options.show_heading_markers, decor),
        .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent, decor),
        .unordered_list_item => |item| {
            const marker = try bulletMarker(allocator, decor, 0);
            defer allocator.free(marker);
            try renderListItem(allocator, builder, item, content_width, marker, .bullet, 0, decor);
        },
        .ordered_list_item => |item| {
            const marker = try orderedMarker(allocator, decor, item.marker);
            defer allocator.free(marker);
            try renderListItem(allocator, builder, item, content_width, marker, .ordered, 0, decor);
        },
        .task_list_item => |item| {
            const marker = try taskMarker(allocator, decor, item.checked);
            defer allocator.free(marker);
            try renderTaskItem(allocator, builder, item, content_width, marker, decor);
        },
        .fenced_code => |code| try code_mod.render(allocator, builder, code, content_width, options.mermaid_debug, options.mermaid_subgraph_edges, decor),
        .html_block => |html| try html_mod.render(allocator, builder, html, content_width, decor),
        .thematic_break => try rules.renderHr(builder, content_width, decor),
        .table => |table| try table_mod.renderTable(allocator, builder, table, content_width, decor),
        .blockquote => |bq| try renderBlockQuote(allocator, builder, bq, content_width, options.left_padding, decor),
    }
}

pub fn renderHeading(allocator: std.mem.Allocator, builder: *Builder, heading: Block.Heading, width: usize, show_markers: bool, decor: *const Decor) !void {
    const heading_style: SpanStyle = switch (heading.level) {
        1 => .heading1,
        2 => .heading2,
        3 => .heading3,
        4 => .heading4,
        5 => .heading5,
        else => .heading6,
    };

    const sd = decor.headingSlot(heading.level);

    if (sd.blank_wrap) try builder.newline();

    const marker = if (show_markers) sd.prefix else "";
    const prefix = if (sd.shift == 0) blk: {
        break :blk try allocator.dupe(u8, marker);
    } else blk: {
        const pad = try repeatSpaces(allocator, sd.shift);
        defer allocator.free(pad);
        break :blk try std.mem.concat(allocator, u8, &.{ pad, marker });
    };
    defer allocator.free(prefix);

    try wrap.renderWrappedInlines(allocator, builder, heading.content, width, heading_style, prefix, heading_style, prefix, heading_style, decor);

    if (sd.underline_row) {
        try builder.newline();
        try rules.renderUnderlineRow(builder, width, heading_style, sd.underline_glyph);
    }
}

pub fn renderParagraph(allocator: std.mem.Allocator, builder: *Builder, inlines: []const Inline, width: usize, prefix_style: SpanStyle, indent: u8, decor: *const Decor) !void {
    const indent_prefix = if (indent > 0)
        try repeatSpaces(allocator, indent)
    else
        "";
    defer if (indent > 0) allocator.free(indent_prefix);

    var start: usize = 0;
    for (inlines, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (start > 0) try builder.newline();
                try wrap.renderWrappedInlines(allocator, builder, inlines[start..i], width, .body, indent_prefix, prefix_style, "", prefix_style, decor);
            }
            start = i + 1;
        }
    }
    if (start < inlines.len) {
        if (start > 0) try builder.newline();
        try wrap.renderWrappedInlines(allocator, builder, inlines[start..], width, .body, indent_prefix, prefix_style, "", prefix_style, decor);
    }
}

pub fn renderListItem(allocator: std.mem.Allocator, builder: *Builder, item: Block.ListItem, width: usize, display_marker: []const u8, marker_style: SpanStyle, depth: u8, decor: *const Decor) anyerror!void {
    const indent_count = @as(usize, depth) * 2;
    const indent = try repeatSpaces(allocator, indent_count);
    defer allocator.free(indent);

    const first_prefix = try std.mem.concat(allocator, u8, &.{ indent, display_marker });
    defer allocator.free(first_prefix);

    const continuation_spaces = try repeatSpaces(allocator, try geometry.displayWidth(display_marker));
    defer allocator.free(continuation_spaces);

    const continuation = try std.mem.concat(allocator, u8, &.{ indent, continuation_spaces });
    defer allocator.free(continuation);

    var start: usize = 0;
    var first = true;
    for (item.content, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (!first) try builder.newline();
                const prefix = if (first) first_prefix else continuation;
                const pstyle: SpanStyle = if (first) marker_style else .body;
                try wrap.renderWrappedInlines(allocator, builder, item.content[start..i], width, pstyle, prefix, .body, continuation, .list_item, decor);
                first = false;
            }
            start = i + 1;
        }
    }
    if (start < item.content.len) {
        if (!first) try builder.newline();
        const prefix = if (first) first_prefix else continuation;
        const pstyle: SpanStyle = if (first) marker_style else .body;
        try wrap.renderWrappedInlines(allocator, builder, item.content[start..], width, pstyle, prefix, .body, continuation, .list_item, decor);
    } else if (first and item.content.len == 0) {
        try builder.appendSpan(marker_style, first_prefix);
    }

    for (item.nested) |nested| {
        if (try rendersNothing(allocator, nested)) continue;
        try builder.newline();
        switch (nested) {
            .unordered_list_item => |n| {
                const nested_bullet = try bulletMarker(allocator, decor, depth + 1);
                defer allocator.free(nested_bullet);
                try renderListItem(allocator, builder, n, width, nested_bullet, .bullet, depth + 1, decor);
            },
            .ordered_list_item => |n| {
                const nested_marker = try orderedMarker(allocator, decor, n.marker);
                defer allocator.free(nested_marker);
                try renderListItem(allocator, builder, n, width, nested_marker, .ordered, depth + 1, decor);
            },
            // Sibling lists step in by depth; task items match them.
            .task_list_item => try renderIndentedBlock(allocator, builder, nested, width, indent_count + 2, decor),
            else => try renderIndentedBlock(allocator, builder, nested, width, try geometry.displayWidth(continuation), decor),
        }
    }
}

/// Renders a list item's child block (paragraph, code, quote, table, HTML,
/// task item, ...) under the item's text column, `indent` columns in. The
/// block is laid out in a scratch builder whose left padding reaches that
/// column, so width and tab math see the real origin, then moved over
/// verbatim, its last line left pending. The builder must be at the start of
/// a line.
fn renderIndentedBlock(allocator: std.mem.Allocator, builder: *Builder, block: Block, width: usize, indent: usize, decor: *const Decor) anyerror!void {
    var scratch = Builder.init(allocator);
    defer scratch.deinit();
    const origin = builder.left_padding + indent;
    scratch.left_padding = origin;
    try renderBlock(allocator, &scratch, block, .{
        .width = origin + (width -| indent),
        .left_padding = origin,
        .decor = decor,
    });
    // Keep the last line open even when the block closed it (block quotes
    // do), so the item's next child follows without a stray blank line.
    _ = try scratch.seal();
    try builder.absorb(&scratch, true);
}

pub fn renderTaskItem(allocator: std.mem.Allocator, builder: *Builder, item: Block.TaskItem, width: usize, marker: []const u8, decor: *const Decor) anyerror!void {
    const content = item.content;
    const marker_style: SpanStyle = if (item.checked) .task_on else .task_off;
    const continuation = try repeatSpaces(allocator, try geometry.displayWidth(marker));
    defer allocator.free(continuation);

    var start: usize = 0;
    var first = true;
    for (content, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (!first) try builder.newline();
                const prefix = if (first) marker else continuation;
                const pstyle: SpanStyle = if (first) marker_style else .body;
                try wrap.renderWrappedInlines(allocator, builder, content[start..i], width, pstyle, prefix, .body, continuation, .list_item, decor);
                first = false;
            }
            start = i + 1;
        }
    }
    if (start < content.len) {
        if (!first) try builder.newline();
        const prefix = if (first) marker else continuation;
        const pstyle: SpanStyle = if (first) marker_style else .body;
        try wrap.renderWrappedInlines(allocator, builder, content[start..], width, pstyle, prefix, .body, continuation, .list_item, decor);
    } else if (first) {
        try builder.appendSpan(marker_style, marker);
    }

    for (item.nested) |nested| {
        if (try rendersNothing(allocator, nested)) continue;
        try builder.newline();
        try renderIndentedBlock(allocator, builder, nested, width, continuation.len, decor);
    }
}

pub fn renderBlockQuote(allocator: std.mem.Allocator, builder: *Builder, bq: Block.BlockQuote, width: usize, left_padding: usize, decor: *const Decor) anyerror!void {
    var prefix_buf: std.ArrayList(u8) = .empty;
    defer prefix_buf.deinit(allocator);
    try prefix_buf.appendNTimes(allocator, ' ', left_padding);
    try appendQuotePrefix(allocator, &prefix_buf, decor, bq.depth);
    const prefix = prefix_buf.items;

    const content_width = width -| try geometry.displayWidth(prefix);
    const quote_start = builder.lines.items.len;

    var first_block = true;
    for (bq.blocks) |block| {
        if (try rendersNothing(allocator, block)) continue;
        if (!first_block) try builder.newline();
        first_block = false;

        if (block == .blockquote) {
            const nested_bq = block.blockquote;
            try renderBlockQuote(allocator, builder, nested_bq, width, left_padding, decor);
            continue;
        }

        const initial_line_count = builder.lines.items.len;

        switch (block) {
            .heading => |h| try renderHeading(allocator, builder, h, content_width, true, decor),
            .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent, decor),
            .unordered_list_item => |item| {
                const marker = try bulletMarker(allocator, decor, 0);
                defer allocator.free(marker);
                try renderListItem(allocator, builder, item, content_width, marker, .bullet, 0, decor);
            },
            .ordered_list_item => |item| {
                const marker = try orderedMarker(allocator, decor, item.marker);
                defer allocator.free(marker);
                try renderListItem(allocator, builder, item, content_width, marker, .ordered, 0, decor);
            },
            .task_list_item => |item| {
                const marker = try taskMarker(allocator, decor, item.checked);
                defer allocator.free(marker);
                try renderTaskItem(allocator, builder, item, content_width, marker, decor);
            },
            .fenced_code => |code| try code_mod.render(allocator, builder, code, content_width, false, .bridge, decor),
            .html_block => |html| try html_mod.render(allocator, builder, html, content_width, decor),
            .thematic_break => try rules.renderHr(builder, content_width, decor),
            .table => |table| try table_mod.renderTable(allocator, builder, table, content_width, decor),
            else => {},
        }

        if (builder.hasPending()) {
            try builder.newline();
        }

        const final_line_count = builder.lines.items.len;
        for (initial_line_count..final_line_count) |line_idx| {
            var line = &builder.lines.items[line_idx];

            var new_spans: std.ArrayList(types.Span) = .empty;
            defer new_spans.deinit(allocator);

            // The prefix already holds the left padding, so drop the builder's
            // own padding from the line. That padding is a leading run of
            // spaces in the first span when it is body-styled (it merges
            // with body text that follows it).
            try new_spans.append(allocator, .{ .style = .quote, .text = try allocator.dupe(u8, prefix) });
            for (line.spans, 0..) |span, span_index| {
                var text = span.text;
                if (span_index == 0 and span.style == .body) {
                    var strip: usize = 0;
                    while (strip < builder.left_padding and strip < text.len and text[strip] == ' ') strip += 1;
                    text = text[strip..];
                    if (text.len == 0) continue;
                }
                try new_spans.append(allocator, .{ .style = span.style, .text = try allocator.dupe(u8, text), .url = if (span.url) |url| try allocator.dupe(u8, url) else null });
            }

            for (line.spans) |span| {
                allocator.free(span.text);
                if (span.url) |url| allocator.free(url);
            }
            allocator.free(line.spans);
            line.spans = try new_spans.toOwnedSlice(allocator);
        }
    }
    // Each child closed its last line for prefixing; reopen the final one
    // so the quote ends like any block and is not followed by a blank line.
    // (Nested quotes keep the closed line: it separates them from the
    // enclosing quote's next block.)
    if (bq.depth == 1 and !builder.hasPending() and builder.lines.items.len > quote_start) builder.reopenLastLine();
}

/// True for a block with nothing to show (an HTML block holding only a
/// comment or a closing wrapper tag); containers skip it entirely.
pub fn rendersNothing(allocator: std.mem.Allocator, block: Block) !bool {
    return switch (block) {
        .html_block => |html| try html_mod.isEmpty(allocator, html),
        else => false,
    };
}

fn repeatSpaces(allocator: std.mem.Allocator, count: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, count);
    @memset(buffer, ' ');
    return buffer;
}

fn appendQuotePrefix(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), decor: *const Decor, depth: usize) !void {
    const bar = std.mem.trimRight(u8, decor.glyphs.quote_bar, " ");
    if (bar.len == 0) {
        try buf.appendNTimes(allocator, ' ', decor.glyphs.quote_indent);
        return;
    }
    var i: usize = 0;
    while (i < depth) : (i += 1) try buf.appendSlice(allocator, bar);
    try buf.append(allocator, ' ');
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

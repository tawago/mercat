const std = @import("std");
const markdown = @import("../parser.zig");
const mermaid_types = @import("../../mermaid/types.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const wrap = @import("wrap.zig");
const table_mod = @import("table.zig");
const frontmatter_mod = @import("frontmatter.zig");
const code_mod = @import("code.zig");
const rules = @import("rules.zig");
const geometry = @import("geometry.zig");
const decor_mod = @import("decor.zig");

const Decor = decor_mod.Decor;
const Block = markdown.Block;
const Inline = markdown.Inline;
const Options = types.Options;
const SpanStyle = types.SpanStyle;
const Builder = builder_mod.Builder;
const BoxDrawingStyle = mermaid_types.BoxDrawingStyle;
const CrossingReductionHeuristic = mermaid_types.CrossingReductionHeuristic;
const ForceLayout = mermaid_types.ForceLayout;
const SubgraphEdges = @import("prim").SubgraphEdges;

/// A list bullet marker for `depth`, e.g. "• " — glyph from decor + one space.
/// Caller owns the returned slice.
fn bulletMarker(allocator: std.mem.Allocator, decor: *const Decor, depth: usize) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ decor.glyphs.bulletAt(depth), " " });
}

/// A task-list marker, e.g. "[x] " — glyph from decor + one space.
fn taskMarker(allocator: std.mem.Allocator, decor: *const Decor, checked: bool) ![]u8 {
    const g = if (checked) decor.glyphs.task_ticked else decor.glyphs.task_unticked;
    return std.mem.concat(allocator, u8, &.{ g, " " });
}

/// An ordered-list marker: the decor's leading pad + the parsed "N." marker.
fn orderedMarker(allocator: std.mem.Allocator, decor: *const Decor, base: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ decor.glyphs.ordered_prefix, base });
}

pub fn renderBlock(allocator: std.mem.Allocator, builder: *Builder, block: Block, options: Options) !void {
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
            try renderTaskItem(allocator, builder, item.content, content_width, marker, if (item.checked) .task_on else .task_off, decor);
        },
        .fenced_code => |code| try code_mod.render(allocator, builder, code, content_width, options.mermaid_box_style, options.mermaid_crossing_heuristic, options.mermaid_force_layout, options.mermaid_aspect_ratio, options.mermaid_debug, options.mermaid_subgraph_edges, decor),
        .html_block => |html| try builder.appendSpan(.muted, html),
        .thematic_break => try rules.renderHr(allocator, builder, content_width, decor),
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
        try rules.renderUnderlineRow(allocator, builder, width, heading_style, sd.underline_glyph);
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
    } else if (start == 0 and inlines.len == 0) {}
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
            .blockquote => |bq| try renderBlockQuoteWithPrefix(allocator, builder, bq, width -| try geometry.displayWidth(continuation), continuation, decor),
            else => {},
        }
    }
}

pub fn renderTaskItem(allocator: std.mem.Allocator, builder: *Builder, content: []const Inline, width: usize, marker: []const u8, marker_style: SpanStyle, decor: *const Decor) !void {
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
}

pub fn renderBlockQuote(allocator: std.mem.Allocator, builder: *Builder, bq: Block.BlockQuote, width: usize, left_padding: usize, decor: *const Decor) !void {
    var prefix_buf: std.ArrayList(u8) = .empty;
    defer prefix_buf.deinit(allocator);
    try prefix_buf.appendNTimes(allocator, ' ', left_padding);
    try appendQuotePrefix(allocator, &prefix_buf, decor, bq.depth);
    const prefix = prefix_buf.items;

    const content_width = width -| try geometry.displayWidth(prefix);

    var first_block = true;
    for (bq.blocks) |block| {
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
                try renderTaskItem(allocator, builder, item.content, content_width, marker, if (item.checked) .task_on else .task_off, decor);
            },
            .fenced_code => |code| try code_mod.render(allocator, builder, code, content_width, .standard, .median, .auto, 1.0, false, .bridge, decor),
            .html_block => |html| try builder.appendSpan(.muted, html),
            .thematic_break => try rules.renderHr(allocator, builder, content_width, decor),
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

            const is_padding_span = blk: {
                if (line.spans.len == 0) break :blk false;
                const first_span_text = line.spans[0].text;
                for (first_span_text) |ch| {
                    if (ch != ' ') break :blk false;
                }
                break :blk true;
            };

            if (is_padding_span) {
                try new_spans.append(allocator, .{ .style = .quote, .text = try allocator.dupe(u8, prefix) });
                for (line.spans[1..]) |span| {
                    try new_spans.append(allocator, .{ .style = span.style, .text = try allocator.dupe(u8, span.text), .url = if (span.url) |url| try allocator.dupe(u8, url) else null });
                }
            } else {
                try new_spans.append(allocator, .{ .style = .quote, .text = try allocator.dupe(u8, prefix) });
                for (line.spans) |span| {
                    try new_spans.append(allocator, .{ .style = span.style, .text = try allocator.dupe(u8, span.text), .url = if (span.url) |url| try allocator.dupe(u8, url) else null });
                }
            }

            for (line.spans) |span| {
                allocator.free(span.text);
                if (span.url) |url| allocator.free(url);
            }
            allocator.free(line.spans);
            line.spans = try new_spans.toOwnedSlice(allocator);
            try line.reprepareOwned(allocator);
        }
    }
}

/// Renders a blockquote with a custom base prefix (for blockquotes inside list items)
pub fn renderBlockQuoteWithPrefix(allocator: std.mem.Allocator, builder: *Builder, bq: Block.BlockQuote, width: usize, base_prefix: []const u8, decor: *const Decor) anyerror!void {
    var prefix_buf: std.ArrayList(u8) = .empty;
    defer prefix_buf.deinit(allocator);
    try prefix_buf.appendSlice(allocator, base_prefix);
    const bar_len_start = prefix_buf.items.len;
    try appendQuotePrefix(allocator, &prefix_buf, decor, bq.depth);
    const prefix = prefix_buf.items;

    const content_width = width -| try geometry.displayWidth(prefix_buf.items[bar_len_start..]);

    var first_block = true;
    for (bq.blocks) |block| {
        if (!first_block) try builder.newline();
        first_block = false;

        if (block == .blockquote) {
            const nested_bq = block.blockquote;
            try renderBlockQuoteWithPrefix(allocator, builder, nested_bq, width, base_prefix, decor);
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
            .fenced_code => |code| try code_mod.render(allocator, builder, code, content_width, .standard, .median, .auto, 1.0, false, .bridge, decor),
            .html_block => |html| try builder.appendSpan(.muted, html),
            .thematic_break => try rules.renderHr(allocator, builder, content_width, decor),
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

            try new_spans.append(allocator, .{ .style = .quote, .text = try allocator.dupe(u8, prefix) });
            for (line.spans) |span| {
                try new_spans.append(allocator, .{ .style = span.style, .text = try allocator.dupe(u8, span.text), .url = if (span.url) |url| try allocator.dupe(u8, url) else null });
            }

            for (line.spans) |span| {
                allocator.free(span.text);
                if (span.url) |url| allocator.free(url);
            }
            allocator.free(line.spans);
            line.spans = try new_spans.toOwnedSlice(allocator);
            try line.reprepareOwned(allocator);
        }
    }
}

fn repeatSpaces(allocator: std.mem.Allocator, count: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, count);
    @memset(buffer, ' ');
    return buffer;
}

/// Append a blockquote bar prefix: `depth` copies of the decor quote-bar glyph
/// (trailing space trimmed so stacking is clean) plus one trailing space; or,
/// when the theme carries no bar, a flat `quote_indent` indent (dracula).
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

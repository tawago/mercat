const std = @import("std");
const markdown = @import("../markdown.zig");
const highlight = @import("../highlight.zig");
const mermaid = @import("../mermaid/render.zig");
const mermaid_types = @import("../mermaid/types.zig");
const types = @import("types.zig");
const builder_mod = @import("builder.zig");
const wrap = @import("wrap.zig");
const table_mod = @import("table.zig");
const frontmatter_mod = @import("frontmatter.zig");
const unicode = @import("../../lib/unicode.zig");
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
const FitStage = mermaid_types.FitStage;

const bullet_shapes = [_][]const u8{ "\u{2022} ", "\u{25E6} ", "\u{2023} " };
// • (bullet), ◦ (white bullet), ‣ (triangular bullet)

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
        .frontmatter => |fm| try frontmatter_mod.render(allocator, builder, fm, content_width, options.frontmatter_style, options.for_export),
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
        .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, options.mermaid_box_style, options.mermaid_crossing_heuristic, options.mermaid_force_layout, options.mermaid_aspect_ratio, options.mermaid_debug, options.mermaid_subgraph_edges, decor),
        .html_block => |html| try builder.appendSpan(.muted, html),
        .thematic_break => try renderHr(allocator, builder, content_width, decor),
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

    // `blank_wrap` (pink h1): the heading owns a blank line instead of a marker.
    if (sd.blank_wrap) try builder.newline();

    // Per-slot cumulative indent (markview headings) is emitted as leading
    // heading-styled spaces so a full-line bg tints them too. The marker prefix
    // (empty when markers are suppressed) follows the indent.
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

    // Optional per-heading underline row: one extra row directly below the last
    // wrapped line, filled edge-to-edge with the slot's glyph in the heading's
    // own style (fg + bg). A space glyph acts as a padding row; "─"/"═" as a
    // setext-style rule. `newline` flushes the (last) heading line so the row
    // lands below it; the block loop then flushes the row itself.
    if (sd.underline_row) {
        try builder.newline();
        try renderUnderlineRow(allocator, builder, width, heading_style, sd.underline_glyph);
    }
}

/// Fill one row with `glyph` repeated to `width` columns (truncated at width,
/// like the full-mode hr), styled with the heading slot's own style.
fn renderUnderlineRow(allocator: std.mem.Allocator, builder: *Builder, width: usize, style: SpanStyle, glyph: []const u8) !void {
    if (width == 0 or glyph.len == 0) return;
    const glyph_w = @max(unicode.displayWidth(glyph), 1);
    const count = width / glyph_w;
    if (count == 0) return;
    const text = try repeatGlyph(allocator, glyph, count);
    defer allocator.free(text);
    try builder.appendSpan(style, text);
}

pub fn renderParagraph(allocator: std.mem.Allocator, builder: *Builder, inlines: []const Inline, width: usize, prefix_style: SpanStyle, indent: u8, decor: *const Decor) !void {
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
                try wrap.renderWrappedInlines(allocator, builder, inlines[start..i], width, .body, indent_prefix, prefix_style, "", prefix_style, decor);
            }
            start = i + 1;
        }
    }
    if (start < inlines.len) {
        if (start > 0) try builder.newline();
        try wrap.renderWrappedInlines(allocator, builder, inlines[start..], width, .body, indent_prefix, prefix_style, "", prefix_style, decor);
    } else if (start == 0 and inlines.len == 0) {
        // Empty paragraph
    }
}

pub fn renderListItem(allocator: std.mem.Allocator, builder: *Builder, item: Block.ListItem, width: usize, display_marker: []const u8, marker_style: SpanStyle, depth: u8, decor: *const Decor) anyerror!void {
    const indent_count = @as(usize, depth) * 2;
    const indent = try repeatSpaces(allocator, indent_count);
    defer allocator.free(indent);

    const first_prefix = try std.mem.concat(allocator, u8, &.{ indent, display_marker });
    defer allocator.free(first_prefix);

    const continuation_spaces = try repeatSpaces(allocator, unicode.displayWidth(display_marker));
    defer allocator.free(continuation_spaces);

    const continuation = try std.mem.concat(allocator, u8, &.{ indent, continuation_spaces });
    defer allocator.free(continuation);

    // Render main content
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

    // Render nested items
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
            .blockquote => |bq| try renderBlockQuoteWithPrefix(allocator, builder, bq, width -| unicode.displayWidth(continuation), continuation, decor),
            else => {},
        }
    }
}

pub fn renderTaskItem(allocator: std.mem.Allocator, builder: *Builder, content: []const Inline, width: usize, marker: []const u8, marker_style: SpanStyle, decor: *const Decor) !void {
    const continuation = try repeatSpaces(allocator, unicode.displayWidth(marker));
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
    // Build the prefix: left padding, then a per-depth quote bar (from decor) +
    // one trailing space, or — when the theme carries no bar (dracula) — a flat
    // `quote_indent` indent.
    var prefix_buf: std.ArrayList(u8) = .empty;
    defer prefix_buf.deinit(allocator);
    try prefix_buf.appendNTimes(allocator, ' ', left_padding);
    try appendQuotePrefix(allocator, &prefix_buf, decor, bq.depth);
    const prefix = prefix_buf.items;

    const content_width = width -| (prefix.len);

    // Render each block inside the blockquote with the prefix
    var first_block = true;
    for (bq.blocks) |block| {
        if (!first_block) try builder.newline();
        first_block = false;

        // Check if this is a blockquote - nested blockquotes handle their own prefixing
        if (block == .blockquote) {
            const nested_bq = block.blockquote;
            try renderBlockQuote(allocator, builder, nested_bq, width, left_padding, decor);
            continue;
        }

        // Record the starting line count
        const initial_line_count = builder.lines.items.len;

        // Render the block - this adds new lines to builder
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
            .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, .standard, .median, .auto, 1.0, false, .bridge, decor),
            .html_block => |html| try builder.appendSpan(.muted, html),
            .thematic_break => try renderHr(allocator, builder, content_width, decor),
            .table => |table| try table_mod.renderTable(allocator, builder, table, content_width, decor),
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

/// Renders a blockquote with a custom base prefix (for blockquotes inside list items)
pub fn renderBlockQuoteWithPrefix(allocator: std.mem.Allocator, builder: *Builder, bq: Block.BlockQuote, width: usize, base_prefix: []const u8, decor: *const Decor) anyerror!void {
    // Build the prefix: base_prefix + per-depth quote bar (from decor) + space.
    var prefix_buf: std.ArrayList(u8) = .empty;
    defer prefix_buf.deinit(allocator);
    try prefix_buf.appendSlice(allocator, base_prefix);
    const bar_len_start = prefix_buf.items.len;
    try appendQuotePrefix(allocator, &prefix_buf, decor, bq.depth);
    const prefix = prefix_buf.items;

    const content_width = width -| (prefix_buf.items.len - bar_len_start);

    // Render each block inside the blockquote
    var first_block = true;
    for (bq.blocks) |block| {
        if (!first_block) try builder.newline();
        first_block = false;

        if (block == .blockquote) {
            const nested_bq = block.blockquote;
            try renderBlockQuoteWithPrefix(allocator, builder, nested_bq, width, base_prefix, decor);
            continue;
        }

        // Record the starting line count
        const initial_line_count = builder.lines.items.len;

        // Render the block
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
            .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, .standard, .median, .auto, 1.0, false, .bridge, decor),
            .html_block => |html| try builder.appendSpan(.muted, html),
            .thematic_break => try renderHr(allocator, builder, content_width, decor),
            else => {},
        }

        // Finalize current line
        if (builder.current.items.len > 0) {
            try builder.newline();
        }

        // Prefix the newly added lines
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
        }
    }
}

pub fn renderCodeBlock(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, box_style: BoxDrawingStyle, crossing_heuristic: CrossingReductionHeuristic, force_layout: ForceLayout, aspect_ratio: f32, debug_mermaid: bool, subgraph_edges: SubgraphEdges, decor: *const Decor) !void {
    // Check if this is a mermaid block
    if (std.mem.eql(u8, code.language, "mermaid")) {
        try renderMermaidBlock(allocator, builder, code.code, content_width, box_style, crossing_heuristic, force_layout, aspect_ratio, debug_mermaid, subgraph_edges);
        return;
    }

    const frame = decor.glyphs.code_frame;
    switch (frame.kind) {
        .panel => try renderCodePanel(allocator, builder, code, frame),
        .plain => try renderCodePlain(allocator, builder, code),
        .rule => try renderCodeRule(allocator, builder, code, content_width, frame),
        .block => try renderCodeFramedBlock(allocator, builder, code, content_width, frame),
    }
}

/// The historical fenced-code rendering: a ```lang header/footer and each line
/// left-padded and right-padded to `max_line_width` so the code_block bg tints
/// a clean panel. `pad` widens the left gutter (dracula/tokyo pad=2). With the
/// default `pad = null` this is byte-identical to the pre-theme renderer.
fn renderCodePanel(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, frame: decor_mod.CodeFrameSpec) !void {
    const left_pad: usize = 1 + @as(usize, frame.pad orelse 0);
    if (code.language.len == 0) {
        try builder.appendSpan(.muted, "```");
    } else {
        const header = try std.fmt.allocPrint(allocator, "```{s}", .{code.language});
        defer allocator.free(header);
        try builder.appendSpan(.muted, header);
    }

    const max_line_width = maxCodeBlockLineWidth(code.code);

    var lines = std.mem.splitScalar(u8, code.code, '\n');
    while (lines.next()) |line| {
        try builder.newline();
        const trimmed = std.mem.trimRight(u8, line, "\r");
        const line_width = unicode.displayWidth(trimmed);
        if (trimmed.len == 0) {
            try appendCodeBlockPadding(builder, left_pad + max_line_width + 1);
            continue;
        }
        try appendCodeBlockPadding(builder, left_pad);
        const tokens = try highlight.tokenizeLine(allocator, code.language, trimmed);
        defer highlight.freeTokens(allocator, tokens);
        for (tokens) |token| try builder.appendSpan(tokenStyle(token.style), token.text);
        try appendCodeBlockPadding(builder, max_line_width - line_width + 1);
    }

    try builder.newline();
    try builder.appendSpan(.muted, "```");
}

/// Plain code frame (pink): highlighted code lines only — no fences, no bg fill.
fn renderCodePlain(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock) !void {
    var lines = std.mem.splitScalar(u8, code.code, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try builder.newline();
        first = false;
        const trimmed = std.mem.trimRight(u8, line, "\r");
        try appendCodeBlockPadding(builder, 1);
        const tokens = try highlight.tokenizeLine(allocator, code.language, trimmed);
        defer highlight.freeTokens(allocator, tokens);
        for (tokens) |token| try builder.appendSpan(tokenStyle(token.style), token.text);
    }
}

/// Rule code frame (ansi): a top and bottom border rule (border_glyph capped at
/// border_cap, clamped to width) bracketing highlighted code lines. The rule is
/// drawn in the muted style; `rule_color` is not honored as an arbitrary color
/// because the render model is style-keyed, not color-keyed (see task notes).
fn renderCodeRule(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, frame: decor_mod.CodeFrameSpec) !void {
    const glyph = frame.border_glyph orelse "\u{2500}";
    const glyph_w = @max(unicode.displayWidth(glyph), 1);
    const cap: usize = if (frame.border_cap) |c| c else content_width;
    const count = @min(cap, content_width / glyph_w);
    try appendRule(allocator, builder, glyph, count);

    var lines = std.mem.splitScalar(u8, code.code, '\n');
    while (lines.next()) |line| {
        try builder.newline();
        const trimmed = std.mem.trimRight(u8, line, "\r");
        try appendCodeBlockPadding(builder, 1);
        const tokens = try highlight.tokenizeLine(allocator, code.language, trimmed);
        defer highlight.freeTokens(allocator, tokens);
        for (tokens) |token| try builder.appendSpan(tokenStyle(token.style), token.text);
    }

    try builder.newline();
    try appendRule(allocator, builder, glyph, count);
}

/// Block code frame (markview): an optional language-label chip, then each line
/// padded to the full content width so the code_block bg reads as a solid slab.
fn renderCodeFramedBlock(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, frame: decor_mod.CodeFrameSpec) !void {
    const left_pad: usize = 1 + @as(usize, frame.pad orelse 0);
    if (frame.language_label and code.language.len != 0) {
        const chip = try std.fmt.allocPrint(allocator, " {s} ", .{code.language});
        defer allocator.free(chip);
        try builder.appendSpan(.muted, chip);
        try builder.newline();
    }
    var lines = std.mem.splitScalar(u8, code.code, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try builder.newline();
        first = false;
        const trimmed = std.mem.trimRight(u8, line, "\r");
        const line_width = unicode.displayWidth(trimmed);
        try appendCodeBlockPadding(builder, left_pad);
        const tokens = try highlight.tokenizeLine(allocator, code.language, trimmed);
        defer highlight.freeTokens(allocator, tokens);
        for (tokens) |token| try builder.appendSpan(tokenStyle(token.style), token.text);
        try appendCodeBlockPadding(builder, content_width -| (left_pad + line_width));
    }
}

fn appendRule(allocator: std.mem.Allocator, builder: *Builder, glyph: []const u8, count: usize) !void {
    if (count == 0) return;
    const text = try repeatGlyph(allocator, glyph, count);
    defer allocator.free(text);
    try builder.appendSpan(.muted, text);
}

pub fn renderMermaidBlock(allocator: std.mem.Allocator, builder: *Builder, source: []const u8, content_width: usize, box_style: BoxDrawingStyle, crossing_heuristic: CrossingReductionHeuristic, force_layout: ForceLayout, aspect_ratio: f32, debug_mermaid: bool, subgraph_edges: SubgraphEdges) !void {
    const result = mermaid.render(allocator, source, .{
        .max_width = @intCast(content_width),
        .unicode_mode = true,
        .box_drawing_style = box_style,
        .crossing_reduction_heuristic = crossing_heuristic,
        .force_layout = force_layout,
        .aspect_ratio_x = aspect_ratio,
        .debug_mermaid = debug_mermaid,
        .subgraph_edges = subgraph_edges,
    }) catch {
        try renderCodeBlockFallback(allocator, builder, "mermaid", source);
        return;
    };

    if (result.is_fallback) {
        // A pipeline error (parse/layout/raster/paint) is a renderer bug,
        // not an "unsupported diagram". Surface it with a visible banner so
        // a silent raw-DSL echo can never masquerade as a clean render. We
        // still print the source below the banner so no information is lost.
        // Genuinely unsupported diagram types keep the bare fence (no
        // banner) — those are an expected, non-buggy passthrough.
        if (result.fallback_reason) |reason| {
            if (std.mem.startsWith(u8, reason, "v2 ")) {
                const banner = try std.fmt.allocPrint(allocator, "<PARSE ERROR: {s}>", .{reason});
                defer allocator.free(banner);
                try builder.appendSpan(.muted, banner);
                try builder.newline();
            }
        }
        try renderCodeBlockFallback(allocator, builder, "mermaid", source);
        return;
    }

    defer allocator.free(result.output);

    if (debug_mermaid) {
        const algo_name = switch (result.algorithm_used) {
            .sugiyama => "Sugiyama",
            .reingold_tilford => "Reingold-Tilford",
            .fruchterman_reingold => "Fruchterman-Reingold",
            .kamada_kawai => "Kamada-Kawai",
            .stress_majorization => "Stress Majorization",
            .dominance_drawing => "Dominance Drawing",
            .layered_bfs => "Layered BFS",
            .unknown => "Unknown",
        };
        try builder.appendSpan(.muted, "---debug-mermaid---");
        try builder.newline();
        const algo_line = try std.fmt.allocPrint(allocator, "Algorithm: {s}", .{algo_name});
        defer allocator.free(algo_line);
        try builder.appendSpan(.muted, algo_line);
        try builder.newline();
        const nodes_line = try std.fmt.allocPrint(allocator, "Nodes: {d}", .{result.node_count});
        defer allocator.free(nodes_line);
        try builder.appendSpan(.muted, nodes_line);
        try builder.newline();
        const edges_line = try std.fmt.allocPrint(allocator, "Edges: {d}", .{result.edge_count});
        defer allocator.free(edges_line);
        try builder.appendSpan(.muted, edges_line);
        try builder.newline();
        const tree_line = try std.fmt.allocPrint(allocator, "Tree detected: {s}", .{if (result.is_tree) "yes" else "no"});
        defer allocator.free(tree_line);
        try builder.appendSpan(.muted, tree_line);
        try builder.newline();
        const cyclic_line = try std.fmt.allocPrint(allocator, "Cyclic: {s}", .{if (result.is_cyclic) "yes" else "no"});
        defer allocator.free(cyclic_line);
        try builder.appendSpan(.muted, cyclic_line);
        try builder.newline();
        const width_line = try std.fmt.allocPrint(allocator, "Width constraint triggered: {s}", .{if (result.width_constraint_triggered) "yes" else "no"});
        defer allocator.free(width_line);
        try builder.appendSpan(.muted, width_line);
        try builder.newline();
        if (result.fit_stage != .natural) {
            const fit_line = try std.fmt.allocPrint(allocator, "Fit stage: {s}", .{result.fit_stage.description()});
            defer allocator.free(fit_line);
            try builder.appendSpan(.muted, fit_line);
            try builder.newline();
        }
        if (result.original_direction) |orig_dir| {
            const dir_name = switch (orig_dir) {
                .TD => "TD",
                .TB => "TB",
                .LR => "LR",
                .RL => "RL",
                .BT => "BT",
            };
            const dir_line = try std.fmt.allocPrint(allocator, "Original direction: {s} (switched for width)", .{dir_name});
            defer allocator.free(dir_line);
            try builder.appendSpan(.muted, dir_line);
            try builder.newline();
        }
        if (result.crossing_reduction_iterations > 0) {
            const cr_line = try std.fmt.allocPrint(allocator, "Crossing reduction iterations: {d}", .{result.crossing_reduction_iterations});
            defer allocator.free(cr_line);
            try builder.appendSpan(.muted, cr_line);
            try builder.newline();
        }
        try builder.appendSpan(.muted, "---debug-mermaid---");
        try builder.newline();
    }

    // Mermaid diagrams handle their own layout - disable left_padding
    const saved_padding = builder.left_padding;
    builder.left_padding = 0;
    defer builder.left_padding = saved_padding;

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

fn repeatGlyph(allocator: std.mem.Allocator, glyph: []const u8, count: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, count * glyph.len);
    var offset: usize = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        @memcpy(buffer[offset .. offset + glyph.len], glyph);
        offset += glyph.len;
    }
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

/// Render a horizontal rule per the decor's hr mode/glyph. `full` fills the
/// content width; `fixed` draws `hr_count` glyphs, always clamped to width.
/// An optional `hr_center` string is placed centered within the rule.
fn renderHr(allocator: std.mem.Allocator, builder: *Builder, width: usize, decor: *const Decor) !void {
    const g = decor.glyphs;
    const glyph = if (g.hr_glyph.len == 0) "\u{2500}" else g.hr_glyph;
    const glyph_w = unicode.displayWidth(glyph);
    if (glyph_w == 0 or width == 0) return;
    const max_glyphs: usize = width / glyph_w;
    const total: usize = switch (g.hr_mode) {
        .full => max_glyphs,
        .fixed => @min(@as(usize, g.hr_count), max_glyphs),
    };
    if (total == 0) return;

    const center = g.hr_center;
    const center_w = if (center.len == 0) 0 else unicode.displayWidth(center);
    const center_slots = (center_w + glyph_w - 1) / glyph_w;
    if (center.len == 0 or center_slots >= total) {
        const text = try repeatGlyph(allocator, glyph, total);
        defer allocator.free(text);
        try builder.appendSpan(.muted, text);
        return;
    }
    const bar_slots = total - center_slots;
    const left = bar_slots / 2;
    const right = bar_slots - left;
    const left_s = try repeatGlyph(allocator, glyph, left);
    defer allocator.free(left_s);
    const right_s = try repeatGlyph(allocator, glyph, right);
    defer allocator.free(right_s);
    try builder.appendSpan(.muted, left_s);
    try builder.appendSpan(.muted, center);
    try builder.appendSpan(.muted, right_s);
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

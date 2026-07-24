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

const Block = markdown.Block;
const Inline = markdown.Inline;
const Options = types.Options;
const SpanStyle = types.SpanStyle;
const Glyphs = types.Glyphs;
const Builder = builder_mod.Builder;
const BoxDrawingStyle = mermaid_types.BoxDrawingStyle;
const CrossingReductionHeuristic = mermaid_types.CrossingReductionHeuristic;
const ForceLayout = mermaid_types.ForceLayout;
const SubgraphEdges = @import("prim").SubgraphEdges;
const FitStage = mermaid_types.FitStage;

/// A list/task marker (glyph + trailing space) formatted into a small stack
/// buffer, with a heap fallback for oversized glyphs. Configured glyphs are
/// bounded but not tiny, so the buffer avoids a per-item heap allocation in the
/// common case. Use it in place (the slice points into `buf`); `deinit` frees
/// only the heap fallback.
const Marker = struct {
    buf: [64]u8 = undefined,
    slice: []const u8 = &.{},
    heap: bool = false,

    fn set(self: *Marker, allocator: std.mem.Allocator, glyph: []const u8) !void {
        const total = glyph.len + 1;
        const dst = if (total <= self.buf.len)
            self.buf[0..total]
        else
            try allocator.alloc(u8, total);
        @memcpy(dst[0..glyph.len], glyph);
        dst[glyph.len] = ' ';
        self.slice = dst;
        self.heap = total > self.buf.len;
    }

    fn deinit(self: *Marker, allocator: std.mem.Allocator) void {
        if (self.heap) allocator.free(self.slice);
    }
};

/// The bullet glyph for a list item at `depth`. Falls back to "•" when no
/// glyphs are configured.
fn bulletGlyph(glyphs: Glyphs, depth: usize) []const u8 {
    return if (glyphs.bullet_glyphs.len == 0)
        "\u{2022}"
    else
        glyphs.bullet_glyphs[depth % glyphs.bullet_glyphs.len];
}

pub fn renderBlock(allocator: std.mem.Allocator, builder: *Builder, block: Block, options: Options) !void {
    const content_width = options.width -| options.left_padding;
    switch (block) {
        .frontmatter => |fm| try frontmatter_mod.render(allocator, builder, fm, content_width, options.frontmatter_style, options.for_export),
        .heading => |h| try renderHeading(allocator, builder, h, content_width, options.show_heading_markers, options.glyphs),
        .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent),
        .unordered_list_item => |item| {
            var marker: Marker = .{};
            try marker.set(allocator, bulletGlyph(options.glyphs, 0));
            defer marker.deinit(allocator);
            try renderListItem(allocator, builder, item, content_width, marker.slice, 0, options.glyphs);
        },
        .ordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, item.marker, 0, options.glyphs),
        .task_list_item => |item| {
            var marker: Marker = .{};
            try marker.set(allocator, if (item.checked) options.glyphs.task_checked else options.glyphs.task_todo);
            defer marker.deinit(allocator);
            const marker_style: SpanStyle = if (item.checked) .task_checkbox_done else .task_checkbox_todo;
            try renderTaskItem(allocator, builder, item.content, content_width, marker.slice, marker_style);
        },
        .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, options.mermaid_box_style, options.mermaid_crossing_heuristic, options.mermaid_force_layout, options.mermaid_aspect_ratio, options.mermaid_debug, options.mermaid_subgraph_edges),
        .html_block => |html| try builder.appendSpan(.muted, html),
        .thematic_break => {
            const hr_text = try repeatChar(allocator, content_width, options.glyphs.hr_glyph);
            defer allocator.free(hr_text);
            try builder.appendSpan(.hr, hr_text);
        },
        .table => |table| try table_mod.renderTable(allocator, builder, table, content_width, options.glyphs),
        .blockquote => |bq| try renderBlockQuote(allocator, builder, bq, content_width, options.left_padding, options.glyphs),
    }
}

pub fn renderHeading(allocator: std.mem.Allocator, builder: *Builder, heading: Block.Heading, width: usize, show_markers: bool, glyphs: Glyphs) !void {
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
    // Repeat the configured prefix `level` times (capped at 6), then a space.
    // A 64-byte stack buffer covers the common case; oversized glyphs fall back
    // to a heap allocation so no per-heading allocation happens normally.
    const repeat = @min(heading.level, 6);
    const glyph = glyphs.heading_prefix;
    const total = repeat * glyph.len + 1;
    var prefix_buf: [64]u8 = undefined;
    const prefix = if (total <= prefix_buf.len)
        prefix_buf[0..total]
    else
        try allocator.alloc(u8, total);
    defer if (total > prefix_buf.len) allocator.free(prefix);
    for (0..repeat) |i| @memcpy(prefix[i * glyph.len ..][0..glyph.len], glyph);
    prefix[total - 1] = ' ';
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

pub fn renderListItem(allocator: std.mem.Allocator, builder: *Builder, item: Block.ListItem, width: usize, display_marker: []const u8, depth: u8, glyphs: Glyphs) anyerror!void {
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
                try wrap.renderWrappedInlines(allocator, builder, item.content[start..i], width, .body, prefix, .list_marker, continuation, .list_marker);
                first = false;
            }
            start = i + 1;
        }
    }
    if (start < item.content.len) {
        if (!first) try builder.newline();
        const prefix = if (first) first_prefix else continuation;
        try wrap.renderWrappedInlines(allocator, builder, item.content[start..], width, .body, prefix, .list_marker, continuation, .list_marker);
    } else if (first and item.content.len == 0) {
        try builder.appendSpan(.list_marker, first_prefix);
    }

    // Render nested items
    for (item.nested) |nested| {
        try builder.newline();
        switch (nested) {
            .unordered_list_item => |n| {
                var nested_bullet: Marker = .{};
                try nested_bullet.set(allocator, bulletGlyph(glyphs, depth + 1));
                defer nested_bullet.deinit(allocator);
                try renderListItem(allocator, builder, n, width, nested_bullet.slice, depth + 1, glyphs);
            },
            .ordered_list_item => |n| try renderListItem(allocator, builder, n, width, n.marker, depth + 1, glyphs),
            .blockquote => |bq| try renderBlockQuoteWithPrefix(allocator, builder, bq, width -| unicode.displayWidth(continuation), continuation, glyphs),
            else => {},
        }
    }
}

pub fn renderTaskItem(allocator: std.mem.Allocator, builder: *Builder, content: []const Inline, width: usize, marker: []const u8, marker_style: SpanStyle) !void {
    const continuation = try repeatSpaces(allocator, unicode.displayWidth(marker));
    defer allocator.free(continuation);

    var start: usize = 0;
    var first = true;
    for (content, 0..) |inline_, i| {
        if (inline_ == .soft_break or inline_ == .line_break) {
            if (i > start) {
                if (!first) try builder.newline();
                const prefix = if (first) marker else continuation;
                try wrap.renderWrappedInlines(allocator, builder, content[start..i], width, .body, prefix, marker_style, continuation, marker_style);
                first = false;
            }
            start = i + 1;
        }
    }
    if (start < content.len) {
        if (!first) try builder.newline();
        const prefix = if (first) marker else continuation;
        try wrap.renderWrappedInlines(allocator, builder, content[start..], width, .body, prefix, marker_style, continuation, marker_style);
    } else if (first) {
        try builder.appendSpan(marker_style, marker);
    }
}

pub fn renderBlockQuote(allocator: std.mem.Allocator, builder: *Builder, bq: Block.BlockQuote, width: usize, left_padding: usize, glyphs: Glyphs) !void {
    // Build the prefix with left padding, then one configured quote bar per
    // depth level (arbitrary byte length), then a trailing space.
    const bar = glyphs.quote_bar;
    const prefix_bytes = left_padding + bq.depth * bar.len + 1;
    const prefix = try allocator.alloc(u8, prefix_bytes);
    defer allocator.free(prefix);

    // Add left padding first
    @memset(prefix[0..left_padding], ' ');

    // Then add the quote bar characters
    for (0..bq.depth) |i| {
        @memcpy(prefix[left_padding + i * bar.len ..][0..bar.len], bar);
    }
    prefix[left_padding + bq.depth * bar.len] = ' ';

    // Subtract the DISPLAY width the prefix occupies, not its byte length (a
    // multi-byte width-1 bar like "▎" is 3 bytes but one column).
    const content_width = width -| unicode.displayWidth(prefix);

    // Render each block inside the blockquote with the prefix
    var first_block = true;
    for (bq.blocks) |block| {
        if (!first_block) try builder.newline();
        first_block = false;

        // Check if this is a blockquote - nested blockquotes handle their own prefixing
        if (block == .blockquote) {
            const nested_bq = block.blockquote;
            try renderBlockQuote(allocator, builder, nested_bq, width, left_padding, glyphs);
            continue;
        }

        // Record the starting line count
        const initial_line_count = builder.lines.items.len;

        // Render the block - this adds new lines to builder
        switch (block) {
            .heading => |h| try renderHeading(allocator, builder, h, content_width, true, glyphs),
            .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent),
            .unordered_list_item => |item| {
                var marker: Marker = .{};
                try marker.set(allocator, bulletGlyph(glyphs, 0));
                defer marker.deinit(allocator);
                try renderListItem(allocator, builder, item, content_width, marker.slice, 0, glyphs);
            },
            .ordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, item.marker, 0, glyphs),
            .task_list_item => |item| {
                var marker: Marker = .{};
                try marker.set(allocator, if (item.checked) glyphs.task_checked else glyphs.task_todo);
                defer marker.deinit(allocator);
                const marker_style: SpanStyle = if (item.checked) .task_checkbox_done else .task_checkbox_todo;
                try renderTaskItem(allocator, builder, item.content, content_width, marker.slice, marker_style);
            },
            .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, .standard, .median, .auto, 1.0, false, .bridge),
            .html_block => |html| try builder.appendSpan(.muted, html),
            .thematic_break => {
                const hr_text = try repeatChar(allocator, content_width, glyphs.hr_glyph);
                defer allocator.free(hr_text);
                try builder.appendSpan(.hr, hr_text);
            },
            .table => |table| try table_mod.renderTable(allocator, builder, table, content_width, glyphs),
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
pub fn renderBlockQuoteWithPrefix(allocator: std.mem.Allocator, builder: *Builder, bq: Block.BlockQuote, width: usize, base_prefix: []const u8, glyphs: Glyphs) anyerror!void {
    // Build the prefix: base_prefix + one configured quote bar per depth + space
    const bar = glyphs.quote_bar;
    const prefix_bytes = base_prefix.len + bq.depth * bar.len + 1;
    const prefix = try allocator.alloc(u8, prefix_bytes);
    defer allocator.free(prefix);

    // Copy base prefix first
    @memcpy(prefix[0..base_prefix.len], base_prefix);

    // Then add the quote bar characters
    for (0..bq.depth) |i| {
        @memcpy(prefix[base_prefix.len + i * bar.len ..][0..bar.len], bar);
    }
    prefix[base_prefix.len + bq.depth * bar.len] = ' ';

    // Width consumed by the depth bars + trailing space, in display columns
    // (not bytes): each bar occupies displayWidth(bar) columns.
    const content_width = width -| (bq.depth * unicode.displayWidth(bar) + 1);

    // Render each block inside the blockquote
    var first_block = true;
    for (bq.blocks) |block| {
        if (!first_block) try builder.newline();
        first_block = false;

        if (block == .blockquote) {
            const nested_bq = block.blockquote;
            try renderBlockQuoteWithPrefix(allocator, builder, nested_bq, width, base_prefix, glyphs);
            continue;
        }

        // Record the starting line count
        const initial_line_count = builder.lines.items.len;

        // Render the block
        switch (block) {
            .heading => |h| try renderHeading(allocator, builder, h, content_width, true, glyphs),
            .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent),
            .unordered_list_item => |item| {
                var marker: Marker = .{};
                try marker.set(allocator, bulletGlyph(glyphs, 0));
                defer marker.deinit(allocator);
                try renderListItem(allocator, builder, item, content_width, marker.slice, 0, glyphs);
            },
            .ordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, item.marker, 0, glyphs),
            .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, .standard, .median, .auto, 1.0, false, .bridge),
            .html_block => |html| try builder.appendSpan(.muted, html),
            .thematic_break => {
                const hr_text = try repeatChar(allocator, content_width, glyphs.hr_glyph);
                defer allocator.free(hr_text);
                try builder.appendSpan(.hr, hr_text);
            },
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

pub fn renderCodeBlock(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, box_style: BoxDrawingStyle, crossing_heuristic: CrossingReductionHeuristic, force_layout: ForceLayout, aspect_ratio: f32, debug_mermaid: bool, subgraph_edges: SubgraphEdges) !void {
    // Check if this is a mermaid block
    if (std.mem.eql(u8, code.language, "mermaid")) {
        try renderMermaidBlock(allocator, builder, code.code, content_width, box_style, crossing_heuristic, force_layout, aspect_ratio, debug_mermaid, subgraph_edges);
        return;
    }

    // Render header
    if (code.language.len == 0) {
        try builder.appendSpan(.code_fence_banner, "```");
    } else {
        const header = try std.fmt.allocPrint(allocator, "```{s}", .{code.language});
        defer allocator.free(header);
        try builder.appendSpan(.code_fence_banner, header);
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
    try builder.appendSpan(.code_fence_banner, "```");
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
        try builder.appendSpan(.code_fence_banner, "```");
    } else {
        const header = try std.fmt.allocPrint(allocator, "```{s}", .{language});
        defer allocator.free(header);
        try builder.appendSpan(.code_fence_banner, header);
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
    try builder.appendSpan(.code_fence_banner, "```");
}

fn repeatSpaces(allocator: std.mem.Allocator, count: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, count);
    @memset(buffer, ' ');
    return buffer;
}

fn repeatChar(allocator: std.mem.Allocator, count: usize, glyph: []const u8) ![]u8 {
    // Fill `count` DISPLAY columns with the glyph: repetitions = columns divided
    // by the glyph's display width (a width-2 glyph tiles half as many times).
    // Default hr_glyph is width 1, so `count/1 == count` keeps byte-parity.
    const glyph_width = @max(unicode.displayWidth(glyph), 1);
    const repeats = count / glyph_width;
    const buffer = try allocator.alloc(u8, repeats * glyph.len);
    var offset: usize = 0;
    var i: usize = 0;
    while (i < repeats) : (i += 1) {
        @memcpy(buffer[offset .. offset + glyph.len], glyph);
        offset += glyph.len;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Test helper: concatenate every span's text on a line into one owned buffer.
fn concatSpans(allocator: std.mem.Allocator, spans: []const types.Span) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (spans) |span| try out.appendSlice(allocator, span.text);
    return out.toOwnedSlice(allocator);
}

test "Marker.set with typical glyph produces glyph+space on the stack (no heap alloc)" {
    // fail_index 0 makes the very first allocation fail; the stack path must
    // therefore complete without touching the allocator at all.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const alloc = failing.allocator();

    var marker: Marker = .{};
    try marker.set(alloc, "\u{2022}"); // "•", 3 bytes
    defer marker.deinit(alloc);

    try std.testing.expectEqualStrings("\u{2022} ", marker.slice);
    try std.testing.expect(!marker.heap);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "Marker.set with oversized glyph falls back to heap and deinit frees it" {
    // 100-byte glyph -> total 101 > 64-byte stack buffer -> heap path.
    // std.testing.allocator turns any missed free into a test failure.
    const glyph = "x" ** 100;
    var marker: Marker = .{};
    try marker.set(std.testing.allocator, glyph);
    defer marker.deinit(std.testing.allocator);

    try std.testing.expect(marker.heap);
    try std.testing.expectEqual(glyph.len + 1, marker.slice.len);
    try std.testing.expectEqualStrings(glyph, marker.slice[0..glyph.len]);
    try std.testing.expectEqual(@as(u8, ' '), marker.slice[glyph.len]);
}

test "Marker.set at the stack/heap boundary" {
    // total == 64 (glyph 63 bytes + space) still fits the stack buffer.
    {
        const glyph = "y" ** 63;
        var marker: Marker = .{};
        try marker.set(std.testing.allocator, glyph);
        defer marker.deinit(std.testing.allocator);
        try std.testing.expect(!marker.heap);
        try std.testing.expectEqual(@as(usize, 64), marker.slice.len);
    }
    // total == 65 (glyph 64 bytes + space) overflows -> heap.
    {
        const glyph = "z" ** 64;
        var marker: Marker = .{};
        try marker.set(std.testing.allocator, glyph);
        defer marker.deinit(std.testing.allocator);
        try std.testing.expect(marker.heap);
        try std.testing.expectEqual(@as(usize, 65), marker.slice.len);
    }
}

test "renderHeading default '#' prefix repeats per level 1-6" {
    const expected = [_][]const u8{
        "# Title",
        "## Title",
        "### Title",
        "#### Title",
        "##### Title",
        "###### Title",
    };
    for (expected, 1..) |want, level| {
        var builder = Builder.init(std.testing.allocator);
        defer builder.deinit();

        var content = [_]Inline{.{ .text = "Title" }};
        const heading = Block.Heading{ .level = @intCast(level), .content = &content };
        try renderHeading(std.testing.allocator, &builder, heading, 80, true, .{});

        const lines = try builder.finish();
        defer {
            for (lines) |l| l.deinit(std.testing.allocator);
            std.testing.allocator.free(lines);
        }
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        const text = try concatSpans(std.testing.allocator, lines[0].spans);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(want, text);
    }
}

test "renderHeading levels above 6 cap the prefix at 6 glyphs" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    var content = [_]Inline{.{ .text = "Title" }};
    const heading = Block.Heading{ .level = 9, .content = &content };
    try renderHeading(std.testing.allocator, &builder, heading, 80, true, .{});

    const lines = try builder.finish();
    defer {
        for (lines) |l| l.deinit(std.testing.allocator);
        std.testing.allocator.free(lines);
    }
    const text = try concatSpans(std.testing.allocator, lines[0].spans);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("###### Title", text);
}

test "renderHeading with a multi-byte glyph repeats bytes correctly at level 6" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    var content = [_]Inline{.{ .text = "Sec" }};
    const heading = Block.Heading{ .level = 6, .content = &content };
    // "§" is U+00A7, two bytes (0xC2 0xA7); six repeats + space = 13 bytes.
    try renderHeading(std.testing.allocator, &builder, heading, 80, true, .{ .heading_prefix = "\u{00A7}" });

    const lines = try builder.finish();
    defer {
        for (lines) |l| l.deinit(std.testing.allocator);
        std.testing.allocator.free(lines);
    }
    const text = try concatSpans(std.testing.allocator, lines[0].spans);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("\u{00A7}\u{00A7}\u{00A7}\u{00A7}\u{00A7}\u{00A7} Sec", text);
}

test "renderHeading with oversized prefix glyph takes heap fallback and renders without leaks" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    var content = [_]Inline{.{ .text = "Big" }};
    const heading = Block.Heading{ .level = 1, .content = &content };
    // 100-byte glyph -> total 101 > 64-byte prefix buffer -> heap allocation.
    const glyph = "#" ** 100;
    try renderHeading(std.testing.allocator, &builder, heading, 400, true, .{ .heading_prefix = glyph });

    const lines = try builder.finish();
    defer {
        for (lines) |l| l.deinit(std.testing.allocator);
        std.testing.allocator.free(lines);
    }
    const text = try concatSpans(std.testing.allocator, lines[0].spans);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(glyph ++ " Big", text);
}

test "renderBlock task_list_item renders default task_todo glyph as 'glyph + space' before content" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    var content = [_]Inline{.{ .text = "Task" }};
    const block = Block{ .task_list_item = .{ .checked = false, .content = &content } };
    try renderBlock(std.testing.allocator, &builder, block, .{ .width = 80, .left_padding = 0 });

    const lines = try builder.finish();
    defer {
        for (lines) |l| l.deinit(std.testing.allocator);
        std.testing.allocator.free(lines);
    }
    const text = try concatSpans(std.testing.allocator, lines[0].spans);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[ ] Task", text);
}

test "renderBlock task_list_item renders default task_checked glyph as 'glyph + space' before content" {
    var builder = Builder.init(std.testing.allocator);
    defer builder.deinit();

    var content = [_]Inline{.{ .text = "Task" }};
    const block = Block{ .task_list_item = .{ .checked = true, .content = &content } };
    try renderBlock(std.testing.allocator, &builder, block, .{ .width = 80, .left_padding = 0 });

    const lines = try builder.finish();
    defer {
        for (lines) |l| l.deinit(std.testing.allocator);
        std.testing.allocator.free(lines);
    }
    const text = try concatSpans(std.testing.allocator, lines[0].spans);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[x] Task", text);
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

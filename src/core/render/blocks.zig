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
const Builder = builder_mod.Builder;
const BoxDrawingStyle = mermaid_types.BoxDrawingStyle;
const CrossingReductionHeuristic = mermaid_types.CrossingReductionHeuristic;
const ForceLayout = mermaid_types.ForceLayout;
const SubgraphEdges = @import("prim").SubgraphEdges;
const FitStage = mermaid_types.FitStage;

const bullet_shapes = [_][]const u8{ "\u{2022} ", "\u{25E6} ", "\u{2023} " };
// • (bullet), ◦ (white bullet), ‣ (triangular bullet)

pub fn renderBlock(allocator: std.mem.Allocator, builder: *Builder, block: Block, options: Options) !void {
    const content_width = options.width -| options.left_padding;
    switch (block) {
        .frontmatter => |fm| try frontmatter_mod.render(allocator, builder, fm, content_width, options.frontmatter_style),
        .heading => |h| try renderHeading(allocator, builder, h, content_width, options.show_heading_markers),
        .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent),
        .unordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, "\u{2022} ", 0),
        .ordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, item.marker, 0),
        .task_list_item => |item| {
            const marker = if (item.checked) "[x] " else "[ ] ";
            try renderTaskItem(allocator, builder, item.content, content_width, marker);
        },
        .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, options.mermaid_box_style, options.mermaid_crossing_heuristic, options.mermaid_force_layout, options.mermaid_aspect_ratio, options.mermaid_debug, options.mermaid_subgraph_edges),
        .html_block => |html| try builder.appendSpan(.muted, html),
        .thematic_break => {
            const hr_text = try repeatChar(allocator, content_width);
            defer allocator.free(hr_text);
            try builder.appendSpan(.muted, hr_text);
        },
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

pub fn renderListItem(allocator: std.mem.Allocator, builder: *Builder, item: Block.ListItem, width: usize, display_marker: []const u8, depth: u8) anyerror!void {
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
                try wrap.renderWrappedInlines(allocator, builder, item.content[start..i], width, .body, prefix, .muted, continuation, .muted);
                first = false;
            }
            start = i + 1;
        }
    }
    if (start < item.content.len) {
        if (!first) try builder.newline();
        const prefix = if (first) first_prefix else continuation;
        try wrap.renderWrappedInlines(allocator, builder, item.content[start..], width, .body, prefix, .muted, continuation, .muted);
    } else if (first and item.content.len == 0) {
        try builder.appendSpan(.muted, first_prefix);
    }

    // Render nested items
    for (item.nested) |nested| {
        try builder.newline();
        switch (nested) {
            .unordered_list_item => |n| {
                const nested_bullet = bullet_shapes[(depth + 1) % bullet_shapes.len];
                try renderListItem(allocator, builder, n, width, nested_bullet, depth + 1);
            },
            .ordered_list_item => |n| try renderListItem(allocator, builder, n, width, n.marker, depth + 1),
            .blockquote => |bq| try renderBlockQuoteWithPrefix(allocator, builder, bq, width -| unicode.displayWidth(continuation), continuation),
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
            .unordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, "\u{2022} ", 0),
            .ordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, item.marker, 0),
            .task_list_item => |item| {
                const marker = if (item.checked) "[x] " else "[ ] ";
                try renderTaskItem(allocator, builder, item.content, content_width, marker);
            },
            .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, .standard, .median, .auto, 1.0, false, .bridge),
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

/// Renders a blockquote with a custom base prefix (for blockquotes inside list items)
pub fn renderBlockQuoteWithPrefix(allocator: std.mem.Allocator, builder: *Builder, bq: Block.BlockQuote, width: usize, base_prefix: []const u8) anyerror!void {
    // Build the prefix: base_prefix + stacked "▎" characters + space
    const prefix_bytes = base_prefix.len + bq.depth * 3 + 1;
    const prefix = try allocator.alloc(u8, prefix_bytes);
    defer allocator.free(prefix);

    // Copy base prefix first
    @memcpy(prefix[0..base_prefix.len], base_prefix);

    // Then add the "▎" characters
    for (0..bq.depth) |i| {
        @memcpy(prefix[base_prefix.len + i*3..][0..3], "\u{258E}");
    }
    prefix[base_prefix.len + bq.depth * 3] = ' ';

    const content_width = width -| (bq.depth * 3 + 1);

    // Render each block inside the blockquote
    var first_block = true;
    for (bq.blocks) |block| {
        if (!first_block) try builder.newline();
        first_block = false;

        if (block == .blockquote) {
            const nested_bq = block.blockquote;
            try renderBlockQuoteWithPrefix(allocator, builder, nested_bq, width, base_prefix);
            continue;
        }

        // Record the starting line count
        const initial_line_count = builder.lines.items.len;

        // Render the block
        switch (block) {
            .heading => |h| try renderHeading(allocator, builder, h, content_width, true),
            .paragraph => |p| try renderParagraph(allocator, builder, p.content, content_width, .body, p.indent),
            .unordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, "\u{2022} ", 0),
            .ordered_list_item => |item| try renderListItem(allocator, builder, item, content_width, item.marker, 0),
            .fenced_code => |code| try renderCodeBlock(allocator, builder, code, content_width, .standard, .median, .auto, 1.0, false, .bridge),
            .html_block => |html| try builder.appendSpan(.muted, html),
            .thematic_break => {
                const hr_text = try repeatChar(allocator, content_width);
                defer allocator.free(hr_text);
                try builder.appendSpan(.muted, hr_text);
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

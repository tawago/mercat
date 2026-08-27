const std = @import("std");
const markdown = @import("../parser.zig");
const highlight = @import("../../highlight.zig");
const mermaid = @import("../../mermaid/render.zig");
const mermaid_types = @import("../../mermaid/types.zig");
const line_mod = @import("line.zig");
const builder_mod = @import("builder.zig");
const geometry = @import("geometry.zig");
const decor_mod = @import("decor.zig");

const Block = markdown.Block;
const Builder = builder_mod.Builder;
const SpanStyle = line_mod.SpanStyle;
const BoxDrawingStyle = mermaid_types.BoxDrawingStyle;
const CrossingReductionHeuristic = mermaid_types.CrossingReductionHeuristic;
const ForceLayout = mermaid_types.ForceLayout;
const SubgraphEdges = @import("prim").SubgraphEdges;
const FitStage = mermaid_types.FitStage;

pub fn render(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, box_style: BoxDrawingStyle, crossing_heuristic: CrossingReductionHeuristic, force_layout: ForceLayout, aspect_ratio: f32, debug_mermaid: bool, subgraph_edges: SubgraphEdges, decor: *const decor_mod.Decor) !void {
    if (std.mem.eql(u8, code.language, "mermaid")) {
        try renderMermaid(allocator, builder, code.code, content_width, box_style, crossing_heuristic, force_layout, aspect_ratio, debug_mermaid, subgraph_edges);
        return;
    }
    const frame = decor.glyphs.code_frame;
    switch (frame.kind orelse .panel) {
        .panel => try renderPanel(allocator, builder, code, content_width, frame),
        .plain => try renderPlain(allocator, builder, code),
        .rule => try renderRule(allocator, builder, code, content_width, frame),
        .block => try renderFramedBlock(allocator, builder, code, content_width, frame),
    }
}

fn renderPanel(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, frame: decor_mod.CodeFrameDelta) !void {
    const left_pad: usize = 1 + @as(usize, frame.pad orelse 0);
    try appendFence(allocator, builder, code.language);
    const pad_limit = content_width -| left_pad -| 1;
    const text_column = builder.left_padding + left_pad;
    const max_line_width = @min(try maxLineWidth(code.code, text_column), pad_limit);

    var lines = std.mem.splitScalar(u8, code.code, '\n');
    while (lines.next()) |line| {
        try builder.newline();
        const trimmed = std.mem.trimRight(u8, line, "\r");
        const line_width = try geometry.displayWidthFrom(trimmed, text_column);
        if (trimmed.len == 0) {
            try appendPadding(builder, left_pad + max_line_width + 1);
            continue;
        }
        try appendPadding(builder, left_pad);
        try appendHighlighted(allocator, builder, code.language, trimmed);
        try appendPadding(builder, (max_line_width -| line_width) + 1);
    }
    try builder.newline();
    try builder.appendSpan(.code_fence_banner, "```");
}

fn renderPlain(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock) !void {
    var lines = std.mem.splitScalar(u8, code.code, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try builder.newline();
        first = false;
        const trimmed = std.mem.trimRight(u8, line, "\r");
        _ = try geometry.displayWidthFrom(trimmed, builder.left_padding + 1);
        try appendPadding(builder, 1);
        try appendHighlighted(allocator, builder, code.language, trimmed);
    }
}

fn renderRule(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, frame: decor_mod.CodeFrameDelta) !void {
    const glyph = frame.border_glyph orelse "\u{2500}";
    const glyph_width = @max(try geometry.displayWidth(glyph), 1);
    const cap: usize = if (frame.border_cap) |value| value else content_width;
    const count = @min(cap, content_width / glyph_width);
    try appendRule(allocator, builder, glyph, count);

    var lines = std.mem.splitScalar(u8, code.code, '\n');
    while (lines.next()) |line| {
        try builder.newline();
        const trimmed = std.mem.trimRight(u8, line, "\r");
        _ = try geometry.displayWidthFrom(trimmed, builder.left_padding + 1);
        try appendPadding(builder, 1);
        try appendHighlighted(allocator, builder, code.language, trimmed);
    }
    try builder.newline();
    try appendRule(allocator, builder, glyph, count);
}

fn renderFramedBlock(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, frame: decor_mod.CodeFrameDelta) !void {
    const left_pad: usize = 1 + @as(usize, frame.pad orelse 0);
    if ((frame.language_label orelse false) and code.language.len != 0) {
        const chip = try std.fmt.allocPrint(allocator, " {s} ", .{code.language});
        defer allocator.free(chip);
        try builder.appendSpan(.code_fence_banner, chip);
        try builder.newline();
    }
    const text_column = builder.left_padding + left_pad;
    var lines = std.mem.splitScalar(u8, code.code, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try builder.newline();
        first = false;
        const trimmed = std.mem.trimRight(u8, line, "\r");
        const line_width = try geometry.displayWidthFrom(trimmed, text_column);
        try appendPadding(builder, left_pad);
        try appendHighlighted(allocator, builder, code.language, trimmed);
        try appendPadding(builder, content_width -| (left_pad + line_width));
    }
}

fn renderMermaid(allocator: std.mem.Allocator, builder: *Builder, source: []const u8, content_width: usize, box_style: BoxDrawingStyle, crossing_heuristic: CrossingReductionHeuristic, force_layout: ForceLayout, aspect_ratio: f32, debug_mermaid: bool, subgraph_edges: SubgraphEdges) !void {
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
        try renderFallback(allocator, builder, "mermaid", source);
        return;
    };
    if (result.is_fallback) {
        if (result.fallback_reason) |reason| {
            if (std.mem.startsWith(u8, reason, "v2 ")) {
                const banner = try std.fmt.allocPrint(allocator, "<PARSE ERROR: {s}>", .{reason});
                defer allocator.free(banner);
                try builder.appendSpan(.muted, banner);
                try builder.newline();
            }
        }
        try renderFallback(allocator, builder, "mermaid", source);
        return;
    }
    defer allocator.free(result.output);

    if (debug_mermaid) try appendMermaidDebug(allocator, builder, result);
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

fn appendMermaidDebug(allocator: std.mem.Allocator, builder: *Builder, result: anytype) !void {
    const algorithm = switch (result.algorithm_used) {
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
    inline for (.{
        .{ "Algorithm: {s}", algorithm },
    }) |entry| {
        try builder.newline();
        const line = try std.fmt.allocPrint(allocator, entry[0], .{entry[1]});
        defer allocator.free(line);
        try builder.appendSpan(.muted, line);
    }
    const numeric = [_]struct { label: []const u8, value: usize }{
        .{ .label = "Nodes", .value = result.node_count },
        .{ .label = "Edges", .value = result.edge_count },
    };
    for (numeric) |entry| {
        try builder.newline();
        const line = try std.fmt.allocPrint(allocator, "{s}: {d}", .{ entry.label, entry.value });
        defer allocator.free(line);
        try builder.appendSpan(.muted, line);
    }
    try appendDebugBool(allocator, builder, "Tree detected", result.is_tree);
    try appendDebugBool(allocator, builder, "Cyclic", result.is_cyclic);
    try appendDebugBool(allocator, builder, "Width constraint triggered", result.width_constraint_triggered);
    if (result.fit_stage != FitStage.natural) {
        try builder.newline();
        const line = try std.fmt.allocPrint(allocator, "Fit stage: {s}", .{result.fit_stage.description()});
        defer allocator.free(line);
        try builder.appendSpan(.muted, line);
    }
    if (result.original_direction) |direction| {
        try builder.newline();
        const line = try std.fmt.allocPrint(allocator, "Original direction: {s} (switched for width)", .{@tagName(direction)});
        defer allocator.free(line);
        try builder.appendSpan(.muted, line);
    }
    if (result.crossing_reduction_iterations > 0) {
        try builder.newline();
        const line = try std.fmt.allocPrint(allocator, "Crossing reduction iterations: {d}", .{result.crossing_reduction_iterations});
        defer allocator.free(line);
        try builder.appendSpan(.muted, line);
    }
    try builder.newline();
    try builder.appendSpan(.muted, "---debug-mermaid---");
    try builder.newline();
}

fn appendDebugBool(allocator: std.mem.Allocator, builder: *Builder, label: []const u8, value: bool) !void {
    try builder.newline();
    const line = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ label, if (value) "yes" else "no" });
    defer allocator.free(line);
    try builder.appendSpan(.muted, line);
}

fn renderFallback(allocator: std.mem.Allocator, builder: *Builder, language: []const u8, source: []const u8) !void {
    try appendFence(allocator, builder, language);
    const text_column = builder.left_padding + 1;
    const max_line_width = try maxLineWidth(source, text_column);
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        try builder.newline();
        const trimmed = std.mem.trimRight(u8, line, "\r");
        const line_width = try geometry.displayWidthFrom(trimmed, text_column);
        try appendPadding(builder, 1);
        try builder.appendSpan(.code_block, trimmed);
        try appendPadding(builder, max_line_width -| line_width + 1);
    }
    try builder.newline();
    try builder.appendSpan(.code_fence_banner, "```");
}

fn appendFence(allocator: std.mem.Allocator, builder: *Builder, language: []const u8) !void {
    if (language.len == 0) return builder.appendSpan(.code_fence_banner, "```");
    const header = try std.fmt.allocPrint(allocator, "```{s}", .{language});
    defer allocator.free(header);
    try builder.appendSpan(.code_fence_banner, header);
}

fn appendHighlighted(allocator: std.mem.Allocator, builder: *Builder, language: []const u8, text: []const u8) !void {
    const tokens = try highlight.tokenizeLine(allocator, language, text);
    defer highlight.freeTokens(allocator, tokens);
    for (tokens) |token| try builder.appendSpan(tokenStyle(token.style), token.text);
}

fn appendRule(allocator: std.mem.Allocator, builder: *Builder, glyph: []const u8, count: usize) !void {
    if (count == 0) return;
    const text = try allocator.alloc(u8, glyph.len * count);
    defer allocator.free(text);
    for (0..count) |index| @memcpy(text[index * glyph.len ..][0..glyph.len], glyph);
    try builder.appendSpan(.muted, text);
}

fn maxLineWidth(source: []const u8, initial_column: usize) !usize {
    var max_width: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        max_width = @max(max_width, try geometry.displayWidthFrom(trimmed, initial_column));
    }
    return max_width;
}

fn appendPadding(builder: *Builder, count: usize) !void {
    if (count != 0) try builder.appendRepeated(.code_block, " ", count);
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

fn renderPanelText(allocator: std.mem.Allocator, source: []const u8, content_width: usize) ![]u8 {
    const code = Block.CodeBlock{ .language = "", .code = source };
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try renderPanel(allocator, &builder, code, content_width, .{ .kind = .panel });
    const lines = try builder.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (lines) |line| {
        for (line.spans) |span| try out.appendSlice(allocator, span.text);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "code panel pads short lines out to the widest line" {
    const allocator = std.testing.allocator;
    const out = try renderPanelText(allocator, "ab\nlonger line", 80);
    defer allocator.free(out);
    var rows = std.mem.splitScalar(u8, std.mem.trimRight(u8, out, "\n"), '\n');
    try std.testing.expectEqualStrings("```", rows.next().?);
    try std.testing.expectEqualStrings(" ab          ", rows.next().?);
    try std.testing.expectEqualStrings(" longer line ", rows.next().?);
    try std.testing.expectEqualStrings("```", rows.next().?);
}

test "code panel padding is capped at the content width" {
    const allocator = std.testing.allocator;
    const long = try allocator.alloc(u8, 50_000);
    defer allocator.free(long);
    @memset(long, 'x');
    const source = try std.fmt.allocPrint(allocator, "a\n{s}\n\nb", .{long});
    defer allocator.free(source);
    const out = try renderPanelText(allocator, source, 80);
    defer allocator.free(out);
    var rows = std.mem.splitScalar(u8, std.mem.trimRight(u8, out, "\n"), '\n');
    _ = rows.next();
    try std.testing.expectEqual(@as(usize, 80), rows.next().?.len);
    try std.testing.expect(rows.next().?.len >= 50_000);
    try std.testing.expectEqual(@as(usize, 80), rows.next().?.len);
    try std.testing.expectEqual(@as(usize, 80), rows.next().?.len);
}

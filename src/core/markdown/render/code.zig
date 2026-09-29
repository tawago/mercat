const std = @import("std");
const markdown = @import("../parser.zig");
const highlight = @import("../../highlight.zig");
const mermaid = @import("../../mermaid/mermaid.zig");
const line_mod = @import("line.zig");
const builder_mod = @import("builder.zig");
const geometry = @import("geometry.zig");
const decor_mod = @import("decor.zig");

const Block = markdown.Block;
const Builder = builder_mod.Builder;
const SpanStyle = line_mod.SpanStyle;
const SubgraphEdges = mermaid.SubgraphEdges;

pub fn render(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, debug_mermaid: bool, subgraph_edges: SubgraphEdges, decor: *const decor_mod.Decor) !void {
    if (std.mem.eql(u8, code.language, "mermaid")) {
        try renderMermaid(allocator, builder, code.code, content_width, debug_mermaid, subgraph_edges);
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
        try appendPadding(builder, 1);
        try appendHighlighted(allocator, builder, code.language, std.mem.trimRight(u8, line, "\r"));
    }
}

fn renderRule(allocator: std.mem.Allocator, builder: *Builder, code: Block.CodeBlock, content_width: usize, frame: decor_mod.CodeFrameDelta) !void {
    const glyph = frame.border_glyph orelse "\u{2500}";
    const glyph_width = @max(try geometry.displayWidth(glyph), 1);
    const cap: usize = if (frame.border_cap) |value| value else content_width;
    const count = @min(cap, content_width / glyph_width);
    try builder.appendRepeated(.muted, glyph, count);
    try builder.newline();
    try renderPlain(allocator, builder, code);
    try builder.newline();
    try builder.appendRepeated(.muted, glyph, count);
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

fn renderMermaid(allocator: std.mem.Allocator, builder: *Builder, source: []const u8, content_width: usize, debug_mermaid: bool, subgraph_edges: SubgraphEdges) !void {
    const output = switch (mermaid.render(allocator, source, .{
        .max_width = @intCast(content_width),
        .subgraph_edges = subgraph_edges,
    })) {
        .drawn => |text| text,
        .not_drawn => |failure| {
            if (failure.banner) |reason| {
                const banner = try std.fmt.allocPrint(allocator, "<PARSE ERROR: {s}>", .{reason});
                defer allocator.free(banner);
                try builder.appendSpan(.muted, banner);
                try builder.newline();
            }
            try renderFallback(allocator, builder, "mermaid", source);
            return;
        },
    };
    defer allocator.free(output);

    if (debug_mermaid) try appendMermaidDebug(builder);
    const saved_padding = builder.left_padding;
    builder.left_padding = 0;
    defer builder.left_padding = saved_padding;
    var diagram_lines = std.mem.splitScalar(u8, output, '\n');
    var first = true;
    while (diagram_lines.next()) |line| {
        if (!first) try builder.newline();
        first = false;
        try builder.appendSpan(.code, line);
    }
}

/// The `--debug-mermaid` block. Its layout statistics have read the same values for every
/// diagram since the flowchart engine rewrite; the flag keeps printing them.
fn appendMermaidDebug(builder: *Builder) !void {
    try builder.appendSpan(.muted, "---debug-mermaid---");
    for ([_][]const u8{
        "Algorithm: Unknown",
        "Nodes: 0",
        "Edges: 0",
        "Tree detected: no",
        "Cyclic: no",
        "Width constraint triggered: no",
    }) |line| {
        try builder.newline();
        try builder.appendSpan(.muted, line);
    }
    try builder.newline();
    try builder.appendSpan(.muted, "---debug-mermaid---");
    try builder.newline();
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

test {
    _ = @import("code_test.zig");
}

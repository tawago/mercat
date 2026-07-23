const std = @import("std");
const markdown = @import("markdown.zig");
const types = @import("render/types.zig");
const builder_mod = @import("render/builder.zig");
const blocks = @import("render/blocks.zig");

// Re-export types
pub const Options = types.Options;
pub const Glyphs = types.Glyphs;
pub const SpanStyle = types.SpanStyle;
pub const Span = types.Span;
pub const Line = types.Line;
pub const Rendered = types.Rendered;

pub fn renderDocument(allocator: std.mem.Allocator, document: markdown.Document, options: Options) !Rendered {
    var builder = builder_mod.Builder.init(allocator);
    builder.left_padding = options.left_padding;
    defer builder.deinit();

    for (document.blocks, 0..) |block, index| {
        if (index != 0) {
            try builder.newline();
            if (!blocks.isCompactBlockPair(document.blocks[index - 1], block)) try builder.newline();
        }
        try blocks.renderBlock(allocator, &builder, block, options);
    }

    return .{ .lines = try builder.finish() };
}

test "renders styled lines for heading and paragraph" {
    const allocator = std.testing.allocator;
    const unicode = @import("../lib/unicode.zig");
    _ = unicode;
    var document = try markdown.parse(allocator,
        \\# Title
        \\
        \\Paragraph text.
    );
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 20, .show_heading_markers = true });
    defer rendered.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), rendered.lines.len);
    try std.testing.expectEqualStrings("  ", rendered.lines[0].spans[0].text);
    try std.testing.expect(std.mem.startsWith(u8, rendered.lines[0].spans[1].text, "# "));
    try std.testing.expectEqual(SpanStyle.heading1, rendered.lines[0].spans[1].style);
    try std.testing.expectEqual(@as(usize, 0), rendered.lines[1].spans.len);
}

test "supports hidden heading markers and glow-like table layout" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\## Heading
        \\
        \\| Name | Value |
        \\| :--- | ---: |
        \\| a | 1 |
    );
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 60, .show_heading_markers = false });
    defer rendered.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0].spans[1].text, "Heading") != null);
    var found_table = false;
    var found_separator = false;
    for (rendered.lines) |line| {
        for (line.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "Name") != null) found_table = true;
            if (std.mem.indexOf(u8, span.text, "\u{2502}") != null) found_separator = true;
        }
    }
    try std.testing.expect(found_table);
    try std.testing.expect(found_separator);
}

test "wraps wide tables without breaking column alignment" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\| Package | Version | Purpose |
        \\| :--- | ---: | :--- |
        \\| oidc-provider | ^8.4.0 | Core OIDC implementation |
    );
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 50, .show_heading_markers = true });
    defer rendered.deinit(allocator);

    var saw_separator = false;
    var saw_wrapped_purpose = false;
    for (rendered.lines) |line| {
        for (line.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "\u{2502}") != null) saw_separator = true;
            if (std.mem.indexOf(u8, span.text, "Core OIDC") != null or std.mem.indexOf(u8, span.text, "implementation") != null) saw_wrapped_purpose = true;
        }
    }

    try std.testing.expect(saw_separator);
    try std.testing.expect(saw_wrapped_purpose);
}

test "pads table cells around vertical separators" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\| A | B |
        \\| --- | --- |
        \\| x | y |
    );
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 30, .show_heading_markers = true });
    defer rendered.deinit(allocator);

    var found_separator = false;
    var found_cross = false;
    for (rendered.lines) |line| {
        for (line.spans) |span| {
            if (std.mem.indexOf(u8, span.text, "\u{2502}") != null) found_separator = true;
            if (std.mem.indexOf(u8, span.text, "\u{253c}") != null) found_cross = true;
        }
    }
    try std.testing.expect(found_separator);
    try std.testing.expect(found_cross);
}

test "keeps inline code foreground-only and pads fenced code blocks" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\Inline `code`
        \\
        \\```zig
        \\const value = 1;
        \\x
        \\```
    );
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{ .width = 80, .show_heading_markers = true });
    defer rendered.deinit(allocator);

    var saw_inline_code = false;
    for (rendered.lines[0].spans) |span| {
        if (std.mem.eql(u8, span.text, "code")) {
            try std.testing.expectEqual(SpanStyle.code, span.style);
            saw_inline_code = true;
        }
    }
    try std.testing.expect(saw_inline_code);

    const code_line = rendered.lines[3];
    const short_code_line = rendered.lines[4];

    try std.testing.expect(code_line.spans.len > 1);
    try std.testing.expect(short_code_line.spans.len > 1);
    try std.testing.expectEqual(SpanStyle.code_block, code_line.spans[code_line.spans.len - 1].style);
    try std.testing.expectEqual(SpanStyle.code_block, short_code_line.spans[short_code_line.spans.len - 1].style);
    try std.testing.expect(std.mem.startsWith(u8, short_code_line.spans[short_code_line.spans.len - 1].text, " x"));
    try std.testing.expect(std.mem.endsWith(u8, short_code_line.spans[short_code_line.spans.len - 1].text, "                "));
}

test "table row widths match rule width with inline code" {
    const allocator = std.testing.allocator;
    const unicode = @import("../lib/unicode.zig");
    var document = try markdown.parse(allocator,
        \\| Name | Command |
        \\| --- | --- |
        \\| run | `go run` |
    );
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{
        .width = 50,
        .left_padding = 0,
        .show_heading_markers = true,
    });
    defer rendered.deinit(allocator);

    var widths: std.ArrayList(usize) = .empty;
    defer widths.deinit(allocator);
    for (rendered.lines) |line| {
        var w: usize = 0;
        for (line.spans) |span| w += unicode.displayWidth(span.text);
        if (w > 0) try widths.append(allocator, w);
    }

    // All table lines should have equal width
    try std.testing.expect(widths.items.len >= 3);
    for (widths.items[1..]) |w| {
        try std.testing.expectEqual(widths.items[0], w);
    }
}

test "table respects terminal width with inline code" {
    const allocator = std.testing.allocator;
    const unicode = @import("../lib/unicode.zig");
    const terminal_width: usize = 80;

    var document = try markdown.parse(allocator,
        \\| Package | Version | Purpose |
        \\| --- | --- | --- |
        \\| `oidc-provider` | ^8.4.0 | Core OIDC implementation |
    );
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{
        .width = terminal_width,
        .left_padding = 2,
        .show_heading_markers = true,
    });
    defer rendered.deinit(allocator);

    for (rendered.lines) |line| {
        var w: usize = 0;
        for (line.spans) |span| w += unicode.displayWidth(span.text);
        try std.testing.expect(w <= terminal_width);
    }
}

test "nested lists have indentation and varying bullet shapes" {
    const allocator = std.testing.allocator;

    var document = try markdown.parse(allocator,
        \\- Level 1
        \\  - Level 2
        \\    - Level 3
    );
    defer document.deinit(allocator);

    var rendered = try renderDocument(allocator, document, .{
        .width = 80,
        .left_padding = 2,
        .show_heading_markers = true,
    });
    defer rendered.deinit(allocator);

    // Should have 3 lines for 3 list items
    try std.testing.expectEqual(@as(usize, 3), rendered.lines.len);

    // Check bullet shapes cycle: • (level 1), ◦ (level 2), ‣ (level 3)
    // Level 1: padding + "• "
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0].spans[0].text, "\u{2022}") != null);
    // Level 2: should have ◦ (white bullet)
    var found_white_bullet = false;
    for (rendered.lines[1].spans) |span| {
        if (std.mem.indexOf(u8, span.text, "\u{25E6}") != null) found_white_bullet = true;
    }
    try std.testing.expect(found_white_bullet);
    // Level 3: should have ‣ (triangular bullet)
    var found_triangular = false;
    for (rendered.lines[2].spans) |span| {
        if (std.mem.indexOf(u8, span.text, "\u{2023}") != null) found_triangular = true;
    }
    try std.testing.expect(found_triangular);

    // Check indentation increases (level 2 has more leading spaces than level 1)
    const line1_prefix = rendered.lines[0].spans[0].text;
    const line2_prefix = rendered.lines[1].spans[0].text;
    const line3_prefix = rendered.lines[2].spans[0].text;
    try std.testing.expect(line2_prefix.len > line1_prefix.len);
    try std.testing.expect(line3_prefix.len > line2_prefix.len);
}

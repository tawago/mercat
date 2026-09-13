const std = @import("std");
const markdown = @import("parser.zig");
const render_model = @import("render.zig");
const theme = @import("../theme.zig");
const resolve = @import("../theme/resolve.zig");

const renderDocument = render_model.renderDocument;
const SpanStyle = render_model.SpanStyle;
const Line = render_model.Line;
const rgb = @import("../theme/color.zig").rgb;
const cidx = @import("../theme/color.zig").idx;

test "front matter never renders as headings (issue #9 regression)" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\---
        \\title: Test
        \\author: Foo
        \\---
        \\
        \\# Real Heading
    );
    defer document.deinit(allocator);
    try std.testing.expect(document.blocks[0] == .frontmatter);
    try std.testing.expectEqual(@as(usize, 2), document.blocks[0].frontmatter.entries.len);
    var rendered = try renderDocument(allocator, document, .{ .width = 60 });
    defer rendered.deinit(allocator);
    var heading_spans: usize = 0;
    var saw_cap = false;
    var saw_key = false;
    for (rendered.lines) |line| for (line.spans) |span| {
        if (span.style == .heading1 or span.style == .heading2) heading_spans += 1;
        if (span.style == .frontmatter_cap) saw_cap = true;
        if (span.style == .frontmatter_key and std.mem.indexOf(u8, span.text, "title") != null) saw_key = true;
    };
    try std.testing.expectEqual(@as(usize, 1), heading_spans);
    try std.testing.expect(saw_cap);
    try std.testing.expect(saw_key);
}

test "hidden front matter leaves no leading blank lines" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\---
        \\title: Test
        \\---
        \\# Real Heading
    );
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 60, .frontmatter_style = .hidden });
    defer rendered.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), rendered.lines.len);
    try std.testing.expect(std.mem.indexOf(u8, rendered.lines[0].spans[1].text, "Real Heading") != null);
}

test "mid-document thematic break is untouched by front matter handling" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "# Heading\n\n---\n\nafter");
    defer document.deinit(allocator);
    try std.testing.expect(document.blocks[0] == .heading);
    try std.testing.expect(document.blocks[1] == .thematic_break);
}

test "renders styled lines for heading and paragraph" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "# Title\n\nParagraph text.");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 20, .show_heading_markers = true });
    defer rendered.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), rendered.lines.len);
    try std.testing.expectEqualStrings("  ", rendered.lines[0].spans[0].text);
    try std.testing.expect(std.mem.startsWith(u8, rendered.lines[0].spans[1].text, "# "));
    try std.testing.expectEqual(SpanStyle.heading1, rendered.lines[0].spans[1].style);
}

test "supports hidden heading markers and glow-like table layout" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "## Heading\n\n| Name | Value |\n| :--- | ---: |\n| a | 1 |");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 60, .show_heading_markers = false });
    defer rendered.deinit(allocator);
    var found_table = false;
    var found_separator = false;
    for (rendered.lines) |line| for (line.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "Name") != null) found_table = true;
        if (std.mem.indexOf(u8, span.text, "\u{2502}") != null) found_separator = true;
    };
    try std.testing.expect(found_table and found_separator);
}

test "wraps wide tables without breaking column alignment" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "| Package | Version | Purpose |\n| :--- | ---: | :--- |\n| oidc-provider | ^8.4.0 | Core OIDC implementation |");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 50 });
    defer rendered.deinit(allocator);
    var saw_separator = false;
    var saw_wrapped_purpose = false;
    for (rendered.lines) |line| for (line.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "\u{2502}") != null) saw_separator = true;
        if (std.mem.indexOf(u8, span.text, "Core OIDC") != null or std.mem.indexOf(u8, span.text, "implementation") != null) saw_wrapped_purpose = true;
    };
    try std.testing.expect(saw_separator and saw_wrapped_purpose);
}

test "pads table cells around vertical separators" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "| A | B |\n| --- | --- |\n| x | y |");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 30 });
    defer rendered.deinit(allocator);
    var found_separator = false;
    var found_cross = false;
    for (rendered.lines) |line| for (line.spans) |span| {
        if (std.mem.indexOf(u8, span.text, "\u{2502}") != null) found_separator = true;
        if (std.mem.indexOf(u8, span.text, "\u{253c}") != null) found_cross = true;
    };
    try std.testing.expect(found_separator and found_cross);
}

test "keeps inline code foreground-only and pads fenced code blocks" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "Inline `code`\n\n```zig\nconst value = 1;\nx\n```");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 80 });
    defer rendered.deinit(allocator);
    var saw_inline_code = false;
    for (rendered.lines[0].spans) |span| if (std.mem.eql(u8, span.text, "code")) {
        try std.testing.expectEqual(SpanStyle.code, span.style);
        saw_inline_code = true;
    };
    try std.testing.expect(saw_inline_code);
    const short_line = rendered.lines[4];
    try std.testing.expectEqual(SpanStyle.code_block, short_line.spans[short_line.spans.len - 1].style);
    try std.testing.expect(std.mem.startsWith(u8, short_line.spans[short_line.spans.len - 1].text, " x"));
}

test "table rows match rule width and respect terminal width" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "| Name | Command |\n| --- | --- |\n| run | `go run` |");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 50, .left_padding = 0 });
    defer rendered.deinit(allocator);
    var expected: ?usize = null;
    for (rendered.lines) |line| {
        const width = line.displayWidth();
        if (width == 0) continue;
        if (expected) |value| try std.testing.expectEqual(value, width) else expected = width;
        try std.testing.expect(width <= 50);
    }
}

test "nested lists have indentation and varying bullet shapes" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator, "- Level 1\n  - Level 2\n    - Level 3");
    defer document.deinit(allocator);
    var rendered = try renderDocument(allocator, document, .{ .width = 80, .left_padding = 2 });
    defer rendered.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), rendered.lines.len);
    const glyphs = [_][]const u8{ "\u{2022}", "\u{25E6}", "\u{2023}" };
    for (glyphs, 0..) |glyph, index| {
        var found = false;
        for (rendered.lines[index].spans) |span| if (std.mem.indexOf(u8, span.text, glyph) != null) {
            found = true;
        };
        try std.testing.expect(found);
    }
    try std.testing.expect(markerColumn(rendered.lines[1]) > markerColumn(rendered.lines[0]));
    try std.testing.expect(markerColumn(rendered.lines[2]) > markerColumn(rendered.lines[1]));
}

fn presetPalette(allocator: std.mem.Allocator, name: []const u8) !theme.StyleMap {
    var registry = resolve.Registry.init(allocator);
    defer registry.deinit();
    var diagnostics = resolve.Diagnostics.init(allocator);
    defer diagnostics.deinit();
    return (try registry.resolve(name, .default, null, &diagnostics)).styles;
}

test "marker slots preserve built-in palette values" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "dark", "light" }) |name| {
        const palette = try presetPalette(allocator, name);
        try std.testing.expectEqual(palette.muted.fg, palette.bullet.fg);
        try std.testing.expectEqual(palette.muted.fg, palette.task_on.fg);
        try std.testing.expectEqual(palette.muted.fg, palette.task_off.fg);
    }
    const dark = try presetPalette(allocator, "dark");
    try std.testing.expectEqual(cidx(74), dark.ordered.fg);
    const markview = try presetPalette(allocator, "markview");
    try std.testing.expectEqual(rgb(0xF3, 0x8B, 0xA8), markview.bullet.fg);
    try std.testing.expectEqual(rgb(0xA6, 0xE3, 0xA1), markview.task_on.fg);
}

fn markerColumn(line: Line) usize {
    var column: usize = 0;
    for (line.spans) |span| for (span.text) |byte| {
        if (byte != ' ') return column;
        column += 1;
    };
    return column;
}

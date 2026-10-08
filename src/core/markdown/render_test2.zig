const std = @import("std");
const markdown = @import("parser.zig");
const render_model = @import("render.zig");

const renderDocument = render_model.renderDocument;
const Line = render_model.Line;

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

test "table rows match rule width and respect terminal width" {
    const allocator = std.testing.allocator;
    const sources = [_][]const u8{
        "| Name | Command |\n| --- | --- |\n| run | `go run` |",
        // Too wide for 50 columns: the Purpose cell wraps and keeps its text.
        "| Package | Version | Purpose |\n| :--- | ---: | :--- |\n| oidc-provider | ^8.4.0 | Core OIDC implementation |",
    };
    for (sources) |source| {
        var document = try markdown.parse(allocator, source);
        defer document.deinit(allocator);
        var rendered = try renderDocument(allocator, document, .{ .width = 50, .left_padding = 0 });
        defer rendered.deinit(allocator);
        var expected: ?usize = null;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(allocator);
        for (rendered.lines) |line| {
            for (line.spans) |span| try text.appendSlice(allocator, span.text);
            const width = line.displayWidth();
            if (width == 0) continue;
            if (expected) |value| try std.testing.expectEqual(value, width) else expected = width;
            try std.testing.expect(width <= 50);
        }
        if (std.mem.indexOf(u8, source, "Purpose") != null) {
            try std.testing.expect(std.mem.indexOf(u8, text.items, "Core OIDC") != null);
            try std.testing.expect(std.mem.indexOf(u8, text.items, "implementation") != null);
        }
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

fn markerColumn(line: Line) usize {
    var column: usize = 0;
    for (line.spans) |span| for (span.text) |byte| {
        if (byte != ' ') return column;
        column += 1;
    };
    return column;
}

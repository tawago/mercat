const std = @import("std");
const markdown = @import("../core/markdown.zig");
const render_model = @import("../core/render_model.zig");
const theme = @import("../core/theme.zig");
const ansi = @import("../lib/ansi.zig");

pub const Options = struct {
    width: usize,
    palette: theme.Palette,
    show_heading_markers: bool = true,
};

pub fn renderDocument(allocator: std.mem.Allocator, document: markdown.Document, options: Options) ![]u8 {
    var rendered = try render_model.renderDocument(allocator, document, .{
        .width = options.width,
        .show_heading_markers = options.show_heading_markers,
    });
    defer rendered.deinit(allocator);

    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    for (rendered.lines, 0..) |line, line_index| {
        if (line_index != 0) try buffer.append(allocator, '\n');
        for (line.spans) |span| {
            const token = theme.token(options.palette, span.style);
            if (span.url) |url| {
                try ansi.writeHyperlink(allocator, &buffer, url, span.text, token);
            } else {
                try ansi.writeTokenStyled(allocator, &buffer, token, span.text);
            }
        }
    }

    return try buffer.toOwnedSlice(allocator);
}

test "renders heading and paragraph" {
    const allocator = std.testing.allocator;
    const source =
        \\# Title
        \\
        \\A paragraph of text that wraps.
    ;
    var document = try markdown.parse(allocator, source);
    defer document.deinit(allocator);

    const rendered = try renderDocument(allocator, document, .{
        .width = 20,
        .palette = theme.palette(.dark, .default),
        .show_heading_markers = true,
    });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Title") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "paragraph") != null);
}

test "renders table with borders" {
    const allocator = std.testing.allocator;
    const source =
        \\| Name | Value |
        \\| ---- | ----- |
        \\| a    | 1     |
    ;
    var document = try markdown.parse(allocator, source);
    defer document.deinit(allocator);

    const rendered = try renderDocument(allocator, document, .{ .width = 80, .palette = theme.palette(.dark, .default), .show_heading_markers = true });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "────") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, ":---") == null);
}

test "renders highlighted code fence" {
    const allocator = std.testing.allocator;
    const source =
        \\```zig
        \\const n = 42;
        \\```
    ;
    var document = try markdown.parse(allocator, source);
    defer document.deinit(allocator);

    const rendered = try renderDocument(allocator, document, .{ .width = 80, .palette = theme.palette(.dark, .default), .show_heading_markers = true });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "const") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "42") != null);
}

test "renders inline markdown styling" {
    const allocator = std.testing.allocator;
    const source =
        \\Paragraph with *emphasis*, **strong**, `code`, and site <https://example.com>.
    ;
    var document = try markdown.parse(allocator, source);
    defer document.deinit(allocator);

    const palette = theme.palette(.dark, .default);
    const rendered = try renderDocument(allocator, document, .{ .width = 100, .palette = palette, .show_heading_markers = true });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[") != null);
}

test "can hide heading markers" {
    const allocator = std.testing.allocator;
    var document = try markdown.parse(allocator,
        \\### Title
    );
    defer document.deinit(allocator);

    const rendered = try renderDocument(allocator, document, .{ .width = 40, .palette = theme.palette(.dark, .default), .show_heading_markers = false });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "###") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Title") != null);
}

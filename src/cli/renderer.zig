const std = @import("std");
const markdown = @import("../core/markdown.zig");
const render_model = @import("../core/render_model.zig");
const theme = @import("../core/theme.zig");
const ansi = @import("../lib/ansi.zig");
const mermaid_types = @import("../core/mermaid/types.zig");

pub const Options = struct {
    width: usize,
    palette: theme.Palette,
    show_heading_markers: bool = true,
    mermaid_box_style: mermaid_types.BoxDrawingStyle = .standard,
    mermaid_crossing_heuristic: mermaid_types.CrossingReductionHeuristic = .median,
    mermaid_force_layout: mermaid_types.ForceLayout = .auto,
    mermaid_aspect_ratio: f32 = 1.0,
    mermaid_debug: bool = false,
    mermaid_subgraph_edges: @import("prim").SubgraphEdges = .bridge,
};

pub fn renderDocument(allocator: std.mem.Allocator, document: markdown.Document, options: Options) ![]u8 {
    var rendered = try render_model.renderDocument(allocator, document, .{
        .width = options.width,
        .show_heading_markers = options.show_heading_markers,
        .mermaid_box_style = options.mermaid_box_style,
        .mermaid_crossing_heuristic = options.mermaid_crossing_heuristic,
        .mermaid_force_layout = options.mermaid_force_layout,
        .mermaid_aspect_ratio = options.mermaid_aspect_ratio,
        .mermaid_debug = options.mermaid_debug,
        .mermaid_subgraph_edges = options.mermaid_subgraph_edges,
    });
    defer rendered.deinit(allocator);

    return serialize(allocator, rendered, options.palette);
}

/// Serialize an already-rendered value to ANSI-styled terminal bytes. This is
/// the terminal backend of the format dispatch: `main.zig` calls
/// `render_model.renderDocument()` once and hands the owned `Rendered` here so
/// the semantic layout is not recomputed per format.
pub fn serialize(
    allocator: std.mem.Allocator,
    rendered: render_model.Rendered,
    palette: theme.Palette,
) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    for (rendered.lines, 0..) |line, line_index| {
        if (line_index != 0) try buffer.append(allocator, '\n');
        for (line.spans) |span| {
            const token = theme.token(palette, span.style);
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

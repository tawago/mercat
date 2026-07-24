const std = @import("std");
const markdown = @import("../core/markdown.zig");
const render_model = @import("../core/render_model.zig");
const theme = @import("../core/theme.zig");
const ansi = @import("../lib/ansi.zig");
const mermaid_types = @import("../core/mermaid/types.zig");
const Color = @import("../core/theme/color.zig").Color;

/// Solid-background ("canvas") fill request for the terminal backend. When
/// present, every line's background is painted with `bg` and padded with
/// bg-styled spaces to `width`; spans that carry their own bg keep it. When
/// `null`, serialization is byte-identical to the historical terminal output.
pub const Canvas = struct {
    bg: Color,
    width: usize,
};

pub const Options = struct {
    width: usize,
    palette: theme.Palette,
    show_heading_markers: bool = true,
    frontmatter_style: @import("../core/config.zig").FrontmatterStyle = .panel,
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
        .frontmatter_style = options.frontmatter_style,
        .mermaid_box_style = options.mermaid_box_style,
        .mermaid_crossing_heuristic = options.mermaid_crossing_heuristic,
        .mermaid_force_layout = options.mermaid_force_layout,
        .mermaid_aspect_ratio = options.mermaid_aspect_ratio,
        .mermaid_debug = options.mermaid_debug,
        .mermaid_subgraph_edges = options.mermaid_subgraph_edges,
    });
    defer rendered.deinit(allocator);

    return serialize(allocator, rendered, options.palette, null);
}

/// Serialize an already-rendered value to ANSI-styled terminal bytes. This is
/// the terminal backend of the format dispatch: `main.zig` calls
/// `render_model.renderDocument()` once and hands the owned `Rendered` here so
/// the semantic layout is not recomputed per format.
pub fn serialize(
    allocator: std.mem.Allocator,
    rendered: render_model.Rendered,
    palette: theme.Palette,
    canvas: ?Canvas,
) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    for (rendered.lines, 0..) |line, line_index| {
        if (line_index != 0) try buffer.append(allocator, '\n');
        for (line.spans) |span| {
            var token = theme.token(palette, span.style);
            // Canvas: spans without their own bg inherit the base_bg so the row
            // reads as a solid sheet; spans that carry a bg (code panels, tints)
            // keep theirs. Each writeTokenStyled resets at its own end, so no
            // color bleeds past a span boundary.
            if (canvas) |c| {
                if (token.bg == null) token.bg = c.bg;
            }
            if (span.url) |url| {
                try ansi.writeHyperlink(allocator, &buffer, url, span.text, token);
            } else {
                try ansi.writeTokenStyled(allocator, &buffer, token, span.text);
            }
        }
        // Canvas: pad the row with bg-styled spaces out to the full width so the
        // background is solid to the right margin (and blank lines fill too).
        // This is the one exception to trailing-space stripping. The fill span
        // resets at its end, so nothing bleeds past the line.
        if (canvas) |c| {
            const cur = line.displayWidth();
            if (cur < c.width) {
                const pad = c.width - cur;
                const spaces = try allocator.alloc(u8, pad);
                defer allocator.free(spaces);
                @memset(spaces, ' ');
                try ansi.writeTokenStyled(allocator, &buffer, .{ .fg = .default, .bg = c.bg }, spaces);
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

const color = @import("../core/theme/color.zig");

// Helper: build a Rendered from markdown for the serialize-path canvas tests.
fn renderFor(allocator: std.mem.Allocator, src: []const u8, width: usize) !render_model.Rendered {
    var document = try markdown.parse(allocator, src);
    defer document.deinit(allocator);
    return render_model.renderDocument(allocator, document, .{ .width = width, .show_heading_markers = true });
}

test "canvas serialization fills every line to width with a bg run and resets at EOL" {
    const allocator = std.testing.allocator;
    color.setTruecolor(true);
    defer color.setTruecolor(false);
    const width: usize = 24;
    var rendered = try renderFor(allocator, "# Hi\n\nbody", width);
    defer rendered.deinit(allocator);

    const bg = color.rgb(40, 42, 54);
    const out = try serialize(allocator, rendered, theme.palette(.dark, .default), .{ .bg = bg, .width = width });
    defer allocator.free(out);

    // The canvas bg SGR (48;2;r;g;b) is emitted.
    try std.testing.expect(std.mem.indexOf(u8, out, "48;2;40;42;54") != null);

    // Every physical line, stripped of ANSI, is padded to the full width, and
    // every newline is immediately preceded by a reset (no bg bleeds past EOL).
    var it = std.mem.splitScalar(u8, out, '\n');
    const unicode = @import("../lib/unicode.zig");
    while (it.next()) |raw_line| {
        const plain = try ansi.stripAlloc(allocator, raw_line);
        defer allocator.free(plain);
        try std.testing.expectEqual(width, unicode.displayWidth(plain));
        try std.testing.expect(std.mem.endsWith(u8, raw_line, "\x1b[0m"));
    }
}

test "canvas off leaves serialization unpadded and free of the canvas bg" {
    const allocator = std.testing.allocator;
    color.setTruecolor(true);
    defer color.setTruecolor(false);
    const width: usize = 24;
    var rendered = try renderFor(allocator, "# Hi\n\nbody", width);
    defer rendered.deinit(allocator);

    const off = try serialize(allocator, rendered, theme.palette(.dark, .default), null);
    defer allocator.free(off);

    // No canvas bg, and short lines stay short (historical trailing-space
    // stripping preserved).
    try std.testing.expect(std.mem.indexOf(u8, off, "48;2;40;42;54") == null);
    const unicode = @import("../lib/unicode.zig");
    var it = std.mem.splitScalar(u8, off, '\n');
    var saw_short = false;
    while (it.next()) |raw_line| {
        const plain = try ansi.stripAlloc(allocator, raw_line);
        defer allocator.free(plain);
        if (unicode.displayWidth(plain) < width) saw_short = true;
    }
    try std.testing.expect(saw_short);
}

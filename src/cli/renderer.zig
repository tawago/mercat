const std = @import("std");
const markdown = @import("../core/markdown/parser.zig");
const render_model = @import("../core/markdown/render.zig");
const theme = @import("../core/theme.zig");
const ansi = @import("../lib/ansi.zig");
const mermaid_types = @import("../core/mermaid/types.zig");
const Color = @import("../core/theme/color.zig").Color;

/// Solid-background ("canvas") fill request for the terminal backend. When
/// present, every line's background is painted with `bg` and padded with
/// bg-styled spaces to `width`; spans that carry their own bg keep it. When
/// `null`, serialization is byte-identical to the historical terminal output
/// (the un-themed neutral palettes have no `base_bg`, so `main.zig` passes
/// `null` and the coalescing path below is unchanged).
pub const Canvas = struct {
    bg: Color,
    width: usize,
};

pub const Options = struct {
    width: usize,
    palette: theme.StyleMap,
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
    palette: theme.StyleMap,
    canvas: ?Canvas,
) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    var run_token: ?theme.StyleToken = null;
    var run_open = false;

    const flushRun = struct {
        fn call(a: std.mem.Allocator, buf: *std.ArrayList(u8), tok: *?theme.StyleToken, open: *bool) !void {
            if (open.*) try buf.appendSlice(a, ansi.reset_sequence);
            tok.* = null;
            open.* = false;
        }
    }.call;

    for (rendered.lines, 0..) |line, line_index| {
        try flushRun(allocator, &buffer, &run_token, &run_open);
        if (line_index != 0) try buffer.append(allocator, '\n');
        for (line.spans) |span| {
            var token = theme.token(palette, span.style);
            if (canvas) |c| {
                if (token.bg == null) token.bg = c.bg;
            }
            if (span.url) |url| {
                try flushRun(allocator, &buffer, &run_token, &run_open);
                try ansi.writeHyperlink(allocator, &buffer, url, span.text, token);
            } else {
                if (run_token != null and !std.meta.eql(run_token.?, token)) {
                    try flushRun(allocator, &buffer, &run_token, &run_open);
                }
                run_token = token;
                if (span.text.len != 0) {
                    if (!run_open) {
                        try ansi.writeTokenPrefix(allocator, &buffer, token);
                        run_open = true;
                    }
                    try buffer.appendSlice(allocator, span.text);
                }
            }
        }
        if (canvas) |c| {
            try flushRun(allocator, &buffer, &run_token, &run_open);
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
    try flushRun(allocator, &buffer, &run_token, &run_open);

    return try buffer.toOwnedSlice(allocator);
}

test "coalesces distinct SpanStyles that map to one StyleToken into a single run" {
    const allocator = std.testing.allocator;
    const palette = theme.neutralDark;

    try std.testing.expectEqual(theme.token(palette, .body), theme.token(palette, .table_header));

    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "bar", .style = .table_header },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette, null);
    defer allocator.free(out);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "foo");
    try expected.appendSlice(allocator, "bar");
    try expected.appendSlice(allocator, ansi.reset_sequence);

    try std.testing.expectEqualStrings(expected.items, out);
}

test "token change mid-line closes the run and opens a new prefix" {
    const allocator = std.testing.allocator;
    const palette = theme.neutralDark;

    try std.testing.expect(!std.meta.eql(theme.token(palette, .body), theme.token(palette, .emphasis)));

    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "bar", .style = .emphasis },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette, null);
    defer allocator.free(out);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "foo");
    try expected.appendSlice(allocator, ansi.reset_sequence);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .emphasis));
    try expected.appendSlice(allocator, "bar");
    try expected.appendSlice(allocator, ansi.reset_sequence);

    try std.testing.expectEqualStrings(expected.items, out);
}

test "same-token empty span leaves the run open" {
    const allocator = std.testing.allocator;
    const palette = theme.neutralDark;

    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "", .style = .table_header },
        .{ .text = "bar", .style = .body },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette, null);
    defer allocator.free(out);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "foo");
    try expected.appendSlice(allocator, "bar");
    try expected.appendSlice(allocator, ansi.reset_sequence);

    try std.testing.expectEqualStrings(expected.items, out);
}

test "different-token empty span closes the run without opening a new prefix" {
    const allocator = std.testing.allocator;
    const palette = theme.neutralDark;

    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "", .style = .emphasis },
        .{ .text = "bar", .style = .body },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette, null);
    defer allocator.free(out);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "foo");
    try expected.appendSlice(allocator, ansi.reset_sequence);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "bar");
    try expected.appendSlice(allocator, ansi.reset_sequence);

    try std.testing.expectEqualStrings(expected.items, out);

    var emph: std.ArrayList(u8) = .empty;
    defer emph.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &emph, theme.token(palette, .emphasis));
    try std.testing.expect(std.mem.indexOf(u8, out, emph.items) == null);
}

test "run resets at line end and newlines sit between lines with no leading newline" {
    const allocator = std.testing.allocator;
    const palette = theme.neutralDark;

    var spans0 = [_]render_model.Span{.{ .text = "a", .style = .body }};
    var spans1 = [_]render_model.Span{.{ .text = "b", .style = .body }};
    var lines = [_]render_model.Line{
        .{ .spans = &spans0 },
        .{ .spans = &spans1 },
    };
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette, null);
    defer allocator.free(out);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "a");
    try expected.appendSlice(allocator, ansi.reset_sequence);
    try expected.append(allocator, '\n');
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "b");
    try expected.appendSlice(allocator, ansi.reset_sequence);

    try std.testing.expectEqualStrings(expected.items, out);

    try std.testing.expect(!std.mem.startsWith(u8, out, "\n"));
}

test "blank middle line emits its own newline without an SGR run" {
    const allocator = std.testing.allocator;
    const palette = theme.neutralDark;

    var spans0 = [_]render_model.Span{.{ .text = "a", .style = .body }};
    var spans1 = [_]render_model.Span{};
    var spans2 = [_]render_model.Span{.{ .text = "b", .style = .body }};
    var lines = [_]render_model.Line{
        .{ .spans = &spans0 },
        .{ .spans = &spans1 },
        .{ .spans = &spans2 },
    };
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette, null);
    defer allocator.free(out);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "a");
    try expected.appendSlice(allocator, ansi.reset_sequence);
    try expected.append(allocator, '\n');
    try expected.append(allocator, '\n');
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "b");
    try expected.appendSlice(allocator, ansi.reset_sequence);

    try std.testing.expectEqualStrings(expected.items, out);
}

test "hyperlink span flushes the run and neighbours re-open around it" {
    const allocator = std.testing.allocator;
    const palette = theme.neutralDark;
    const url = "https://example.com";

    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "link", .style = .link, .url = url },
        .{ .text = "bar", .style = .body },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette, null);
    defer allocator.free(out);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "foo");
    try expected.appendSlice(allocator, ansi.reset_sequence);
    try ansi.writeHyperlink(allocator, &expected, url, "link", theme.token(palette, .link));
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "bar");
    try expected.appendSlice(allocator, ansi.reset_sequence);

    try std.testing.expectEqualStrings(expected.items, out);
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
        .palette = theme.neutralDark,
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

    const rendered = try renderDocument(allocator, document, .{ .width = 80, .palette = theme.neutralDark, .show_heading_markers = true });
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

    const rendered = try renderDocument(allocator, document, .{ .width = 80, .palette = theme.neutralDark, .show_heading_markers = true });
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

    const palette = theme.neutralDark;
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

    const rendered = try renderDocument(allocator, document, .{ .width = 40, .palette = theme.neutralDark, .show_heading_markers = false });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "###") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Title") != null);
}

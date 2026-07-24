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

    // Coalesce consecutive non-hyperlink spans that resolve to the same
    // StyleToken into a single SGR run: emit the style prefix once when a run's
    // first non-empty span arrives, append each matching span's text straight
    // into `buffer`, and emit the reset when the token changes or the line ends.
    // Distinct SpanStyle enums (e.g. body vs table_header) can map to an
    // identical token under a given theme; emitting one SGR run for them keeps
    // default-theme output byte-identical to the pre-Issue-17 renderer, where
    // those slots shared a single enum. An empty-text span with a different
    // token still closes the current run (matching the pre-refactor per-run
    // flush); a same-token empty span leaves the run open.
    var run_token: ?theme.StyleToken = null;
    var run_open = false; // prefix emitted for the current run, reset still pending

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
            const token = theme.token(palette, span.style);
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
    }
    try flushRun(allocator, &buffer, &run_token, &run_open);

    return try buffer.toOwnedSlice(allocator);
}

// --- Span-coalescing serializer unit tests (Issue 17) ------------------------
//
// These pin the lazy-prefix / coalesce-run / reset-on-change behavior of
// serialize() and the ansi prefix/reset helpers it drives. Fixtures are built
// directly as Rendered{ .lines = []Line{ .spans = []Span } } with string
// literals so no fixture allocation/free is needed (serialize() never frees the
// Rendered it consumes). Expected bytes are assembled from the same ansi
// constants and helpers serialize() uses, so no escape bytes are hard-coded.

test "coalesces distinct SpanStyles that map to one StyleToken into a single run" {
    const allocator = std.testing.allocator;
    const palette = theme.palette(.dark, .default, .{});

    // .body and .table_header are different SpanStyle enums but table_header is
    // stamped equal to body in the palette, so they resolve to one StyleToken.
    try std.testing.expectEqual(theme.token(palette, .body), theme.token(palette, .table_header));

    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "bar", .style = .table_header },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette);
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
    const palette = theme.palette(.dark, .default, .{});

    try std.testing.expect(!std.meta.eql(theme.token(palette, .body), theme.token(palette, .emphasis)));

    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "bar", .style = .emphasis },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette);
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
    const palette = theme.palette(.dark, .default, .{});

    // Empty span between two body spans (via table_header, same token) must not
    // close/reopen the run: the whole line is one prefix/reset pair.
    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "", .style = .table_header },
        .{ .text = "bar", .style = .body },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette);
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
    const palette = theme.palette(.dark, .default, .{});

    // The empty emphasis span closes the open body run (emits a reset) but must
    // NOT emit an emphasis prefix, because it carries no text. The next body
    // span then re-opens a fresh body prefix. Net: two body runs, one reset each,
    // and no emphasis SGR anywhere.
    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "", .style = .emphasis },
        .{ .text = "bar", .style = .body },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette);
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

    // No emphasis SGR was emitted for the empty span.
    var emph: std.ArrayList(u8) = .empty;
    defer emph.deinit(allocator);
    try ansi.writeTokenPrefix(allocator, &emph, theme.token(palette, .emphasis));
    try std.testing.expect(std.mem.indexOf(u8, out, emph.items) == null);
}

test "run resets at line end and newlines sit between lines with no leading newline" {
    const allocator = std.testing.allocator;
    const palette = theme.palette(.dark, .default, .{});

    var spans0 = [_]render_model.Span{.{ .text = "a", .style = .body }};
    var spans1 = [_]render_model.Span{.{ .text = "b", .style = .body }};
    var lines = [_]render_model.Line{
        .{ .spans = &spans0 },
        .{ .spans = &spans1 },
    };
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette);
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

    // First line carries no leading newline; reset precedes the separator.
    try std.testing.expect(!std.mem.startsWith(u8, out, "\n"));
}

test "blank middle line emits its own newline without an SGR run" {
    const allocator = std.testing.allocator;
    const palette = theme.palette(.dark, .default, .{});

    var spans0 = [_]render_model.Span{.{ .text = "a", .style = .body }};
    var spans1 = [_]render_model.Span{}; // empty line
    var spans2 = [_]render_model.Span{.{ .text = "b", .style = .body }};
    var lines = [_]render_model.Line{
        .{ .spans = &spans0 },
        .{ .spans = &spans1 },
        .{ .spans = &spans2 },
    };
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette);
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
    const palette = theme.palette(.dark, .default, .{});
    const url = "https://example.com";

    var spans = [_]render_model.Span{
        .{ .text = "foo", .style = .body },
        .{ .text = "link", .style = .link, .url = url },
        .{ .text = "bar", .style = .body },
    };
    var lines = [_]render_model.Line{.{ .spans = &spans }};
    const rendered = render_model.Rendered{ .lines = &lines };

    const out = try serialize(allocator, rendered, palette);
    defer allocator.free(out);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    // Run before the hyperlink closes first.
    try ansi.writeTokenPrefix(allocator, &expected, theme.token(palette, .body));
    try expected.appendSlice(allocator, "foo");
    try expected.appendSlice(allocator, ansi.reset_sequence);
    // The hyperlink is emitted by the OSC 8 helper, self-contained.
    try ansi.writeHyperlink(allocator, &expected, url, "link", theme.token(palette, .link));
    // The trailing body span re-opens a fresh run.
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
        .palette = theme.palette(.dark, .default, .{}),
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

    const rendered = try renderDocument(allocator, document, .{ .width = 80, .palette = theme.palette(.dark, .default, .{}), .show_heading_markers = true });
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

    const rendered = try renderDocument(allocator, document, .{ .width = 80, .palette = theme.palette(.dark, .default, .{}), .show_heading_markers = true });
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

    const palette = theme.palette(.dark, .default, .{});
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

    const rendered = try renderDocument(allocator, document, .{ .width = 40, .palette = theme.palette(.dark, .default, .{}), .show_heading_markers = false });
    defer allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "###") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Title") != null);
}

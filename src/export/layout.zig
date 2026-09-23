const std = @import("std");

const render_model = @import("../core/markdown/render/types.zig");
const theme = @import("../core/theme.zig");
const color = @import("../core/theme/color.zig");
const unicode = @import("unicode");
const font = @import("font.zig");
const types = @import("types.zig");

const Color = types.Color;
const Decoration = types.Decoration;
const PositionedRun = types.PositionedRun;
const Geometry = types.Geometry;
const ExportDocument = types.ExportDocument;

pub const ColorMode = enum { theme, monochrome };

pub const Options = struct {
    palette: theme.StyleMap,
    color_mode: ColorMode,
    canvas_bg: ?color.Color = null,
    font_pixel_height: u16 = 20,
    horizontal_padding_cells: u16 = 1,
    vertical_padding_cells: u16 = 1,
};

pub const Error = std.mem.Allocator.Error || Geometry.PixelError || error{
    InvalidControlScalar,
    InvalidUtf8,
    ColumnOverflow,
};

const white: Color = .{ .r = 255, .g = 255, .b = 255 };
const black: Color = .{ .r = 0, .g = 0, .b = 0 };

pub fn build(
    allocator: std.mem.Allocator,
    rendered: render_model.Rendered,
    face: *const font.Font,
    options: Options,
) Error!ExportDocument {
    const geometry = try buildGeometry(face, options);

    var runs: std.ArrayList(PositionedRun) = .empty;
    errdefer freeRuns(allocator, &runs);

    var max_columns: u32 = 0;

    for (rendered.lines, 0..) |line, line_index| {
        const row: u32 = std.math.cast(u32, line_index) orelse return error.ColumnOverflow;
        const col = try appendLineRuns(allocator, &runs, row, line, options);
        max_columns = @max(max_columns, col);
    }

    const rows: u32 = if (rendered.lines.len == 0)
        1
    else
        std.math.cast(u32, rendered.lines.len) orelse return error.ColumnOverflow;

    const doc = ExportDocument{
        .rows = rows,
        .columns = max_columns,
        .geometry = geometry,
        .page_background = pageBackground(options),
        .runs = try runs.toOwnedSlice(allocator),
        .font_sha256 = face.sha256,
    };

    _ = try doc.pixelWidth();
    _ = try doc.pixelHeight();

    return doc;
}

fn buildGeometry(face: *const font.Font, options: Options) Error!Geometry {
    const pad_x = try mulU16(options.horizontal_padding_cells, face.cell_width_px);
    const pad_y = try mulU16(options.vertical_padding_cells, face.cell_height_px);

    const baseline_i32 = @as(i32, pad_y) + @as(i32, face.baseline_px);
    if (baseline_i32 > std.math.maxInt(i16)) return error.PixelOverflow;

    return .{
        .cell_width_px = face.cell_width_px,
        .cell_height_px = face.cell_height_px,
        .baseline_px = @intCast(baseline_i32),
        .padding_left_px = pad_x,
        .padding_right_px = pad_x,
        .padding_top_px = pad_y,
        .padding_bottom_px = pad_y,
    };
}

fn mulU16(a: u16, b: u16) Error!u16 {
    const product = @as(u32, a) * @as(u32, b);
    return std.math.cast(u16, product) orelse error.PixelOverflow;
}

fn appendLineRuns(
    allocator: std.mem.Allocator,
    runs: *std.ArrayList(PositionedRun),
    row: u32,
    line: render_model.Line,
    options: Options,
) Error!u32 {
    const text = try line.joinedText(allocator);
    defer allocator.free(text);

    var run_span_index: ?usize = null;
    var run_start_col: u32 = 0;
    var run_byte_start: usize = 0;
    var run_columns: u32 = 0;

    var span_index: usize = 0;
    var span_end: usize = if (line.spans.len == 0) 0 else line.spans[0].text.len;
    var graphemes = unicode.Iterator.init(text);
    while (try nextGrapheme(&graphemes)) |grapheme| {
        while (span_index < line.spans.len and grapheme.byte_start >= span_end) {
            span_index += 1;
            if (span_index < line.spans.len) span_end += line.spans[span_index].text.len;
        }
        if (span_index == line.spans.len) unreachable;

        if (run_span_index != null and run_span_index.? != span_index) {
            try appendRun(
                allocator,
                runs,
                row,
                run_start_col,
                run_columns,
                text[run_byte_start..grapheme.byte_start],
                line.spans[run_span_index.?],
                options,
            );
            run_columns = 0;
            run_span_index = null;
        }
        if (run_span_index == null) {
            run_span_index = span_index;
            run_start_col = std.math.cast(u32, grapheme.column_start) orelse return error.ColumnOverflow;
            run_byte_start = grapheme.byte_start;
        }

        run_columns = std.math.add(u32, run_columns, @intCast(grapheme.width)) catch return error.ColumnOverflow;
    }

    if (run_span_index) |owner| {
        try appendRun(
            allocator,
            runs,
            row,
            run_start_col,
            run_columns,
            text[run_byte_start..],
            line.spans[owner],
            options,
        );
    }
    return std.math.cast(u32, graphemes.column) orelse return error.ColumnOverflow;
}

pub fn nextGrapheme(iterator: *unicode.Iterator) Error!?unicode.GraphemeSlice {
    return iterator.next() catch |err| switch (err) {
        error.InvalidUtf8 => error.InvalidUtf8,
        error.DisallowedControl => error.InvalidControlScalar,
        error.Overflow => error.ColumnOverflow,
    };
}

fn appendRun(
    allocator: std.mem.Allocator,
    runs: *std.ArrayList(PositionedRun),
    row: u32,
    start_col: u32,
    columns: u32,
    text: []const u8,
    span: render_model.Span,
    options: Options,
) Error!void {
    const style = theme.token(options.palette, span.style);

    const foreground: Color = switch (options.color_mode) {
        .theme => srgbOf(style.fg) orelse black,
        .monochrome => black,
    };
    const background: ?Color = switch (options.color_mode) {
        .theme => if (style.bg) |bg| srgbOf(bg) else null,
        .monochrome => null,
    };

    const text_copy = try allocator.dupe(u8, text);
    errdefer allocator.free(text_copy);
    const url_copy: ?[]const u8 = if (span.url) |u| try allocator.dupe(u8, u) else null;
    errdefer if (url_copy) |u| allocator.free(u);

    try runs.append(allocator, .{
        .text = text_copy,
        .row = row,
        .start_col = start_col,
        .columns = columns,
        .foreground = foreground,
        .background = background,
        .decoration = .{
            .underline = style.underline,
            .strikethrough = style.strikethrough,
        },
        .semantic_style = span.style,
        .url = url_copy,
    });
}

fn freeRuns(allocator: std.mem.Allocator, runs: *std.ArrayList(PositionedRun)) void {
    for (runs.items) |run| {
        allocator.free(run.text);
        if (run.url) |u| allocator.free(u);
    }
    runs.deinit(allocator);
}

fn pageBackground(options: Options) Color {
    if (options.color_mode == .monochrome) return white;
    if (options.canvas_bg) |bg| {
        if (srgbOf(bg)) |c| return c;
    }
    const body_fg = srgbOf(options.palette.body.fg) orelse black;
    return if (luminance(body_fg) > 128) black else white;
}

fn luminance(c: Color) u32 {
    return (@as(u32, c.r) * 299 + @as(u32, c.g) * 587 + @as(u32, c.b) * 114) / 1000;
}

pub fn xterm256ToSrgb(index: u8) Color {
    const s = color.xterm256ToSrgb(index);
    return .{ .r = s.r, .g = s.g, .b = s.b };
}

fn srgbOf(c: color.Color) ?Color {
    const s = color.toSrgb(c) orelse return null;
    return .{ .r = s.r, .g = s.g, .b = s.b };
}

const testing = std.testing;

const Span = render_model.Span;
const Line = render_model.Line;
const Rendered = render_model.Rendered;

fn testOptions(mode: ColorMode) Options {
    return .{ .palette = theme.neutralDark, .color_mode = mode };
}

fn makeSpan(text: []const u8, style: render_model.SpanStyle) Span {
    return .{ .text = text, .style = style };
}

test "xterm-256 table matches known cube and grayscale anchors" {
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, xterm256ToSrgb(0));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, xterm256ToSrgb(15));
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, xterm256ToSrgb(16));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, xterm256ToSrgb(231));
    try testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, xterm256ToSrgb(196));
    try testing.expectEqual(Color{ .r = 8, .g = 8, .b = 8 }, xterm256ToSrgb(232));
    try testing.expectEqual(Color{ .r = 238, .g = 238, .b = 238 }, xterm256ToSrgb(255));
}

test "span to column mapping records start_col and columns" {
    const face = try font.Font.init(20);
    var spans = [_]Span{ makeSpan("foo", .body), makeSpan("barbaz", .code) };
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };

    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), doc.rows);
    try testing.expectEqual(@as(u32, 9), doc.columns);
    try testing.expectEqual(@as(usize, 2), doc.runs.len);
    try testing.expectEqual(@as(u32, 0), doc.runs[0].start_col);
    try testing.expectEqual(@as(u32, 3), doc.runs[0].columns);
    try testing.expectEqual(@as(u32, 3), doc.runs[1].start_col);
    try testing.expectEqual(@as(u32, 6), doc.runs[1].columns);
    try testing.expectEqualStrings("barbaz", doc.runs[1].text);
}

test "empty spans emit no run but empty lines still count as rows" {
    const face = try font.Font.init(20);
    var spans0 = [_]Span{makeSpan("a", .body)};
    var empty = [_]Span{};
    var spans2 = [_]Span{makeSpan("b", .body)};
    var lines = [_]Line{
        .{ .spans = &spans0 },
        .{ .spans = &empty },
        .{ .spans = &spans2 },
    };
    const rendered = Rendered{ .lines = &lines };

    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), doc.rows);
    try testing.expectEqual(@as(usize, 2), doc.runs.len);
    try testing.expectEqual(@as(u32, 0), doc.runs[0].row);
    try testing.expectEqual(@as(u32, 2), doc.runs[1].row);
}

test "zero-line document lays out one padded row" {
    const face = try font.Font.init(20);
    const rendered = Rendered{ .lines = &.{} };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), doc.rows);
    try testing.expectEqual(@as(u32, 0), doc.columns);
    try testing.expectEqual(@as(usize, 0), doc.runs.len);
    try testing.expect((try doc.pixelHeight()) > 0);
    try testing.expect((try doc.pixelWidth()) > 0);
}

test "trailing spaces are preserved in run text and columns" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("hi   ", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("hi   ", doc.runs[0].text);
    try testing.expectEqual(@as(u32, 5), doc.runs[0].columns);
    try testing.expectEqual(@as(u32, 5), doc.columns);
}

test "wide characters occupy two cells" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("Ａb", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), doc.runs[0].columns);
    try testing.expectEqual(@as(u32, 3), doc.columns);
}

test "combining marks attach without advancing" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("e\u{0301}", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), doc.runs[0].columns);
    try testing.expectEqual(@as(u32, 1), doc.columns);
}

test "base style owns a grapheme crossing a style boundary" {
    const face = try font.Font.init(20);
    var spans = [_]Span{ makeSpan("e", .body), makeSpan("\u{0301}x", .emphasis) };
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 2), doc.columns);
    try testing.expectEqual(@as(usize, 2), doc.runs.len);
    try testing.expectEqualStrings("e\u{0301}", doc.runs[0].text);
    try testing.expectEqual(render_model.SpanStyle.body, doc.runs[0].semantic_style);
    try testing.expectEqual(@as(u32, 1), doc.runs[0].columns);
    try testing.expectEqualStrings("x", doc.runs[1].text);
    try testing.expectEqual(render_model.SpanStyle.emphasis, doc.runs[1].semantic_style);
    try testing.expectEqual(@as(u32, 1), doc.runs[1].start_col);
}

test "Unicode sequence geometry follows the authority" {
    const face = try font.Font.init(20);
    const cases = [_]struct { text: []const u8, columns: u32 }{
        .{ .text = "👩‍💻", .columns = 2 },
        .{ .text = "🇯🇵", .columns = 2 },
        .{ .text = "#️⃣", .columns = 2 },
        .{ .text = "🏴\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}", .columns = 2 },
        .{ .text = "©︎", .columns = 1 },
        .{ .text = "©️", .columns = 2 },
        .{ .text = "日本", .columns = 4 },
        .{ .text = "·", .columns = 1 },
    };
    for (cases) |case| {
        var spans = [_]Span{makeSpan(case.text, .body)};
        var lines = [_]Line{.{ .spans = &spans }};
        var doc = try build(testing.allocator, .{ .lines = &lines }, &face, testOptions(.theme));
        defer doc.deinit(testing.allocator);
        try testing.expectEqual(case.columns, doc.columns);
        try testing.expectEqual(case.columns, doc.runs[0].columns);
    }
}

test "tabs use four-column stops after narrow and wide graphemes" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("a\t日\tx", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try build(testing.allocator, .{ .lines = &lines }, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("a\t日\tx", doc.runs[0].text);
    try testing.expectEqual(@as(u32, 9), doc.columns);
}

test "precomposed and decomposed text have equal geometry and distinct bytes" {
    const face = try font.Font.init(20);
    var composed_spans = [_]Span{makeSpan("é", .body)};
    var composed_lines = [_]Line{.{ .spans = &composed_spans }};
    var composed = try build(testing.allocator, .{ .lines = &composed_lines }, &face, testOptions(.theme));
    defer composed.deinit(testing.allocator);

    var decomposed_spans = [_]Span{ makeSpan("e", .body), makeSpan("\u{0301}", .emphasis) };
    var decomposed_lines = [_]Line{.{ .spans = &decomposed_spans }};
    var decomposed = try build(testing.allocator, .{ .lines = &decomposed_lines }, &face, testOptions(.theme));
    defer decomposed.deinit(testing.allocator);

    try testing.expectEqual(composed.columns, decomposed.columns);
    try testing.expectEqualStrings("é", composed.runs[0].text);
    try testing.expectEqualStrings("e\u{0301}", decomposed.runs[0].text);
    try testing.expect(!std.mem.eql(u8, composed.runs[0].text, decomposed.runs[0].text));
}

test "control scalar in rendered content is rejected" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("a\x07b", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidControlScalar, build(testing.allocator, rendered, &face, testOptions(.theme)));
}

test "Unicode format controls are rejected with the existing typed error" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("a\u{2060}b", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    try testing.expectError(error.InvalidControlScalar, build(testing.allocator, .{ .lines = &lines }, &face, testOptions(.theme)));
}

test "invalid utf8 in rendered content is rejected" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("\xff\xfe", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidUtf8, build(testing.allocator, rendered, &face, testOptions(.theme)));
}

test "themed color resolution maps through the xterm table" {
    const face = try font.Font.init(20);
    const palette = theme.neutralDark;
    var spans = [_]Span{makeSpan("code", .code)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, .{ .palette = palette, .color_mode = .theme });
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(xterm256ToSrgb(114), doc.runs[0].foreground);
    try testing.expectEqual(@as(?Color, null), doc.runs[0].background);
}

test "themed code block resolves a background rectangle" {
    const face = try font.Font.init(20);
    const palette = theme.neutralDark;
    var spans = [_]Span{makeSpan("x", .code_block)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, .{ .palette = palette, .color_mode = .theme });
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(?Color, xterm256ToSrgb(236)), doc.runs[0].background);
}

test "monochrome resolution forces black text, white page, no span background" {
    const face = try font.Font.init(20);
    var spans = [_]Span{ makeSpan("head", .heading1), makeSpan("code", .code_block) };
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.monochrome));
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(white, doc.page_background);
    for (doc.runs) |run| {
        try testing.expectEqual(black, run.foreground);
        try testing.expectEqual(@as(?Color, null), run.background);
    }
}

test "monochrome keeps geometric decorations" {
    const face = try font.Font.init(20);
    var spans = [_]Span{ makeSpan("a", .link), makeSpan("b", .strikethrough) };
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.monochrome));
    defer doc.deinit(testing.allocator);
    try testing.expect(doc.runs[0].decoration.underline);
    try testing.expect(doc.runs[1].decoration.strikethrough);
}

test "url metadata is preserved on the run" {
    const face = try font.Font.init(20);
    var spans = [_]Span{.{ .text = "link", .style = .link, .url = "https://example.com" }};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("https://example.com", doc.runs[0].url.?);
}

test "geometry derives padding and page baseline from font and options" {
    const face = try font.Font.init(20);
    const rendered = Rendered{ .lines = &.{} };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 9), doc.geometry.padding_left_px);
    try testing.expectEqual(@as(u16, 9), doc.geometry.padding_right_px);
    try testing.expectEqual(@as(u16, 20), doc.geometry.padding_top_px);
    try testing.expectEqual(@as(u16, 20), doc.geometry.padding_bottom_px);
    try testing.expectEqual(@as(i16, 36), doc.geometry.baseline_px);
}

test "hash is stable across two independent builds of the same document" {
    const face = try font.Font.init(20);
    var spans0 = [_]Span{ makeSpan("Title", .heading1), makeSpan(" x", .body) };
    var empty = [_]Span{};
    var spans2 = [_]Span{makeSpan("café →", .body)};
    var lines = [_]Line{
        .{ .spans = &spans0 },
        .{ .spans = &empty },
        .{ .spans = &spans2 },
    };
    const rendered = Rendered{ .lines = &lines };

    var doc_a = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc_a.deinit(testing.allocator);
    var doc_b = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc_b.deinit(testing.allocator);

    const ha = doc_a.canonicalSha256();
    const hb = doc_b.canonicalSha256();
    try testing.expectEqualSlices(u8, &ha, &hb);

    var doc_m = try build(testing.allocator, rendered, &face, testOptions(.monochrome));
    defer doc_m.deinit(testing.allocator);
    try testing.expect(!std.mem.eql(u8, &ha, &doc_m.canonicalSha256()));
}

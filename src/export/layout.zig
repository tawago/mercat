//! Fixed-cell export layout: `Rendered` -> `ExportDocument`.
//!
//!
//! This stage projects the semantic `Rendered` value onto a fixed monospace
//! cell grid and resolves each span's color/decoration for the chosen color
//! mode. It is backend-neutral: it produces the `types.ExportDocument` that the
//! PNG (and future PDF) writer consumes, and never touches pixels itself.
//!
//! Column traversal uses the repository's display-width policy
//! (`src/lib/unicode.zig`), not UTF-8 byte length:
//!   * width-1 scalar occupies one cell;
//!   * width-2 scalar occupies two cells (the painter centers the glyph);
//!   * combining (width-0) scalar attaches to the preceding cell and does not
//!     advance;
//!   * a tab or any non-linebreak control scalar is rejected as invalid
//!     rendered content (§7.2).
//!
//! One `PositionedRun` is emitted per non-empty span; an empty line still
//! contributes exactly one row (§7.2), and a zero-line document is laid out as
//! one padded background row (§7.4).

const std = @import("std");

const render_model = @import("../core/render_model.zig");
const theme = @import("../core/theme.zig");
const unicode = @import("../lib/unicode.zig");
const font = @import("font.zig");
const types = @import("types.zig");

const Color = types.Color;
const Decoration = types.Decoration;
const PositionedRun = types.PositionedRun;
const Geometry = types.Geometry;
const ExportDocument = types.ExportDocument;

pub const ColorMode = enum { theme, monochrome };

/// Export options (§6.4). `.auto` theme MUST already be resolved into a
/// concrete `theme.Palette` before this stage — the export backend cannot
/// inspect terminal state.
pub const Options = struct {
    palette: theme.Palette,
    color_mode: ColorMode,
    font_pixel_height: u16 = 20,
    horizontal_padding_cells: u16 = 1,
    vertical_padding_cells: u16 = 1,
};

pub const Error = std.mem.Allocator.Error || Geometry.PixelError || error{
    /// A tab (U+0009) appeared in rendered content (§7.2).
    InvalidTabInRendered,
    /// A control scalar other than a permitted line boundary appeared in a
    /// span (§7.2). Line breaks are structural (between `Line` values) and
    /// never appear inside span text.
    InvalidControlScalar,
    /// Span text was not valid UTF-8.
    InvalidUtf8,
    /// A column index or count exceeded `u32`.
    ColumnOverflow,
};

const white: Color = .{ .r = 255, .g = 255, .b = 255 };
const black: Color = .{ .r = 0, .g = 0, .b = 0 };

/// Build a backend-neutral export document from an owned `Rendered` value and
/// an initialized font face. The document owns copies of every string, so it
/// may outlive `rendered`.
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
        var col: u32 = 0;
        for (line.spans) |span| {
            const span_columns = try measureColumns(span.text);
            if (span.text.len != 0) {
                try appendRun(allocator, &runs, row, col, span_columns, span, options);
            }
            col = std.math.add(u32, col, span_columns) catch return error.ColumnOverflow;
        }
        max_columns = @max(max_columns, col);
    }

    // §7.4: a zero-row document is laid out as one padded background row.
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

    // Fail early if the surface would overflow (§7.4).
    _ = try doc.pixelWidth();
    _ = try doc.pixelHeight();

    return doc;
}

fn buildGeometry(face: *const font.Font, options: Options) Error!Geometry {
    const pad_x = try mulU16(options.horizontal_padding_cells, face.cell_width_px);
    const pad_y = try mulU16(options.vertical_padding_cells, face.cell_height_px);

    // Baseline from the top of the page = top padding + in-cell baseline.
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

/// Sum of the display widths of the scalars in `text`, rejecting tabs and
/// control scalars per §7.2.
fn measureColumns(text: []const u8) Error!u32 {
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var it = view.iterator();
    var total: u32 = 0;
    while (it.nextCodepoint()) |cp| {
        const cells = try scalarCells(cp);
        total = std.math.add(u32, total, cells) catch return error.ColumnOverflow;
    }
    return total;
}

/// Cells occupied by one scalar under the export width policy.
fn scalarCells(cp: u21) Error!u32 {
    if (cp == '\t') return error.InvalidTabInRendered;
    // C0 controls, DEL, and C1 controls are never permitted inside span text;
    // line boundaries are structural (between `Line` values).
    if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidControlScalar;
    if (isCombining(cp)) return 0;
    return @intCast(unicode.codepointWidth(cp));
}

/// Combining (zero-width) scalars that attach to the preceding cell. The
/// repository width policy already returns width 2 for wide scalars; this
/// predicate supplies the width-0 combining case the policy does not classify.
/// `pub` so the PNG painter can re-traverse a run's text with the identical
/// width policy the layout used (a run only records start_col/columns).
pub fn isCombining(cp: u21) bool {
    return (cp >= 0x0300 and cp <= 0x036F) or // combining diacritical marks
        (cp >= 0x0483 and cp <= 0x0489) or
        (cp >= 0x0591 and cp <= 0x05BD) or
        (cp >= 0x0610 and cp <= 0x061A) or
        (cp >= 0x064B and cp <= 0x065F) or
        (cp >= 0x1AB0 and cp <= 0x1AFF) or // combining diacritical marks extended
        (cp >= 0x1DC0 and cp <= 0x1DFF) or // combining diacritical marks supplement
        (cp >= 0x200B and cp <= 0x200F) or // zero-width space/joiners/marks
        (cp >= 0x20D0 and cp <= 0x20FF) or // combining marks for symbols
        (cp >= 0xFE20 and cp <= 0xFE2F) or // combining half marks
        cp == 0xFEFF; // zero-width no-break space / BOM
}

fn appendRun(
    allocator: std.mem.Allocator,
    runs: *std.ArrayList(PositionedRun),
    row: u32,
    start_col: u32,
    columns: u32,
    span: render_model.Span,
    options: Options,
) Error!void {
    const style = theme.token(options.palette, span.style);

    const foreground: Color = switch (options.color_mode) {
        .theme => xterm256ToSrgb(style.fg_index),
        .monochrome => black,
    };
    const background: ?Color = switch (options.color_mode) {
        // A span background only exists in themed mode; in monochrome every
        // span background equals the white page, so no rectangle is painted.
        .theme => if (style.bg_index) |bg| xterm256ToSrgb(bg) else null,
        .monochrome => null,
    };

    const text_copy = try allocator.dupe(u8, span.text);
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
        // Decorations are geometric and survive monochrome (drawn black).
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

/// Page background (§6.4). Monochrome is always white. In themed mode the
/// terminal has no numbered page color, so it is chosen from the palette's body
/// foreground luminance: light text implies a dark page, dark text a light one.
fn pageBackground(options: Options) Color {
    if (options.color_mode == .monochrome) return white;
    const body_fg = xterm256ToSrgb(options.palette.body.fg_index);
    return if (luminance(body_fg) > 128) black else white;
}

fn luminance(c: Color) u32 {
    return (@as(u32, c.r) * 299 + @as(u32, c.g) * 587 + @as(u32, c.b) * 114) / 1000;
}

// ---------------------------------------------------------------------------
// xterm-256 -> sRGB
// ---------------------------------------------------------------------------

/// The one committed, deterministic xterm-256 -> sRGB table (§6.4). Indexes
/// 0-15 are the standard system colors; 16-231 are the 6×6×6 cube; 232-255 are
/// the 24-step grayscale ramp.
pub fn xterm256ToSrgb(index: u8) Color {
    if (index < 16) return system_colors[index];
    if (index < 232) {
        const i: u16 = @as(u16, index) - 16;
        const r = cube_levels[i / 36];
        const g = cube_levels[(i % 36) / 6];
        const b = cube_levels[i % 6];
        return .{ .r = r, .g = g, .b = b };
    }
    // 232..255 -> 8, 18, ... , 238.
    const gray: u8 = @intCast(8 + 10 * (@as(u16, index) - 232));
    return .{ .r = gray, .g = gray, .b = gray };
}

const cube_levels = [_]u8{ 0, 95, 135, 175, 215, 255 };

const system_colors = [16]Color{
    .{ .r = 0, .g = 0, .b = 0 }, // 0  black
    .{ .r = 128, .g = 0, .b = 0 }, // 1  red
    .{ .r = 0, .g = 128, .b = 0 }, // 2  green
    .{ .r = 128, .g = 128, .b = 0 }, // 3  yellow
    .{ .r = 0, .g = 0, .b = 128 }, // 4  blue
    .{ .r = 128, .g = 0, .b = 128 }, // 5  magenta
    .{ .r = 0, .g = 128, .b = 128 }, // 6  cyan
    .{ .r = 192, .g = 192, .b = 192 }, // 7  white
    .{ .r = 128, .g = 128, .b = 128 }, // 8  bright black
    .{ .r = 255, .g = 0, .b = 0 }, // 9  bright red
    .{ .r = 0, .g = 255, .b = 0 }, // 10 bright green
    .{ .r = 255, .g = 255, .b = 0 }, // 11 bright yellow
    .{ .r = 0, .g = 0, .b = 255 }, // 12 bright blue
    .{ .r = 255, .g = 0, .b = 255 }, // 13 bright magenta
    .{ .r = 0, .g = 255, .b = 255 }, // 14 bright cyan
    .{ .r = 255, .g = 255, .b = 255 }, // 15 bright white
};

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

const Span = render_model.Span;
const Line = render_model.Line;
const Rendered = render_model.Rendered;

fn testOptions(mode: ColorMode) Options {
    return .{ .palette = theme.palette(.dark, .default), .color_mode = mode };
}

fn makeSpan(text: []const u8, style: render_model.SpanStyle) Span {
    return .{ .text = text, .style = style };
}

test "xterm-256 table matches known cube and grayscale anchors" {
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, xterm256ToSrgb(0));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, xterm256ToSrgb(15));
    // 16 is the cube origin (0,0,0); 231 is the cube apex (255,255,255).
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0 }, xterm256ToSrgb(16));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255 }, xterm256ToSrgb(231));
    // 196 = bright red in the cube (5,0,0).
    try testing.expectEqual(Color{ .r = 255, .g = 0, .b = 0 }, xterm256ToSrgb(196));
    // grayscale ramp endpoints.
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
    try testing.expectEqual(@as(u32, 9), doc.columns); // 3 + 6
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
    // One padded background row, never a zero-dimension surface.
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
    // U+FF21 FULLWIDTH LATIN CAPITAL A is width-2.
    var spans = [_]Span{makeSpan("Ａb", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    // width-2 'Ａ' + width-1 'b' = 3 columns.
    try testing.expectEqual(@as(u32, 3), doc.runs[0].columns);
    try testing.expectEqual(@as(u32, 3), doc.columns);
}

test "combining marks attach without advancing" {
    const face = try font.Font.init(20);
    // 'e' + U+0301 COMBINING ACUTE ACCENT renders as one cell.
    var spans = [_]Span{makeSpan("e\u{0301}", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, testOptions(.theme));
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 1), doc.runs[0].columns);
    try testing.expectEqual(@as(u32, 1), doc.columns);
}

test "tab in rendered content is rejected" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("a\tb", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidTabInRendered, build(testing.allocator, rendered, &face, testOptions(.theme)));
}

test "control scalar in rendered content is rejected" {
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("a\x07b", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidControlScalar, build(testing.allocator, rendered, &face, testOptions(.theme)));
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
    const palette = theme.palette(.dark, .default);
    var spans = [_]Span{makeSpan("code", .code)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, .{ .palette = palette, .color_mode = .theme });
    defer doc.deinit(testing.allocator);
    // .code -> fg_index 114 in the dark default palette.
    try testing.expectEqual(xterm256ToSrgb(114), doc.runs[0].foreground);
    try testing.expectEqual(@as(?Color, null), doc.runs[0].background);
}

test "themed code block resolves a background rectangle" {
    const face = try font.Font.init(20);
    const palette = theme.palette(.dark, .default);
    var spans = [_]Span{makeSpan("x", .code_block)};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    var doc = try build(testing.allocator, rendered, &face, .{ .palette = palette, .color_mode = .theme });
    defer doc.deinit(testing.allocator);
    // .code_block has bg_index 236 in the dark default palette.
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
    // .link is underlined; .strikethrough is struck through.
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
    // Default 1-cell padding at 9x20 cells.
    try testing.expectEqual(@as(u16, 9), doc.geometry.padding_left_px);
    try testing.expectEqual(@as(u16, 9), doc.geometry.padding_right_px);
    try testing.expectEqual(@as(u16, 20), doc.geometry.padding_top_px);
    try testing.expectEqual(@as(u16, 20), doc.geometry.padding_bottom_px);
    // Page baseline = top padding (20) + in-cell baseline (16) = 36.
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

    // Monochrome differs from themed (different colors/page background).
    var doc_m = try build(testing.allocator, rendered, &face, testOptions(.monochrome));
    defer doc_m.deinit(testing.allocator);
    try testing.expect(!std.mem.eql(u8, &ha, &doc_m.canonicalSha256()));
}

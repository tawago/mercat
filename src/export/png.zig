//! ExportDocument -> RGBA surface -> native PNG.
//!
//! This is the composition root of the PNG backend. It rasterizes a
//! backend-neutral `types.ExportDocument` onto an RGBA `Surface` in the §7.5
//! paint order, then hands the finished surface to the native `png_encode`
//! encoder. No resampling, sharpening, or cropping happens after
//! rasterization.
//!
//! Paint order (§7.5):
//!   1. page background
//!   2. span background rectangles
//!   3. glyph coverage masks (alpha-blended in the run foreground)
//!   4. underline geometry
//!   5. strikethrough geometry
//!
//! The painter traverses each run with the Unicode authority. It advances once
//! by each grapheme's recorded `CellWidth`; constituent scalars are drawn from
//! the same pen and are never remeasured. Every rendered non-space constituent
//! must resolve to a real glyph. A `.notdef` mapping is `error.MissingGlyph`
//! (§7.3), reported with the offending code point and grapheme row/column, and
//! no output file is written.
//!
//! `writeFile` performs the §5.2 atomic output: the surface is fully rasterized
//! and every glyph validated *before* any file is created, then the bytes are
//! written to a sibling temp file and atomically renamed over the target. A
//! failed export leaves no partial target.

const std = @import("std");

const unicode = @import("unicode");
const font = @import("font.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");
const surface_mod = @import("surface.zig");
const png_encode = @import("png_encode.zig");

const Color = types.Color;
const Surface = surface_mod.Surface;
const ExportDocument = types.ExportDocument;
const Geometry = types.Geometry;

/// `font.Error` (which includes `MissingGlyph`, reported per §7.3 with the
/// offending code point and its row/column) plus the surface/encoder errors.
pub const RenderError = layout.Error || png_encode.Error || font.Error;

pub const WriteError = RenderError || std.fs.File.OpenError || std.fs.File.WriteError || std.posix.RenameError;

/// Populated on a `MissingGlyph` failure so the caller can report the offending
/// code point and its location (§20). Pass a pointer to `render`/`writeFile`;
/// after an `error.MissingGlyph` its fields describe the first missing glyph.
pub const Diagnostic = struct {
    missing_codepoint: u21 = 0,
    row: u32 = 0,
    column: u32 = 0,
};

/// The result of a PNG render: the encoded bytes plus the metadata §7.6
/// requires the caller to be able to expose (dimensions, color mode, font hash,
/// output SHA-256). Owns `encoded.bytes`.
pub const RenderResult = struct {
    encoded: png_encode.Encoded,
    color_mode: layout.ColorMode,
    font_sha256: [32]u8,

    /// §4.3/§9.3 manifest provenance. The asset SHA-256 is per-instance
    /// (`font_sha256`); the font release/version and `stb_truetype` revision are
    /// build-time pins re-exported here so the manifest producer has a single
    /// `png.RenderResult` API surface for every required field and never has to
    /// hand-copy from PIN.txt comments.
    pub const font_name = font.font_name;
    pub const font_release_version = font.font_release_version;
    pub const rasterizer_revision = font.stb_truetype_revision;
    pub const rasterizer_version = font.stb_truetype_version;

    pub fn width(self: RenderResult) u32 {
        return self.encoded.width;
    }
    pub fn height(self: RenderResult) u32 {
        return self.encoded.height;
    }
    /// SHA-256 of the encoded PNG file bytes.
    pub fn outputSha256(self: RenderResult) [32]u8 {
        return self.encoded.sha256;
    }

    pub fn deinit(self: RenderResult, allocator: std.mem.Allocator) void {
        self.encoded.deinit(allocator);
    }
};

/// Rasterize `doc` to an RGBA surface and encode it as a PNG in memory. Glyph
/// coverage is validated here; on any failure no bytes reach the filesystem
/// because nothing is written by this function.
pub fn render(
    allocator: std.mem.Allocator,
    doc: ExportDocument,
    face: *const font.Font,
    color_mode: layout.ColorMode,
    diag: ?*Diagnostic,
) RenderError!RenderResult {
    const w = try doc.pixelWidth();
    const h = try doc.pixelHeight();

    var surface = try Surface.init(allocator, w, h);
    defer surface.deinit(allocator);

    // 1. page background.
    surface.fill(doc.page_background);

    // 2. span background rectangles.
    for (doc.runs) |run| {
        if (run.background) |bg| {
            const left = runLeftPx(doc.geometry, run.start_col);
            const top = runTopPx(doc.geometry, run.row);
            const width_px = @as(u32, run.columns) * doc.geometry.cell_width_px;
            surface.fillRect(left, top, width_px, doc.geometry.cell_height_px, bg);
        }
    }

    // 3-5. glyph masks, underline, strikethrough.
    try paintSheet(allocator, &surface, doc, face, diag);

    // No resample/sharpen/crop after rasterization (§7.5).
    const encoded = try png_encode.encodeRgba(allocator, surface.pixels, w, h);
    return .{ .encoded = encoded, .color_mode = color_mode, .font_sha256 = face.sha256 };
}

/// Paint the foreground of `doc` onto a surface whose page background and
/// span-background rectangles are already filled: glyph masks (step 3), then
/// underline (step 4), then strikethrough (step 5) in the §7.5 order. Shared by
/// the glyph-sheet verification suite (`glyph_sheet.zig`) so it exercises the
/// exact production painter rather than a copy. Propagates `error.MissingGlyph`
/// (§7.3), recording the offending code point/row/column in `diag` when given.
pub fn paintSheet(
    allocator: std.mem.Allocator,
    surface: *Surface,
    doc: ExportDocument,
    face: *const font.Font,
    diag: ?*Diagnostic,
) RenderError!void {
    for (doc.runs) |run| {
        try paintRunGlyphs(allocator, surface, doc.geometry, run, face, diag);
    }
    for (doc.runs) |run| {
        if (run.decoration.underline) drawUnderline(surface, doc.geometry, run);
    }
    for (doc.runs) |run| {
        if (run.decoration.strikethrough) drawStrikethrough(surface, doc.geometry, run);
    }
}

/// Render `doc` and atomically write the PNG to `path` (§5.2). The full render
/// (including glyph validation) completes before any file is created; the bytes
/// are written to a sibling temp file which is then renamed over `path`. On any
/// error the target is left untouched and the temp file is removed. Returns the
/// render metadata; the caller owns and must `deinit` it.
pub fn writeFile(
    allocator: std.mem.Allocator,
    doc: ExportDocument,
    face: *const font.Font,
    color_mode: layout.ColorMode,
    path: []const u8,
    diag: ?*Diagnostic,
) WriteError!RenderResult {
    const result = try render(allocator, doc, face, color_mode, diag);
    errdefer result.deinit(allocator);
    try atomicWrite(allocator, path, result.encoded.bytes);
    return result;
}

/// Left pixel of a cell column.
fn runLeftPx(g: Geometry, col: u32) i64 {
    return @as(i64, g.padding_left_px) + @as(i64, col) * @as(i64, g.cell_width_px);
}

/// Top pixel of a row.
fn runTopPx(g: Geometry, row: u32) i64 {
    return @as(i64, g.padding_top_px) + @as(i64, row) * @as(i64, g.cell_height_px);
}

/// Page-relative baseline pixel of a row. `geometry.baseline_px` already folds
/// in the top padding for row 0 (§7.1 step 9), so later rows add whole cells.
fn baselinePx(g: Geometry, row: u32) i64 {
    return @as(i64, g.baseline_px) + @as(i64, row) * @as(i64, g.cell_height_px);
}

fn paintRunGlyphs(
    allocator: std.mem.Allocator,
    surface: *Surface,
    g: Geometry,
    run: types.PositionedRun,
    face: *const font.Font,
    diag: ?*Diagnostic,
) RenderError!void {
    const baseline_y = baselinePx(g, run.row);

    var graphemes = unicode.Iterator.initAt(run.text, run.start_col);
    while (try nextGrapheme(&graphemes)) |grapheme| {
        const col = std.math.cast(u32, grapheme.column_start) orelse return error.ColumnOverflow;
        const box_left = runLeftPx(g, col);
        const box_px = @as(i64, grapheme.width) * @as(i64, g.cell_width_px);
        const pen_left = box_left + @divFloor(box_px - @as(i64, g.cell_width_px), 2);
        try drawGrapheme(
            allocator,
            surface,
            face,
            grapheme.bytes,
            pen_left,
            baseline_y,
            run.foreground,
            run.row,
            col,
            diag,
        );
    }
}

fn nextGrapheme(iterator: *unicode.Iterator) RenderError!?unicode.GraphemeSlice {
    return iterator.next() catch |err| switch (err) {
        error.InvalidUtf8 => error.InvalidUtf8,
        error.DisallowedControl => error.InvalidControlScalar,
        error.Overflow => error.ColumnOverflow,
    };
}

fn drawGrapheme(
    allocator: std.mem.Allocator,
    surface: *Surface,
    face: *const font.Font,
    bytes: []const u8,
    pen_left: i64,
    baseline_y: i64,
    color: Color,
    row: u32,
    col: u32,
    diag: ?*Diagnostic,
) RenderError!void {
    if (bytes.len == 1 and bytes[0] == '\t') return;
    const view = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
    var scalars = view.iterator();
    while (scalars.nextCodepoint()) |cp| {
        if (isNonRenderingConstituent(cp)) continue;
        try drawGlyph(allocator, surface, face, cp, pen_left, baseline_y, color, row, col, diag);
    }
}

/// Shaping constituents accepted by the Unicode authority but intentionally
/// carrying no standalone ink. This is raster policy only; width and boundaries
/// remain exclusively authority-owned.
fn isNonRenderingConstituent(cp: u21) bool {
    return cp == 0x200c or cp == 0x200d or
        (cp >= 0x180b and cp <= 0x180d) or
        (cp >= 0xfe00 and cp <= 0xfe0f) or
        (cp >= 0xe0020 and cp <= 0xe007f) or
        (cp >= 0xe0100 and cp <= 0xe01ef);
}

fn drawGlyph(
    allocator: std.mem.Allocator,
    surface: *Surface,
    face: *const font.Font,
    cp: u21,
    pen_left: i64,
    baseline_y: i64,
    color: Color,
    row: u32,
    col: u32,
    diag: ?*Diagnostic,
) RenderError!void {
    const gi = face.requireGlyph(cp) catch |err| {
        if (err == error.MissingGlyph) {
            if (diag) |d| d.* = .{ .missing_codepoint = cp, .row = row, .column = col };
        }
        return err;
    };
    if (gi == 0) return; // space / empty glyph — nothing to raster.

    var bmp = try face.rasterizeGlyphIndex(allocator, gi);
    defer bmp.deinit(allocator);
    if (bmp.width <= 0 or bmp.height <= 0) return;

    const dst_x = pen_left + @as(i64, bmp.left);
    const dst_y = baseline_y + @as(i64, bmp.top);
    surface.blendMask(
        bmp.coverage,
        @intCast(bmp.width),
        @intCast(bmp.height),
        dst_x,
        dst_y,
        color,
    );
}

/// Stroke thickness for underline/strikethrough: fixed geometry scaled to the
/// cell height, at least one pixel.
fn strokeThickness(g: Geometry) u32 {
    return @max(1, g.cell_height_px / 16);
}

fn drawUnderline(surface: *Surface, g: Geometry, run: types.PositionedRun) void {
    const t = strokeThickness(g);
    const left = runLeftPx(g, run.start_col);
    const width_px = @as(u32, run.columns) * g.cell_width_px;
    // Just below the baseline.
    const y = baselinePx(g, run.row) + @as(i64, t);
    surface.fillRect(left, y, width_px, t, run.foreground);
}

fn drawStrikethrough(surface: *Surface, g: Geometry, run: types.PositionedRun) void {
    const t = strokeThickness(g);
    const left = runLeftPx(g, run.start_col);
    const width_px = @as(u32, run.columns) * g.cell_width_px;
    // Roughly the x-height midline of the cell.
    const y = runTopPx(g, run.row) + @as(i64, @divFloor(@as(i64, g.cell_height_px) * 45, 100));
    surface.fillRect(left, y, width_px, t, run.foreground);
}

/// Write `bytes` to `path` atomically: a sibling temp file is written and
/// closed, then renamed over `path`. On failure the temp file is removed and
/// `path` is untouched.
fn atomicWrite(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) WriteError!void {
    var suffix: [8]u8 = undefined;
    std.crypto.random.bytes(&suffix);
    const hex = std.fmt.bytesToHex(suffix, .lower);
    const temp_path = try std.fmt.allocPrint(
        allocator,
        "{s}.mercat-tmp-{s}",
        .{ path, hex },
    );
    defer allocator.free(temp_path);

    const cwd = std.fs.cwd();
    {
        const file = try cwd.createFile(temp_path, .{ .truncate = true });
        errdefer cwd.deleteFile(temp_path) catch {};
        defer file.close();
        try file.writeAll(bytes);
    }
    errdefer cwd.deleteFile(temp_path) catch {};

    try cwd.rename(temp_path, path);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;
const render_model = @import("../core/markdown/render/types.zig");
const theme = @import("../core/theme.zig");

const Span = render_model.Span;
const Line = render_model.Line;
const Rendered = render_model.Rendered;

fn buildDoc(
    allocator: std.mem.Allocator,
    rendered: Rendered,
    face: *const font.Font,
    mode: layout.ColorMode,
) !ExportDocument {
    return layout.build(allocator, rendered, face, .{
        .palette = theme.neutralDark,
        .color_mode = mode,
    });
}

/// Minimal in-test PNG reader mirroring png_encode's, used to confirm the CLI
/// path produced a decodable image at the expected size.
fn decodeDims(bytes: []const u8) struct { w: u32, h: u32 } {
    // Signature (8) + IHDR length (4) + "IHDR" (4) => width at offset 16.
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    return .{ .w = w, .h = h };
}

test "render produces a PNG matching the document pixel dimensions" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("Hi", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try buildDoc(allocator, .{ .lines = &lines }, &face, .monochrome);
    defer doc.deinit(allocator);

    const result = try render(allocator, doc, &face, .monochrome, null);
    defer result.deinit(allocator);

    try testing.expectEqual(try doc.pixelWidth(), result.width());
    try testing.expectEqual(try doc.pixelHeight(), result.height());
    const dims = decodeDims(result.encoded.bytes);
    try testing.expectEqual(result.width(), dims.w);
    try testing.expectEqual(result.height(), dims.h);
    try testing.expectEqualSlices(u8, &face.sha256, &result.font_sha256);
}

fn makeSpan(text: []const u8, style: render_model.SpanStyle) Span {
    return .{ .text = text, .style = style };
}

test "render is deterministic across two same-process exports" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);
    var spans = [_]Span{ makeSpan("Deterministic ", .heading1), makeSpan("output", .code) };
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try buildDoc(allocator, .{ .lines = &lines }, &face, .theme);
    defer doc.deinit(allocator);

    const a = try render(allocator, doc, &face, .theme, null);
    defer a.deinit(allocator);
    const b = try render(allocator, doc, &face, .theme, null);
    defer b.deinit(allocator);
    try testing.expectEqualSlices(u8, a.encoded.bytes, b.encoded.bytes);
    try testing.expectEqualSlices(u8, &a.outputSha256(), &b.outputSha256());
}

test "monochrome output contains only black, white, and antialias grays" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("Ag", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try buildDoc(allocator, .{ .lines = &lines }, &face, .monochrome);
    defer doc.deinit(allocator);

    // Rasterize to a surface directly so we can inspect pixels.
    const w = try doc.pixelWidth();
    const h = try doc.pixelHeight();
    var surface = try Surface.init(allocator, w, h);
    defer surface.deinit(allocator);
    surface.fill(doc.page_background);
    for (doc.runs) |run| try paintRunGlyphs(allocator, &surface, doc.geometry, run, &face, null);

    // Every pixel is a gray (r==g==b) between black and white, and alpha 255.
    var i: usize = 0;
    while (i < surface.pixels.len) : (i += 4) {
        const r = surface.pixels[i];
        try testing.expectEqual(r, surface.pixels[i + 1]);
        try testing.expectEqual(r, surface.pixels[i + 2]);
        try testing.expectEqual(@as(u8, 255), surface.pixels[i + 3]);
    }
}

test "combining mark across styles shares the base grapheme geometry and ink" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);

    // Whole-line segmentation assigns the complete grapheme to the base span.
    var spans_b = [_]Span{ makeSpan("e", .body), makeSpan("\u{0301}", .emphasis) };
    var lines_b = [_]Line{.{ .spans = &spans_b }};
    var doc_b = try buildDoc(allocator, .{ .lines = &lines_b }, &face, .monochrome);
    defer doc_b.deinit(allocator);

    var spans_a = [_]Span{makeSpan("e\u{0301}", .body)};
    var lines_a = [_]Line{.{ .spans = &spans_a }};
    var doc_a = try buildDoc(allocator, .{ .lines = &lines_a }, &face, .monochrome);
    defer doc_a.deinit(allocator);

    const w = try doc_b.pixelWidth();
    const h = try doc_b.pixelHeight();
    try testing.expectEqual(@as(usize, 1), doc_b.runs.len);
    try testing.expectEqual(render_model.SpanStyle.body, doc_b.runs[0].semantic_style);
    try testing.expectEqualStrings("e\u{0301}", doc_b.runs[0].text);
    try testing.expectEqual(w, try doc_a.pixelWidth());
    try testing.expectEqual(h, try doc_a.pixelHeight());

    var sa = try Surface.init(allocator, w, h);
    defer sa.deinit(allocator);
    var sb = try Surface.init(allocator, w, h);
    defer sb.deinit(allocator);
    sa.fill(doc_a.page_background);
    sb.fill(doc_b.page_background);
    for (doc_a.runs) |run| try paintRunGlyphs(allocator, &sa, doc_a.geometry, run, &face, null);
    for (doc_b.runs) |run| try paintRunGlyphs(allocator, &sb, doc_b.geometry, run, &face, null);

    try testing.expectEqualSlices(u8, sa.pixels, sb.pixels);
}

test "missing glyph fails and writeFile leaves no file" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);
    // U+1F4A9 is not covered by JetBrains Mono.
    var spans = [_]Span{makeSpan("\u{1F4A9}", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try buildDoc(allocator, .{ .lines = &lines }, &face, .monochrome);
    defer doc.deinit(allocator);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);
    const out_path = try std.fs.path.join(allocator, &.{ path, "missing.png" });
    defer allocator.free(out_path);

    var diag: Diagnostic = .{};
    try testing.expectError(error.MissingGlyph, writeFile(allocator, doc, &face, .monochrome, out_path, &diag));
    try testing.expectEqual(@as(u21, 0x1F4A9), diag.missing_codepoint);
    try testing.expectEqual(@as(u32, 0), diag.row);
    // No target and no leftover temp files.
    try testing.expectError(error.FileNotFound, std.fs.cwd().access(out_path, .{}));
    var it = tmp.dir.iterate();
    while (try it.next()) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".mercat-tmp-") == null);
    }
}

test "missing constituent leaves an existing target byte-identical" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);
    // U+0483 extends the preceding base into one grapheme but is not covered
    // by the pinned face. Constituent validation must still fail closed.
    var spans = [_]Span{makeSpan("e\u{0483}", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try buildDoc(allocator, .{ .lines = &lines }, &face, .monochrome);
    defer doc.deinit(allocator);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "existing.png", .data = "original" });
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out_path = try std.fs.path.join(allocator, &.{ dir_path, "existing.png" });
    defer allocator.free(out_path);

    var diag: Diagnostic = .{};
    try testing.expectError(error.MissingGlyph, writeFile(allocator, doc, &face, .monochrome, out_path, &diag));
    try testing.expectEqual(@as(u21, 0x0483), diag.missing_codepoint);
    try testing.expectEqual(@as(u32, 0), diag.column);
    const after = try tmp.dir.readFileAlloc(allocator, "existing.png", 32);
    defer allocator.free(after);
    try testing.expectEqualStrings("original", after);
    var it = tmp.dir.iterate();
    while (try it.next()) |entry| try testing.expect(std.mem.indexOf(u8, entry.name, ".mercat-tmp-") == null);
}

test "writeFile atomically creates a decodable PNG" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("Full document", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try buildDoc(allocator, .{ .lines = &lines }, &face, .monochrome);
    defer doc.deinit(allocator);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const out_path = try std.fs.path.join(allocator, &.{ dir_path, "doc.png" });
    defer allocator.free(out_path);

    const result = try writeFile(allocator, doc, &face, .monochrome, out_path, null);
    defer result.deinit(allocator);

    const written = try std.fs.cwd().readFileAlloc(allocator, out_path, 64 * 1024 * 1024);
    defer allocator.free(written);
    try testing.expectEqualSlices(u8, result.encoded.bytes, written);
    const dims = decodeDims(written);
    try testing.expectEqual(result.width(), dims.w);
    try testing.expectEqual(result.height(), dims.h);

    // No temp file left behind.
    var it = tmp.dir.iterate();
    while (try it.next()) |entry| {
        try testing.expect(std.mem.indexOf(u8, entry.name, ".mercat-tmp-") == null);
    }
}

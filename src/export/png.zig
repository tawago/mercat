const std = @import("std");

const unicode = @import("unicode");
const font = @import("font.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");
const surface_mod = @import("surface.zig");
const png_encode = @import("png_encode.zig");
const out_fs = @import("../platform/fs.zig");

const Color = types.Color;
const Surface = surface_mod.Surface;
const ExportDocument = types.ExportDocument;
const Geometry = types.Geometry;

pub const RenderError = layout.Error || png_encode.Error || font.Error;

pub const WriteError = RenderError || out_fs.WriteError || error{SymLinkLoop};

pub const Diagnostic = struct {
    missing_codepoint: u21 = 0,
    row: u32 = 0,
    column: u32 = 0,
};

pub const RenderResult = struct {
    encoded: png_encode.Encoded,
    color_mode: layout.ColorMode,
    font_sha256: [32]u8,

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
    pub fn outputSha256(self: RenderResult) [32]u8 {
        return self.encoded.sha256;
    }

    pub fn deinit(self: RenderResult, allocator: std.mem.Allocator) void {
        self.encoded.deinit(allocator);
    }
};

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

    surface.fill(doc.page_background);

    for (doc.runs) |run| {
        if (run.background) |bg| {
            const left = runLeftPx(doc.geometry, run.start_col);
            const top = runTopPx(doc.geometry, run.row);
            const width_px = @as(u32, run.columns) * doc.geometry.cell_width_px;
            surface.fillRect(left, top, width_px, doc.geometry.cell_height_px, bg);
        }
    }

    try paintSheet(allocator, &surface, doc, face, diag);

    const encoded = try png_encode.encodeRgba(allocator, surface.pixels, w, h);
    return .{ .encoded = encoded, .color_mode = color_mode, .font_sha256 = face.sha256 };
}

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
    try out_fs.writeOutput(allocator, path, result.encoded.bytes);
    return result;
}

fn runLeftPx(g: Geometry, col: u32) i64 {
    return @as(i64, g.padding_left_px) + @as(i64, col) * @as(i64, g.cell_width_px);
}

fn runTopPx(g: Geometry, row: u32) i64 {
    return @as(i64, g.padding_top_px) + @as(i64, row) * @as(i64, g.cell_height_px);
}

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
    while (try layout.nextGrapheme(&graphemes)) |grapheme| {
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
    if (gi == 0) return;

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

fn strokeThickness(g: Geometry) u32 {
    return @max(1, g.cell_height_px / 16);
}

fn drawUnderline(surface: *Surface, g: Geometry, run: types.PositionedRun) void {
    const t = strokeThickness(g);
    const left = runLeftPx(g, run.start_col);
    const width_px = @as(u32, run.columns) * g.cell_width_px;
    const y = baselinePx(g, run.row) + @as(i64, t);
    surface.fillRect(left, y, width_px, t, run.foreground);
}

fn drawStrikethrough(surface: *Surface, g: Geometry, run: types.PositionedRun) void {
    const t = strokeThickness(g);
    const left = runLeftPx(g, run.start_col);
    const width_px = @as(u32, run.columns) * g.cell_width_px;
    const y = runTopPx(g, run.row) + @as(i64, @divFloor(@as(i64, g.cell_height_px) * 45, 100));
    surface.fillRect(left, y, width_px, t, run.foreground);
}

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

fn decodeDims(bytes: []const u8) struct { w: u32, h: u32 } {
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    return .{ .w = w, .h = h };
}

test "writeFile writes the encoded PNG at the document pixel dimensions" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);
    var spans = [_]Span{makeSpan("Full document", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try buildDoc(allocator, .{ .lines = &lines }, &face, .monochrome);
    defer doc.deinit(allocator);

    var tmp = testing.tmpDir(.{});
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
    try testing.expectEqual(try doc.pixelWidth(), dims.w);
    try testing.expectEqual(try doc.pixelHeight(), dims.h);
    try testing.expectEqualSlices(u8, &face.sha256, &result.font_sha256);
}

fn makeSpan(text: []const u8, style: render_model.SpanStyle) Span {
    return .{ .text = text, .style = style };
}

test "missing constituent leaves an existing target byte-identical" {
    const allocator = testing.allocator;
    const face = try font.Font.init(20);
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

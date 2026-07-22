//! Glyph-sheet fixture + export verification (including the in-process
//! parts of the export determinism checks).
//!
//! The glyph sheet is a synthetic `Rendered` value that exercises every
//! renderer-owned box/line/arrow/bullet/table/shape glyph, the full ASCII
//! printable range, adjacent horizontal and vertical line runs, every junction
//! glyph, leading/trailing spaces and blank rows, and underline/strikethrough
//! samples. It is the enforcement point (§4.3) that the pinned JetBrains Mono
//! release maps every glyph the renderer can emit, and that box-drawing joins
//! tile without a raster gap at the production 20px height.
//!
//! The glyph inventory below is gathered by hand from:
//!   * `src/core/mermaid_v2/paint/junction_glyphs.zig` (16-entry junction table),
//!   * `src/core/mermaid_v2/paint/stroke_glyphs.zig` (dotted/thick/hybrid),
//!   * `src/core/mermaid_v2/paint/shape_glyphs.zig` (node-shape perimeters),
//!   * `src/export/font.zig` `required_shape_scalars` (arrow/diamond geometrics),
//!   * `src/core/render/` + `src/cli/renderer.zig` (markdown rule/bullet/table/
//!     blockquote/section/clip glyphs).
//! When the renderer gains a new glyph, add it here so the coverage test guards
//! it against a future font swap.

const std = @import("std");

const render_model = @import("../core/render_model.zig");
const theme = @import("../core/theme.zig");
const font = @import("font.zig");
const layout = @import("layout.zig");
const types = @import("types.zig");
const surface_mod = @import("surface.zig");
const png = @import("png.zig");

const Span = render_model.Span;
const Line = render_model.Line;
const Rendered = render_model.Rendered;
const SpanStyle = render_model.SpanStyle;

// ===========================================================================
// Renderer-owned glyph inventory
// ===========================================================================

/// The 16 junction-table box-drawing glyphs (`junction_glyphs.zig`). Index 0
/// is the empty cell (space); the rest are the corner/tee/cross/stub set.
pub const junction_glyphs = [_]u21{
    ' ', '╵', '╶', '└', '╷', '│', '┌', '├',
    '╴', '┘', '─', '┴', '┐', '┤', '┬', '┼',
};

/// Non-solid stroke glyphs and the solid/double hybrid border glyphs
/// (`stroke_glyphs.zig`).
pub const stroke_glyphs = [_]u21{
    // dotted straight runs
    '┊', '╌',
    // thick (double-line) full box set
    '║', '═', '╚', '╔', '╠', '╝', '╩', '╗', '╣', '╦', '╬',
    // thick/solid hybrid border cells
    '╨', '╞', '╥', '╡',
};

/// Node-shape perimeter glyphs (`shape_glyphs.zig`): rounded corners, stadium
/// caps, cylinder rails/tees, circle/hexagon/parallelogram/trapezoid diagonals,
/// asymmetric caps, rhombus diamond.
pub const shape_glyphs = [_]u21{
    '╭', '╮', '╯', '╰', // rounded corners
    '(',  ')', // stadium caps
    '╤',  '╧', // cylinder tees
    '╱',  '╲', // circle/hexagon/parallelogram diagonals
    '>',  '<', // asymmetric / hexagon caps
    '◇', // rhombus
    '/',  '\\', // trapezoid corners
};

/// Arrow / geometric marker glyphs the flowchart painter owns. These are the
/// five `required_shape_scalars` from `font.zig` (guarded there too) plus the
/// markdown link arrow.
pub const arrow_glyphs = [_]u21{
    0x25B2, // ▲ BLACK UP-POINTING TRIANGLE
    0x25B6, // ▶ BLACK RIGHT-POINTING TRIANGLE
    0x25BC, // ▼ BLACK DOWN-POINTING TRIANGLE
    0x25C0, // ◀ BLACK LEFT-POINTING TRIANGLE
    0x25C7, // ◇ WHITE DIAMOND
    0x2192, // → RIGHTWARDS ARROW (markdown inline)
};

/// Heavy (bold) box-drawing set (`types.box_chars_heavy`), emitted by the
/// legacy sequence/class/ER/state renderers via `Canvas.drawBox`.
pub const heavy_box_glyphs = [_]u21{
    0x250F, // ┏ top-left
    0x2513, // ┓ top-right
    0x2517, // ┗ bottom-left
    0x251B, // ┛ bottom-right
    0x2501, // ━ horizontal
    0x2503, // ┃ vertical
};

/// Dashed/dotted stroke glyphs (`types.LineChars`) emitted by legacy edge
/// routing and class relation lines. (`┊` U+250A is already in
/// `stroke_glyphs`; these are the remaining three.)
pub const legacy_stroke_glyphs = [_]u21{
    0x2504, // ┄ horizontal dotted (also class dependency/realization line)
    0x2506, // ┆ vertical dotted
    0x2508, // ┈ horizontal dashed
};

/// Marker / arrow geometrics emitted only by the legacy sequence/class/ER/state
/// renderers (distinct scalars from the flowchart `arrow_glyphs` above).
///   * state: `●` initial, `◎` final, `△` up-arrow (`state/render.zig`);
///   * class relations: `►` `◄` pointers, `◁` inheritance/realization,
///     `◆` composition (`types.zig` Arrows + RelationType markers).
pub const legacy_marker_glyphs = [_]u21{
    0x25CF, // ● BLACK CIRCLE (state initial marker)
    0x25CE, // ◎ BULLSEYE (state final marker)
    0x25B3, // △ WHITE UP-POINTING TRIANGLE (state up-arrow)
    0x25BA, // ► BLACK RIGHT-POINTING POINTER (class relation arrow)
    0x25C4, // ◄ BLACK LEFT-POINTING POINTER (class relation arrow)
    0x25C1, // ◁ WHITE LEFT-POINTING TRIANGLE (inheritance/realization)
    0x25C6, // ◆ BLACK DIAMOND (composition)
};

/// Markdown-renderer-owned non-box glyphs: bullet, blockquote bar, table
/// separators, section sign, width-clip overflow marker.
pub const misc_render_glyphs = [_]u21{
    0x2022, // • BULLET (unordered list marker)
    0x258E, // ▎ LEFT ONE QUARTER BLOCK (blockquote bar)
    0x2502, // │ table column separator (also in junctions)
    0x2500, // ─ horizontal rule / heading underline / table rule
    0x253C, // ┼ table header/body junction
    0x00A7, // § section sign (cli/renderer.zig)
    0x00BB, // » width-clip overflow marker (paint.zig)
};

/// Every renderer-owned non-space scalar the coverage test asserts the font
/// maps. Duplicates across categories are harmless (the test dedupes).
pub fn allRendererOwned(buf: *std.ArrayList(u21), allocator: std.mem.Allocator) !void {
    for (junction_glyphs) |g| try buf.append(allocator, g);
    for (stroke_glyphs) |g| try buf.append(allocator, g);
    for (shape_glyphs) |g| try buf.append(allocator, g);
    for (arrow_glyphs) |g| try buf.append(allocator, g);
    for (heavy_box_glyphs) |g| try buf.append(allocator, g);
    for (legacy_stroke_glyphs) |g| try buf.append(allocator, g);
    for (legacy_marker_glyphs) |g| try buf.append(allocator, g);
    for (misc_render_glyphs) |g| try buf.append(allocator, g);
}

// ===========================================================================
// Fixture construction
// ===========================================================================

/// Build the glyph-sheet `Rendered` value. Every line/span is allocated from
/// `arena`; free the whole arena to release it. The returned `Rendered`
/// borrows arena memory and must not outlive it.
pub fn build(arena: std.mem.Allocator) !Rendered {
    var lines: std.ArrayList(Line) = .empty;

    // --- ASCII printables (0x20..0x7E), split so no single line is huge. ---
    {
        var s: std.ArrayList(u8) = .empty;
        var cp: u21 = 0x20;
        while (cp <= 0x7E) : (cp += 1) {
            var b: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &b);
            try s.appendSlice(arena, b[0..n]);
        }
        try appendLine(arena, &lines, &.{spanOf(try s.toOwnedSlice(arena), .body)});
    }

    // --- Adjacent horizontal line run (10 cells of ─). ---
    try appendLine(arena, &lines, &.{spanOf(try repeatGlyph(arena, '─', 10), .body)});

    // --- Adjacent vertical line run: three stacked │ in the same column. ---
    try appendLine(arena, &lines, &.{spanOf(try repeatGlyph(arena, '│', 1), .body)});
    try appendLine(arena, &lines, &.{spanOf(try repeatGlyph(arena, '│', 1), .body)});
    try appendLine(arena, &lines, &.{spanOf(try repeatGlyph(arena, '│', 1), .body)});

    // --- Every junction glyph on one row. ---
    try appendLine(arena, &lines, &.{spanOf(try glyphsToUtf8(arena, &junction_glyphs), .body)});

    // --- Stroke (dotted/thick/hybrid) glyphs. ---
    try appendLine(arena, &lines, &.{spanOf(try glyphsToUtf8(arena, &stroke_glyphs), .body)});

    // --- Node-shape perimeter glyphs. ---
    try appendLine(arena, &lines, &.{spanOf(try glyphsToUtf8(arena, &shape_glyphs), .body)});

    // --- Arrow / geometric markers. ---
    try appendLine(arena, &lines, &.{spanOf(try glyphsToUtf8(arena, &arrow_glyphs), .body)});

    // --- Legacy sequence/class/ER/state heavy box, dashed strokes, markers. ---
    try appendLine(arena, &lines, &.{spanOf(try glyphsToUtf8(arena, &heavy_box_glyphs), .body)});
    try appendLine(arena, &lines, &.{spanOf(try glyphsToUtf8(arena, &legacy_stroke_glyphs), .body)});
    try appendLine(arena, &lines, &.{spanOf(try glyphsToUtf8(arena, &legacy_marker_glyphs), .body)});

    // --- Bullet / table / blockquote / section / clip glyphs. ---
    try appendLine(arena, &lines, &.{spanOf(try glyphsToUtf8(arena, &misc_render_glyphs), .body)});

    // --- A small box built from adjacent joins (tiling cross + corners). ---
    //   ┌─┬─┐
    //   │ │ │
    //   ├─┼─┤
    //   └─┴─┘
    try appendLine(arena, &lines, &.{spanOf("┌─┬─┐", .body)});
    try appendLine(arena, &lines, &.{spanOf("│ │ │", .body)});
    try appendLine(arena, &lines, &.{spanOf("├─┼─┤", .body)});
    try appendLine(arena, &lines, &.{spanOf("└─┴─┘", .body)});

    // --- Leading/trailing spaces. ---
    try appendLine(arena, &lines, &.{spanOf("   spaced text   ", .body)});

    // --- Blank row (a line with no spans). ---
    try appendLine(arena, &lines, &.{});

    // --- Underline + strikethrough samples (geometric decorations). ---
    try appendLine(arena, &lines, &.{spanOf("underlined", .link)});
    try appendLine(arena, &lines, &.{spanOf("struck", .strikethrough)});

    return .{ .lines = try lines.toOwnedSlice(arena) };
}

fn appendLine(arena: std.mem.Allocator, lines: *std.ArrayList(Line), spans: []const Span) !void {
    const owned = try arena.dupe(Span, spans);
    try lines.append(arena, .{ .spans = owned });
}

fn spanOf(text: []const u8, style: SpanStyle) Span {
    return .{ .text = text, .style = style };
}

fn repeatGlyph(arena: std.mem.Allocator, cp: u21, count: usize) ![]u8 {
    var b: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &b);
    var s: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < count) : (i += 1) try s.appendSlice(arena, b[0..n]);
    return s.toOwnedSlice(arena);
}

fn glyphsToUtf8(arena: std.mem.Allocator, glyphs: []const u21) ![]u8 {
    var s: std.ArrayList(u8) = .empty;
    for (glyphs) |cp| {
        var b: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &b);
        try s.appendSlice(arena, b[0..n]);
    }
    return s.toOwnedSlice(arena);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn sheetOptions() layout.Options {
    return .{
        .palette = theme.palette(.dark, .default),
        .color_mode = .monochrome,
    };
}

test "PROBE box-drawing glyph vertical/horizontal ink extents at 20px" {
    if (true) return error.SkipZigTest; // flip to run the geometry probe
    const face = try font.Font.init(20);
    const probes = [_]u21{ '│', '─', '┼', '┌', '└' };
    for (probes) |cp| {
        const gi = try face.requireGlyph(cp);
        var bmp = try face.rasterizeGlyphIndex(testing.allocator, gi);
        defer bmp.deinit(testing.allocator);
        std.debug.print(
            "U+{X:0>4}: bmp {d}x{d} left={d} top={d}  cell {d}x{d} baseline={d}\n",
            .{ cp, bmp.width, bmp.height, bmp.left, bmp.top, face.cell_width_px, face.cell_height_px, face.baseline_px },
        );
    }
}

// ---------------------------------------------------------------------------
// §8.1 glyph coverage
// ---------------------------------------------------------------------------

test "font covers every renderer-owned glyph and every ASCII printable" {
    const face = try font.Font.init(20);

    // Every ASCII printable (0x20..0x7E). Space may map to glyph 0; the rest
    // must resolve to a real glyph.
    var cp: u21 = 0x20;
    while (cp <= 0x7E) : (cp += 1) {
        _ = face.requireGlyph(cp) catch |err| {
            std.debug.print("uncovered ASCII U+{X:0>4}\n", .{cp});
            return err;
        };
    }

    var glyphs: std.ArrayList(u21) = .empty;
    defer glyphs.deinit(testing.allocator);
    try allRendererOwned(&glyphs, testing.allocator);
    for (glyphs.items) |g| {
        if (g == ' ') continue;
        _ = face.requireGlyph(g) catch |err| {
            std.debug.print("uncovered renderer glyph U+{X:0>4}\n", .{g});
            return err;
        };
    }
}

test "the whole glyph sheet rasterizes with no missing glyph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rendered = try build(arena);
    const face = try font.Font.init(20);
    var doc = try layout.build(testing.allocator, rendered, &face, sheetOptions());
    defer doc.deinit(testing.allocator);

    var diag: png.Diagnostic = .{};
    const result = png.render(testing.allocator, doc, &face, .monochrome, &diag) catch |err| {
        std.debug.print("sheet render failed: {} (U+{X:0>4} at {d},{d})\n", .{ err, diag.missing_codepoint, diag.row, diag.column });
        return err;
    };
    defer result.deinit(testing.allocator);
    try testing.expect(result.width() > 0);
    try testing.expect(result.height() > 0);
}

// ---------------------------------------------------------------------------
// §8.1 dimensions
// ---------------------------------------------------------------------------

test "glyph sheet export dimensions follow the fixture and §7.4" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rendered = try build(arena);
    const face = try font.Font.init(20);
    var doc = try layout.build(testing.allocator, rendered, &face, sheetOptions());
    defer doc.deinit(testing.allocator);

    // Rows equal the fixture line count exactly (a blank line still counts).
    try testing.expectEqual(@as(u32, @intCast(rendered.lines.len)), doc.rows);

    // Columns equal the widest line's display width.
    var expect_cols: u32 = 0;
    for (rendered.lines) |line| {
        var w: u32 = 0;
        for (line.spans) |span| w += try displayWidth(span.text);
        expect_cols = @max(expect_cols, w);
    }
    try testing.expectEqual(expect_cols, doc.columns);

    // Pixel dimensions follow §7.4 with the 9x20 cell and 1-cell padding.
    const cw: u32 = 9;
    const ch: u32 = 20;
    try testing.expectEqual(cw + doc.columns * cw + cw, try doc.pixelWidth());
    try testing.expectEqual(ch + doc.rows * ch + ch, try doc.pixelHeight());
}

fn displayWidth(text: []const u8) !u32 {
    const unicode = @import("../lib/unicode.zig");
    const view = try std.unicode.Utf8View.init(text);
    var it = view.iterator();
    var total: u32 = 0;
    while (it.nextCodepoint()) |c| {
        if (layout.isCombining(c)) continue;
        total += @intCast(unicode.codepointWidth(c));
    }
    return total;
}

// ---------------------------------------------------------------------------
// §8.1 target-qualified stable RGBA hash
// ---------------------------------------------------------------------------

/// SHA-256 of the monochrome glyph-sheet RGBA surface, recorded for the pinned
/// dev target (aarch64 macOS). Hashes are target-qualified (§7.6): on other
/// targets the equality check is skipped and only determinism is asserted.
const expected_surface_sha256_aarch64_macos: [32]u8 = .{
    0x05, 0xf5, 0x3a, 0x48, 0x8c, 0x1a, 0x24, 0x31,
    0x25, 0xc4, 0xde, 0xf8, 0x76, 0x69, 0xc5, 0x1d,
    0x29, 0x9d, 0x03, 0xc3, 0x8b, 0xb4, 0xf5, 0x7c,
    0x25, 0xa2, 0x64, 0x95, 0xd8, 0x3c, 0x77, 0xa5,
};

fn renderSheetSurface(allocator: std.mem.Allocator) !surface_mod.Surface {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rendered = try build(arena);
    const face = try font.Font.init(20);
    var doc = try layout.build(allocator, rendered, &face, sheetOptions());
    defer doc.deinit(allocator);

    const w = try doc.pixelWidth();
    const h = try doc.pixelHeight();
    var surface = try surface_mod.Surface.init(allocator, w, h);
    errdefer surface.deinit(allocator);
    surface.fill(doc.page_background);
    for (doc.runs) |run| {
        if (run.background) |bg| {
            const left = @as(i64, doc.geometry.padding_left_px) + @as(i64, run.start_col) * @as(i64, doc.geometry.cell_width_px);
            const top = @as(i64, doc.geometry.padding_top_px) + @as(i64, run.row) * @as(i64, doc.geometry.cell_height_px);
            surface.fillRect(left, top, @as(u32, run.columns) * doc.geometry.cell_width_px, doc.geometry.cell_height_px, bg);
        }
    }
    try png.paintSheet(allocator, &surface, doc, &face, null);
    return surface;
}

test "glyph-sheet RGBA surface hash is deterministic and target-qualified" {
    const builtin = @import("builtin");

    var s1 = try renderSheetSurface(testing.allocator);
    defer s1.deinit(testing.allocator);
    var s2 = try renderSheetSurface(testing.allocator);
    defer s2.deinit(testing.allocator);

    var h1: [32]u8 = undefined;
    var h2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s1.pixels, &h1, .{});
    std.crypto.hash.sha2.Sha256.hash(s2.pixels, &h2, .{});
    // Determinism holds on every target.
    try testing.expectEqualSlices(u8, &h1, &h2);
    if (std.process.hasEnvVarConstant("MERCAT_PRINT_SHEET_HASH")) {
        std.debug.print("SHEET_HASH {s} {s}\n", .{ @tagName(builtin.cpu.arch), std.fmt.bytesToHex(h1, .lower) });
    }

    // Equality is asserted only on the pinned reference target.
    if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .macos) {
        try testing.expectEqualSlices(u8, &expected_surface_sha256_aarch64_macos, &h1);
    }
}

// ---------------------------------------------------------------------------
// §8.1 no gap at box-drawing joins (20px production height)
// ---------------------------------------------------------------------------

/// A pixel is "inked" when it is materially darker than the white monochrome
/// page (antialias grays above this threshold don't count as a stroke).
fn inked(s: surface_mod.Surface, x: u32, y: u32) bool {
    const i = (@as(usize, y) * s.width + x) * 4;
    return s.pixels[i] < 128;
}

/// True when some x-column inside cell column `col` has ink on BOTH sides of the
/// horizontal cell boundary at `seam_y` — i.e. a vertical stroke crosses the
/// shared edge with no blank seam.
fn verticalJoinContinuous(s: surface_mod.Surface, g: types.Geometry, col: u32, seam_y: u32) bool {
    const x0 = @as(u32, g.padding_left_px) + col * g.cell_width_px;
    var x = x0;
    while (x < x0 + g.cell_width_px) : (x += 1) {
        if (inked(s, x, seam_y - 1) and inked(s, x, seam_y)) return true;
    }
    return false;
}

/// Mirror of the above for a vertical cell boundary at `seam_x` inside row
/// `row` — a horizontal stroke crosses with no blank seam.
fn horizontalJoinContinuous(s: surface_mod.Surface, g: types.Geometry, row: u32, seam_x: u32) bool {
    const y0 = @as(u32, g.padding_top_px) + row * g.cell_height_px;
    var y = y0;
    while (y < y0 + g.cell_height_px) : (y += 1) {
        if (inked(s, seam_x - 1, y) and inked(s, seam_x, y)) return true;
    }
    return false;
}

fn renderMini(allocator: std.mem.Allocator, lines: []Line) !struct { surface: surface_mod.Surface, geometry: types.Geometry } {
    const face = try font.Font.init(20);
    var doc = try layout.build(allocator, .{ .lines = lines }, &face, sheetOptions());
    defer doc.deinit(allocator);
    const w = try doc.pixelWidth();
    const h = try doc.pixelHeight();
    var surface = try surface_mod.Surface.init(allocator, w, h);
    errdefer surface.deinit(allocator);
    surface.fill(doc.page_background);
    try png.paintSheet(allocator, &surface, doc, &face, null);
    return .{ .surface = surface, .geometry = doc.geometry };
}

test "vertically adjacent box lines tile with no raster gap" {
    var bar0 = [_]Span{spanOf("│", .body)};
    var bar1 = [_]Span{spanOf("│", .body)};
    var lines = [_]Line{ .{ .spans = &bar0 }, .{ .spans = &bar1 } };
    var mini = try renderMini(testing.allocator, &lines);
    defer mini.surface.deinit(testing.allocator);

    // Shared edge between row 0 and row 1: y = top_pad + 1*cell_height.
    const seam_y = @as(u32, mini.geometry.padding_top_px) + mini.geometry.cell_height_px;
    try testing.expect(verticalJoinContinuous(mini.surface, mini.geometry, 0, seam_y));
}

test "horizontally adjacent box lines tile with no raster gap" {
    var rule = [_]Span{spanOf("──", .body)};
    var lines = [_]Line{.{ .spans = &rule }};
    var mini = try renderMini(testing.allocator, &lines);
    defer mini.surface.deinit(testing.allocator);

    // Shared edge between col 0 and col 1: x = left_pad + 1*cell_width.
    const seam_x = @as(u32, mini.geometry.padding_left_px) + mini.geometry.cell_width_px;
    try testing.expect(horizontalJoinContinuous(mini.surface, mini.geometry, 0, seam_x));
}

test "a + junction connects to all four adjacent line cells with no gap" {
    // row0: " │ "  row1: "─┼─"  row2: " │ "
    var r0 = [_]Span{spanOf(" │ ", .body)};
    var r1 = [_]Span{spanOf("─┼─", .body)};
    var r2 = [_]Span{spanOf(" │ ", .body)};
    var lines = [_]Line{ .{ .spans = &r0 }, .{ .spans = &r1 }, .{ .spans = &r2 } };
    var mini = try renderMini(testing.allocator, &lines);
    defer mini.surface.deinit(testing.allocator);

    const g = mini.geometry;
    const top_seam = @as(u32, g.padding_top_px) + g.cell_height_px; // row0/row1
    const bot_seam = @as(u32, g.padding_top_px) + 2 * g.cell_height_px; // row1/row2
    const left_seam = @as(u32, g.padding_left_px) + g.cell_width_px; // col0/col1
    const right_seam = @as(u32, g.padding_left_px) + 2 * g.cell_width_px; // col1/col2

    // The vertical bar sits in column 1; the horizontal rule in row 1.
    try testing.expect(verticalJoinContinuous(mini.surface, g, 1, top_seam));
    try testing.expect(verticalJoinContinuous(mini.surface, g, 1, bot_seam));
    try testing.expect(horizontalJoinContinuous(mini.surface, g, 1, left_seam));
    try testing.expect(horizontalJoinContinuous(mini.surface, g, 1, right_seam));
}

// ---------------------------------------------------------------------------
// §8.2 in-process structural checks
// ---------------------------------------------------------------------------

test "rendered line count maps exactly to export rows" {
    const face = try font.Font.init(20);
    var s0 = [_]Span{spanOf("one", .body)};
    var s1 = [_]Span{};
    var s2 = [_]Span{spanOf("three", .body)};
    var lines = [_]Line{ .{ .spans = &s0 }, .{ .spans = &s1 }, .{ .spans = &s2 } };
    var doc = try layout.build(testing.allocator, .{ .lines = &lines }, &face, sheetOptions());
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), doc.rows);
}

test "display width maps exactly to export columns for wide + combining scalars" {
    const face = try font.Font.init(20);
    // "Ａ" width-2, "e" + combining acute = 1 cell, "x" = 1 → 4 columns total.
    var spans = [_]Span{spanOf("Ａe\u{0301}x", .body)};
    var lines = [_]Line{.{ .spans = &spans }};
    var doc = try layout.build(testing.allocator, .{ .lines = &lines }, &face, sheetOptions());
    defer doc.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 4), doc.columns);
}

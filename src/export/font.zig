//! Font service for the native PNG/PDF exporter.
//!
//! Wraps the vendored `stb_truetype` single-header library (implemented once in
//! `src/export/font_stb.c`; see `vendor/stb/PIN.txt`) around the JetBrains Mono
//! Regular TTF, which is embedded into the binary at build time via the
//! `jetbrains_mono_ttf` anonymous import declared in `build.zig`.
//!
//! Responsibilities:
//!   * SHA-256 the embedded font bytes at init and verify them against the
//!     pinned digest (guards against a corrupted embed).
//!   * Initialize `stbtt_fontinfo` at font index 0 and derive the fixed-cell
//!     metrics per §7.1 (scale, ascent/descent/line-gap, monospace advance,
//!     integer cell width/height, in-cell baseline).
//!   * Resolve glyph indices, failing with `error.MissingGlyph` for any
//!     non-space scalar that maps to `.notdef` (§7.3) — no fallback font, no
//!     replacement character.
//!   * Rasterize glyph coverage masks for the surface/PNG stage.
//!
//! Runtime font lookup/fallback is forbidden: this module owns exactly one face.

const std = @import("std");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// The embedded JetBrains Mono Regular TTF bytes (build-time asset, not a
/// runtime file read). The import name is declared in `build.zig` on every
/// module that compiles this file.
pub const ttf_bytes: []const u8 = @embedFile("jetbrains_mono_ttf");

/// SHA-256 of the pinned `assets/fonts/JetBrainsMono-Regular.ttf` (v2.304).
/// See `assets/fonts/PIN.txt`. Init fails with `error.FontHashMismatch` if the
/// embedded bytes ever diverge from this digest.
pub const expected_sha256: [32]u8 = .{
    0xa0, 0xbf, 0x60, 0xef, 0x0f, 0x83, 0xc5, 0xed,
    0x4d, 0x7a, 0x75, 0xd4, 0x58, 0x38, 0x54, 0x8b,
    0x1f, 0x68, 0x73, 0x37, 0x2d, 0xfa, 0xc8, 0x8f,
    0x71, 0x80, 0x44, 0x91, 0x89, 0x8d, 0x13, 0x8f,
};

/// Human-readable font family name of the pinned asset. Surfaced to the §9.3
/// manifest `font.name` field.
pub const font_name = "JetBrains Mono Regular";

/// Font release/version of the pinned asset ("the font
/// release/version [...] MUST be available to the PNG metadata/manifest API").
/// Kept in lockstep with `assets/fonts/PIN.txt`.
pub const font_release_version = "v2.304";

/// Vendored `stb_truetype.h` pinned commit (the manifest's
/// `rasterizer_revision`). Kept in lockstep with `vendor/stb/PIN.txt`. No
/// value here may drift from that pin without a matching PIN.txt update.
pub const stb_truetype_revision = "6e9f34d5429cf16790ec43c9bac3f1ee4ad1f760";

/// `stb_truetype.h` library version banner of the pinned commit.
pub const stb_truetype_version = "v1.26";

/// The five renderer-owned geometric shape scalars that a valid pin MUST
/// cover. The glyph-sheet test asserts each resolves to a non-`.notdef`
/// glyph.
pub const required_shape_scalars = [_]u21{
    0x25B2, // BLACK UP-POINTING TRIANGLE
    0x25B6, // BLACK RIGHT-POINTING TRIANGLE
    0x25BC, // BLACK DOWN-POINTING TRIANGLE
    0x25C0, // BLACK LEFT-POINTING TRIANGLE
    0x25C7, // WHITE DIAMOND
};

pub const Error = error{
    /// `stbtt_InitFont` rejected the embedded bytes / offset table.
    InvalidFontData,
    /// The embedded bytes do not match the pinned SHA-256.
    FontHashMismatch,
    /// A metric was zero/degenerate, or the U+0020 and U+004D advances disagree
    /// by a fixed-point unit or more — the face is not the expected monospace.
    InconsistentMetrics,
    /// A non-space scalar mapped to glyph index 0 (`.notdef`). No fallback.
    MissingGlyph,
};

/// Sub-pixel tolerance for the monospace advance-agreement check (§7.1 step 6).
/// TrueType fixed-point is 1/64 px; two scaled advances must differ by strictly
/// less than one such unit.
const fixed_point_unit: f32 = 1.0 / 64.0;

pub const Font = struct {
    /// stb face handle. Holds raw pointers into `ttf_bytes` (a static embedded
    /// slice that outlives every `Font`), so copying this struct by value is
    /// safe.
    info: c.stbtt_fontinfo,

    /// SHA-256 of the embedded font bytes (equals `expected_sha256` after a
    /// successful init). Surfaced to the PNG metadata/manifest API.
    sha256: [32]u8,

    /// `stbtt_ScaleForPixelHeight(font_pixel_height)`.
    scale: f32,

    /// Requested pixel height passed to `init`.
    pixel_height: u16,

    // Raw unscaled vertical metrics (font design units).
    ascent_units: i32,
    descent_units: i32,
    line_gap_units: i32,

    // Fixed-cell metrics derived per §7.1.
    /// Integer advance width of every cell (rounded common monospace advance).
    cell_width_px: u16,
    /// Row height: `ceil((ascent - descent + line_gap) * scale)`.
    cell_height_px: u16,
    /// Baseline offset from the TOP of a glyph cell: `ceil(ascent * scale)`.
    /// The layout stage adds the document's top padding to obtain the final
    /// `Geometry.baseline_px`.
    baseline_px: i16,

    /// Initialize the exporter font face. Fatal on any degenerate/inconsistent
    /// metric (§7.1: "Zero or inconsistent metrics are fatal export errors").
    pub fn init(pixel_height: u16) Error!Font {
        if (pixel_height == 0) return Error.InconsistentMetrics;

        // 1. Hash the embedded bytes and verify the pin.
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(ttf_bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &expected_sha256)) return Error.FontHashMismatch;

        // 2. Initialize stbtt at font index zero.
        var info: c.stbtt_fontinfo = undefined;
        const offset = c.stbtt_GetFontOffsetForIndex(ttf_bytes.ptr, 0);
        if (offset < 0) return Error.InvalidFontData;
        if (c.stbtt_InitFont(&info, ttf_bytes.ptr, offset) == 0) return Error.InvalidFontData;

        // 3. Scale for the requested pixel height.
        const scale = c.stbtt_ScaleForPixelHeight(&info, @floatFromInt(pixel_height));
        if (!(scale > 0.0)) return Error.InconsistentMetrics;

        // 4. Vertical metrics.
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);
        if (ascent <= 0 or descent >= 0) return Error.InconsistentMetrics;

        // 5-6. Advance width of U+0020 and U+004D must agree (monospace).
        const space_adv = advanceUnits(&info, ' ');
        const m_adv = advanceUnits(&info, 'M');
        if (space_adv <= 0 or m_adv <= 0) return Error.InconsistentMetrics;
        const space_px = @as(f32, @floatFromInt(space_adv)) * scale;
        const m_px = @as(f32, @floatFromInt(m_adv)) * scale;
        if (@abs(space_px - m_px) >= fixed_point_unit) return Error.InconsistentMetrics;

        // 7. Round the common advance to an integer cell width.
        const common_px = (space_px + m_px) * 0.5;
        const cell_w = @as(i64, @intFromFloat(@round(common_px)));
        if (cell_w <= 0 or cell_w > std.math.maxInt(u16)) return Error.InconsistentMetrics;

        // 8. Cell height = ceil((ascent - descent + line_gap) * scale).
        const extent_units = @as(f32, @floatFromInt(ascent - descent + line_gap));
        const cell_h = @as(i64, @intFromFloat(@ceil(extent_units * scale)));
        if (cell_h <= 0 or cell_h > std.math.maxInt(u16)) return Error.InconsistentMetrics;

        // 9. In-cell baseline = ceil(ascent * scale).
        const baseline = @as(i64, @intFromFloat(@ceil(@as(f32, @floatFromInt(ascent)) * scale)));
        if (baseline <= 0 or baseline > std.math.maxInt(i16)) return Error.InconsistentMetrics;
        if (baseline > cell_h) return Error.InconsistentMetrics;

        return .{
            .info = info,
            .sha256 = digest,
            .scale = scale,
            .pixel_height = pixel_height,
            .ascent_units = ascent,
            .descent_units = descent,
            .line_gap_units = line_gap,
            .cell_width_px = @intCast(cell_w),
            .cell_height_px = @intCast(cell_h),
            .baseline_px = @intCast(baseline),
        };
    }

    /// Raw glyph index for a scalar (`0` == `.notdef`/uncovered). Does not error;
    /// use `requireGlyph` for the exporter's fail-closed policy.
    pub fn glyphIndex(self: *const Font, codepoint: u21) i32 {
        return c.stbtt_FindGlyphIndex(&self.info, @intCast(codepoint));
    }

    /// True when the scalar maps to a real (non-`.notdef`) glyph.
    pub fn hasGlyph(self: *const Font, codepoint: u21) bool {
        return self.glyphIndex(codepoint) != 0;
    }

    /// Resolve a scalar to a non-zero glyph index. A non-space scalar mapping to
    /// glyph 0 is `error.MissingGlyph` (§7.3). Space (U+0020) is allowed to use
    /// whatever glyph the font assigns, including 0. The caller supplies the
    /// row/column diagnostic context; the code point is the argument.
    pub fn requireGlyph(self: *const Font, codepoint: u21) Error!i32 {
        const gi = self.glyphIndex(codepoint);
        if (gi == 0 and codepoint != ' ') return Error.MissingGlyph;
        return gi;
    }

    /// Integer scaled advance for a scalar (all covered scalars share the
    /// monospace `cell_width_px`; exposed mainly for assertions).
    pub fn advancePx(self: *const Font, codepoint: u21) i32 {
        const adv = advanceUnits(&self.info, codepoint);
        return @intFromFloat(@round(@as(f32, @floatFromInt(adv)) * self.scale));
    }

    /// A rasterized glyph coverage mask. `coverage` is `width*height` bytes of
    /// 0..255 alpha in row-major order, allocated by the caller's allocator.
    /// `left`/`top` are the pixel offsets from the pen origin (baseline, x=pen)
    /// to the top-left of the bitmap; `top` is typically negative (above the
    /// baseline). An empty glyph (e.g. space) yields a zero-size, non-owning
    /// bitmap.
    pub const GlyphBitmap = struct {
        coverage: []u8,
        width: i32,
        height: i32,
        left: i32,
        top: i32,

        pub fn deinit(self: GlyphBitmap, allocator: std.mem.Allocator) void {
            if (self.coverage.len != 0) allocator.free(self.coverage);
        }
    };

    /// Rasterize `glyph_index` into a caller-owned coverage mask at this font's
    /// scale. Uses `stbtt_MakeGlyphBitmap` into a Zig-allocated buffer so no C
    /// `malloc` ownership crosses the boundary. Empty glyphs return a zero-size
    /// bitmap.
    pub fn rasterizeGlyphIndex(
        self: *const Font,
        allocator: std.mem.Allocator,
        glyph_index: i32,
    ) std.mem.Allocator.Error!GlyphBitmap {
        var ix0: c_int = 0;
        var iy0: c_int = 0;
        var ix1: c_int = 0;
        var iy1: c_int = 0;
        c.stbtt_GetGlyphBitmapBox(
            &self.info,
            glyph_index,
            self.scale,
            self.scale,
            &ix0,
            &iy0,
            &ix1,
            &iy1,
        );
        const w = ix1 - ix0;
        const h = iy1 - iy0;
        if (w <= 0 or h <= 0) {
            return .{ .coverage = &[_]u8{}, .width = 0, .height = 0, .left = ix0, .top = iy0 };
        }
        const size: usize = @intCast(@as(i64, w) * @as(i64, h));
        const buf = try allocator.alloc(u8, size);
        @memset(buf, 0);
        c.stbtt_MakeGlyphBitmap(
            &self.info,
            buf.ptr,
            w,
            h,
            w, // stride == width (tightly packed)
            self.scale,
            self.scale,
            glyph_index,
        );
        return .{ .coverage = buf, .width = w, .height = h, .left = ix0, .top = iy0 };
    }
};

/// Unscaled horizontal advance (design units) for a scalar.
fn advanceUnits(info: *const c.stbtt_fontinfo, codepoint: u21) i32 {
    var advance: c_int = 0;
    var lsb: c_int = 0;
    c.stbtt_GetCodepointHMetrics(info, @intCast(codepoint), &advance, &lsb);
    return advance;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "font provenance metadata is exposed for the manifest API (§4.3)" {
    // The font release/version and stb_truetype revision MUST be programmatic,
    // not prose-only in PIN.txt — the §9.3 manifest producer reads them here.
    try testing.expect(font_release_version.len != 0);
    try testing.expect(stb_truetype_revision.len != 0);
    try testing.expect(font_name.len != 0);
    try testing.expect(stb_truetype_version.len != 0);
    // The revision is a full 40-char git commit hash.
    try testing.expectEqual(@as(usize, 40), stb_truetype_revision.len);
}

test "embedded font hash is stable and matches the pin" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(ttf_bytes, &digest, .{});
    try testing.expectEqualSlices(u8, &expected_sha256, &digest);

    const font = try Font.init(20);
    try testing.expectEqualSlices(u8, &expected_sha256, &font.sha256);
}

test "font initializes with sane monospace metrics at 20px" {
    const font = try Font.init(20);
    try testing.expect(font.scale > 0.0);
    try testing.expect(font.cell_width_px > 0);
    try testing.expect(font.cell_height_px > 0);
    try testing.expect(font.baseline_px > 0);
    // Baseline must sit within the row.
    try testing.expect(@as(u16, @intCast(font.baseline_px)) <= font.cell_height_px);
    // JetBrains Mono at 20px: verified integer cell metrics.
    try testing.expectEqual(@as(u16, 20), font.cell_height_px);
    try testing.expectEqual(@as(u16, 9), font.cell_width_px);
    try testing.expectEqual(@as(i16, 16), font.baseline_px);
    // Monospace: space and 'M' share the same integer advance == cell width.
    try testing.expectEqual(@as(i32, font.cell_width_px), font.advancePx(' '));
    try testing.expectEqual(@as(i32, font.cell_width_px), font.advancePx('M'));
}

test "cell metrics are integer and internally consistent" {
    const font = try Font.init(20);
    // ascent - descent + line_gap, scaled and ceiled, equals the stored height.
    const extent: f32 = @floatFromInt(font.ascent_units - font.descent_units + font.line_gap_units);
    const expect_h: u16 = @intFromFloat(@ceil(extent * font.scale));
    try testing.expectEqual(expect_h, font.cell_height_px);
    const expect_baseline: i16 = @intFromFloat(@ceil(@as(f32, @floatFromInt(font.ascent_units)) * font.scale));
    try testing.expectEqual(expect_baseline, font.baseline_px);
}

test "the five geometric shape code points resolve to real glyphs" {
    const font = try Font.init(20);
    for (required_shape_scalars) |cp| {
        try testing.expect(font.hasGlyph(cp));
        const gi = try font.requireGlyph(cp);
        try testing.expect(gi != 0);
    }
}

test "ASCII printable and box-drawing code points resolve" {
    const font = try Font.init(20);
    // A sample of renderer-owned box/line/arrow glyphs plus ASCII.
    const sample = [_]u21{
        'A', 'z', '0', '#', ' ', // space allowed either way
        0x2500, // ─ box horizontal
        0x2502, // │ box vertical
        0x250C, // ┌ corner
        0x2514, // └ corner
        0x253C, // ┼ cross junction
        0x2022, // • bullet
        0x2192, // → arrow
    };
    for (sample) |cp| {
        _ = try font.requireGlyph(cp);
    }
}

test "missing glyph fails closed with error.MissingGlyph" {
    const font = try Font.init(20);
    // U+1F4A9 (PILE OF POO) — a color-emoji scalar JetBrains Mono does not map.
    const absent: u21 = 0x1F4A9;
    try testing.expect(!font.hasGlyph(absent));
    try testing.expectError(Error.MissingGlyph, font.requireGlyph(absent));
    // Sanity: the absent scalar really is .notdef (index 0), not merely unmapped
    // by our helper.
    try testing.expectEqual(@as(i32, 0), font.glyphIndex(absent));
}

test "space may map to glyph zero without erroring" {
    const font = try Font.init(20);
    // requireGlyph must never reject U+0020, regardless of its glyph index.
    _ = try font.requireGlyph(' ');
}

test "rasterizing a covered glyph yields a non-empty coverage mask" {
    const font = try Font.init(20);
    const gi = try font.requireGlyph('M');
    var bmp = try font.rasterizeGlyphIndex(testing.allocator, gi);
    defer bmp.deinit(testing.allocator);
    try testing.expect(bmp.width > 0);
    try testing.expect(bmp.height > 0);
    try testing.expectEqual(@as(usize, @intCast(bmp.width * bmp.height)), bmp.coverage.len);
    // 'M' must have at least one inked pixel.
    var any_ink = false;
    for (bmp.coverage) |px| {
        if (px != 0) {
            any_ink = true;
            break;
        }
    }
    try testing.expect(any_ink);
}

test "rasterizing an empty glyph (space) yields a zero-size bitmap" {
    const font = try Font.init(20);
    const gi = font.glyphIndex(' ');
    var bmp = try font.rasterizeGlyphIndex(testing.allocator, gi);
    defer bmp.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 0), bmp.width);
    try testing.expectEqual(@as(usize, 0), bmp.coverage.len);
}

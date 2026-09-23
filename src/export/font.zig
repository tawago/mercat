const std = @import("std");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

pub const ttf_bytes: []const u8 = @embedFile("jetbrains_mono_ttf");

pub const expected_sha256: [32]u8 = .{
    0xa0, 0xbf, 0x60, 0xef, 0x0f, 0x83, 0xc5, 0xed,
    0x4d, 0x7a, 0x75, 0xd4, 0x58, 0x38, 0x54, 0x8b,
    0x1f, 0x68, 0x73, 0x37, 0x2d, 0xfa, 0xc8, 0x8f,
    0x71, 0x80, 0x44, 0x91, 0x89, 0x8d, 0x13, 0x8f,
};

pub const font_name = "JetBrains Mono Regular";

pub const font_release_version = "v2.304";

pub const stb_truetype_revision = "6e9f34d5429cf16790ec43c9bac3f1ee4ad1f760";

pub const stb_truetype_version = "v1.26";

pub const required_shape_scalars = [_]u21{
    0x25B2,
    0x25B6,
    0x25BC,
    0x25C0,
    0x25C7,
    0x25B3,
    0x25B7,
    0x25BD,
    0x25C1,
    0x25CB,
    0x2715,
};

pub const Error = error{
    InvalidFontData,
    FontHashMismatch,
    InconsistentMetrics,
    MissingGlyph,
};

const fixed_point_unit: f32 = 1.0 / 64.0;

pub const Font = struct {
    info: c.stbtt_fontinfo,

    sha256: [32]u8,

    scale: f32,

    pixel_height: u16,

    ascent_units: i32,
    descent_units: i32,
    line_gap_units: i32,

    cell_width_px: u16,
    cell_height_px: u16,
    baseline_px: i16,

    pub fn init(pixel_height: u16) Error!Font {
        if (pixel_height == 0) return Error.InconsistentMetrics;

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(ttf_bytes, &digest, .{});
        if (!std.mem.eql(u8, &digest, &expected_sha256)) return Error.FontHashMismatch;

        var info: c.stbtt_fontinfo = undefined;
        const offset = c.stbtt_GetFontOffsetForIndex(ttf_bytes.ptr, 0);
        if (offset < 0) return Error.InvalidFontData;
        if (c.stbtt_InitFont(&info, ttf_bytes.ptr, offset) == 0) return Error.InvalidFontData;

        const scale = c.stbtt_ScaleForPixelHeight(&info, @floatFromInt(pixel_height));
        if (!(scale > 0.0)) return Error.InconsistentMetrics;

        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);
        if (ascent <= 0 or descent >= 0) return Error.InconsistentMetrics;

        const space_adv = advanceUnits(&info, ' ');
        const m_adv = advanceUnits(&info, 'M');
        if (space_adv <= 0 or m_adv <= 0) return Error.InconsistentMetrics;
        const space_px = @as(f32, @floatFromInt(space_adv)) * scale;
        const m_px = @as(f32, @floatFromInt(m_adv)) * scale;
        if (@abs(space_px - m_px) >= fixed_point_unit) return Error.InconsistentMetrics;

        const common_px = (space_px + m_px) * 0.5;
        const cell_w = @as(i64, @intFromFloat(@round(common_px)));
        if (cell_w <= 0 or cell_w > std.math.maxInt(u16)) return Error.InconsistentMetrics;

        const extent_units = @as(f32, @floatFromInt(ascent - descent + line_gap));
        const cell_h = @as(i64, @intFromFloat(@ceil(extent_units * scale)));
        if (cell_h <= 0 or cell_h > std.math.maxInt(u16)) return Error.InconsistentMetrics;

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

    pub fn glyphIndex(self: *const Font, codepoint: u21) i32 {
        return c.stbtt_FindGlyphIndex(&self.info, @intCast(codepoint));
    }

    pub fn hasGlyph(self: *const Font, codepoint: u21) bool {
        return self.glyphIndex(codepoint) != 0;
    }

    pub fn requireGlyph(self: *const Font, codepoint: u21) Error!i32 {
        const gi = self.glyphIndex(codepoint);
        if (gi == 0 and codepoint != ' ') return Error.MissingGlyph;
        return gi;
    }

    pub fn advancePx(self: *const Font, codepoint: u21) i32 {
        const adv = advanceUnits(&self.info, codepoint);
        return @intFromFloat(@round(@as(f32, @floatFromInt(adv)) * self.scale));
    }

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
            w,
            self.scale,
            self.scale,
            glyph_index,
        );
        return .{ .coverage = buf, .width = w, .height = h, .left = ix0, .top = iy0 };
    }
};

fn advanceUnits(info: *const c.stbtt_fontinfo, codepoint: u21) i32 {
    var advance: c_int = 0;
    var lsb: c_int = 0;
    c.stbtt_GetCodepointHMetrics(info, @intCast(codepoint), &advance, &lsb);
    return advance;
}

const testing = std.testing;

test "font provenance metadata is exposed for the manifest API (§4.3)" {
    try testing.expect(font_release_version.len != 0);
    try testing.expect(stb_truetype_revision.len != 0);
    try testing.expect(font_name.len != 0);
    try testing.expect(stb_truetype_version.len != 0);
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
    try testing.expect(@as(u16, @intCast(font.baseline_px)) <= font.cell_height_px);
    try testing.expectEqual(@as(u16, 20), font.cell_height_px);
    try testing.expectEqual(@as(u16, 9), font.cell_width_px);
    try testing.expectEqual(@as(i16, 16), font.baseline_px);
    try testing.expectEqual(@as(i32, font.cell_width_px), font.advancePx(' '));
    try testing.expectEqual(@as(i32, font.cell_width_px), font.advancePx('M'));
}

test "cell metrics are integer and internally consistent" {
    const font = try Font.init(20);
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
    const sample = [_]u21{
        'A',    'z',    '0',    '#',    ' ',
        0x2500, 0x2502, 0x250C, 0x2514, 0x253C,
        0x2022, 0x2192,
    };
    for (sample) |cp| {
        _ = try font.requireGlyph(cp);
    }
}

test "missing glyph fails closed with error.MissingGlyph" {
    const font = try Font.init(20);
    const absent: u21 = 0x1F4A9;
    try testing.expect(!font.hasGlyph(absent));
    try testing.expectError(Error.MissingGlyph, font.requireGlyph(absent));
    try testing.expectEqual(@as(i32, 0), font.glyphIndex(absent));
}

test "space may map to glyph zero without erroring" {
    const font = try Font.init(20);
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

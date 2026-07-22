//! 8-bit RGBA row-major raster surface with rectangle fills and alpha-blended
//! glyph-mask compositing.
//!
//! The surface is treated as fully opaque: every pixel keeps alpha 255. Fills
//! overwrite; glyph masks and decoration strokes are alpha-blended over the
//! existing pixels using the source color's coverage. All coordinates are
//! integers and every write is clipped to the surface bounds, so callers may
//! pass masks that hang off any edge without a bounds check of their own.

const std = @import("std");
const types = @import("types.zig");

const Color = types.Color;

pub const Surface = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes, row-major RGBA.
    pixels: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!Surface {
        const len = @as(usize, width) * @as(usize, height) * 4;
        const pixels = try allocator.alloc(u8, len);
        @memset(pixels, 0);
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: Surface, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    /// Overwrite the entire surface with an opaque color.
    pub fn fill(self: *Surface, color: Color) void {
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            self.pixels[i + 0] = color.r;
            self.pixels[i + 1] = color.g;
            self.pixels[i + 2] = color.b;
            self.pixels[i + 3] = 255;
        }
    }

    /// Overwrite an axis-aligned rectangle with an opaque color, clipped to the
    /// surface. `x`/`y` are signed so a caller can pass a partially off-screen
    /// rectangle.
    pub fn fillRect(self: *Surface, x: i64, y: i64, w: u32, h: u32, color: Color) void {
        const x0 = clampLow(x);
        const y0 = clampLow(y);
        const x1 = clampHigh(x + @as(i64, w), self.width);
        const y1 = clampHigh(y + @as(i64, h), self.height);
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            var px: u32 = x0;
            const row = @as(usize, py) * self.width;
            while (px < x1) : (px += 1) {
                const i = (row + px) * 4;
                self.pixels[i + 0] = color.r;
                self.pixels[i + 1] = color.g;
                self.pixels[i + 2] = color.b;
                self.pixels[i + 3] = 255;
            }
        }
    }

    /// Alpha-blend a coverage mask (`mask_w * mask_h` bytes of 0..255 in
    /// row-major order) onto the surface at integer pixel `(dst_x, dst_y)` using
    /// `color`. The effective per-pixel alpha is `coverage * color.a / 255`.
    /// Fully clipped; a zero-size mask is a no-op.
    pub fn blendMask(
        self: *Surface,
        mask: []const u8,
        mask_w: u32,
        mask_h: u32,
        dst_x: i64,
        dst_y: i64,
        color: Color,
    ) void {
        if (mask_w == 0 or mask_h == 0) return;
        std.debug.assert(mask.len == @as(usize, mask_w) * @as(usize, mask_h));

        var my: u32 = 0;
        while (my < mask_h) : (my += 1) {
            const py = dst_y + @as(i64, my);
            if (py < 0 or py >= self.height) continue;
            const dst_row = @as(usize, @intCast(py)) * self.width;
            const mask_row = @as(usize, my) * mask_w;
            var mx: u32 = 0;
            while (mx < mask_w) : (mx += 1) {
                const px = dst_x + @as(i64, mx);
                if (px < 0 or px >= self.width) continue;
                const coverage = mask[mask_row + mx];
                if (coverage == 0) continue;
                const alpha = scale255(coverage, color.a);
                if (alpha == 0) continue;
                self.blendPixel(dst_row + @as(usize, @intCast(px)), color, alpha);
            }
        }
    }

    fn blendPixel(self: *Surface, pixel_index: usize, color: Color, alpha: u8) void {
        const i = pixel_index * 4;
        self.pixels[i + 0] = blend(color.r, self.pixels[i + 0], alpha);
        self.pixels[i + 1] = blend(color.g, self.pixels[i + 1], alpha);
        self.pixels[i + 2] = blend(color.b, self.pixels[i + 2], alpha);
        self.pixels[i + 3] = 255;
    }

    fn clampLow(v: i64) u32 {
        return if (v < 0) 0 else @intCast(v);
    }

    fn clampHigh(v: i64, limit: u32) u32 {
        if (v < 0) return 0;
        if (v > limit) return limit;
        return @intCast(v);
    }
};

/// `src * alpha + dst * (255 - alpha)`, rounded, over 0..255.
fn blend(src: u8, dst: u8, alpha: u8) u8 {
    const a: u32 = alpha;
    const s: u32 = src;
    const d: u32 = dst;
    return @intCast((s * a + d * (255 - a) + 127) / 255);
}

/// `a * b / 255`, rounded.
fn scale255(a: u8, b: u8) u8 {
    return @intCast((@as(u32, a) * @as(u32, b) + 127) / 255);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn pixelAt(s: Surface, x: u32, y: u32) Color {
    const i = (@as(usize, y) * s.width + x) * 4;
    return .{ .r = s.pixels[i], .g = s.pixels[i + 1], .b = s.pixels[i + 2], .a = s.pixels[i + 3] };
}

test "fill paints every pixel opaque" {
    var s = try Surface.init(testing.allocator, 3, 2);
    defer s.deinit(testing.allocator);
    s.fill(.{ .r = 10, .g = 20, .b = 30 });
    try testing.expectEqual(Color{ .r = 10, .g = 20, .b = 30, .a = 255 }, pixelAt(s, 2, 1));
}

test "fillRect clips to surface bounds" {
    var s = try Surface.init(testing.allocator, 4, 4);
    defer s.deinit(testing.allocator);
    s.fill(.{ .r = 0, .g = 0, .b = 0 });
    // Rectangle starting off the top-left, extending past the bottom-right.
    s.fillRect(-2, -2, 4, 4, .{ .r = 255, .g = 255, .b = 255 });
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 255 }, pixelAt(s, 0, 0));
    try testing.expectEqual(Color{ .r = 255, .g = 255, .b = 255, .a = 255 }, pixelAt(s, 1, 1));
    // Outside the rect stays black.
    try testing.expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 255 }, pixelAt(s, 2, 2));
}

test "blendMask composites coverage over the background" {
    var s = try Surface.init(testing.allocator, 2, 1);
    defer s.deinit(testing.allocator);
    s.fill(.{ .r = 255, .g = 255, .b = 255 }); // white page
    // Left pixel full coverage black, right pixel half coverage.
    const mask = [_]u8{ 255, 128 };
    s.blendMask(&mask, 2, 1, 0, 0, .{ .r = 0, .g = 0, .b = 0 });
    try testing.expectEqual(@as(u8, 0), pixelAt(s, 0, 0).r); // fully black
    const half = pixelAt(s, 1, 0).r; // ~ (0*128 + 255*127 +127)/255 = 127
    try testing.expectEqual(@as(u8, 127), half);
}

test "blendMask clips negative and overflowing coordinates" {
    var s = try Surface.init(testing.allocator, 2, 2);
    defer s.deinit(testing.allocator);
    s.fill(.{ .r = 255, .g = 255, .b = 255 });
    const mask = [_]u8{ 255, 255, 255, 255 };
    // Placed so only the bottom-right mask pixel lands on surface pixel (0,0).
    s.blendMask(&mask, 2, 2, -1, -1, .{ .r = 0, .g = 0, .b = 0 });
    try testing.expectEqual(@as(u8, 0), pixelAt(s, 0, 0).r);
    try testing.expectEqual(@as(u8, 255), pixelAt(s, 1, 1).r);
}

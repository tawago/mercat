const std = @import("std");
const line_mod = @import("line.zig");
const builder_mod = @import("builder.zig");
const geometry = @import("geometry.zig");
const decor_mod = @import("decor.zig");

const Builder = builder_mod.Builder;
const SpanStyle = line_mod.SpanStyle;
const Decor = decor_mod.Decor;

/// Fill one row with `glyph` repeated to `width` columns.
pub fn renderUnderlineRow(allocator: std.mem.Allocator, builder: *Builder, width: usize, style: SpanStyle, glyph: []const u8) !void {
    if (width == 0 or glyph.len == 0) return;
    const glyph_width = @max(try geometry.displayWidth(glyph), 1);
    const count = width / glyph_width;
    if (count == 0) return;
    const text = try repeatGlyph(allocator, glyph, count);
    defer allocator.free(text);
    try builder.appendSpan(style, text);
}

/// Render a horizontal rule per the decor's mode and glyph.
pub fn renderHr(allocator: std.mem.Allocator, builder: *Builder, width: usize, decor: *const Decor) !void {
    const glyphs = decor.glyphs;
    const glyph = if (glyphs.hr_glyph.len == 0) "\u{2500}" else glyphs.hr_glyph;
    const glyph_width = try geometry.displayWidth(glyph);
    if (glyph_width == 0 or width == 0) return;
    const max_glyphs = width / glyph_width;
    const total: usize = switch (glyphs.hr_mode) {
        .full => max_glyphs,
        .fixed => @min(@as(usize, glyphs.hr_count), max_glyphs),
    };
    if (total == 0) return;

    const center = glyphs.hr_center;
    const center_width = if (center.len == 0) 0 else try geometry.displayWidth(center);
    const center_slots = (center_width + glyph_width - 1) / glyph_width;
    if (center.len == 0 or center_slots >= total) {
        const text = try repeatGlyph(allocator, glyph, total);
        defer allocator.free(text);
        try builder.appendSpan(.hr, text);
        return;
    }
    const bar_slots = total - center_slots;
    const left = bar_slots / 2;
    const right = bar_slots - left;
    const left_text = try repeatGlyph(allocator, glyph, left);
    defer allocator.free(left_text);
    const right_text = try repeatGlyph(allocator, glyph, right);
    defer allocator.free(right_text);
    try builder.appendSpan(.hr, left_text);
    try builder.appendSpan(.hr, center);
    try builder.appendSpan(.hr, right_text);
}

fn repeatGlyph(allocator: std.mem.Allocator, glyph: []const u8, count: usize) ![]u8 {
    const buffer = try allocator.alloc(u8, count * glyph.len);
    for (0..count) |index| {
        @memcpy(buffer[index * glyph.len ..][0..glyph.len], glyph);
    }
    return buffer;
}

const std = @import("std");
const line_mod = @import("line.zig");
const builder_mod = @import("builder.zig");
const geometry = @import("geometry.zig");
const decor_mod = @import("decor.zig");

const Builder = builder_mod.Builder;
const SpanStyle = line_mod.SpanStyle;
const Decor = decor_mod.Decor;

pub fn renderUnderlineRow(builder: *Builder, width: usize, style: SpanStyle, glyph: []const u8) !void {
    if (width == 0 or glyph.len == 0) return;
    const glyph_width = @max(try geometry.displayWidth(glyph), 1);
    try builder.appendRepeated(style, glyph, width / glyph_width);
}

pub fn renderHr(builder: *Builder, width: usize, decor: *const Decor) !void {
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
        try builder.appendRepeated(.hr, glyph, total);
        return;
    }
    const bar_slots = total - center_slots;
    const left = bar_slots / 2;
    try builder.appendRepeated(.hr, glyph, left);
    try builder.appendSpan(.hr, center);
    try builder.appendRepeated(.hr, glyph, bar_slots - left);
}

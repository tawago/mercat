//! Sparse-spec merge primitives for the extends-chain fold. Pure data
//! transforms over `spec` types — no diagnostics, no I/O — split out of
//! resolve.zig so that module stays under the line-count limit. `mergeChain`
//! (in resolve.zig) drives these; later layers override earlier (absent field
//! inherits, present field wins; a present `""` prefix/glyph deliberately
//! clears — see bake).
const spec = @import("spec.zig");

const ThemeSpec = spec.ThemeSpec;
const SlotSpec = spec.SlotSpec;

pub fn mergeInto(out: *ThemeSpec, s: *const ThemeSpec) void {
    if (s.extends) |_| {}
    if (s.palette_mode) |m| out.palette_mode = m;
    if (s.base_bg) |c| out.base_bg = c;
    if (s.canvas) |v| out.canvas = v;

    var i: usize = 0;
    while (i < spec.slot_count) : (i += 1) {
        if (s.slots.entries[i]) |over| {
            out.slots.entries[i] = overlay(SlotSpec, out.slots.entries[i] orelse .{}, over);
        }
    }
    out.glyphs = overlay(spec.GlyphSet, out.glyphs, s.glyphs);
    out.tokens = overlay(spec.TokenColors, out.tokens, s.tokens);
}

/// Field-wise overlay over an all-optional-field struct: an absent (`null`)
/// field of `over` inherits `base`'s value, a present field wins (so a present
/// `""` prefix/glyph deliberately clears — see bake). Sparse-struct fields
/// (`GlyphSet.code_frame`) recurse rather than replacing wholesale, so
/// `[theme.code_frame] pad = 2` inherits the base's kind/language_label.
pub fn overlay(comptime T: type, base: T, over: T) T {
    var r = base;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (@field(over, f.name)) |v| {
            if (comptime @TypeOf(v) == spec.CodeFrameDelta) {
                @field(r, f.name) = overlay(spec.CodeFrameDelta, @field(r, f.name) orelse .{}, v);
            } else {
                @field(r, f.name) = v;
            }
        }
    }
    return r;
}

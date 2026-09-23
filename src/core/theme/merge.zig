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

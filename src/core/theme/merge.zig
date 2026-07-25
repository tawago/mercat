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
    if (s.extends) |_| {} // extends already consumed by chain walk
    if (s.palette_mode) |m| out.palette_mode = m;
    if (s.base_bg) |c| out.base_bg = c;
    if (s.canvas) |v| out.canvas = v;

    // Slots.
    var i: usize = 0;
    while (i < spec.slot_count) : (i += 1) {
        if (s.slots.entries[i]) |over| {
            out.slots.entries[i] = mergeSlot(out.slots.entries[i], over);
        }
    }
    // Glyphs (each field independently sparse).
    mergeGlyphs(&out.glyphs, s.glyphs);
    // Tokens.
    if (s.tokens.keyword) |c| out.tokens.keyword = c;
    if (s.tokens.string) |c| out.tokens.string = c;
    if (s.tokens.number) |c| out.tokens.number = c;
    if (s.tokens.comment) |c| out.tokens.comment = c;
}

pub fn mergeSlot(base: ?SlotSpec, over: SlotSpec) SlotSpec {
    var r = base orelse SlotSpec{};
    if (over.fg) |v| r.fg = v;
    if (over.bg) |v| r.bg = v;
    if (over.full_line_bg) |v| r.full_line_bg = v;
    if (over.bold) |v| r.bold = v;
    if (over.italic) |v| r.italic = v;
    if (over.underline) |v| r.underline = v;
    if (over.strike) |v| r.strike = v;
    if (over.prefix) |v| r.prefix = v; // present "" clears
    if (over.suffix) |v| r.suffix = v;
    if (over.shift) |v| r.shift = v;
    if (over.blank_wrap) |v| r.blank_wrap = v;
    if (over.icon) |v| r.icon = v;
    if (over.underline_row) |v| r.underline_row = v;
    if (over.underline_glyph) |v| r.underline_glyph = v; // present "" clears to default
    return r;
}

pub fn mergeGlyphs(out: *spec.GlyphSet, g: spec.GlyphSet) void {
    if (g.bullets) |v| out.bullets = v;
    if (g.ordered_prefix) |v| out.ordered_prefix = v;
    if (g.task_ticked) |v| out.task_ticked = v;
    if (g.task_unticked) |v| out.task_unticked = v;
    if (g.quote_bar) |v| out.quote_bar = v;
    if (g.quote_indent) |v| out.quote_indent = v;
    if (g.hr_glyph) |v| out.hr_glyph = v;
    if (g.hr_mode) |v| out.hr_mode = v;
    if (g.hr_count) |v| out.hr_count = v;
    if (g.hr_center) |v| out.hr_center = v;
    if (g.table_style) |v| out.table_style = v;
    // Per-field, not wholesale: `[theme.code_frame] pad = 2` inherits the base's
    // kind/language_label rather than resetting them.
    if (g.code_frame) |v| out.code_frame = mergeCodeFrame(out.code_frame, v);
}

/// Fold one sparse code frame over another, mirroring `mergeSlot`: absent field
/// inherits, present field wins.
pub fn mergeCodeFrame(base: ?spec.CodeFrameDelta, over: spec.CodeFrameDelta) spec.CodeFrameDelta {
    var r = base orelse spec.CodeFrameDelta{};
    if (over.kind) |v| r.kind = v;
    if (over.border_glyph) |v| r.border_glyph = v;
    if (over.border_cap) |v| r.border_cap = v;
    if (over.pad) |v| r.pad = v;
    if (over.language_label) |v| r.language_label = v;
    return r;
}

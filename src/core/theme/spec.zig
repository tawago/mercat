//! Stage S3: the theme *spec* schema — the sparse, pure-data description of a
//! full theme (colors + decor + attrs). Every field of a `SlotSpec` /
//! `GlyphSet` is optional so a theme can carry only its deltas from a base:
//!
//!   - a field left `null`  → inherit the base value
//!   - a string field set to `""` → *clear* the inherited value (see resolve)
//!
//! Nothing here interprets colors or reads files; this module is the vocabulary
//! that `presets.zig` (built-ins, S4) and `loadfile`/`resolve` (user files,
//! sparse folding) both speak. The concrete, non-optional bake target lives in
//! `render/decor.zig` (`Decor`) and `theme.StyleMap`.

const std = @import("std");
const color = @import("color.zig");
const types = @import("../markdown/render/types.zig");

pub const Color = color.Color;

/// The set of themeable slots. Every slot mirrors a `render_model.SpanStyle`
/// one-for-one (same names) so a `SpanStyle` maps to a `Slot` by tag name. The
/// list/task marker slots (`bullet`/`ordered`/`task_on`/`task_off`) are
/// color-bearing too; a theme that leaves their `fg` unset resolves them to the
/// `muted` color (their SpanStyle palette default), so markers stay muted unless
/// a theme opts in.
pub const Slot = enum {
    heading1,
    heading2,
    heading3,
    heading4,
    heading5,
    heading6,
    body,
    muted,
    emphasis,
    strong,
    strong_emphasis,
    code,
    code_block,
    code_block_keyword,
    code_block_string,
    code_block_number,
    code_block_comment,
    code_keyword,
    code_string,
    code_number,
    code_comment,
    quote,
    link,
    strikethrough,
    image_alt,
    superscript,
    subscript,
    highlight,
    frontmatter_key,
    frontmatter_value,
    frontmatter_cap,
    bullet,
    ordered,
    task_on,
    task_off,
    list_item,
    table_border,
    table_header,
    hr,
    code_fence_banner,

    /// The `Slot` matching a `SpanStyle` (identical tag names).
    pub fn fromSpanStyle(style: types.SpanStyle) Slot {
        return std.meta.stringToEnum(Slot, @tagName(style)).?;
    }
};

pub const slot_count = @typeInfo(Slot).@"enum".fields.len;

/// A sparse per-slot delta. Absent (`null`) fields inherit; a string field set
/// to the empty string clears the inherited value (resolve treats `""` as a
/// deliberate "no prefix / no icon", distinct from `null`'s "inherit").
pub const SlotSpec = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    /// true → tint the whole terminal row (markview headings); default span-bg.
    full_line_bg: ?bool = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    strike: ?bool = null,
    /// "" clears the inherited prefix.
    prefix: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    /// Per-slot cumulative indent (markview headings 1..5).
    shift: ?u8 = null,
    /// Own-line blank wraps around the block (pink h1).
    blank_wrap: ?bool = null,
    /// Leading glyph for link/image slots.
    icon: ?[]const u8 = null,
    /// Heading slots (1..6) only: add one extra row directly below the heading,
    /// filled edge-to-edge with `underline_glyph`. A space glyph makes it a
    /// padding row (visible under a `full_line_bg` tint / canvas); "─"/"═" make
    /// it a setext-style underline. Ignored (harmless) on non-heading slots.
    underline_row: ?bool = null,
    /// Glyph for the `underline_row` fill. `null` (enabled but unset) and an
    /// explicit "" both resolve to the default "─"; "" thus clears an inherited
    /// glyph back to the default (distinct from the null-vs-"" semantics used by
    /// prefix/icon, where "" means "none").
    underline_glyph: ?[]const u8 = null,
};

pub const HrMode = enum { full, fixed };
pub const TableStyle = enum { grid, heavy, double, ascii, rounded };
pub const CodeFrameKind = enum { panel, rule, block, plain };

/// One encoding for every code-frame flavor: `kind` selects the flavor and the
/// remaining fields parameterize it (Simplicity #1 — no per-kind struct zoo).
///
/// Sparse like a `SlotSpec`: every field optional so a code frame folds
/// field-by-field — a child theme that sets only `pad` keeps its base's `kind`
/// and `language_label`. The renderer reads this form directly
/// (`render/blocks.zig`), applying the `.panel`/`false` defaults at the read
/// sites for whatever the fold left unset.
pub const CodeFrameDelta = struct {
    kind: ?CodeFrameKind = null,
    border_glyph: ?[]const u8 = null,
    /// Rule-mode cap on the drawn border width.
    border_cap: ?u16 = null,
    pad: ?u8 = null,
    /// Block-mode language chip.
    language_label: ?bool = null,
};

/// Sparse list/hr/table/code glyph vocabulary.
pub const GlyphSet = struct {
    /// Per-depth bullet glyphs; index clamps to the last entry.
    bullets: ?[]const []const u8 = null,
    /// Leading pad before "N." (ansi = " ").
    ordered_prefix: ?[]const u8 = null,
    task_ticked: ?[]const u8 = null,
    task_unticked: ?[]const u8 = null,
    quote_bar: ?[]const u8 = null,
    quote_indent: ?u8 = null,
    hr_glyph: ?[]const u8 = null,
    hr_mode: ?HrMode = null,
    hr_count: ?u16 = null,
    hr_center: ?[]const u8 = null,
    table_style: ?TableStyle = null,
    code_frame: ?CodeFrameDelta = null,
};

/// Code-token colors, collapsed onto mercat's existing four token classes. The
/// TOML key `function` is an accepted *alias* canonicalized into `keyword` at
/// parse time (`fromraw`), so there is one field and a child's `function` beats
/// an inherited `keyword` like any other override (do not widen the highlighter
/// taxonomy — locked decision).
pub const TokenColors = struct {
    keyword: ?Color = null,
    string: ?Color = null,
    number: ?Color = null,
    comment: ?Color = null,
};

/// The 16-color `ansi` preset locks the palette to named ANSI slots so the
/// terminal's own palette decides the hues; everything else may use rgb/256.
pub const PaletteMode = enum { truecolor_or_256, ansi16 };

/// A fixed-size sparse slot table. Index by `Slot`; absent entries are `null`.
pub const SlotMap = struct {
    entries: [slot_count]?SlotSpec = [_]?SlotSpec{null} ** slot_count,

    pub fn get(self: SlotMap, s: Slot) ?SlotSpec {
        return self.entries[@intFromEnum(s)];
    }

    pub fn getPtr(self: *SlotMap, s: Slot) *?SlotSpec {
        return &self.entries[@intFromEnum(s)];
    }

    pub fn set(self: *SlotMap, s: Slot, v: SlotSpec) void {
        self.entries[@intFromEnum(s)] = v;
    }
};

/// A full theme description — the sparse `SlotMap` *is* the partial palette
/// (Simplicity #8: no separate PartialPalette type).
pub const ThemeSpec = struct {
    name: []const u8,
    extends: ?[]const u8 = null,
    palette_mode: ?PaletteMode = null,
    slots: SlotMap = .{},
    /// The `classic` syntax-highlighting variant, modeled as a sparse delta over
    /// `slots` covering only the code-token slots that differ. Consumed for the
    /// `dark`/`light` bases by `resolve` when `syntax_theme == .classic`
    /// (folded as an extra layer before inline overrides). `--dump-theme` stays
    /// classic-agnostic and always dumps the default variant (`slots`). Kept here
    /// so `presets.zig` remains the single source of truth for both variants.
    slots_classic: SlotMap = .{},
    glyphs: GlyphSet = .{},
    tokens: TokenColors = .{},
    base_bg: ?Color = null,
    /// Paint the whole document background with the resolved `base_bg` (a solid
    /// "canvas"). Sparse like the other top-level fields: `null` inherits down
    /// the extends chain; the terminal-native presets (dark/light/ansi) set it
    /// false so their output stays byte-identical to the un-themed terminal.
    canvas: ?bool = null,
};

const testing = std.testing;

test "Slot mirrors SpanStyle by name" {
    inline for (@typeInfo(types.SpanStyle).@"enum".fields) |f| {
        _ = Slot.fromSpanStyle(@field(types.SpanStyle, f.name));
    }
}

test "SlotMap get/set is sparse" {
    var m = SlotMap{};
    try testing.expect(m.get(.heading1) == null);
    m.set(.heading1, .{ .bold = true });
    try testing.expectEqual(@as(?bool, true), m.get(.heading1).?.bold);
    try testing.expect(m.get(.heading2) == null);
}

test "ThemeSpec defaults are all-sparse" {
    const s = ThemeSpec{ .name = "x" };
    try testing.expect(s.extends == null);
    try testing.expect(s.palette_mode == null);
    try testing.expect(s.glyphs.bullets == null);
    var slots = s.slots;
    try testing.expect(slots.get(.body) == null);
}

//! Stage S4: the seven built-in theme presets, encoded as `ThemeSpec` data.
//!
//! Source of truth is the `#presetsData` JSON in the design preview; each
//! preset here mirrors its entry. Two intentional adaptations:
//!
//!   - `ansi` stores *named* ANSI colors (`.ansi16`) rather than the JSON's
//!     rendered hex, so the terminal's own palette decides the hues (SGR
//!     30-37/90-97). The JSON hex are just one terminal's rendering of them.
//!   - `markview` replaces every Nerd-font private-use glyph with a widely
//!     supported Unicode equivalent (owner-locked ◉/◈/◇ heading family, ✓/○
//!     tasks, ▋ quote bar, → / ⧉ link/image icons, rounded table borders) so
//!     the preset is authored PUA-free and never triggers `glyph_fallback`.
//!
//! `dark`/`light` are encoded as FULL data specs (every one of the 35 slots +
//! the `classic` syntax-variant delta), so `presets.zig` is the single source
//! of truth for them exactly like `dracula`. `theme.zig` derives its neutral
//! fallback palettes from these specs at comptime (`theme.neutralDark`/
//! `neutralLight`), so the slot colors live in exactly one place. A byte-identity
//! unit test (`resolve.zig`) guards `resolve("dark"/"light") == the historical
//! palette literals`.
//!
//! Schema-gap notes (not representable in the S3 slot/glyph schema, so
//! deliberately dropped here):
//!   - horizontal-rule *color* (no hr color slot; hr keeps the muted default),
//!   - a link/image label color distinct from the URL color (JSON `text`),
//!   - `pink`'s bold-link-text and `markview`'s heading `sign` gutter marks.

const std = @import("std");
const spec = @import("spec.zig");
const color = @import("color.zig");

const Color = color.Color;
const rgb = color.rgb;
const ThemeSpec = spec.ThemeSpec;
const SlotMap = spec.SlotMap;
const SlotSpec = spec.SlotSpec;
const GlyphSet = spec.GlyphSet;
const TokenColors = spec.TokenColors;
const CodeFrameDelta = spec.CodeFrameDelta;

fn a16(named: color.Ansi16) Color {
    return .{ .ansi16 = named };
}

fn ix(n: u8) Color {
    return color.idx(n);
}

/// The `# ` heading markers the historical renderer drew, folded onto the six
/// heading slots (color/attrs supplied by the caller's base spec).
fn withHeadingPrefixes(m: *SlotMap) void {
    inline for (.{ "# ", "## ", "### ", "#### ", "##### ", "###### " }, 0..) |p, i| {
        const slot: spec.Slot = @enumFromInt(@intFromEnum(spec.Slot.heading1) + i);
        var ss = m.get(slot) orelse SlotSpec{};
        ss.prefix = p;
        m.set(slot, ss);
    }
}

/// `▎` quote bar (U+258E) that the historical renderer drew.
const legacy_glyphs = GlyphSet{ .quote_bar = "\u{258E}" };

fn darkSlots() SlotMap {
    var m = SlotMap{};
    m.set(.heading1, .{ .fg = ix(81), .bold = true, .underline_row = true, .underline_glyph = "‾" });
    m.set(.heading2, .{ .fg = ix(80), .bold = true });
    m.set(.heading3, .{ .fg = ix(74) });
    m.set(.heading4, .{ .fg = ix(67) });
    m.set(.heading5, .{ .fg = ix(66) });
    m.set(.heading6, .{ .fg = ix(59) });
    m.set(.body, .{ .fg = ix(254) });
    m.set(.muted, .{ .fg = ix(244) });
    m.set(.emphasis, .{ .fg = ix(188), .italic = true });
    m.set(.strong, .{ .fg = ix(231), .bold = true });
    m.set(.strong_emphasis, .{ .fg = ix(231), .bold = true, .italic = true });
    m.set(.code, .{ .fg = ix(114) });
    m.set(.code_block, .{ .fg = ix(250), .bg = ix(236) });
    m.set(.code_block_keyword, .{ .fg = ix(141), .bold = true, .bg = ix(236) });
    m.set(.code_block_string, .{ .fg = ix(114), .bg = ix(236) });
    m.set(.code_block_number, .{ .fg = ix(216), .bg = ix(236) });
    m.set(.code_block_comment, .{ .fg = ix(243), .bg = ix(236) });
    m.set(.code_keyword, .{ .fg = ix(141), .bold = true });
    m.set(.code_string, .{ .fg = ix(180) });
    m.set(.code_number, .{ .fg = ix(216) });
    m.set(.code_comment, .{ .fg = ix(243) });
    m.set(.quote, .{ .fg = ix(109) });
    m.set(.link, .{ .fg = ix(117), .underline = true });
    m.set(.strikethrough, .{ .fg = ix(244), .strike = true });
    m.set(.image_alt, .{ .fg = ix(213) });
    m.set(.superscript, .{ .fg = ix(153) });
    m.set(.subscript, .{ .fg = ix(152) });
    m.set(.highlight, .{ .fg = ix(227), .bold = true });
    m.set(.frontmatter_key, .{ .fg = ix(109), .bg = ix(236) });
    m.set(.frontmatter_value, .{ .fg = ix(250), .bg = ix(236) });
    m.set(.frontmatter_cap, .{ .fg = ix(236) });
    m.set(.bullet, .{ .fg = ix(244) });
    m.set(.ordered, .{ .fg = ix(74) });
    m.set(.task_on, .{ .fg = ix(244) });
    m.set(.task_off, .{ .fg = ix(244) });
    m.set(.list_item, .{ .fg = ix(250) });
    withHeadingPrefixes(&m);
    return m;
}

/// classic syntax variant delta for dark: recolored code tokens.
fn darkClassic() SlotMap {
    var m = SlotMap{};
    m.set(.code_block, .{ .fg = ix(114), .bg = ix(236) });
    m.set(.code_block_keyword, .{ .fg = ix(81), .bold = true, .bg = ix(236) });
    m.set(.code_block_string, .{ .fg = ix(186), .bg = ix(236) });
    m.set(.code_block_number, .{ .fg = ix(221), .bg = ix(236) });
    m.set(.code_keyword, .{ .fg = ix(81), .bold = true });
    m.set(.code_string, .{ .fg = ix(186) });
    m.set(.code_number, .{ .fg = ix(221) });
    return m;
}

fn lightSlots() SlotMap {
    var m = SlotMap{};
    m.set(.heading1, .{ .fg = ix(20), .bold = true, .underline_row = true, .underline_glyph = "‾" });
    m.set(.heading2, .{ .fg = ix(21), .bold = true });
    m.set(.heading3, .{ .fg = ix(33) });
    m.set(.heading4, .{ .fg = ix(39) });
    m.set(.heading5, .{ .fg = ix(45) });
    m.set(.heading6, .{ .fg = ix(109) });
    m.set(.body, .{ .fg = ix(234) });
    m.set(.muted, .{ .fg = ix(245) });
    m.set(.emphasis, .{ .fg = ix(60), .italic = true });
    m.set(.strong, .{ .fg = ix(19), .bold = true });
    m.set(.strong_emphasis, .{ .fg = ix(19), .bold = true, .italic = true });
    m.set(.code, .{ .fg = ix(34) });
    m.set(.code_block, .{ .fg = ix(239), .bg = ix(254) });
    m.set(.code_block_keyword, .{ .fg = ix(92), .bold = true, .bg = ix(254) });
    m.set(.code_block_string, .{ .fg = ix(34), .bg = ix(254) });
    m.set(.code_block_number, .{ .fg = ix(172), .bg = ix(254) });
    m.set(.code_block_comment, .{ .fg = ix(246), .bg = ix(254) });
    m.set(.code_keyword, .{ .fg = ix(97), .bold = true });
    m.set(.code_string, .{ .fg = ix(131) });
    m.set(.code_number, .{ .fg = ix(167) });
    m.set(.code_comment, .{ .fg = ix(246) });
    m.set(.quote, .{ .fg = ix(60) });
    m.set(.link, .{ .fg = ix(27), .underline = true });
    m.set(.strikethrough, .{ .fg = ix(245), .strike = true });
    m.set(.image_alt, .{ .fg = ix(213) });
    m.set(.superscript, .{ .fg = ix(26) });
    m.set(.subscript, .{ .fg = ix(31) });
    m.set(.highlight, .{ .fg = ix(202), .bold = true });
    m.set(.frontmatter_key, .{ .fg = ix(60), .bg = ix(254) });
    m.set(.frontmatter_value, .{ .fg = ix(239), .bg = ix(254) });
    m.set(.frontmatter_cap, .{ .fg = ix(254) });
    m.set(.bullet, .{ .fg = ix(245) });
    m.set(.ordered, .{ .fg = ix(31) });
    m.set(.task_on, .{ .fg = ix(245) });
    m.set(.task_off, .{ .fg = ix(245) });
    m.set(.list_item, .{ .fg = ix(236) });
    withHeadingPrefixes(&m);
    return m;
}

fn lightClassic() SlotMap {
    var m = SlotMap{};
    m.set(.code_block, .{ .fg = ix(28), .bg = ix(254) });
    m.set(.code_block_keyword, .{ .fg = ix(25), .bold = true, .bg = ix(254) });
    m.set(.code_block_string, .{ .fg = ix(94), .bg = ix(254) });
    m.set(.code_block_number, .{ .fg = ix(130), .bg = ix(254) });
    m.set(.code_keyword, .{ .fg = ix(25), .bold = true });
    m.set(.code_string, .{ .fg = ix(94) });
    m.set(.code_number, .{ .fg = ix(130) });
    return m;
}

pub const dark = ThemeSpec{
    .name = "dark",
    .base_bg = rgb(0x1c, 0x1c, 0x1c),
    .canvas = false,
    .slots = darkSlots(),
    .slots_classic = darkClassic(),
    .glyphs = legacy_glyphs,
};

pub const light = ThemeSpec{
    .name = "light",
    .base_bg = rgb(0xff, 0xff, 0xff),
    .canvas = true,
    .slots = lightSlots(),
    .slots_classic = lightClassic(),
    .glyphs = legacy_glyphs,
};

pub const ansi = ThemeSpec{
    .name = "ansi",
    .palette_mode = .ansi16,
    .base_bg = .default,
    .canvas = false,
    .slots = blk: {
        var m = SlotMap{};
        m.set(.heading1, .{ .fg = a16(.bright_blue), .bold = true, .prefix = "┄ " });
        m.set(.heading2, .{ .fg = a16(.bright_blue), .bold = true, .prefix = "┄┄ " });
        m.set(.heading3, .{ .fg = a16(.bright_blue), .bold = true, .prefix = "┄┄┄ " });
        m.set(.heading4, .{ .fg = a16(.bright_blue), .bold = true, .prefix = "┄┄┄ " });
        m.set(.heading5, .{ .fg = a16(.bright_blue), .bold = true, .prefix = "┄┄┄ " });
        m.set(.heading6, .{ .fg = a16(.bright_blue), .bold = true, .prefix = "┄┄┄ " });
        m.set(.body, .{ .fg = .default });
        m.set(.quote, .{ .fg = a16(.bright_blue), .bold = true });
        m.set(.bullet, .{ .fg = .default });
        m.set(.ordered, .{ .fg = .default });
        m.set(.task_on, .{ .fg = .default });
        m.set(.task_off, .{ .fg = .default });
        m.set(.code, .{ .fg = a16(.yellow) });
        m.set(.code_block, .{ .fg = .default, .bg = null });
        m.set(.link, .{ .fg = a16(.bright_blue), .underline = true });
        m.set(.image_alt, .{ .fg = a16(.bright_magenta) });
        m.set(.strong, .{ .fg = .default, .bold = true });
        m.set(.emphasis, .{ .fg = .default, .italic = true });
        m.set(.strikethrough, .{ .fg = .default, .strike = true });
        break :blk m;
    },
    .glyphs = .{
        .ordered_prefix = " ",
        .task_ticked = "☑",
        .task_unticked = "☐",
        .hr_glyph = "═",
        .hr_mode = .full,
        .code_frame = CodeFrameDelta{
            .kind = .rule,
            .border_glyph = "─",
            .border_cap = 20,
        },
    },
    .tokens = .{
        .keyword = a16(.bright_blue),
        .string = a16(.bright_green),
        .number = a16(.bright_magenta),
        .comment = a16(.bright_black),
    },
};

pub const dracula = ThemeSpec{
    .name = "dracula",
    .base_bg = rgb(0x28, 0x2a, 0x36),
    .canvas = true,
    .slots = blk: {
        var m = SlotMap{};
        const h = SlotSpec{ .fg = rgb(0xbd, 0x93, 0xf9), .bold = true };
        m.set(.heading1, mergePrefix(h, "# "));
        m.set(.heading2, mergePrefix(h, "## "));
        m.set(.heading3, mergePrefix(h, "### "));
        m.set(.heading4, mergePrefix(h, "### "));
        m.set(.heading5, mergePrefix(h, "### "));
        m.set(.heading6, mergePrefix(h, "### "));
        m.set(.body, .{ .fg = rgb(0xf8, 0xf8, 0xf2) });
        m.set(.quote, .{ .fg = rgb(0xf1, 0xfa, 0x8c), .italic = true });
        m.set(.bullet, .{ .fg = rgb(0xf8, 0xf8, 0xf2) });
        m.set(.ordered, .{ .fg = rgb(0x8b, 0xe9, 0xfd) });
        m.set(.task_on, .{ .fg = rgb(0xf8, 0xf8, 0xf2) });
        m.set(.task_off, .{ .fg = rgb(0xf8, 0xf8, 0xf2) });
        m.set(.code, .{ .fg = rgb(0x50, 0xfa, 0x7b) });
        m.set(.code_block, .{ .fg = rgb(0xff, 0xb8, 0x6c), .bg = rgb(0x28, 0x2a, 0x36) });
        m.set(.link, .{ .fg = rgb(0x8b, 0xe9, 0xfd), .underline = true });
        m.set(.image_alt, .{ .fg = rgb(0x8b, 0xe9, 0xfd), .underline = true, .suffix = " →" });
        m.set(.strong, .{ .fg = rgb(0xff, 0xb8, 0x6c), .bold = true });
        m.set(.emphasis, .{ .fg = rgb(0xf1, 0xfa, 0x8c), .italic = true });
        m.set(.strikethrough, .{ .fg = rgb(0xf8, 0xf8, 0xf2), .strike = true });
        break :blk m;
    },
    .glyphs = .{
        .quote_bar = "",
        .quote_indent = 2,
        .task_ticked = "[✓]",
        .task_unticked = "[ ]",
        .hr_glyph = "-",
        .hr_mode = .fixed,
        .hr_count = 8,
        .code_frame = CodeFrameDelta{ .kind = .panel, .pad = 2 },
    },
    .tokens = .{
        .keyword = rgb(0xff, 0x79, 0xc6),
        .string = rgb(0xf1, 0xfa, 0x8c),
        .number = rgb(0xbd, 0x93, 0xf9),
        .comment = rgb(0x62, 0x72, 0xa4),
    },
};

pub const tokyo_night = ThemeSpec{
    .name = "tokyo-night",
    .base_bg = rgb(0x1a, 0x1b, 0x26),
    .canvas = true,
    .slots = blk: {
        var m = SlotMap{};
        const h = SlotSpec{ .fg = rgb(0xbb, 0x9a, 0xf7), .bold = true };
        m.set(.heading1, mergePrefix(h, "# "));
        m.set(.heading2, mergePrefix(h, "## "));
        m.set(.heading3, mergePrefix(h, "### "));
        m.set(.heading4, mergePrefix(h, "### "));
        m.set(.heading5, mergePrefix(h, "### "));
        m.set(.heading6, mergePrefix(h, "### "));
        m.set(.body, .{ .fg = rgb(0xa9, 0xb1, 0xd6) });
        m.set(.quote, .{ .fg = rgb(0xa9, 0xb1, 0xd6) });
        m.set(.bullet, .{ .fg = rgb(0xa9, 0xb1, 0xd6) });
        m.set(.ordered, .{ .fg = rgb(0x7a, 0xa2, 0xf7) });
        m.set(.task_on, .{ .fg = rgb(0xa9, 0xb1, 0xd6) });
        m.set(.task_off, .{ .fg = rgb(0xa9, 0xb1, 0xd6) });
        m.set(.code, .{ .fg = rgb(0x9e, 0xce, 0x6a) });
        m.set(.code_block, .{ .fg = rgb(0xff, 0x9e, 0x64), .bg = rgb(0x1a, 0x1b, 0x26) });
        m.set(.link, .{ .fg = rgb(0x7a, 0xa2, 0xf7), .underline = true });
        m.set(.image_alt, .{ .fg = rgb(0x7a, 0xa2, 0xf7), .underline = true, .suffix = " →" });
        m.set(.strong, .{ .fg = rgb(0xa9, 0xb1, 0xd6), .bold = true });
        m.set(.emphasis, .{ .fg = rgb(0xa9, 0xb1, 0xd6), .italic = true });
        m.set(.strikethrough, .{ .fg = rgb(0xa9, 0xb1, 0xd6), .strike = true });
        break :blk m;
    },
    .glyphs = .{
        .quote_bar = "│ ",
        .task_ticked = "[✓]",
        .task_unticked = "[ ]",
        .hr_glyph = "-",
        .hr_mode = .fixed,
        .hr_count = 8,
        .code_frame = CodeFrameDelta{ .kind = .panel, .pad = 2 },
    },
    .tokens = .{
        .keyword = rgb(0x2a, 0xc3, 0xde),
        .string = rgb(0x9e, 0xce, 0x6a),
        .number = rgb(0xff, 0x9e, 0x64),
        .comment = rgb(0x56, 0x5f, 0x89),
    },
};

pub const pink = ThemeSpec{
    .name = "pink",
    .base_bg = rgb(0x1c, 0x1c, 0x1c),
    .canvas = true,
    .slots = blk: {
        var m = SlotMap{};
        const accent = rgb(0xff, 0x87, 0xff);
        m.set(.heading1, .{ .fg = accent, .bold = true, .blank_wrap = true });
        m.set(.heading2, .{ .fg = accent, .bold = true, .prefix = "▌ " });
        m.set(.heading3, .{ .fg = accent, .bold = true, .prefix = "┃ " });
        m.set(.heading4, .{ .fg = accent, .bold = true, .prefix = "│ " });
        m.set(.heading5, .{ .fg = accent, .bold = true, .prefix = "┆ " });
        m.set(.heading6, .{ .fg = accent, .bold = false, .prefix = "┊ " });
        m.set(.body, .{ .fg = rgb(0xD0, 0xD0, 0xD0) });
        m.set(.quote, .{ .fg = rgb(0xD0, 0xD0, 0xD0) });
        m.set(.bullet, .{ .fg = rgb(0xD0, 0xD0, 0xD0) });
        m.set(.ordered, .{ .fg = rgb(0xD0, 0xD0, 0xD0) });
        m.set(.task_on, .{ .fg = rgb(0xD0, 0xD0, 0xD0) });
        m.set(.task_off, .{ .fg = rgb(0xD0, 0xD0, 0xD0) });
        m.set(.code, .{ .fg = accent, .bg = rgb(0x30, 0x30, 0x30), .prefix = " ", .suffix = " " });
        m.set(.code_block, .{ .fg = rgb(0xD0, 0xD0, 0xD0) });
        m.set(.link, .{ .fg = rgb(0x87, 0x5f, 0xff), .underline = true });
        m.set(.image_alt, .{ .fg = rgb(0xD0, 0xD0, 0xD0), .underline = true });
        m.set(.strong, .{ .fg = rgb(0xD0, 0xD0, 0xD0), .bold = true });
        m.set(.emphasis, .{ .fg = rgb(0xD0, 0xD0, 0xD0), .italic = true });
        m.set(.strikethrough, .{ .fg = rgb(0xD0, 0xD0, 0xD0), .strike = true });
        break :blk m;
    },
    .glyphs = .{
        .quote_bar = "│ ",
        .task_ticked = "[✓]",
        .task_unticked = "[ ]",
        .hr_glyph = "─",
        .hr_mode = .fixed,
        .hr_count = 6,
        .code_frame = CodeFrameDelta{ .kind = .plain },
    },
    .tokens = .{
        .keyword = rgb(0xFF, 0x5F, 0xD7),
        .string = rgb(0xD7, 0xD7, 0x87),
        .number = rgb(0xAF, 0x87, 0xFF),
        .comment = rgb(0x76, 0x76, 0x76),
    },
};

pub const markview = ThemeSpec{
    .name = "markview",
    .base_bg = rgb(0x1E, 0x1E, 0x2E),
    .canvas = true,
    .slots = blk: {
        var m = SlotMap{};
        m.set(.heading1, .{ .fg = rgb(0xF3, 0x8B, 0xA8), .bg = rgb(0x3a, 0x2b, 0x33), .bold = true, .prefix = "◉  ", .full_line_bg = true, .shift = 0 });
        m.set(.heading2, .{ .fg = rgb(0xFA, 0xB3, 0x87), .bg = rgb(0x3a, 0x33, 0x29), .bold = true, .prefix = "◈  ", .full_line_bg = true, .shift = 1 });
        m.set(.heading3, .{ .fg = rgb(0xF9, 0xE2, 0xAF), .bg = rgb(0x3a, 0x38, 0x2c), .bold = true, .prefix = "◇  ", .full_line_bg = true, .shift = 2 });
        m.set(.heading4, .{ .fg = rgb(0xA6, 0xE3, 0xA1), .bg = rgb(0x2f, 0x38, 0x2d), .bold = true, .prefix = "▪  ", .full_line_bg = true, .shift = 3 });
        m.set(.heading5, .{ .fg = rgb(0x74, 0xC7, 0xEC), .bg = rgb(0x2b, 0x35, 0x40), .bold = true, .prefix = "▫  ", .full_line_bg = true, .shift = 4 });
        m.set(.heading6, .{ .fg = rgb(0xB4, 0xBE, 0xFE), .bg = rgb(0x33, 0x35, 0x3f), .bold = true, .prefix = "·  ", .full_line_bg = true, .shift = 5 });
        m.set(.body, .{ .fg = rgb(0xCD, 0xD6, 0xF4) });
        m.set(.quote, .{ .fg = rgb(0x93, 0x99, 0xB2) });
        m.set(.bullet, .{ .fg = rgb(0xF3, 0x8B, 0xA8) });
        m.set(.ordered, .{ .fg = rgb(0xCD, 0xD6, 0xF4) });
        m.set(.task_on, .{ .fg = rgb(0xA6, 0xE3, 0xA1) });
        m.set(.task_off, .{ .fg = rgb(0xF3, 0x8B, 0xA8) });
        m.set(.code, .{ .fg = rgb(0xCD, 0xD6, 0xF4), .bg = rgb(0x31, 0x32, 0x44), .prefix = " ", .suffix = " " });
        m.set(.code_block, .{ .fg = rgb(0xCD, 0xD6, 0xF4), .bg = rgb(0x18, 0x18, 0x25) });
        m.set(.link, .{ .fg = rgb(0x89, 0xB4, 0xFA), .underline = true, .icon = "→ " });
        m.set(.image_alt, .{ .fg = rgb(0xCB, 0xA6, 0xF7), .icon = "⧉ " });
        m.set(.strong, .{ .fg = rgb(0xCD, 0xD6, 0xF4), .bold = true });
        m.set(.emphasis, .{ .fg = rgb(0xCD, 0xD6, 0xF4), .italic = true });
        m.set(.strikethrough, .{ .fg = rgb(0x93, 0x99, 0xB2), .strike = true });
        break :blk m;
    },
    .glyphs = .{
        .bullets = &[_][]const u8{"●"},
        .quote_bar = "▋ ",
        .task_ticked = "✓",
        .task_unticked = "○",
        .hr_glyph = "─",
        .hr_mode = .full,
        .hr_center = "  ",
        .table_style = .rounded,
        .code_frame = CodeFrameDelta{ .kind = .block, .language_label = true, .pad = 2 },
    },
    .tokens = .{
        .keyword = rgb(0xCB, 0xA6, 0xF7),
        .string = rgb(0xA6, 0xE3, 0xA1),
        .number = rgb(0xFA, 0xB3, 0x87),
        .comment = rgb(0x6C, 0x70, 0x86),
    },
};

/// Copy `base` and set its prefix (comptime helper for the repeated heading
/// rows that share color/attrs but differ only in prefix depth).
fn mergePrefix(base: SlotSpec, prefix: []const u8) SlotSpec {
    var s = base;
    s.prefix = prefix;
    return s;
}

pub const ALL = [_]*const ThemeSpec{
    &dark,
    &light,
    &ansi,
    &dracula,
    &tokyo_night,
    &pink,
    &markview,
};

const testing = std.testing;

fn isPua(cp: u21) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0xFFFFD) or (cp >= 0x100000 and cp <= 0x10FFFD);
}

fn assertNoPua(s: []const u8) !void {
    var view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try testing.expect(!isPua(cp));
}

test "ALL has the seven presets in order" {
    try testing.expectEqual(@as(usize, 7), ALL.len);
    try testing.expectEqualStrings("dark", ALL[0].name);
    try testing.expectEqualStrings("light", ALL[1].name);
    try testing.expectEqualStrings("ansi", ALL[2].name);
    try testing.expectEqualStrings("dracula", ALL[3].name);
    try testing.expectEqualStrings("tokyo-night", ALL[4].name);
    try testing.expectEqualStrings("pink", ALL[5].name);
    try testing.expectEqualStrings("markview", ALL[6].name);
}

test "markview is PUA-free across every glyph, prefix, suffix and icon" {
    var i: usize = 0;
    while (i < spec.slot_count) : (i += 1) {
        if (markview.slots.entries[i]) |ss| {
            if (ss.prefix) |p| try assertNoPua(p);
            if (ss.suffix) |p| try assertNoPua(p);
            if (ss.icon) |p| try assertNoPua(p);
        }
    }
    const g = markview.glyphs;
    if (g.bullets) |bs| for (bs) |b| try assertNoPua(b);
    if (g.task_ticked) |t| try assertNoPua(t);
    if (g.task_unticked) |t| try assertNoPua(t);
    if (g.quote_bar) |t| try assertNoPua(t);
    if (g.hr_glyph) |t| try assertNoPua(t);
    if (g.hr_center) |t| try assertNoPua(t);
}

test "ansi preset locks the 16-color palette mode with named slots" {
    try testing.expectEqual(spec.PaletteMode.ansi16, ansi.palette_mode.?);
    const h1 = ansi.slots.get(.heading1).?;
    try testing.expectEqual(Color{ .ansi16 = .bright_blue }, h1.fg.?);
    try testing.expectEqualStrings("┄ ", h1.prefix.?);
}

test "spot-check preset fields against the spec JSON" {
    try testing.expectEqualStrings("## ", dracula.slots.get(.heading2).?.prefix.?);
    try testing.expectEqual(@as(?bool, false), pink.slots.get(.heading6).?.bold);
    try testing.expectEqual(@as(?bool, true), pink.slots.get(.heading1).?.blank_wrap);
    try testing.expectEqualStrings("│ ", tokyo_night.glyphs.quote_bar.?);
    try testing.expectEqual(spec.TableStyle.rounded, markview.glyphs.table_style.?);
    try testing.expectEqualStrings("◉  ", markview.slots.get(.heading1).?.prefix.?);
    try testing.expectEqual(@as(?u8, 5), markview.slots.get(.heading6).?.shift);
    try testing.expectEqual(spec.CodeFrameKind.rule, ansi.glyphs.code_frame.?.kind.?);
    try testing.expectEqual(@as(?u16, 20), ansi.glyphs.code_frame.?.border_cap);
}

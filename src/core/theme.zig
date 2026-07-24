//! Theme Module - Maps semantic styles to concrete colors
//!
//! This module bridges the gap between the semantic SpanStyle (heading, code, link)
//! and the concrete terminal output. It provides:
//!
//!   - Palette: A set of StyleTokens for each semantic style
//!   - token(): Maps SpanStyle → StyleToken for a given palette
//!   - vaxisStyle(): Converts StyleToken → vaxis.Style for TUI rendering
//!
//! The CLI uses StyleToken directly with ansi.writeTokenStyled().
//! The TUI uses vaxisStyle() to convert StyleToken to vaxis.Style.
//!
//! This separation allows the same Span data to render identically in both modes.

const config = @import("config.zig");
const render_model = @import("render_model.zig");
const vaxis = @import("vaxis");
const presets = @import("theme/presets.zig");
const spec = @import("theme/spec.zig");
const types = @import("render/types.zig");
pub const color = @import("theme/color.zig");
pub const Color = color.Color;

/// Terse constructor re-export so palette literals stay readable: `idx(81)`.
pub const idx = color.idx;

/// Concrete style attributes for terminal output.
/// Colors are a `Color` union (terminal-default / xterm-256 index / named
/// ansi16 / rgb) so the same token drives the CLI ANSI writer, the TUI vaxis
/// backend, and the PNG exporter.
pub const StyleToken = struct {
    fg: Color,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    bg: ?Color = null,
};

pub const Palette = struct {
    heading1: StyleToken,
    heading2: StyleToken,
    heading3: StyleToken,
    heading4: StyleToken,
    heading5: StyleToken,
    heading6: StyleToken,
    body: StyleToken,
    muted: StyleToken,
    emphasis: StyleToken,
    strong: StyleToken,
    strong_emphasis: StyleToken,
    code: StyleToken,
    code_block: StyleToken,
    code_block_keyword: StyleToken,
    code_block_string: StyleToken,
    code_block_number: StyleToken,
    code_block_comment: StyleToken,
    code_keyword: StyleToken,
    code_string: StyleToken,
    code_number: StyleToken,
    code_comment: StyleToken,
    quote: StyleToken,
    link: StyleToken,
    strikethrough: StyleToken,
    image_alt: StyleToken,
    superscript: StyleToken,
    subscript: StyleToken,
    highlight: StyleToken,
    frontmatter_key: StyleToken,
    frontmatter_value: StyleToken,
    frontmatter_cap: StyleToken,
    bullet: StyleToken,
    ordered: StyleToken,
    task_on: StyleToken,
    task_off: StyleToken,
    list_item: StyleToken,
};

/// The neutral mechanism-level palettes. These are *derived at comptime* from
/// the `dark`/`light` preset specs in `theme/presets.zig` — the single source of
/// truth — so the slot colors live in exactly one place. They serve two roles:
///   1. the legacy `palette()`/`token()` API used by the export/PNG paths + tests,
///   2. the base palette that `resolve.bake` overlays sparse preset slots onto
///      (unset slots of dracula/ansi/etc. fall back to these).
pub const neutralDark: Palette = bakeSlots(presets.dark.slots, null);
pub const neutralLight: Palette = bakeSlots(presets.light.slots, null);

/// Overlay a sparse `SlotSpec` onto a concrete `StyleToken` (mirror of
/// `resolve.applySlot`; kept here so `theme.zig` has no dependency on `resolve`).
fn applySlotToken(tok: *StyleToken, s: spec.SlotSpec) void {
    if (s.fg) |c| tok.fg = c;
    if (s.bg) |c| tok.bg = c;
    if (s.bold) |v| tok.bold = v;
    if (s.italic) |v| tok.italic = v;
    if (s.underline) |v| tok.underline = v;
    if (s.strike) |v| tok.strikethrough = v;
}

/// Bake a default `SlotMap` (plus an optional `classic`-variant delta) into a
/// concrete `Palette`, starting from an all-terminal-default palette.
fn bakeSlots(base_slots: spec.SlotMap, classic_slots: ?spec.SlotMap) Palette {
    var p: Palette = undefined;
    inline for (@typeInfo(Palette).@"struct".fields) |f| {
        @field(p, f.name) = StyleToken{ .fg = .default };
    }
    inline for (@typeInfo(types.SpanStyle).@"enum".fields) |f| {
        const style = @field(types.SpanStyle, f.name);
        const slot = spec.Slot.fromSpanStyle(style);
        if (base_slots.get(slot)) |ss| applySlotToken(&@field(p, f.name), ss);
        if (classic_slots) |cs| {
            if (cs.get(slot)) |ss| applySlotToken(&@field(p, f.name), ss);
        }
    }
    // `list_item` inherits the theme's own `body` when the slot is unset, so item
    // text renders exactly like a paragraph unless a theme opts in.
    if (base_slots.get(.list_item) == null) p.list_item = p.body;
    return p;
}

pub fn palette(theme: config.Theme, syntax_theme: config.SyntaxTheme) Palette {
    const base = switch (theme) {
        .dark, .auto => presets.dark,
        .light => presets.light,
    };
    const classic: ?spec.SlotMap = if (syntax_theme == .classic) base.slots_classic else null;
    return bakeSlots(base.slots, classic);
}

/// Maps a semantic SpanStyle to a concrete StyleToken using the given palette.
/// This is the key function that bridges semantic styles to terminal colors.
pub fn token(palette_value: Palette, style: render_model.SpanStyle) StyleToken {
    return switch (style) {
        .heading1 => palette_value.heading1,
        .heading2 => palette_value.heading2,
        .heading3 => palette_value.heading3,
        .heading4 => palette_value.heading4,
        .heading5 => palette_value.heading5,
        .heading6 => palette_value.heading6,
        .body => palette_value.body,
        .muted => palette_value.muted,
        .emphasis => palette_value.emphasis,
        .strong => palette_value.strong,
        .strong_emphasis => palette_value.strong_emphasis,
        .code => palette_value.code,
        .code_block => palette_value.code_block,
        .code_block_keyword => palette_value.code_block_keyword,
        .code_block_string => palette_value.code_block_string,
        .code_block_number => palette_value.code_block_number,
        .code_block_comment => palette_value.code_block_comment,
        .code_keyword => palette_value.code_keyword,
        .code_string => palette_value.code_string,
        .code_number => palette_value.code_number,
        .code_comment => palette_value.code_comment,
        .quote => palette_value.quote,
        .link => palette_value.link,
        .strikethrough => palette_value.strikethrough,
        .image_alt => palette_value.image_alt,
        .superscript => palette_value.superscript,
        .subscript => palette_value.subscript,
        .highlight => palette_value.highlight,
        .frontmatter_key => palette_value.frontmatter_key,
        .frontmatter_value => palette_value.frontmatter_value,
        .frontmatter_cap => palette_value.frontmatter_cap,
        .bullet => palette_value.bullet,
        .ordered => palette_value.ordered,
        .task_on => palette_value.task_on,
        .task_off => palette_value.task_off,
        .list_item => palette_value.list_item,
    };
}

/// Styling for the copy-confirmation toast: a soft panel with a subtle green
/// rounded border and readable text, tuned per light/dark mode so it reads as a
/// gentle confirmation rather than a harsh reverse-video block.
pub const ToastStyle = struct {
    fill: vaxis.Style,
    border: vaxis.Style,
    text: vaxis.Style,
};

/// Builds the toast/metadata panel style from a resolved theme's accent color
/// and panel background (Correctness #1). Both overlays share the same soft
/// panel; the caller decides whether the text is bold (toast) or not
/// (metadata). Deriving from the ResolvedTheme means all seven presets — not
/// just dark/light — get panel colors that match their palette.
pub fn panelStyle(accent: Color, base_bg: Color, bold: bool) ToastStyle {
    const bg = toVaxisColor(base_bg);
    return .{
        .fill = .{ .bg = bg },
        .border = .{ .fg = toVaxisColor(accent), .bg = bg },
        .text = .{ .fg = toVaxisColor(accent), .bg = bg, .bold = bold },
    };
}

/// Copy-confirmation toast: bold accent text on the theme panel background.
pub fn toastStyle(accent: Color, base_bg: Color) ToastStyle {
    return panelStyle(accent, base_bg, true);
}

/// TUI metadata overlay (front matter panel toggled with `m`): same soft panel
/// as the toast, non-bold so it reads as reference information.
pub fn metadataPanelStyle(accent: Color, base_bg: Color) ToastStyle {
    return panelStyle(accent, base_bg, false);
}

/// Converts a StyleToken to vaxis.Style for TUI rendering.
/// The CLI equivalent is ansi.writeTokenStyled() which emits ANSI escape codes.
pub fn vaxisStyle(token_value: StyleToken) vaxis.Style {
    return .{
        .fg = toVaxisColor(token_value.fg),
        .bg = if (token_value.bg) |bg| toVaxisColor(bg) else .default,
        .bold = token_value.bold,
        .italic = token_value.italic,
        .strikethrough = token_value.strikethrough,
        .ul_style = if (token_value.underline) .single else .off,
    };
}

/// Maps a Color union arm onto a vaxis color. The terminal decides the exact
/// hue for `default` and `ansi16`; vaxis always receives rgb for truecolor
/// (the terminal, not mercat, negotiates capability there).
pub fn toVaxisColor(c: Color) vaxis.Color {
    return switch (c) {
        .default => .default,
        .index => |n| .{ .index = n },
        .ansi16 => |a| .{ .index = a.index() },
        .rgb => |v| .{ .rgb = .{ v.r, v.g, v.b } },
    };
}

const std = @import("std");

test "vaxisStyle maps each Color union arm" {
    const a = vaxisStyle(.{ .fg = idx(81), .bg = idx(236), .bold = true });
    try std.testing.expectEqual(vaxis.Color{ .index = 81 }, a.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 236 }, a.bg);

    const b = vaxisStyle(.{ .fg = .{ .ansi16 = .blue } });
    try std.testing.expectEqual(vaxis.Color{ .index = 4 }, b.fg);
    try std.testing.expectEqual(vaxis.Color.default, b.bg);

    const c = vaxisStyle(.{ .fg = color.rgb(10, 20, 30) });
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 10, 20, 30 } }, c.fg);

    const d = vaxisStyle(.{ .fg = .default });
    try std.testing.expectEqual(vaxis.Color.default, d.fg);
}

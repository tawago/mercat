//! Theme Module - Maps semantic styles to concrete colors
//!
//! This module bridges the gap between the semantic SpanStyle (heading, code, link)
//! and the concrete terminal output. It provides:
//!
//!   - StyleMap: A set of StyleTokens for each semantic style
//!   - token(): Maps SpanStyle → StyleToken for a given palette
//!   - vaxisStyle(): Converts StyleToken → vaxis.Style for TUI rendering
//!
//! The CLI uses StyleToken directly with ansi.writeTokenStyled().
//! The TUI uses vaxisStyle() to convert StyleToken to vaxis.Style.
//!
//! This separation allows the same Span data to render identically in both modes.

const std = @import("std");
const render_model = @import("markdown/render.zig");
const vaxis = @import("vaxis");
const presets = @import("theme/presets.zig");
const spec = @import("theme/spec.zig");
const types = @import("markdown/render/types.zig");

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

pub const StyleMap = struct {
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
    // #22's marker taxonomy (replaces #17's list_marker/task_checkbox_done/
    // task_checkbox_todo). Field names are name-for-name identical to SpanStyle
    // so spec.Slot.fromSpanStyle (stringToEnum(Slot, @tagName(style)).?) resolves.
    bullet: StyleToken,
    ordered: StyleToken,
    task_on: StyleToken,
    task_off: StyleToken,
    list_item: StyleToken,
    // Structural color slots re-added for the reconciled 40-slot union (S2). Bake
    // defaults them to borrowed tokens (table_border/hr/code_fence_banner → muted,
    // table_header → body) for byte-parity with #17's un-themed output.
    table_border: StyleToken,
    table_header: StyleToken,
    hr: StyleToken,
    code_fence_banner: StyleToken,
};

/// The neutral mechanism-level palettes. These are *derived at comptime* from
/// the `dark`/`light` preset specs in `theme/presets.zig` — the single source of
/// truth — so the slot colors live in exactly one place. They serve two roles:
///   1. the default `StyleMap` used by the export/PNG paths + tests,
///   2. the base palette that `resolve.bake` overlays sparse preset slots onto
///      (unset slots of dracula/ansi/etc. fall back to these).
pub const neutralDark: StyleMap = bakeSlots(presets.dark.slots);
pub const neutralLight: StyleMap = bakeSlots(presets.light.slots);

/// Overlay a sparse `SlotSpec` onto a concrete `StyleToken`.
fn applySlotToken(tok: *StyleToken, s: spec.SlotSpec) void {
    if (s.fg) |c| tok.fg = c;
    if (s.bg) |c| tok.bg = c;
    if (s.bold) |v| tok.bold = v;
    if (s.italic) |v| tok.italic = v;
    if (s.underline) |v| tok.underline = v;
    if (s.strike) |v| tok.strikethrough = v;
}

/// The single bake primitive: overlay a sparse `SlotMap` onto an existing
/// `StyleMap` base, then borrow structural defaults for any slot the overlay
/// left unset. Shared by the neutral-palette bake and `resolve.bake`, so the
/// overlay + borrow rules live in exactly one place.
pub fn overlaySlots(base: StyleMap, slots: spec.SlotMap) StyleMap {
    var p = base;
    inline for (@typeInfo(types.SpanStyle).@"enum".fields) |f| {
        const style = @field(types.SpanStyle, f.name);
        const slot = spec.Slot.fromSpanStyle(style);
        if (slots.get(slot)) |ss| applySlotToken(&@field(p, f.name), ss);
    }
    borrowStructuralDefaults(&p, slots);
    return p;
}

/// #17-parity: `list_item` and the four structural color slots borrow a sibling
/// token (list_item/table_header → body; table_border/hr/code_fence_banner →
/// muted) whenever `slots` leaves them unset, so the un-themed path stays
/// byte-identical while a preset may still set them explicitly.
fn borrowStructuralDefaults(p: *StyleMap, slots: spec.SlotMap) void {
    if (slots.get(.list_item) == null) p.list_item = p.body;
    if (slots.get(.table_border) == null) p.table_border = p.muted;
    if (slots.get(.table_header) == null) p.table_header = p.body;
    if (slots.get(.hr) == null) p.hr = p.muted;
    if (slots.get(.code_fence_banner) == null) p.code_fence_banner = p.muted;
}

/// Bake a default `SlotMap` into a concrete `StyleMap`, starting from an
/// all-terminal-default palette. The resolver (`resolve.zig`) is the single
/// bake authority for the themed pipeline (including the `classic` syntax
/// variant); this comptime arm only derives the two neutral base palettes.
fn bakeSlots(base_slots: spec.SlotMap) StyleMap {
    @setEvalBranchQuota(200000);
    var p: StyleMap = undefined;
    inline for (@typeInfo(StyleMap).@"struct".fields) |f| {
        @field(p, f.name) = StyleToken{ .fg = .default };
    }
    return overlaySlots(p, base_slots);
}

/// Maps a semantic SpanStyle to its concrete StyleToken in the given StyleMap.
/// Relies on the name-for-name SpanStyle↔StyleMap field mirror (the same
/// invariant `overlaySlots` uses), so it needs no per-slot maintenance.
pub fn token(style_map: StyleMap, style: render_model.SpanStyle) StyleToken {
    inline for (@typeInfo(render_model.SpanStyle).@"enum".fields) |f| {
        if (style == @field(render_model.SpanStyle, f.name)) return @field(style_map, f.name);
    }
    unreachable;
}

/// Styling for the copy-confirmation toast / metadata overlay: a soft panel
/// with a rounded border and readable text, derived from the resolved theme so
/// every preset gets matching overlay colors.
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
/// hue for `default` and `ansi16`. For `rgb` mercat — not the terminal — decides:
/// the pinned vaxis never downgrades, so we mirror ansi.writeColorSgr() and fall
/// back to the nearest xterm-256 index when `color.truecolorEnabled()` is false.
pub fn toVaxisColor(c: Color) vaxis.Color {
    return switch (c) {
        .default => .default,
        .index => |n| .{ .index = n },
        .ansi16 => |a| .{ .index = a.index() },
        .rgb => |v| if (color.truecolorEnabled())
            .{ .rgb = .{ v.r, v.g, v.b } }
        else
            .{ .index = color.to256(c).? },
    };
}

test "toVaxisColor downgrades rgb when truecolor is off" {
    const saved = color.truecolorEnabled();
    defer color.setTruecolor(saved);

    const c: Color = .{ .rgb = .{ .r = 0xd7, .g = 0x87, .b = 0x00 } };

    color.setTruecolor(true);
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xd7, 0x87, 0x00 } }, toVaxisColor(c));

    color.setTruecolor(false);
    try std.testing.expectEqual(vaxis.Color{ .index = color.to256(c).? }, toVaxisColor(c));
}

test "structural slots bake to their borrowed defaults (byte-parity)" {
    // The four re-added slots are unset in every preset, so they default to the
    // same tokens #17 stamped for them (table_border/hr/code_fence_banner →
    // muted, table_header → body). This is the byte-parity anchor for the
    // un-themed table/hr/fence rendering. (list_item is NOT one of these four —
    // dark/light presets explicitly color it, so it is asserted separately.)
    inline for (.{ neutralDark, neutralLight }) |pal| {
        try std.testing.expectEqual(token(pal, .muted), token(pal, .table_border));
        try std.testing.expectEqual(token(pal, .muted), token(pal, .hr));
        try std.testing.expectEqual(token(pal, .muted), token(pal, .code_fence_banner));
        try std.testing.expectEqual(token(pal, .body), token(pal, .table_header));
    }
}

test "list_item defaults to body only when a preset leaves it unset" {
    // The bake fallback stamps list_item = body, but a preset may override it.
    // markview leaves list_item unset → it must equal body; dark sets it to a
    // dimmer register (ix(250)) → it must differ from body.
    const markview = bakeSlots(presets.markview.slots);
    try std.testing.expectEqual(token(markview, .body), token(markview, .list_item));

    try std.testing.expect(!std.meta.eql(token(neutralDark, .body), token(neutralDark, .list_item)));
}

test "neutral palette anchors match the preset specs" {
    // Classic-variant anchors live in resolve_test.zig — the resolver is the
    // only path that bakes the `classic` delta.
    try std.testing.expectEqual(idx(254), neutralDark.body.fg);
    try std.testing.expectEqual(idx(141), neutralDark.code_block_keyword.fg);
    try std.testing.expectEqual(idx(234), neutralLight.body.fg);
    try std.testing.expectEqual(idx(92), neutralLight.code_block_keyword.fg);
}

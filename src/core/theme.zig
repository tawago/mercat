const std = @import("std");
const render_model = @import("markdown/render.zig");
const vaxis = @import("vaxis");
const presets = @import("theme/presets.zig");
const spec = @import("theme/spec.zig");
const types = @import("markdown/render/types.zig");

pub const color = @import("theme/color.zig");
pub const Color = color.Color;

pub const idx = color.idx;

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
    bullet: StyleToken,
    ordered: StyleToken,
    task_on: StyleToken,
    task_off: StyleToken,
    list_item: StyleToken,
    table_border: StyleToken,
    table_header: StyleToken,
    hr: StyleToken,
    code_fence_banner: StyleToken,
};

pub const neutralDark: StyleMap = bakeSlots(presets.dark.slots);
pub const neutralLight: StyleMap = bakeSlots(presets.light.slots);

fn applySlotToken(tok: *StyleToken, s: spec.SlotSpec) void {
    if (s.fg) |c| tok.fg = c;
    if (s.bg) |c| tok.bg = c;
    if (s.bold) |v| tok.bold = v;
    if (s.italic) |v| tok.italic = v;
    if (s.underline) |v| tok.underline = v;
    if (s.strike) |v| tok.strikethrough = v;
}

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

fn borrowStructuralDefaults(p: *StyleMap, slots: spec.SlotMap) void {
    if (slots.get(.list_item) == null) p.list_item = p.body;
    if (slots.get(.table_border) == null) p.table_border = p.muted;
    if (slots.get(.table_header) == null) p.table_header = p.body;
    if (slots.get(.hr) == null) p.hr = p.muted;
    if (slots.get(.code_fence_banner) == null) p.code_fence_banner = p.muted;
}

fn bakeSlots(base_slots: spec.SlotMap) StyleMap {
    @setEvalBranchQuota(200000);
    var p: StyleMap = undefined;
    inline for (@typeInfo(StyleMap).@"struct".fields) |f| {
        @field(p, f.name) = StyleToken{ .fg = .default };
    }
    return overlaySlots(p, base_slots);
}

pub fn token(style_map: StyleMap, style: render_model.SpanStyle) StyleToken {
    inline for (@typeInfo(render_model.SpanStyle).@"enum".fields) |f| {
        if (style == @field(render_model.SpanStyle, f.name)) return @field(style_map, f.name);
    }
    unreachable;
}

pub const ToastStyle = struct {
    fill: vaxis.Style,
    border: vaxis.Style,
    text: vaxis.Style,
};

pub fn panelStyle(accent: Color, base_bg: Color, bold: bool) ToastStyle {
    const bg = toVaxisColor(base_bg);
    return .{
        .fill = .{ .bg = bg },
        .border = .{ .fg = toVaxisColor(accent), .bg = bg },
        .text = .{ .fg = toVaxisColor(accent), .bg = bg, .bold = bold },
    };
}

pub fn toastStyle(accent: Color, base_bg: Color) ToastStyle {
    return panelStyle(accent, base_bg, true);
}

pub fn metadataPanelStyle(accent: Color, base_bg: Color) ToastStyle {
    return panelStyle(accent, base_bg, false);
}

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
    inline for (.{ neutralDark, neutralLight }) |pal| {
        try std.testing.expectEqual(token(pal, .muted), token(pal, .table_border));
        try std.testing.expectEqual(token(pal, .muted), token(pal, .hr));
        try std.testing.expectEqual(token(pal, .muted), token(pal, .code_fence_banner));
        try std.testing.expectEqual(token(pal, .body), token(pal, .table_header));
    }
}

test "list_item defaults to body only when a preset leaves it unset" {
    const markview = bakeSlots(presets.markview.slots);
    try std.testing.expectEqual(token(markview, .body), token(markview, .list_item));

    try std.testing.expect(!std.meta.eql(token(neutralDark, .body), token(neutralDark, .list_item)));
}

test "neutral palette anchors match the preset specs" {
    try std.testing.expectEqual(idx(254), neutralDark.body.fg);
    try std.testing.expectEqual(idx(141), neutralDark.code_block_keyword.fg);
    try std.testing.expectEqual(idx(234), neutralLight.body.fg);
    try std.testing.expectEqual(idx(92), neutralLight.code_block_keyword.fg);
}

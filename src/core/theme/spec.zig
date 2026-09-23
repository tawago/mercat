const std = @import("std");
const color = @import("color.zig");
const types = @import("../markdown/render/types.zig");

pub const Color = color.Color;

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

    pub fn fromSpanStyle(style: types.SpanStyle) Slot {
        return std.meta.stringToEnum(Slot, @tagName(style)).?;
    }
};

pub const slot_count = @typeInfo(Slot).@"enum".fields.len;

pub const SlotSpec = struct {
    fg: ?Color = null,
    bg: ?Color = null,
    full_line_bg: ?bool = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    strike: ?bool = null,
    prefix: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    shift: ?u8 = null,
    blank_wrap: ?bool = null,
    icon: ?[]const u8 = null,
    underline_row: ?bool = null,
    underline_glyph: ?[]const u8 = null,
};

pub const HrMode = enum { full, fixed };
pub const TableStyle = enum { grid, heavy, double, ascii, rounded };
pub const CodeFrameKind = enum { panel, rule, block, plain };

pub const CodeFrameDelta = struct {
    kind: ?CodeFrameKind = null,
    border_glyph: ?[]const u8 = null,
    border_cap: ?u16 = null,
    pad: ?u8 = null,
    language_label: ?bool = null,
};

pub const GlyphSet = struct {
    bullets: ?[]const []const u8 = null,
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

pub const TokenColors = struct {
    keyword: ?Color = null,
    string: ?Color = null,
    number: ?Color = null,
    comment: ?Color = null,
};

pub const PaletteMode = enum { truecolor_or_256, ansi16 };

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

pub const ThemeSpec = struct {
    name: []const u8,
    extends: ?[]const u8 = null,
    palette_mode: ?PaletteMode = null,
    slots: SlotMap = .{},
    slots_classic: SlotMap = .{},
    glyphs: GlyphSet = .{},
    tokens: TokenColors = .{},
    base_bg: ?Color = null,
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

const std = @import("std");
const spec = @import("../../theme/spec.zig");

pub const Slot = spec.Slot;
pub const slot_count = spec.slot_count;
pub const HrMode = spec.HrMode;
pub const TableStyle = spec.TableStyle;
pub const CodeFrameDelta = spec.CodeFrameDelta;

pub const SlotDecor = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    icon: []const u8 = "",
    shift: u8 = 0,
    blank_wrap: bool = false,
    full_line_bg: bool = false,
    underline_row: bool = false,
    underline_glyph: []const u8 = "─",
};

pub const ResolvedGlyphSet = struct {
    bullets: []const []const u8 = &default_bullets,
    ordered_prefix: []const u8 = "",
    task_ticked: []const u8 = "[x]",
    task_unticked: []const u8 = "[ ]",
    quote_bar: []const u8 = "",
    quote_indent: u8 = 0,
    hr_glyph: []const u8 = "─",
    hr_mode: HrMode = .full,
    hr_count: u16 = 0,
    hr_center: []const u8 = "",
    table_style: TableStyle = .grid,
    code_frame: CodeFrameDelta = .{},

    pub fn bulletAt(self: ResolvedGlyphSet, depth: usize) []const u8 {
        if (self.bullets.len == 0) return "•";
        const i = @min(depth, self.bullets.len - 1);
        return self.bullets[i];
    }
};

pub const default_bullets = [_][]const u8{ "•", "◦", "‣" };

pub const Decor = struct {
    slots: [slot_count]SlotDecor = [_]SlotDecor{.{}} ** slot_count,
    glyphs: ResolvedGlyphSet = .{},

    pub fn slot(self: *const Decor, s: Slot) SlotDecor {
        return self.slots[@intFromEnum(s)];
    }

    pub fn headingSlot(self: *const Decor, level: usize) SlotDecor {
        const s: Slot = switch (@min(@max(level, 1), 6)) {
            1 => .heading1,
            2 => .heading2,
            3 => .heading3,
            4 => .heading4,
            5 => .heading5,
            else => .heading6,
        };
        return self.slot(s);
    }
};

pub const legacy: Decor = blk: {
    var d = Decor{};
    d.slots[@intFromEnum(Slot.heading1)] = .{ .prefix = "# " };
    d.slots[@intFromEnum(Slot.heading2)] = .{ .prefix = "## " };
    d.slots[@intFromEnum(Slot.heading3)] = .{ .prefix = "### " };
    d.slots[@intFromEnum(Slot.heading4)] = .{ .prefix = "#### " };
    d.slots[@intFromEnum(Slot.heading5)] = .{ .prefix = "##### " };
    d.slots[@intFromEnum(Slot.heading6)] = .{ .prefix = "###### " };
    d.glyphs = .{ .quote_bar = "\u{258E}" };
    break :blk d;
};

const testing = std.testing;

test "Decor defaults are total (no null holes)" {
    const d = Decor{};
    try testing.expectEqualStrings("", d.slot(.heading1).prefix);
    try testing.expectEqualStrings("─", d.glyphs.hr_glyph);
    try testing.expectEqual(HrMode.full, d.glyphs.hr_mode);
}

test "bulletAt clamps to last entry" {
    const g = ResolvedGlyphSet{};
    try testing.expectEqualStrings("•", g.bulletAt(0));
    try testing.expectEqualStrings("‣", g.bulletAt(2));
    try testing.expectEqualStrings("‣", g.bulletAt(99));
}

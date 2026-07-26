//! Stage S3 (data) / S5 (consumption): the *resolved* structural-decor
//! vocabulary. Where `theme/spec.zig` is sparse and optional (a theme's
//! deltas), `Decor` is concrete and total — every slot has a definite
//! prefix/suffix/shift/icon and the glyph set is fully populated. `resolve.bake`
//! produces one of these; the block/inline/table renderers consume it in S5.

const std = @import("std");
const spec = @import("../../theme/spec.zig");

pub const Slot = spec.Slot;
pub const slot_count = spec.slot_count;
pub const HrMode = spec.HrMode;
pub const TableStyle = spec.TableStyle;
pub const CodeFrameDelta = spec.CodeFrameDelta;

/// Resolved per-slot structural decoration. All fields concrete: an empty
/// string means "no prefix/suffix/icon", never "inherit".
pub const SlotDecor = struct {
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    icon: []const u8 = "",
    shift: u8 = 0,
    blank_wrap: bool = false,
    full_line_bg: bool = false,
    /// Heading slots only: emit one extra row below the heading, filled with
    /// `underline_glyph`. Concrete (no null): `false` means no row.
    underline_row: bool = false,
    /// Concrete fill glyph for `underline_row` (default "─"; never empty).
    underline_glyph: []const u8 = "─",
};

/// Resolved, non-optional glyph vocabulary. Backed by string constants (from
/// presets or user files); the renderer never sees a `null` here — except the
/// `code_frame`, which stays sparse and whose `.panel`/`false` defaults land at
/// the render read sites (`kind orelse .panel`).
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

    /// Bullet glyph for a given (0-based) list depth, clamping to the last.
    pub fn bulletAt(self: ResolvedGlyphSet, depth: usize) []const u8 {
        if (self.bullets.len == 0) return "•";
        const i = @min(depth, self.bullets.len - 1);
        return self.bullets[i];
    }
};

pub const default_bullets = [_][]const u8{ "•", "◦", "‣" };

/// The concrete decor produced by baking a resolved theme.
pub const Decor = struct {
    slots: [slot_count]SlotDecor = [_]SlotDecor{.{}} ** slot_count,
    glyphs: ResolvedGlyphSet = .{},

    pub fn slot(self: *const Decor, s: Slot) SlotDecor {
        return self.slots[@intFromEnum(s)];
    }

    pub fn slotPtr(self: *Decor, s: Slot) *SlotDecor {
        return &self.slots[@intFromEnum(s)];
    }

    /// Decor for a heading of `level` (1..6), clamped to the 6 heading slots.
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

/// The default structural decor that reproduces mercat's historical hardcoded
/// literals byte-for-byte (`# ` heading prefixes, `• ◦ ‣` bullets, `[x]`/`[ ]`
/// tasks, `▎` quote bar, full-width `─` rules, grid tables, panel code frames).
/// `Options.decor` defaults to `&legacy`, so every un-themed render path — and
/// every existing golden — is unchanged. The `dark`/`light` presets bake to an
/// equal `Decor` (guarded by a resolve-side field-by-field test).
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

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "Decor defaults are total (no null holes)" {
    const d = Decor{};
    // Every slot has a concrete (empty) decor.
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

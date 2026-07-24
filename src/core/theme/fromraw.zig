//! Stage S3 (split from `resolve.zig` for the 1000-line cap): the single typed
//! `RawThemeTables → ThemeSpec` conversion path. This is the one place raw
//! string tables (inline `[theme.*]` config, user theme files, and `extends=`
//! targets) are interpreted into a typed sparse `ThemeSpec`.
//!
//! It parses everything `--dump-theme` can emit so a dumped preset round-trips
//! byte-for-byte:
//!   - top-level `extends` / `palette` / `name` / `canvas` / `base_bg` / `base_fg`
//!   - `[theme.<slot>]` color + attr + decor keys
//!   - `[theme.glyphs]` / `[theme.code_frame]` / `[theme.tokens]` sections
//!
//! (Custom `bullets` arrays are the one decor field not representable in the
//! flat key/value parser; the dumper omits them, so a preset using non-default
//! bullets would not round-trip that field. dark/light use the default bullets.)

const std = @import("std");
const spec = @import("spec.zig");
const color = @import("color.zig");
const loadfile = @import("loadfile.zig");
const resolve = @import("resolve.zig");

const Color = color.Color;
const ThemeSpec = spec.ThemeSpec;
const SlotSpec = spec.SlotSpec;
const Slot = spec.Slot;
const Collector = resolve.Collector;
const RawThemeTables = loadfile.RawThemeTables;

/// Convert raw string tables into a typed `ThemeSpec`. Unknown slot names and
/// keys are reported (`unknown_key`) and skipped; bad colors are reported
/// (`bad_color`) and dropped (inherit kept); user glyphs containing Nerd PUA
/// codepoints are substituted and reported (`glyph_fallback`).
///
/// String values are referenced (not duped) from `raw`; `raw` must outlive the
/// returned spec. `alloc` is used only for glyph-fallback substitution buffers.
pub fn specFromRaw(alloc: std.mem.Allocator, raw: RawThemeTables, diag: *Collector) ThemeSpec {
    var out = ThemeSpec{ .name = "" };

    // Top-level keys.
    for (raw.top) |kv| {
        if (std.mem.eql(u8, kv.key, "extends")) {
            out.extends = kv.value;
        } else if (std.mem.eql(u8, kv.key, "palette")) {
            out.palette_mode = if (std.mem.eql(u8, kv.value, "ansi16")) .ansi16 else .truecolor_or_256;
        } else if (std.mem.eql(u8, kv.key, "name")) {
            out.name = kv.value;
        } else if (std.mem.eql(u8, kv.key, "canvas")) {
            if (parseBool(kv.value)) |b| out.canvas = b else diag.warnFmt(.unknown_key, "invalid [theme] canvas value '{s}'", .{kv.value});
        } else if (std.mem.eql(u8, kv.key, "base_bg")) {
            out.base_bg = parseColorOrWarn(kv.value, "base_bg", diag) orelse out.base_bg;
        } else if (std.mem.eql(u8, kv.key, "base_fg")) {
            out.base_fg = parseColorOrWarn(kv.value, "base_fg", diag) orelse out.base_fg;
        } else {
            diag.warnFmt(.unknown_key, "unknown [theme] key '{s}'", .{kv.key});
        }
    }

    for (raw.slots) |raw_slot| {
        // Non-slot sub-tables: glyph vocabulary, code frame, syntax tokens.
        if (std.mem.eql(u8, raw_slot.name, "glyphs")) {
            for (raw_slot.kvs) |kv| applyGlyphKv(alloc, &out.glyphs, kv, diag);
            continue;
        }
        if (std.mem.eql(u8, raw_slot.name, "code_frame")) {
            var cf = out.glyphs.code_frame orelse spec.CodeFrameSpec{};
            for (raw_slot.kvs) |kv| applyCodeFrameKv(&cf, kv, diag);
            out.glyphs.code_frame = cf;
            continue;
        }
        if (std.mem.eql(u8, raw_slot.name, "tokens")) {
            for (raw_slot.kvs) |kv| applyTokenKv(&out.tokens, kv, diag);
            continue;
        }

        const slot = std.meta.stringToEnum(Slot, raw_slot.name) orelse {
            diag.warnFmt(.unknown_key, "unknown theme slot '{s}'", .{raw_slot.name});
            continue;
        };
        var ss = out.slots.get(slot) orelse SlotSpec{};
        for (raw_slot.kvs) |kv| applyRawKv(alloc, &ss, kv, raw_slot.name, diag);
        out.slots.set(slot, ss);
    }
    return out;
}

fn applyRawKv(
    alloc: std.mem.Allocator,
    ss: *SlotSpec,
    kv: loadfile.RawKV,
    slot_name: []const u8,
    diag: *Collector,
) void {
    const k = kv.key;
    const v = kv.value;
    if (std.mem.eql(u8, k, "fg")) {
        ss.fg = parseColorOrWarn(v, slot_name, diag) orelse ss.fg;
    } else if (std.mem.eql(u8, k, "bg")) {
        ss.bg = parseColorOrWarn(v, slot_name, diag) orelse ss.bg;
    } else if (std.mem.eql(u8, k, "bold")) {
        ss.bold = parseBool(v);
    } else if (std.mem.eql(u8, k, "italic")) {
        ss.italic = parseBool(v);
    } else if (std.mem.eql(u8, k, "underline")) {
        ss.underline = parseBool(v);
    } else if (std.mem.eql(u8, k, "strike") or std.mem.eql(u8, k, "strikethrough")) {
        ss.strike = parseBool(v);
    } else if (std.mem.eql(u8, k, "full_line_bg")) {
        ss.full_line_bg = parseBool(v);
    } else if (std.mem.eql(u8, k, "blank_wrap")) {
        ss.blank_wrap = parseBool(v);
    } else if (std.mem.eql(u8, k, "prefix")) {
        ss.prefix = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "suffix")) {
        ss.suffix = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "icon")) {
        ss.icon = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "shift")) {
        ss.shift = std.fmt.parseUnsigned(u8, v, 10) catch 0;
    } else if (std.mem.eql(u8, k, "underline_row")) {
        ss.underline_row = parseBool(v);
    } else if (std.mem.eql(u8, k, "underline_glyph")) {
        ss.underline_glyph = safeGlyph(alloc, v, diag);
    } else {
        diag.warnFmt(.unknown_key, "unknown key '{s}' in [theme.{s}]", .{ k, slot_name });
    }
}

fn applyGlyphKv(alloc: std.mem.Allocator, g: *spec.GlyphSet, kv: loadfile.RawKV, diag: *Collector) void {
    const k = kv.key;
    const v = kv.value;
    if (std.mem.eql(u8, k, "ordered_prefix")) {
        g.ordered_prefix = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "task_ticked")) {
        g.task_ticked = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "task_unticked")) {
        g.task_unticked = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "quote_bar")) {
        g.quote_bar = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "hr_glyph")) {
        g.hr_glyph = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "hr_center")) {
        g.hr_center = safeGlyph(alloc, v, diag);
    } else if (std.mem.eql(u8, k, "quote_indent")) {
        g.quote_indent = std.fmt.parseUnsigned(u8, v, 10) catch 0;
    } else if (std.mem.eql(u8, k, "hr_count")) {
        g.hr_count = std.fmt.parseUnsigned(u16, v, 10) catch 0;
    } else if (std.mem.eql(u8, k, "doc_margin")) {
        g.doc_margin = std.fmt.parseUnsigned(u8, v, 10) catch 0;
    } else if (std.mem.eql(u8, k, "hr_mode")) {
        if (std.mem.eql(u8, v, "full")) g.hr_mode = .full else if (std.mem.eql(u8, v, "fixed")) g.hr_mode = .fixed else diag.warnFmt(.unknown_key, "invalid hr_mode '{s}'", .{v});
    } else if (std.mem.eql(u8, k, "table_style")) {
        // Widened table_style vocabulary (restored #17 border weights): the
        // full enum is grid|heavy|double|ascii|rounded. Use stringToEnum so
        // any future variant is covered for free.
        if (std.meta.stringToEnum(spec.TableStyle, v)) |ts| g.table_style = ts else diag.warnFmt(.unknown_key, "invalid table_style '{s}'", .{v});
    } else {
        diag.warnFmt(.unknown_key, "unknown key '{s}' in [theme.glyphs]", .{k});
    }
}

fn applyCodeFrameKv(cf: *spec.CodeFrameSpec, kv: loadfile.RawKV, diag: *Collector) void {
    const k = kv.key;
    const v = kv.value;
    if (std.mem.eql(u8, k, "kind")) {
        if (std.meta.stringToEnum(spec.CodeFrameKind, v)) |kind| cf.kind = kind else diag.warnFmt(.unknown_key, "invalid code_frame kind '{s}'", .{v});
    } else if (std.mem.eql(u8, k, "border_glyph")) {
        cf.border_glyph = v;
    } else if (std.mem.eql(u8, k, "border_cap")) {
        cf.border_cap = std.fmt.parseUnsigned(u16, v, 10) catch null;
    } else if (std.mem.eql(u8, k, "pad")) {
        cf.pad = std.fmt.parseUnsigned(u8, v, 10) catch null;
    } else if (std.mem.eql(u8, k, "language_label")) {
        cf.language_label = parseBool(v) orelse false;
    } else if (std.mem.eql(u8, k, "rule_color")) {
        cf.rule_color = color.parseColor(v) catch null;
    } else {
        diag.warnFmt(.unknown_key, "unknown key '{s}' in [theme.code_frame]", .{k});
    }
}

fn applyTokenKv(t: *spec.TokenColors, kv: loadfile.RawKV, diag: *Collector) void {
    const k = kv.key;
    const c = parseColorOrWarn(kv.value, "tokens", diag);
    if (std.mem.eql(u8, k, "keyword")) {
        if (c) |v| t.keyword = v;
    } else if (std.mem.eql(u8, k, "string")) {
        if (c) |v| t.string = v;
    } else if (std.mem.eql(u8, k, "number")) {
        if (c) |v| t.number = v;
    } else if (std.mem.eql(u8, k, "comment")) {
        if (c) |v| t.comment = v;
    } else if (std.mem.eql(u8, k, "function")) {
        if (c) |v| t.function = v;
    } else {
        diag.warnFmt(.unknown_key, "unknown key '{s}' in [theme.tokens]", .{k});
    }
}

fn parseColorOrWarn(v: []const u8, slot_name: []const u8, diag: *Collector) ?Color {
    if (v.len == 0) return null; // "" clears; leave inherited (S3 minimal)
    return color.parseColor(v) catch {
        diag.warnFmt(.bad_color, "bad color '{s}' in [theme.{s}]", .{ v, slot_name });
        return null;
    };
}

fn parseBool(v: []const u8) ?bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return null;
}

/// If `s` contains a Nerd-font PUA codepoint, substitute a safe placeholder and
/// report `glyph_fallback`; otherwise return `s` unchanged. This fires only on
/// the user-file path (built-in presets are authored PUA-free).
fn safeGlyph(alloc: std.mem.Allocator, s: []const u8, diag: *Collector) []const u8 {
    if (!containsPua(s)) return s;
    diag.warnFmt(.glyph_fallback, "glyph '{s}' uses a private-use codepoint; substituting", .{s});
    // Replace each PUA codepoint with '?'; keep other bytes.
    var out = std.ArrayList(u8).empty;
    var view = std.unicode.Utf8View.init(s) catch return "?";
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (isPua(cp)) {
            out.append(alloc, '?') catch return "?";
        } else {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch continue;
            out.appendSlice(alloc, buf[0..n]) catch return "?";
        }
    }
    return out.toOwnedSlice(alloc) catch "?";
}

pub fn containsPua(s: []const u8) bool {
    var view = std.unicode.Utf8View.init(s) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| if (isPua(cp)) return true;
    return false;
}

fn isPua(cp: u21) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or (cp >= 0xF0000 and cp <= 0xFFFFD) or (cp >= 0x100000 and cp <= 0x10FFFD);
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "isPua/containsPua flag the three private-use ranges only" {
    // BMP PUA, and the two supplementary PUA planes.
    try testing.expect(isPua(0xE000));
    try testing.expect(isPua(0xF8FF));
    try testing.expect(isPua(0xF0000));
    try testing.expect(isPua(0x100000));
    // Ordinary glyphs (arrow, bullet, box-drawing) are not PUA.
    try testing.expect(!isPua('a'));
    try testing.expect(!isPua(0x2192)); // →
    try testing.expect(!isPua(0x2022)); // •
    try testing.expect(containsPua("x\u{F011}y"));
    try testing.expect(!containsPua("plain text →"));
}

test "specFromRaw parses the re-added structural slots (S2)" {
    const alloc = testing.allocator;
    var tables = try loadfile.parseThemeTables(alloc,
        "[theme.hr]\nfg = \"202\"\n" ++
        "[theme.table_border]\nfg = \"45\"\n" ++
        "[theme.table_header]\nfg = \"213\"\nbold = true\n" ++
        "[theme.code_fence_banner]\nfg = \"99\"\n");
    defer tables.deinit(alloc);
    var diag = resolve.Collector.init(alloc);
    defer diag.deinit();

    const s = specFromRaw(alloc, tables, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expect(std.meta.eql(s.slots.get(.hr).?.fg.?, Color{ .index = 202 }));
    try testing.expect(std.meta.eql(s.slots.get(.table_border).?.fg.?, Color{ .index = 45 }));
    try testing.expect(std.meta.eql(s.slots.get(.table_header).?.fg.?, Color{ .index = 213 }));
    try testing.expectEqual(true, s.slots.get(.table_header).?.bold.?);
    try testing.expect(std.meta.eql(s.slots.get(.code_fence_banner).?.fg.?, Color{ .index = 99 }));
}

test "specFromRaw parses the widened table_style weights and reports invalid ones" {
    const alloc = testing.allocator;
    // Every restored #17 weight parses via stringToEnum.
    inline for (.{
        .{ .name = "grid", .want = spec.TableStyle.grid },
        .{ .name = "heavy", .want = spec.TableStyle.heavy },
        .{ .name = "double", .want = spec.TableStyle.double },
        .{ .name = "ascii", .want = spec.TableStyle.ascii },
        .{ .name = "rounded", .want = spec.TableStyle.rounded },
    }) |c| {
        var tables = try loadfile.parseThemeTables(alloc, "[theme.glyphs]\ntable_style = \"" ++ c.name ++ "\"\n");
        defer tables.deinit(alloc);
        var diag = resolve.Collector.init(alloc);
        defer diag.deinit();
        const s = specFromRaw(alloc, tables, &diag);
        try testing.expectEqual(@as(usize, 0), diag.count());
        try testing.expectEqual(c.want, s.glyphs.table_style.?);
    }

    // An unknown weight is reported and leaves the field unset.
    var bad = try loadfile.parseThemeTables(alloc, "[theme.glyphs]\ntable_style = \"triple\"\n");
    defer bad.deinit(alloc);
    var diag = resolve.Collector.init(alloc);
    defer diag.deinit();
    const s = specFromRaw(alloc, bad, &diag);
    try testing.expect(diag.has(.unknown_key));
    try testing.expect(s.glyphs.table_style == null);
}

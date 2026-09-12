//! Stage S3 (split from `resolve.zig` for the 1000-line cap): the single typed
//! `RawThemeTables → ThemeSpec` conversion path. This is the one place raw
//! string tables (inline `[theme.*]` config, user theme files, and `extends=`
//! targets) are interpreted into a typed sparse `ThemeSpec`.
//!
//! It parses everything `--dump-theme` can emit so a dumped preset round-trips
//! byte-for-byte:
//!   - top-level `extends` / `palette` / `name` / `canvas` / `base_bg`
//!   - `[theme.<slot>]` color + attr + decor keys
//!   - `[theme.glyphs]` / `[theme.code_frame]` / `[theme.tokens]` sections
//!
//! `[theme.glyphs] bullets` is the one array-valued key; it is decoded with
//! `loadfile.parseInlineArray` and the dumper emits it, so custom bullet
//! vocabularies round-trip like everything else.

const std = @import("std");
const spec = @import("spec.zig");
const color = @import("color.zig");
const loadfile = @import("loadfile.zig");
const resolve = @import("resolve.zig");

const Color = color.Color;
const ThemeSpec = spec.ThemeSpec;
const SlotSpec = spec.SlotSpec;
const Slot = spec.Slot;
const Diagnostics = resolve.Diagnostics;
const RawThemeTables = loadfile.RawThemeTables;

/// Convert raw string tables into a typed `ThemeSpec`. Unknown slot names and
/// keys are reported (`unknown_key`) and skipped; bad colors are reported
/// (`bad_color`) and dropped (inherit kept); user glyphs containing Nerd PUA
/// codepoints are substituted and reported (`glyph_fallback`).
///
/// String values are referenced (not duped) from the builder behind `raw`,
/// which must outlive the returned spec (the view itself only has to survive
/// this call). `alloc` is used only for glyph-fallback substitution buffers.
pub fn specFromRaw(alloc: std.mem.Allocator, raw: RawThemeTables, diag: *Diagnostics) ThemeSpec {
    var out = ThemeSpec{ .name = "" };

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
        } else {
            diag.warnFmt(.unknown_key, "unknown [theme] key '{s}'", .{kv.key});
        }
    }

    for (raw.slots) |raw_slot| {
        if (std.mem.eql(u8, raw_slot.name, "glyphs")) {
            for (raw_slot.kvs.items) |kv| applyGlyphKv(alloc, &out.glyphs, kv, diag);
            continue;
        }
        if (std.mem.eql(u8, raw_slot.name, "code_frame")) {
            var cf = out.glyphs.code_frame orelse spec.CodeFrameDelta{};
            for (raw_slot.kvs.items) |kv| applyCodeFrameKv(&cf, kv, diag);
            out.glyphs.code_frame = cf;
            continue;
        }
        if (std.mem.eql(u8, raw_slot.name, "tokens")) {
            for (raw_slot.kvs.items) |kv| applyTokenKv(&out.tokens, kv, diag);
            continue;
        }

        const slot = std.meta.stringToEnum(Slot, raw_slot.name) orelse {
            diag.warnFmt(.unknown_key, "unknown theme slot '{s}'", .{raw_slot.name});
            continue;
        };
        var ss = out.slots.get(slot) orelse SlotSpec{};
        for (raw_slot.kvs.items) |kv| applyRawKv(alloc, &ss, kv, raw_slot.name, diag);
        out.slots.set(slot, ss);
    }
    return out;
}

fn applyRawKv(
    alloc: std.mem.Allocator,
    ss: *SlotSpec,
    kv: loadfile.RawKV,
    slot_name: []const u8,
    diag: *Diagnostics,
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

fn applyGlyphKv(alloc: std.mem.Allocator, g: *spec.GlyphSet, kv: loadfile.RawKV, diag: *Diagnostics) void {
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
    } else if (std.mem.eql(u8, k, "hr_mode")) {
        if (std.mem.eql(u8, v, "full")) g.hr_mode = .full else if (std.mem.eql(u8, v, "fixed")) g.hr_mode = .fixed else diag.warnFmt(.unknown_key, "invalid hr_mode '{s}'", .{v});
    } else if (std.mem.eql(u8, k, "bullets")) {
        const items = loadfile.parseInlineArray(alloc, v) catch null;
        if (items) |list| {
            if (list.len == 0) {
                diag.warnFmt(.unknown_key, "empty bullets array in [theme.glyphs]", .{});
            } else {
                for (list) |*b| b.* = safeGlyph(alloc, b.*, diag);
                g.bullets = list;
            }
        } else {
            diag.warnFmt(.unknown_key, "bullets must be an array of strings, got '{s}'", .{v});
        }
    } else if (std.mem.eql(u8, k, "table_style")) {
        if (std.meta.stringToEnum(spec.TableStyle, v)) |ts| g.table_style = ts else diag.warnFmt(.unknown_key, "invalid table_style '{s}'", .{v});
    } else {
        diag.warnFmt(.unknown_key, "unknown key '{s}' in [theme.glyphs]", .{k});
    }
}

fn applyCodeFrameKv(cf: *spec.CodeFrameDelta, kv: loadfile.RawKV, diag: *Diagnostics) void {
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
        cf.language_label = parseBool(v);
    } else {
        diag.warnFmt(.unknown_key, "unknown key '{s}' in [theme.code_frame]", .{k});
    }
}

fn applyTokenKv(t: *spec.TokenColors, kv: loadfile.RawKV, diag: *Diagnostics) void {
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
        if (c) |v| t.keyword = v;
    } else {
        diag.warnFmt(.unknown_key, "unknown key '{s}' in [theme.tokens]", .{k});
    }
}

fn parseColorOrWarn(v: []const u8, slot_name: []const u8, diag: *Diagnostics) ?Color {
    if (v.len == 0) return null;
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
fn safeGlyph(alloc: std.mem.Allocator, s: []const u8, diag: *Diagnostics) []const u8 {
    if (!containsPua(s)) return s;
    diag.warnFmt(.glyph_fallback, "glyph '{s}' uses a private-use codepoint; substituting", .{s});
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

const testing = std.testing;

test "isPua/containsPua flag the three private-use ranges only" {
    try testing.expect(isPua(0xE000));
    try testing.expect(isPua(0xF8FF));
    try testing.expect(isPua(0xF0000));
    try testing.expect(isPua(0x100000));
    try testing.expect(!isPua('a'));
    try testing.expect(!isPua(0x2192));
    try testing.expect(!isPua(0x2022));
    try testing.expect(containsPua("x\u{F011}y"));
    try testing.expect(!containsPua("plain text →"));
}

test "specFromRaw parses the re-added structural slots (S2)" {
    const alloc = testing.allocator;
    var tables = try loadfile.parseThemeTables(alloc, "[theme.hr]\nfg = \"202\"\n" ++
        "[theme.table_border]\nfg = \"45\"\n" ++
        "[theme.table_header]\nfg = \"213\"\nbold = true\n" ++
        "[theme.code_fence_banner]\nfg = \"99\"\n");
    defer tables.deinit(alloc);
    var diag = resolve.Diagnostics.init(alloc);
    defer diag.deinit();

    const s = specFromRaw(alloc, tables.view(), &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expect(std.meta.eql(s.slots.get(.hr).?.fg.?, Color{ .index = 202 }));
    try testing.expect(std.meta.eql(s.slots.get(.table_border).?.fg.?, Color{ .index = 45 }));
    try testing.expect(std.meta.eql(s.slots.get(.table_header).?.fg.?, Color{ .index = 213 }));
    try testing.expectEqual(true, s.slots.get(.table_header).?.bold.?);
    try testing.expect(std.meta.eql(s.slots.get(.code_fence_banner).?.fg.?, Color{ .index = 99 }));
}

test "specFromRaw parses a user bullets array (documented [theme.glyphs] key)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const tables = try loadfile.parseThemeTables(alloc,
        \\[theme.glyphs]
        \\bullets = ["#", "◦", "‣"] # a quoted hash stays a glyph
    );
    var diag = resolve.Diagnostics.init(alloc);
    const s = specFromRaw(alloc, tables.view(), &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    const bs = s.glyphs.bullets.?;
    try testing.expectEqual(@as(usize, 3), bs.len);
    try testing.expectEqualStrings("#", bs[0]);
    try testing.expectEqualStrings("\u{25E6}", bs[1]);
    try testing.expectEqualStrings("\u{2023}", bs[2]);
}

test "a scalar or empty bullets value is reported, not silently accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    inline for (.{ "bullets = \"*\"", "bullets = []" }) |line| {
        const tables = try loadfile.parseThemeTables(alloc, "[theme.glyphs]\n" ++ line ++ "\n");
        var diag = resolve.Diagnostics.init(alloc);
        const s = specFromRaw(alloc, tables.view(), &diag);
        try testing.expect(diag.has(.unknown_key));
        try testing.expect(s.glyphs.bullets == null);
    }
}

test "specFromRaw parses the widened table_style weights and reports invalid ones" {
    const alloc = testing.allocator;
    inline for (.{
        .{ .name = "grid", .want = spec.TableStyle.grid },
        .{ .name = "heavy", .want = spec.TableStyle.heavy },
        .{ .name = "double", .want = spec.TableStyle.double },
        .{ .name = "ascii", .want = spec.TableStyle.ascii },
        .{ .name = "rounded", .want = spec.TableStyle.rounded },
    }) |c| {
        var tables = try loadfile.parseThemeTables(alloc, "[theme.glyphs]\ntable_style = \"" ++ c.name ++ "\"\n");
        defer tables.deinit(alloc);
        var diag = resolve.Diagnostics.init(alloc);
        defer diag.deinit();
        const s = specFromRaw(alloc, tables.view(), &diag);
        try testing.expectEqual(@as(usize, 0), diag.count());
        try testing.expectEqual(c.want, s.glyphs.table_style.?);
    }

    var bad = try loadfile.parseThemeTables(alloc, "[theme.glyphs]\ntable_style = \"triple\"\n");
    defer bad.deinit(alloc);
    var diag = resolve.Diagnostics.init(alloc);
    defer diag.deinit();
    const s = specFromRaw(alloc, bad.view(), &diag);
    try testing.expect(diag.has(.unknown_key));
    try testing.expect(s.glyphs.table_style == null);
}

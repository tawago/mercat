const std = @import("std");
const spec = @import("spec.zig");
const color = @import("color.zig");
const loadfile = @import("loadfile.zig");
const presets = @import("presets.zig");
const decor_mod = @import("../markdown/render/decor.zig");
const theme = @import("../theme.zig");
const config = @import("../config.zig");
const resolve = @import("resolve.zig");

const Registry = resolve.Registry;
const ResolvedTheme = resolve.ResolvedTheme;
const Diagnostics = resolve.Diagnostics;
const DiagKind = resolve.DiagKind;
const ThemeSpec = resolve.ThemeSpec;
const SlotSpec = resolve.SlotSpec;
const Slot = resolve.Slot;
const Color = resolve.Color;
const StyleMap = resolve.StyleMap;
const Decor = resolve.Decor;
const specFromRaw = resolve.specFromRaw;
const mergeChain = resolve.mergeChain;
const bake = resolve.bake;
const bakeDecor = resolve.bakeDecor;
const builtinResolved = resolve.builtinResolved;
const buildChain = resolve.buildChain;
const containsPua = @import("fromraw.zig").containsPua;

const testing = std.testing;

fn rawFrom(alloc: std.mem.Allocator, text: []const u8) !loadfile.RawThemeBuilder {
    return loadfile.parseThemeTables(alloc, text);
}

test "resolve(dark/light) == the neutral base palettes across all slots" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const cases = [_]struct { name: []const u8, want: StyleMap }{
        .{ .name = "dark", .want = theme.neutralDark },
        .{ .name = "light", .want = theme.neutralLight },
    };
    for (cases) |c| {
        const r = try reg.resolve(c.name, .default, null, &diag);
        try testing.expectEqual(@as(usize, 0), diag.count());
        inline for (@typeInfo(StyleMap).@"struct".fields) |f| {
            try testing.expect(std.meta.eql(@field(c.want, f.name), @field(r.styles, f.name)));
        }
    }
}

test "resolve(dark/light, .classic) recolors code tokens; default is unchanged" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    for ([_][]const u8{ "dark", "light" }) |name| {
        const classic = try reg.resolve(name, .classic, null, &diag);
        const default = try reg.resolve(name, .default, null, &diag);
        try testing.expectEqual(@as(usize, 0), diag.count());
        try testing.expect(!std.meta.eql(classic.styles.code_block_keyword, default.styles.code_block_keyword));
    }

    const drac_def = try reg.resolve("dracula", .default, null, &diag);
    const drac_cls = try reg.resolve("dracula", .classic, null, &diag);
    try testing.expectEqual(drac_def.styles.code_block_keyword.fg, drac_cls.styles.code_block_keyword.fg);

    var raw = try rawFrom(testing.allocator, "[theme.code_block_keyword]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);
    const overridden = try reg.resolve("dark", .classic, raw.view(), &diag);
    try testing.expectEqual(color.rgb(0xff, 0, 0), overridden.styles.code_block_keyword.fg);
}

test "dark/light bake to the render/decor legacy Decor (goldens safety net)" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    for ([_][]const u8{ "dark", "light" }) |name| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const r = try reg.resolve(name, .default, null, &diag);
        const legacy = decor_mod.legacy;
        try testing.expectEqualStrings(legacy.slot(.heading1).prefix, r.decor.slot(.heading1).prefix);
        try testing.expectEqualStrings(legacy.slot(.heading6).prefix, r.decor.slot(.heading6).prefix);
        try testing.expectEqualStrings(legacy.glyphs.quote_bar, r.decor.glyphs.quote_bar);
        try testing.expectEqualStrings(legacy.glyphs.task_ticked, r.decor.glyphs.task_ticked);
        try testing.expectEqualStrings(legacy.glyphs.bulletAt(0), r.decor.glyphs.bulletAt(0));
        try testing.expectEqual(legacy.glyphs.hr_mode, r.decor.glyphs.hr_mode);
        try testing.expectEqualStrings(legacy.glyphs.hr_glyph, r.decor.glyphs.hr_glyph);
        try testing.expectEqual(legacy.glyphs.table_style, r.decor.glyphs.table_style);
        try testing.expectEqual(legacy.glyphs.code_frame.kind, r.decor.glyphs.code_frame.kind);
    }
}

test "every built-in preset resolves with zero diagnostics" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    for (presets.ALL) |p| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const r = try reg.resolve(p.name, .default, null, &diag);
        try testing.expectEqual(@as(usize, 0), diag.count());
        try testing.expect(r.decor.glyphs.hr_glyph.len > 0);
    }
}

test "unknown theme name falls back to dark with a diagnostic" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("nope", .default, null, &diag);
    try testing.expect(diag.has(.unknown_theme));
    const expected = theme.neutralDark;
    try testing.expectEqual(expected.body.fg, r.styles.body.fg);
}

test "inline override changes a slot color" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var raw = try rawFrom(testing.allocator, "[theme.heading1]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);

    const r = try reg.resolve("dark", .default, raw.view(), &diag);
    try testing.expectEqual(color.rgb(0xff, 0, 0), r.styles.heading1.fg);
}

test "sparse merge: child sets fg only, inherits prefix from base" {
    const base = ThemeSpec{ .name = "base", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .prefix = ">> ", .fg = color.idx(10) });
        break :blk m;
    } };
    const leaf = ThemeSpec{ .name = "leaf", .extends = "base", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .fg = color.idx(20) });
        break :blk m;
    } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const chain = [_]*const ThemeSpec{ &base, &leaf };
    var merged = mergeChain(testing.allocator, &chain, null, null, &diag);
    const h1 = merged.slots.get(.heading1).?;
    try testing.expectEqual(color.idx(20), h1.fg.?);
    try testing.expectEqualStrings(">> ", h1.prefix.?);
}

test "canvas merges through the extends chain (absent inherits, present wins)" {
    const base = ThemeSpec{ .name = "cbase", .canvas = true };
    const mid = ThemeSpec{ .name = "cmid", .extends = "cbase" };
    const leaf = ThemeSpec{ .name = "cleaf", .extends = "cmid", .canvas = false };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const chain_inherit = [_]*const ThemeSpec{ &base, &mid };
    const folded_inherit = mergeChain(testing.allocator, &chain_inherit, null, null, &diag);
    try testing.expectEqual(@as(?bool, true), folded_inherit.canvas);

    const chain_override = [_]*const ThemeSpec{ &base, &mid, &leaf };
    const folded_override = mergeChain(testing.allocator, &chain_override, null, null, &diag);
    try testing.expectEqual(@as(?bool, false), folded_override.canvas);
}

test "canvas preset defaults + canvasBg gating" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const dracula = try reg.resolve("dracula", .default, null, &diag);
    try testing.expect(dracula.canvas and dracula.canvasBg() != null);
    const dark = try reg.resolve("dark", .default, null, &diag);
    try testing.expect(!dark.canvas and dark.canvasBg() == null);
    const ansi = try reg.resolve("ansi", .default, null, &diag);
    try testing.expect(!ansi.canvas and ansi.canvasBg() == null);
}

test "inline [theme] canvas = true overrides a preset default" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var raw = try rawFrom(testing.allocator, "canvas = true\n");
    defer raw.deinit(testing.allocator);
    const r = try reg.resolve("dark", .default, raw.view(), &diag);
    try testing.expect(r.canvas and r.canvasBg() != null);
}

test "an empty string clears an inherited string field" {
    const rows = [_]struct { base: SlotSpec, leaf: SlotSpec, field: enum { prefix, underline_glyph }, want: []const u8 }{
        .{ .base = .{ .prefix = "# " }, .leaf = .{ .prefix = "" }, .field = .prefix, .want = "" },
        // An empty underline_glyph bakes back to the default rule glyph.
        .{ .base = .{ .underline_row = true, .underline_glyph = "\u{2550}" }, .leaf = .{ .underline_glyph = "" }, .field = .underline_glyph, .want = "\u{2500}" },
    };
    for (rows) |row| {
        var base = ThemeSpec{ .name = "base" };
        base.slots.set(.heading1, row.base);
        var leaf = ThemeSpec{ .name = "leaf", .extends = "base" };
        leaf.slots.set(.heading1, row.leaf);
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const chain = [_]*const ThemeSpec{ &base, &leaf };
        var merged = mergeChain(testing.allocator, &chain, null, null, &diag);
        const sd = bakeDecor(&merged).slot(.heading1);
        try testing.expectEqualStrings(row.want, switch (row.field) {
            .prefix => sd.prefix,
            .underline_glyph => sd.underline_glyph,
        });
    }
}

test "underline_row inherits through extends; glyph bakes concretely" {
    const base = ThemeSpec{ .name = "ubase", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .underline_row = true, .underline_glyph = "\u{2550}" });
        break :blk m;
    } };
    const leaf = ThemeSpec{ .name = "uleaf", .extends = "ubase", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .fg = color.idx(5) });
        break :blk m;
    } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const chain = [_]*const ThemeSpec{ &base, &leaf };
    var merged = mergeChain(testing.allocator, &chain, null, null, &diag);
    const d = bakeDecor(&merged);
    try testing.expect(d.slot(.heading1).underline_row);
    try testing.expectEqualStrings("\u{2550}", d.slot(.heading1).underline_glyph);
}

test "a missing or cyclic extends reports and falls back to dark" {
    const orphan = ThemeSpec{ .name = "orphan", .extends = "ghost" };
    const a = ThemeSpec{ .name = "acyc", .extends = "bcyc" };
    const b = ThemeSpec{ .name = "bcyc", .extends = "acyc" };
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&orphan);
    try reg.insertUserSpec(&a);
    try reg.insertUserSpec(&b);

    var missing = Diagnostics.init(testing.allocator);
    defer missing.deinit();
    const r = try reg.resolve("orphan", .default, null, &missing);
    try testing.expect(missing.has(.missing_extends));
    try testing.expect(std.meta.eql(theme.neutralDark.body, r.styles.body));

    var cyclic = Diagnostics.init(testing.allocator);
    defer cyclic.deinit();
    _ = try reg.resolve("acyc", .default, null, &cyclic);
    try testing.expect(cyclic.has(.cyclic_extends));
}

test "specFromRaw reports bad color and unknown key, keeps good ones" {
    var raw = try rawFrom(testing.allocator, "[theme.heading1]\nfg = \"notacolor\"\nbold = true\nbogus = \"x\"\n" ++
        "[theme.not_a_slot]\nfg = \"#fff\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const s = specFromRaw(testing.allocator, raw.view(), &diag);
    try testing.expect(diag.has(.bad_color));
    var unknown_slot = false;
    for (diag.list.items) |d| {
        if (std.mem.indexOf(u8, d.detail, "unknown theme slot 'not_a_slot'") != null) unknown_slot = true;
    }
    try testing.expect(unknown_slot);
    try testing.expect(diag.has(.unknown_key));
    const h1 = s.slots.get(.heading1).?;
    try testing.expect(h1.fg == null);
    try testing.expectEqual(@as(?bool, true), h1.bold);
}

test "extends chain through a second user file (leaf → user base → built-in)" {
    var base_raw = try rawFrom(testing.allocator, "extends = \"dracula\"\n[theme.link]\nfg = \"#010203\"\n");
    defer base_raw.deinit(testing.allocator);
    var leaf_raw = try rawFrom(testing.allocator, "extends = \"userbase\"\n[theme.heading1]\nfg = \"#040506\"\n");
    defer leaf_raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var base = specFromRaw(testing.allocator, base_raw.view(), &diag);
    base.name = "userbase";
    var leaf = specFromRaw(testing.allocator, leaf_raw.view(), &diag);
    leaf.name = "userleaf";

    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&base);
    try reg.insertUserSpec(&leaf);

    const r = try reg.resolve("userleaf", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expectEqual(color.rgb(0x04, 0x05, 0x06), r.styles.heading1.fg);
    try testing.expectEqual(color.rgb(0x01, 0x02, 0x03), r.styles.link.fg);
    const drac = try reg.resolve("dracula", .default, null, &diag);
    try testing.expectEqual(drac.styles.body.fg, r.styles.body.fg);
    try testing.expect(!std.meta.eql(theme.neutralDark.body.fg, r.styles.body.fg));
}

test "inline [theme] extends re-roots the chain" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var raw = try rawFrom(testing.allocator, "extends = \"dracula\"\n[theme.heading1]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);
    const r = try reg.resolve("dark", .default, raw.view(), &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());

    const drac = try reg.resolve("dracula", .default, null, &diag);
    try testing.expect(std.meta.eql(drac.styles.body, r.styles.body));
    try testing.expect(std.meta.eql(drac.styles.code_block, r.styles.code_block));
    try testing.expectEqual(color.rgb(0xff, 0, 0), r.styles.heading1.fg);

    var bad = try rawFrom(testing.allocator, "extends = \"ghost\"\n");
    defer bad.deinit(testing.allocator);
    const fb = try reg.resolve("dracula", .default, bad.view(), &diag);
    try testing.expect(diag.has(.missing_extends));
    const dark = try reg.resolve("dark", .default, null, &diag);
    try testing.expect(std.meta.eql(dark.styles.body, fb.styles.body));
}

test "code_frame folds per field: a pad-only child keeps kind/language_label" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var raw = try rawFrom(testing.allocator, "extends = \"markview\"\n[theme.code_frame]\npad = 4\n");
    defer raw.deinit(testing.allocator);
    var child = specFromRaw(testing.allocator, raw.view(), &diag);
    child.name = "padded";
    try reg.insertUserSpec(&child);

    const r = try reg.resolve("padded", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expectEqual(spec.CodeFrameKind.block, r.decor.glyphs.code_frame.kind);
    try testing.expectEqual(true, r.decor.glyphs.code_frame.language_label);
    try testing.expectEqual(@as(?u8, 4), r.decor.glyphs.code_frame.pad);

    const bare = try reg.resolve("dark", .default, null, &diag);
    try testing.expectEqual(@as(?spec.CodeFrameKind, null), bare.decor.glyphs.code_frame.kind);
    try testing.expectEqual(@as(?bool, null), bare.decor.glyphs.code_frame.language_label);
}

test "tokens.function is an alias that overrides an inherited keyword" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var raw = try rawFrom(testing.allocator, "extends = \"dracula\"\n[theme.tokens]\nfunction = \"#00ff00\"\n");
    defer raw.deinit(testing.allocator);
    var child = specFromRaw(testing.allocator, raw.view(), &diag);
    child.name = "fnalias";
    try reg.insertUserSpec(&child);
    try testing.expectEqual(color.rgb(0, 0xff, 0), child.tokens.keyword.?);

    const r = try reg.resolve("fnalias", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expectEqual(color.rgb(0, 0xff, 0), r.styles.code_keyword.fg);
    try testing.expectEqual(color.rgb(0, 0xff, 0), r.styles.code_block_keyword.fg);
}

test "inline PUA glyph substitution is registry-arena owned (no leak)" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var raw = try rawFrom(testing.allocator, "[theme.heading1]\nprefix = \"\u{f011} \"\n");
    defer raw.deinit(testing.allocator);
    const r = try reg.resolve("dark", .default, raw.view(), &diag);
    try testing.expect(diag.has(.glyph_fallback));
    try testing.expect(!containsPua(r.decor.slot(.heading1).prefix));
}

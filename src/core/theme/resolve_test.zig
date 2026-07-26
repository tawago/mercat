//! Tests for resolve.zig (split out to keep the module under the line-count
//! limit). Exercises the Registry/resolve pipeline and the merge/bake helpers.
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
const PaletteMode = resolve.PaletteMode;
const containsPua = @import("fromraw.zig").containsPua;

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn rawFrom(alloc: std.mem.Allocator, text: []const u8) !loadfile.RawThemeBuilder {
    return loadfile.parseThemeTables(alloc, text);
}

// Byte-identity guard for the dark/light data-spec migration: resolving the
// un-themed presets must reproduce the neutral base palettes across EVERY
// slot (dark/light carry no delta over their own base, so any difference
// means the bake drifted), plus numeric anchors pinning the historical
// literals themselves.
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
    // Independent numeric anchors (default variant) so the historical values
    // are pinned even if the derived paths were to drift together. The classic
    // anchors live in the adjacent syntax-variant test.
    try testing.expectEqual(color.idx(254), theme.neutralDark.body.fg);
    try testing.expectEqual(color.idx(141), theme.neutralDark.code_block_keyword.fg);
    try testing.expectEqual(color.idx(250), theme.neutralDark.code_block.fg);
    try testing.expectEqual(color.idx(234), theme.neutralLight.body.fg);
    try testing.expectEqual(color.idx(92), theme.neutralLight.code_block_keyword.fg);
}

// Classic syntax variant threaded end-to-end through the resolver (S5): the
// `dark`/`light` bases carry a `slots_classic` delta that recolors code tokens.
test "resolve(dark/light, .classic) recolors code tokens; default is unchanged" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const dark_c = try reg.resolve("dark", .classic, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expectEqual(color.idx(81), dark_c.styles.code_block_keyword.fg);
    try testing.expectEqual(color.idx(114), dark_c.styles.code_block.fg);

    const dark_d = try reg.resolve("dark", .default, null, &diag);
    try testing.expectEqual(color.idx(141), dark_d.styles.code_block_keyword.fg);

    const light_c = try reg.resolve("light", .classic, null, &diag);
    try testing.expectEqual(color.idx(25), light_c.styles.code_block_keyword.fg);

    // Non-dark/light preset ignores the variant (no delta): dracula unchanged.
    const drac_def = try reg.resolve("dracula", .default, null, &diag);
    const drac_cls = try reg.resolve("dracula", .classic, null, &diag);
    try testing.expectEqual(drac_def.styles.code_block_keyword.fg, drac_cls.styles.code_block_keyword.fg);

    // Inline overrides still win over the classic delta.
    var raw = try rawFrom(testing.allocator, "[theme.code_block_keyword]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);
    const overridden = try reg.resolve("dark", .classic, raw.view(), &diag);
    try testing.expectEqual(color.rgb(0xff, 0, 0), overridden.styles.code_block_keyword.fg);
}

// The four structural color slots re-added in S2 bake to their #17 borrowed
// tokens (muted / body) for every un-themed built-in, so the default path is
// byte-identical.
test "re-added structural slots default to muted/body" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const r = try reg.resolve("dark", .default, null, &diag);
    try testing.expect(std.meta.eql(r.styles.table_border, r.styles.muted));
    try testing.expect(std.meta.eql(r.styles.hr, r.styles.muted));
    try testing.expect(std.meta.eql(r.styles.code_fence_banner, r.styles.muted));
    try testing.expect(std.meta.eql(r.styles.table_header, r.styles.body));
}

test "resolve dark yields a full palette + total decor" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("dark", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    // dark bakes to the neutral dark base exactly.
    const expected = theme.neutralDark;
    try testing.expectEqual(expected.heading1.fg, r.styles.heading1.fg);
    try testing.expectEqual(expected.body.fg, r.styles.body.fg);
    // Default decor is total.
    try testing.expectEqualStrings("─", r.decor.glyphs.hr_glyph);
}

test "dark/light bake to the render/decor legacy Decor (goldens safety net)" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    for ([_][]const u8{ "dark", "light" }) |name| {
        var diag = Diagnostics.init(testing.allocator);
        defer diag.deinit();
        const r = try reg.resolve(name, .default, null, &diag);
        const legacy = decor_mod.legacy;
        // Heading prefixes match the historical `#`.. markers.
        try testing.expectEqualStrings(legacy.slot(.heading1).prefix, r.decor.slot(.heading1).prefix);
        try testing.expectEqualStrings(legacy.slot(.heading6).prefix, r.decor.slot(.heading6).prefix);
        // Glyph vocabulary matches (bullets, tasks, quote bar, hr, table, frame).
        try testing.expectEqualStrings(legacy.glyphs.quote_bar, r.decor.glyphs.quote_bar);
        try testing.expectEqualStrings(legacy.glyphs.task_ticked, r.decor.glyphs.task_ticked);
        try testing.expectEqualStrings(legacy.glyphs.bulletAt(0), r.decor.glyphs.bulletAt(0));
        try testing.expectEqual(legacy.glyphs.hr_mode, r.decor.glyphs.hr_mode);
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
        // Bake is total: hr glyph is always populated.
        try testing.expect(r.decor.glyphs.hr_glyph.len > 0);
    }
}

test "ansi preset bakes ansi16-typed slot colors" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const r = try reg.resolve("ansi", .default, null, &diag);
    try testing.expectEqual(Color{ .ansi16 = .bright_blue }, r.styles.heading1.fg);
}

test "light preset bakes to the light base palette" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const r = try reg.resolve("light", .default, null, &diag);
    const expected = theme.neutralLight;
    try testing.expectEqual(expected.body.fg, r.styles.body.fg);
    try testing.expectEqual(expected.heading1.fg, r.styles.heading1.fg);
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
    // Base spec with a prefix; leaf overrides only fg. Fold keeps the prefix.
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
    // Base turns canvas on; a middle spec leaves it absent (inherits true); the
    // leaf turns it off. Fold must end at the leaf's explicit false.
    const base = ThemeSpec{ .name = "cbase", .canvas = true };
    const mid = ThemeSpec{ .name = "cmid", .extends = "cbase" }; // canvas absent
    const leaf = ThemeSpec{ .name = "cleaf", .extends = "cmid", .canvas = false };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    // Inherit-through-absent: base(true) → mid(absent) folds to true.
    const chain_inherit = [_]*const ThemeSpec{ &base, &mid };
    const folded_inherit = mergeChain(testing.allocator, &chain_inherit, null, null, &diag);
    try testing.expectEqual(@as(?bool, true), folded_inherit.canvas);

    // Explicit override: leaf(false) wins over inherited true.
    const chain_override = [_]*const ThemeSpec{ &base, &mid, &leaf };
    const folded_override = mergeChain(testing.allocator, &chain_override, null, null, &diag);
    try testing.expectEqual(@as(?bool, false), folded_override.canvas);
}

test "canvas preset defaults + canvasBg gating" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    // dracula: canvas on, concrete base_bg → canvasBg non-null.
    const dracula = try reg.resolve("dracula", .default, null, &diag);
    try testing.expect(dracula.canvas and dracula.canvasBg() != null);
    // dark: canvas off → canvasBg null even though base_bg is concrete.
    const dark = try reg.resolve("dark", .default, null, &diag);
    try testing.expect(!dark.canvas and dark.canvasBg() == null);
    // ansi: canvas off and base_bg .default → canvasBg null.
    const ansi = try reg.resolve("ansi", .default, null, &diag);
    try testing.expect(!ansi.canvas and ansi.canvasBg() == null);
}

test "inline [theme] canvas = true overrides a preset default" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    // dark is canvas=false by default; the inline override flips it on.
    var raw = try rawFrom(testing.allocator, "canvas = true\n");
    defer raw.deinit(testing.allocator);
    const r = try reg.resolve("dark", .default, raw.view(), &diag);
    try testing.expect(r.canvas and r.canvasBg() != null);
}

test "empty-string prefix clears inherited prefix" {
    const base = ThemeSpec{ .name = "base", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .prefix = "# " });
        break :blk m;
    } };
    const leaf = ThemeSpec{ .name = "leaf", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .prefix = "" });
        break :blk m;
    } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const chain = [_]*const ThemeSpec{ &base, &leaf };
    var merged = mergeChain(testing.allocator, &chain, null, null, &diag);
    const d = bakeDecor(&merged);
    try testing.expectEqualStrings("", d.slot(.heading1).prefix);
}

test "underline_row inherits through extends; glyph bakes concretely" {
    // Base enables the row with "═"; leaf inherits the flag and keeps the glyph.
    const base = ThemeSpec{ .name = "ubase", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .underline_row = true, .underline_glyph = "\u{2550}" });
        break :blk m;
    } };
    const leaf = ThemeSpec{ .name = "uleaf", .extends = "ubase", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .fg = color.idx(5) }); // unrelated override
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

test "underline_glyph empty string clears an inherited glyph back to the default" {
    const base = ThemeSpec{ .name = "gbase", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .underline_row = true, .underline_glyph = "\u{2550}" });
        break :blk m;
    } };
    const leaf = ThemeSpec{ .name = "gleaf", .extends = "gbase", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.heading1, .{ .underline_glyph = "" }); // clear → default "─"
        break :blk m;
    } };
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const chain = [_]*const ThemeSpec{ &base, &leaf };
    var merged = mergeChain(testing.allocator, &chain, null, null, &diag);
    const d = bakeDecor(&merged);
    try testing.expect(d.slot(.heading1).underline_row);
    try testing.expectEqualStrings("\u{2500}", d.slot(.heading1).underline_glyph);
}

test "buildChain detects a cycle and still resolves" {
    // A→B→A. Register user specs forming a cycle.
    const a = ThemeSpec{ .name = "acyc", .extends = "bcyc" };
    const b = ThemeSpec{ .name = "bcyc", .extends = "acyc" };
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&a);
    try reg.insertUserSpec(&b);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("acyc", .default, null, &diag);
    try testing.expect(diag.has(.cyclic_extends));
    _ = r; // still usable
}

test "missing extends target reports and falls back to dark" {
    const a = ThemeSpec{ .name = "orphan", .extends = "ghost" };
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&a);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("orphan", .default, null, &diag);
    try testing.expect(diag.has(.missing_extends));
    // Base is dark.
    const expected = theme.neutralDark;
    try testing.expectEqual(expected.body.fg, r.styles.body.fg);
}

test "extends chain depth >= 2 folds correctly" {
    const grand = ThemeSpec{ .name = "grand", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.body, .{ .fg = color.idx(1) });
        break :blk m;
    } };
    const parent = ThemeSpec{ .name = "parent", .extends = "grand", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.strong, .{ .fg = color.idx(2) });
        break :blk m;
    } };
    const child = ThemeSpec{ .name = "child", .extends = "parent", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.link, .{ .fg = color.idx(3) });
        break :blk m;
    } };
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&grand);
    try reg.insertUserSpec(&parent);
    try reg.insertUserSpec(&child);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("child", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expectEqual(color.idx(1), r.styles.body.fg);
    try testing.expectEqual(color.idx(2), r.styles.strong.fg);
    try testing.expectEqual(color.idx(3), r.styles.link.fg);
}

test "specFromRaw reports bad color and unknown key, keeps good ones" {
    var raw = try rawFrom(testing.allocator,
        "[theme.heading1]\nfg = \"notacolor\"\nbold = true\nbogus = \"x\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const s = specFromRaw(testing.allocator, raw.view(), &diag);
    try testing.expect(diag.has(.bad_color));
    try testing.expect(diag.has(.unknown_key));
    const h1 = s.slots.get(.heading1).?;
    try testing.expect(h1.fg == null); // bad color dropped
    try testing.expectEqual(@as(?bool, true), h1.bold);
}

test "specFromRaw reports unknown slot name" {
    var raw = try rawFrom(testing.allocator, "[theme.not_a_slot]\nfg = \"#fff\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    _ = specFromRaw(testing.allocator, raw.view(), &diag);
    try testing.expect(diag.has(.unknown_key));
}

test "user file as named theme resolves via specFromRaw" {
    var raw = try rawFrom(testing.allocator, "[theme.body]\nfg = \"#010203\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var spec_val = specFromRaw(testing.allocator, raw.view(), &diag);
    spec_val.name = "usertheme";

    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&spec_val);

    const r = try reg.resolve("usertheme", .default, null, &diag);
    try testing.expectEqual(color.rgb(1, 2, 3), r.styles.body.fg);
}

test "user file as extends= target folds into the chain" {
    // A user base + a user leaf extending it.
    var base_raw = try rawFrom(testing.allocator, "[theme.body]\nfg = \"#0a0b0c\"\n");
    defer base_raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    var base_spec = specFromRaw(testing.allocator, base_raw.view(), &diag);
    base_spec.name = "userbase";

    const leaf = ThemeSpec{ .name = "userleaf", .extends = "userbase", .slots = blk: {
        var m = spec.SlotMap{};
        m.set(.link, .{ .fg = color.idx(7) });
        break :blk m;
    } };

    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&base_spec);
    try reg.insertUserSpec(&leaf);

    const r = try reg.resolve("userleaf", .default, null, &diag);
    try testing.expectEqual(color.rgb(0x0a, 0x0b, 0x0c), r.styles.body.fg);
    try testing.expectEqual(color.idx(7), r.styles.link.fg);
}

test "user file as extends= built-in preset: non-overridden slots equal the preset" {
    // Mirrors the repro: a user file whose root `extends = "dracula"` plus a
    // single heading1 override. Every non-overridden slot must equal dracula.
    var raw = try rawFrom(testing.allocator,
        "extends = \"dracula\"\n[theme.heading1]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    var user = specFromRaw(testing.allocator, raw.view(), &diag);
    user.name = "tmptest";
    try testing.expectEqualStrings("dracula", user.extends.?);

    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&user);

    const r = try reg.resolve("tmptest", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());

    const drac = try reg.resolve("dracula", .default, null, &diag);
    // Overridden slot differs; everything else matches dracula exactly.
    try testing.expectEqual(color.rgb(0xff, 0, 0), r.styles.heading1.fg);
    try testing.expectEqual(drac.styles.body.fg, r.styles.body.fg);
    try testing.expectEqual(drac.styles.link.fg, r.styles.link.fg);
    try testing.expectEqual(drac.styles.code.fg, r.styles.code.fg);
    try testing.expectEqual(drac.styles.strong.fg, r.styles.strong.fg);
    // And it did NOT collapse to the built-in dark base.
    const dark_base = theme.neutralDark;
    try testing.expect(!std.meta.eql(r.styles.body.fg, dark_base.body.fg));
}

test "extends chain through a second user file (leaf → user base → built-in)" {
    var base_raw = try rawFrom(testing.allocator,
        "extends = \"dracula\"\n[theme.link]\nfg = \"#010203\"\n");
    defer base_raw.deinit(testing.allocator);
    var leaf_raw = try rawFrom(testing.allocator,
        "extends = \"userbase\"\n[theme.heading1]\nfg = \"#040506\"\n");
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
    // leaf override, user-base override, and inherited built-in dracula slot all present.
    try testing.expectEqual(color.rgb(0x04, 0x05, 0x06), r.styles.heading1.fg);
    try testing.expectEqual(color.rgb(0x01, 0x02, 0x03), r.styles.link.fg);
    const drac = try reg.resolve("dracula", .default, null, &diag);
    try testing.expectEqual(drac.styles.body.fg, r.styles.body.fg);
}

test "user file with missing/cyclic root extends still reports diagnostics" {
    // Missing target.
    var miss_raw = try rawFrom(testing.allocator, "extends = \"ghost\"\n");
    defer miss_raw.deinit(testing.allocator);
    var d1 = Diagnostics.init(testing.allocator);
    defer d1.deinit();
    var miss = specFromRaw(testing.allocator, miss_raw.view(), &d1);
    miss.name = "orphanfile";
    var reg1 = Registry.init(testing.allocator);
    defer reg1.deinit();
    try reg1.insertUserSpec(&miss);
    _ = try reg1.resolve("orphanfile", .default, null, &d1);
    try testing.expect(d1.has(.missing_extends));

    // Cyclic: two user files extending each other.
    var a_raw = try rawFrom(testing.allocator, "extends = \"fileb\"\n");
    defer a_raw.deinit(testing.allocator);
    var b_raw = try rawFrom(testing.allocator, "extends = \"filea\"\n");
    defer b_raw.deinit(testing.allocator);
    var d2 = Diagnostics.init(testing.allocator);
    defer d2.deinit();
    var a = specFromRaw(testing.allocator, a_raw.view(), &d2);
    a.name = "filea";
    var b = specFromRaw(testing.allocator, b_raw.view(), &d2);
    b.name = "fileb";
    var reg2 = Registry.init(testing.allocator);
    defer reg2.deinit();
    try reg2.insertUserSpec(&a);
    try reg2.insertUserSpec(&b);
    _ = try reg2.resolve("filea", .default, null, &d2);
    try testing.expect(d2.has(.cyclic_extends));
}

test "glyph_fallback fires on PUA user glyph and substitutes" {
    // U+F011 is in the Nerd PUA range.
    var raw = try rawFrom(testing.allocator, "[theme.heading1]\nprefix = \"\u{f011} \"\n");
    defer raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    const s = specFromRaw(testing.allocator, raw.view(), &diag);
    try testing.expect(diag.has(.glyph_fallback));
    const h1 = s.slots.get(.heading1).?;
    // PUA codepoint replaced; no PUA byte survives. The substituted buffer is
    // heap-owned (arena-owned in production); free it here for the leak check.
    defer testing.allocator.free(h1.prefix.?);
    try testing.expect(!containsPua(h1.prefix.?));
}

test "unknown palette mode and ansi16 mode" {
    var raw = try rawFrom(testing.allocator, "[theme]\npalette = \"ansi16\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();
    const s = specFromRaw(testing.allocator, raw.view(), &diag);
    try testing.expectEqual(PaletteMode.ansi16, s.palette_mode.?);
}

// --- Cluster B: theme resolution semantics -------------------------------

test "inline [theme] extends re-roots the chain" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    // `--style dark` plus an inline `extends = "dracula"`: dracula becomes the
    // chain leaf, so every slot the inline keys do not touch comes from dracula.
    var raw = try rawFrom(testing.allocator, "extends = \"dracula\"\n[theme.heading1]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);
    const r = try reg.resolve("dark", .default, raw.view(), &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());

    const drac = try reg.resolve("dracula", .default, null, &diag);
    try testing.expect(std.meta.eql(drac.styles.body, r.styles.body));
    try testing.expect(std.meta.eql(drac.styles.code_block, r.styles.code_block));
    // The inline key itself still wins over the inherited value.
    try testing.expectEqual(color.rgb(0xff, 0, 0), r.styles.heading1.fg);

    // An unknown inline target reports missing_extends and falls back to dark.
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

    // markview frames code blocks as a labelled block; a child that touches only
    // `pad` must inherit both `kind = block` and `language_label = true`.
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

    // A theme with no code_frame at all stays fully sparse; the .panel/false
    // defaults land at the render read sites (`kind orelse .panel`).
    const bare = try reg.resolve("dark", .default, null, &diag);
    try testing.expectEqual(@as(?spec.CodeFrameKind, null), bare.decor.glyphs.code_frame.kind);
    try testing.expectEqual(@as(?bool, null), bare.decor.glyphs.code_frame.language_label);
}

test "tokens.function is an alias that overrides an inherited keyword" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Diagnostics.init(testing.allocator);
    defer diag.deinit();

    // dracula sets tokens.keyword; a child spelling the alias must win.
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
    // The substituted buffer is allocated while folding the inline overrides;
    // it must come from the registry arena, or testing.allocator reports a leak.
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

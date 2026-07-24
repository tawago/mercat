//! Stage S3: the theme *engine*. Turns a theme name + inline `[theme.*]`
//! overrides into a concrete `ResolvedTheme{ Palette, Decor, mode, accent,
//! base_bg }` by:
//!
//!   1. looking the name up in a `Registry` (built-in presets win the name,
//!      then user-file specs),
//!   2. walking the `extends` chain base→leaf (cycle- and missing-target-aware),
//!   3. folding the sparse specs (absent = inherit, `""` = clear) plus the
//!      optional `classic` syntax-variant delta and the inline overrides,
//!   4. baking the folded spec over a base built-in Palette into concrete
//!      `Palette` + `Decor`.
//!
//! Every soft failure (unknown key/color/theme, missing/cyclic extends,
//! unreadable file, glyph fallback) is *reported* via a `Collector`, never
//! fatal — resolution always yields a usable theme (dark fallback).
//!
//! The `Diagnostic` type + `Collector` live here (Simplicity #7: no standalone
//! diag.zig). The single RawThemeTables→ThemeSpec conversion (`specFromRaw`)
//! also lives here and is the one typed path for inline overrides, user files
//! selected by name, and user files named as `extends=` targets.

const std = @import("std");
const spec = @import("spec.zig");
const color = @import("color.zig");
const loadfile = @import("loadfile.zig");
const presets = @import("presets.zig");
const fromraw = @import("fromraw.zig");
const decor_mod = @import("../render/decor.zig");
const theme = @import("../theme.zig");
const types = @import("../render/types.zig");
const config = @import("../config.zig");

pub const Color = color.Color;
pub const ThemeSpec = spec.ThemeSpec;
pub const SlotSpec = spec.SlotSpec;
pub const Slot = spec.Slot;
pub const PaletteMode = spec.PaletteMode;
pub const RawThemeTables = loadfile.RawThemeTables;
pub const Decor = decor_mod.Decor;
pub const Palette = theme.Palette;
pub const StyleToken = theme.StyleToken;

/// The one typed RawThemeTables→ThemeSpec conversion (split into `fromraw.zig`
/// for the file-size cap). Re-exported so callers and tests keep using
/// `resolve.specFromRaw`.
pub const specFromRaw = fromraw.specFromRaw;
const containsPua = fromraw.containsPua;

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

pub const DiagKind = enum {
    unknown_key,
    bad_color,
    missing_extends,
    cyclic_extends,
    unreadable_file,
    unknown_theme,
    glyph_fallback,
};

pub const Diagnostic = struct { kind: DiagKind, detail: []const u8 };

/// Accumulates resolution warnings. `detail` strings are duped into `alloc` and
/// freed by `deinit`, so callers may pass transient formatted text to `warn`.
pub const Collector = struct {
    list: std.ArrayList(Diagnostic) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Collector {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Collector) void {
        for (self.list.items) |d| self.alloc.free(d.detail);
        self.list.deinit(self.alloc);
    }

    pub fn warn(self: *Collector, kind: DiagKind, detail: []const u8) void {
        const owned = self.alloc.dupe(u8, detail) catch return;
        self.list.append(self.alloc, .{ .kind = kind, .detail = owned }) catch {
            self.alloc.free(owned);
        };
    }

    pub fn warnFmt(self: *Collector, kind: DiagKind, comptime fmt: []const u8, args: anytype) void {
        const owned = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.list.append(self.alloc, .{ .kind = kind, .detail = owned }) catch {
            self.alloc.free(owned);
        };
    }

    pub fn count(self: *const Collector) usize {
        return self.list.items.len;
    }

    pub fn has(self: *const Collector, kind: DiagKind) bool {
        for (self.list.items) |d| if (d.kind == kind) return true;
        return false;
    }
};

// ---------------------------------------------------------------------------
// Resolved theme
// ---------------------------------------------------------------------------

pub const ResolvedTheme = struct {
    palette: Palette,
    decor: Decor,
    mode: PaletteMode,
    /// Toast/metadata accent (Correctness #1): the heading-1 color.
    accent: Color,
    /// Panel background used by toast/metadata overlays.
    base_bg: Color,
    /// Paint the whole document background with `base_bg` (solid canvas). False
    /// keeps the terminal-native background (byte-identical un-themed output).
    canvas: bool,

    /// Effective canvas background, or `null` to keep the terminal-native bg
    /// (`null` iff canvas off OR base_bg is the terminal default). Backends gate
    /// bg-fill on non-null, so `canvas=false` output stays byte-identical.
    pub fn canvasBg(self: *const ResolvedTheme) ?Color {
        if (!self.canvas) return null;
        if (self.base_bg == .default) return null;
        return self.base_bg;
    }
};

// ---------------------------------------------------------------------------
// Built-in specs — the seven presets (S4).
// ---------------------------------------------------------------------------

const builtins = presets.ALL;

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

pub const Registry = struct {
    /// User-file specs, inserted after built-ins. Built-ins win a name clash.
    user: std.ArrayList(*const ThemeSpec) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        self.user.deinit(self.alloc);
    }

    /// Insert a user-file spec (already converted via `specFromRaw`). The
    /// pointee must outlive the registry (owned by the caller's arena).
    pub fn insertUserSpec(self: *Registry, s: *const ThemeSpec) !void {
        try self.user.append(self.alloc, s);
    }

    /// Look a theme up by name: built-in presets first, then user files.
    pub fn lookup(self: *const Registry, name: []const u8) ?*const ThemeSpec {
        for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return b;
        for (self.user.items) |u| if (std.mem.eql(u8, u.name, name)) return u;
        return null;
    }

    /// Resolve `name` (+ optional `classic` syntax variant + inline overrides)
    /// into a concrete theme, reporting every soft failure to `diag`. Always
    /// returns a usable theme.
    ///
    /// `syntax_theme` is the legacy #17 code-token variant selector: when
    /// `.classic` **and** the extends-chain root is `dark`/`light`, that
    /// preset's `slots_classic` delta is folded as an extra layer *before* the
    /// inline overrides (so inline `[theme.*]` still wins over the variant).
    pub fn resolve(
        self: *const Registry,
        name: []const u8,
        syntax_theme: config.SyntaxTheme,
        inline_overrides: ?RawThemeTables,
        diag: *Collector,
    ) !ResolvedTheme {
        var leaf = self.lookup(name);
        if (leaf == null) {
            diag.warnFmt(.unknown_theme, "unknown theme '{s}' (using dark)", .{name});
            leaf = self.lookup("dark").?;
        }

        var chain_buf: [max_chain]*const ThemeSpec = undefined;
        const chain = self.buildChain(leaf.?, &chain_buf, diag);

        // The `classic` syntax variant folds the chain root's code-token recolor
        // delta. Presets without one carry an empty `slots_classic`, so the fold
        // is a self-evident no-op there — no per-name allowlist needed.
        const classic_delta: ?spec.SlotMap =
            if (syntax_theme == .classic and chain.len != 0) chain[0].slots_classic else null;

        var folded = foldSpecs(self.alloc, chain, classic_delta, inline_overrides, diag);
        const base_light = std.mem.eql(u8, chain[0].name, "light");
        return bake(&folded, base_light, diag);
    }

    /// Fold `name`'s extends chain into one flattened `ThemeSpec` (no classic
    /// delta, no inline overrides, no palette bake). Returns null for an unknown
    /// name (reporting `unknown_theme`) — used by `--dump-theme`, which must
    /// fail hard rather than silently fall back to dark, and which dumps the
    /// named theme's own data (classic-agnostic). The returned spec borrows
    /// string slices from the registry's specs, so it must not outlive them.
    pub fn foldedSpec(self: *const Registry, name: []const u8, diag: *Collector) ?ThemeSpec {
        const leaf = self.lookup(name) orelse {
            diag.warnFmt(.unknown_theme, "unknown theme '{s}'", .{name});
            return null;
        };
        var chain_buf: [max_chain]*const ThemeSpec = undefined;
        const chain = self.buildChain(leaf, &chain_buf, diag);
        return foldSpecs(self.alloc, chain, null, null, diag);
    }

    /// Walk `extends` from leaf to root, returning the chain root-first. Detects
    /// cycles (`cyclic_extends`) and missing targets (`missing_extends`, falls
    /// back to dark as the base).
    fn buildChain(
        self: *const Registry,
        leaf: *const ThemeSpec,
        buf: *[max_chain]*const ThemeSpec,
        diag: *Collector,
    ) []const *const ThemeSpec {
        // Collect leaf→root, then reverse.
        var n: usize = 0;
        var visited: [max_chain][]const u8 = undefined;
        var vn: usize = 0;
        var cur: ?*const ThemeSpec = leaf;

        while (cur) |node| {
            // Cycle guard: name already seen.
            var seen = false;
            for (visited[0..vn]) |name| {
                if (std.mem.eql(u8, name, node.name)) {
                    seen = true;
                    break;
                }
            }
            if (seen) {
                diag.warnFmt(.cyclic_extends, "extends cycle at '{s}'", .{node.name});
                break;
            }
            if (n >= max_chain) break;
            buf[n] = node;
            n += 1;
            visited[vn] = node.name;
            vn += 1;

            const target = node.extends orelse break;
            if (self.lookup(target)) |next| {
                cur = next;
            } else {
                diag.warnFmt(.missing_extends, "extends target '{s}' not found (using dark)", .{target});
                // Fall back to dark as the base of the chain.
                if (self.lookup("dark")) |dark_spec| {
                    if (n < max_chain and !std.mem.eql(u8, dark_spec.name, node.name)) {
                        buf[n] = dark_spec;
                        n += 1;
                    }
                }
                break;
            }
        }

        // Reverse in place → root-first.
        std.mem.reverse(*const ThemeSpec, buf[0..n]);
        return buf[0..n];
    }
};

const max_chain = 16;

// ---------------------------------------------------------------------------
// Folding
// ---------------------------------------------------------------------------

/// Fold a root→leaf chain (plus an optional `classic` slot delta and inline
/// overrides) into one dense-ish spec. Later layers override earlier: absent
/// field inherits, present field wins (a present `""` prefix/icon deliberately
/// clears — see bake). Order: chain root→leaf, then `classic_slots`, then
/// `inline_overrides` (so inline `[theme.*]` beats the syntax variant).
fn foldSpecs(
    alloc: std.mem.Allocator,
    chain: []const *const ThemeSpec,
    classic_slots: ?spec.SlotMap,
    inline_overrides: ?RawThemeTables,
    diag: *Collector,
) ThemeSpec {
    var out = ThemeSpec{ .name = if (chain.len > 0) chain[chain.len - 1].name else "dark" };

    for (chain) |s| mergeInto(&out, s);

    // Classic syntax-variant delta (code-token recolor) folds after the chain
    // but before inline overrides. Wrap it as a slots-only spec so it reuses the
    // same `mergeInto` overlay (all other fields null → identity).
    if (classic_slots) |cs| {
        const classic_spec = ThemeSpec{ .name = out.name, .slots = cs };
        mergeInto(&out, &classic_spec);
    }

    if (inline_overrides) |raw| {
        const inline_spec = specFromRaw(alloc, raw, diag);
        mergeInto(&out, &inline_spec);
    }
    return out;
}

fn mergeInto(out: *ThemeSpec, s: *const ThemeSpec) void {
    if (s.extends) |_| {} // extends already consumed by chain walk
    if (s.palette_mode) |m| out.palette_mode = m;
    if (s.base_bg) |c| out.base_bg = c;
    if (s.base_fg) |c| out.base_fg = c;
    if (s.canvas) |v| out.canvas = v;

    // Slots.
    var i: usize = 0;
    while (i < spec.slot_count) : (i += 1) {
        if (s.slots.entries[i]) |over| {
            out.slots.entries[i] = mergeSlot(out.slots.entries[i], over);
        }
    }
    // Glyphs (each field independently sparse).
    mergeGlyphs(&out.glyphs, s.glyphs);
    // Tokens.
    if (s.tokens.keyword) |c| out.tokens.keyword = c;
    if (s.tokens.string) |c| out.tokens.string = c;
    if (s.tokens.number) |c| out.tokens.number = c;
    if (s.tokens.comment) |c| out.tokens.comment = c;
    if (s.tokens.function) |c| out.tokens.function = c;
}

fn mergeSlot(base: ?SlotSpec, over: SlotSpec) SlotSpec {
    var r = base orelse SlotSpec{};
    if (over.fg) |v| r.fg = v;
    if (over.bg) |v| r.bg = v;
    if (over.full_line_bg) |v| r.full_line_bg = v;
    if (over.bold) |v| r.bold = v;
    if (over.italic) |v| r.italic = v;
    if (over.underline) |v| r.underline = v;
    if (over.strike) |v| r.strike = v;
    if (over.prefix) |v| r.prefix = v; // present "" clears
    if (over.suffix) |v| r.suffix = v;
    if (over.shift) |v| r.shift = v;
    if (over.blank_wrap) |v| r.blank_wrap = v;
    if (over.icon) |v| r.icon = v;
    if (over.underline_row) |v| r.underline_row = v;
    if (over.underline_glyph) |v| r.underline_glyph = v; // present "" clears to default
    return r;
}

fn mergeGlyphs(out: *spec.GlyphSet, g: spec.GlyphSet) void {
    if (g.bullets) |v| out.bullets = v;
    if (g.ordered_prefix) |v| out.ordered_prefix = v;
    if (g.task_ticked) |v| out.task_ticked = v;
    if (g.task_unticked) |v| out.task_unticked = v;
    if (g.quote_bar) |v| out.quote_bar = v;
    if (g.quote_indent) |v| out.quote_indent = v;
    if (g.hr_glyph) |v| out.hr_glyph = v;
    if (g.hr_mode) |v| out.hr_mode = v;
    if (g.hr_count) |v| out.hr_count = v;
    if (g.hr_center) |v| out.hr_center = v;
    if (g.table_style) |v| out.table_style = v;
    if (g.code_frame) |v| out.code_frame = v;
    if (g.doc_margin) |v| out.doc_margin = v;
}

// ---------------------------------------------------------------------------
// Bake: folded spec → concrete Palette + Decor
// ---------------------------------------------------------------------------

fn bake(folded: *const ThemeSpec, base_light: bool, diag: *Collector) ResolvedTheme {
    _ = diag;
    var palette: Palette = if (base_light)
        theme.palette(.light, .default)
    else
        theme.palette(.dark, .default);

    // Overlay each SpanStyle-corresponding slot onto the base palette.
    inline for (@typeInfo(types.SpanStyle).@"enum".fields) |f| {
        const style = @field(types.SpanStyle, f.name);
        const s = spec.Slot.fromSpanStyle(style);
        if (folded.slots.get(s)) |ss| {
            applySlot(&@field(palette, f.name), ss);
        }
    }

    // `list_item` inherits the theme's own `body` when neither this theme nor a
    // user override sets it, so item text matches paragraphs unless opted in.
    // (Runs before applyTokens, which never touches list_item/body.)
    if (folded.slots.get(.list_item) == null) palette.list_item = palette.body;

    // #17-parity: the four structural color slots re-added in S2 borrow the same
    // tokens #17 stamped for them (table_border/hr/code_fence_banner → muted,
    // table_header → body) unless a preset or user override sets them. Runs after
    // the overlay so they track a folded-overridden `muted`/`body`, and mirrors
    // `theme.bakeSlots`'s stamping so the un-themed path stays byte-identical.
    if (folded.slots.get(.table_border) == null) palette.table_border = palette.muted;
    if (folded.slots.get(.table_header) == null) palette.table_header = palette.body;
    if (folded.slots.get(.hr) == null) palette.hr = palette.muted;
    if (folded.slots.get(.code_fence_banner) == null) palette.code_fence_banner = palette.muted;

    // Token colors collapse onto both inline and block code classes.
    applyTokens(&palette, folded.tokens);

    const decor = bakeDecor(folded);

    const accent: Color = palette.heading1.fg;
    const base_bg: Color = folded.base_bg orelse (palette.code_block.bg orelse .default);

    return .{
        .palette = palette,
        .decor = decor,
        .mode = folded.palette_mode orelse .truecolor_or_256,
        .accent = accent,
        .base_bg = base_bg,
        .canvas = folded.canvas orelse false,
    };
}

/// Convenience: resolve a built-in preset with no overrides (default syntax
/// variant). Built-in glyphs and prefixes are static data, so the returned
/// theme owns no allocations and needs no deinit; `alloc` backs only a
/// throwaway diagnostics collector.
pub fn builtinResolved(alloc: std.mem.Allocator, name: []const u8) ResolvedTheme {
    var reg = Registry.init(alloc);
    defer reg.deinit();
    var d = Collector.init(alloc);
    defer d.deinit();
    return reg.resolve(name, .default, null, &d) catch unreachable;
}

fn applySlot(tok: *StyleToken, s: SlotSpec) void {
    if (s.fg) |c| tok.fg = c;
    if (s.bg) |c| tok.bg = c;
    if (s.bold) |v| tok.bold = v;
    if (s.italic) |v| tok.italic = v;
    if (s.underline) |v| tok.underline = v;
    if (s.strike) |v| tok.strikethrough = v;
}

fn applyTokens(palette: *Palette, t: spec.TokenColors) void {
    const kw = t.keyword orelse t.function;
    if (kw) |c| {
        palette.code_keyword.fg = c;
        palette.code_block_keyword.fg = c;
    }
    if (t.string) |c| {
        palette.code_string.fg = c;
        palette.code_block_string.fg = c;
    }
    if (t.number) |c| {
        palette.code_number.fg = c;
        palette.code_block_number.fg = c;
    }
    if (t.comment) |c| {
        palette.code_comment.fg = c;
        palette.code_block_comment.fg = c;
    }
}

fn bakeDecor(folded: *const ThemeSpec) Decor {
    var d = Decor{};
    var i: usize = 0;
    while (i < spec.slot_count) : (i += 1) {
        if (folded.slots.entries[i]) |ss| {
            d.slots[i] = .{
                .prefix = ss.prefix orelse "",
                .suffix = ss.suffix orelse "",
                .icon = ss.icon orelse "",
                .shift = ss.shift orelse 0,
                .blank_wrap = ss.blank_wrap orelse false,
                .full_line_bg = ss.full_line_bg orelse false,
                .underline_row = ss.underline_row orelse false,
                // null (unset) and explicit "" both bake to the default "─".
                .underline_glyph = blk: {
                    const g = ss.underline_glyph orelse "";
                    break :blk if (g.len == 0) "\u{2500}" else g;
                },
            };
        }
    }
    const g = folded.glyphs;
    d.glyphs = .{
        .bullets = g.bullets orelse &decor_mod.default_bullets,
        .ordered_prefix = g.ordered_prefix orelse "",
        .task_ticked = g.task_ticked orelse "[x]",
        .task_unticked = g.task_unticked orelse "[ ]",
        .quote_bar = g.quote_bar orelse "",
        .quote_indent = g.quote_indent orelse 0,
        .hr_glyph = g.hr_glyph orelse "─",
        .hr_mode = g.hr_mode orelse .full,
        .hr_count = g.hr_count orelse 0,
        .hr_center = g.hr_center orelse "",
        .table_style = g.table_style orelse .grid,
        .code_frame = g.code_frame orelse .{ .kind = .panel },
        .doc_margin = g.doc_margin orelse 0,
    };
    return d;
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

fn rawFrom(alloc: std.mem.Allocator, text: []const u8) !RawThemeTables {
    return loadfile.parseThemeTables(alloc, text);
}

// Byte-identity guard for the dark/light data-spec migration: the resolve
// pipeline must reproduce the historical `theme.palette()` literals across
// EVERY one of the palette slots. If any slot in `presets.dark`/`light`
// drifts from the historical `theme.darkPalette`/`lightPalette` values, this
// fails. Both variant paths flow from `presets.zig` (single source of truth),
// so this equally pins the numeric anchors below.
test "resolve(dark/light) == theme.palette default variant across all slots" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    const cases = [_]struct { name: []const u8, kind: @import("../config.zig").Theme }{
        .{ .name = "dark", .kind = .dark },
        .{ .name = "light", .kind = .light },
    };
    for (cases) |c| {
        const r = try reg.resolve(c.name, .default, null, &diag);
        try testing.expectEqual(@as(usize, 0), diag.count());
        const want = theme.palette(c.kind, .default);
        inline for (@typeInfo(Palette).@"struct".fields) |f| {
            try testing.expect(std.meta.eql(@field(want, f.name), @field(r.palette, f.name)));
        }
    }
    // Independent numeric anchors (default + classic variant) so the historical
    // values are pinned even if both derived paths were to drift together.
    const dark_d = theme.palette(.dark, .default);
    const dark_c = theme.palette(.dark, .classic);
    try testing.expectEqual(color.idx(254), dark_d.body.fg);
    try testing.expectEqual(color.idx(141), dark_d.code_block_keyword.fg); // default
    try testing.expectEqual(color.idx(81), dark_c.code_block_keyword.fg); // classic recolor
    try testing.expectEqual(color.idx(250), dark_d.code_block.fg);
    try testing.expectEqual(color.idx(114), dark_c.code_block.fg);
    const light_d = theme.palette(.light, .default);
    const light_c = theme.palette(.light, .classic);
    try testing.expectEqual(color.idx(234), light_d.body.fg);
    try testing.expectEqual(color.idx(92), light_d.code_block_keyword.fg);
    try testing.expectEqual(color.idx(25), light_c.code_block_keyword.fg);
}

// Classic syntax variant threaded end-to-end through the resolver (S5): the
// `dark`/`light` bases carry a `slots_classic` delta that recolors code tokens.
test "resolve(dark/light, .classic) recolors code tokens; default is unchanged" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    const dark_c = try reg.resolve("dark", .classic, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expectEqual(color.idx(81), dark_c.palette.code_block_keyword.fg);
    try testing.expectEqual(color.idx(114), dark_c.palette.code_block.fg);

    const dark_d = try reg.resolve("dark", .default, null, &diag);
    try testing.expectEqual(color.idx(141), dark_d.palette.code_block_keyword.fg);

    const light_c = try reg.resolve("light", .classic, null, &diag);
    try testing.expectEqual(color.idx(25), light_c.palette.code_block_keyword.fg);

    // Non-dark/light preset ignores the variant (no delta): dracula unchanged.
    const drac_def = try reg.resolve("dracula", .default, null, &diag);
    const drac_cls = try reg.resolve("dracula", .classic, null, &diag);
    try testing.expectEqual(drac_def.palette.code_block_keyword.fg, drac_cls.palette.code_block_keyword.fg);

    // Inline overrides still win over the classic delta.
    var raw = try rawFrom(testing.allocator, "[theme.code_block_keyword]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);
    const overridden = try reg.resolve("dark", .classic, raw, &diag);
    try testing.expectEqual(color.rgb(0xff, 0, 0), overridden.palette.code_block_keyword.fg);
}

// The four structural color slots re-added in S2 bake to their #17 borrowed
// tokens (muted / body) for every un-themed built-in, so the default path is
// byte-identical.
test "re-added structural slots default to muted/body" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    const r = try reg.resolve("dark", .default, null, &diag);
    try testing.expect(std.meta.eql(r.palette.table_border, r.palette.muted));
    try testing.expect(std.meta.eql(r.palette.hr, r.palette.muted));
    try testing.expect(std.meta.eql(r.palette.code_fence_banner, r.palette.muted));
    try testing.expect(std.meta.eql(r.palette.table_header, r.palette.body));
}

test "resolve dark yields a full palette + total decor" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("dark", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    // dark bakes to the current darkPalette exactly.
    const expected = theme.palette(.dark, .default);
    try testing.expectEqual(expected.heading1.fg, r.palette.heading1.fg);
    try testing.expectEqual(expected.body.fg, r.palette.body.fg);
    // Default decor is total.
    try testing.expectEqualStrings("─", r.decor.glyphs.hr_glyph);
}

test "dark/light bake to the render/decor legacy Decor (goldens safety net)" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    for ([_][]const u8{ "dark", "light" }) |name| {
        var diag = Collector.init(testing.allocator);
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
        var diag = Collector.init(testing.allocator);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    const r = try reg.resolve("ansi", .default, null, &diag);
    try testing.expectEqual(PaletteMode.ansi16, r.mode);
    try testing.expectEqual(Color{ .ansi16 = .bright_blue }, r.palette.heading1.fg);
}

test "light preset bakes to the light base palette" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    const r = try reg.resolve("light", .default, null, &diag);
    const expected = theme.palette(.light, .default);
    try testing.expectEqual(expected.body.fg, r.palette.body.fg);
    try testing.expectEqual(expected.heading1.fg, r.palette.heading1.fg);
}

test "unknown theme name falls back to dark with a diagnostic" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("nope", .default, null, &diag);
    try testing.expect(diag.has(.unknown_theme));
    const expected = theme.palette(.dark, .default);
    try testing.expectEqual(expected.body.fg, r.palette.body.fg);
}

test "inline override changes a slot color" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    var raw = try rawFrom(testing.allocator, "[theme.heading1]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);

    const r = try reg.resolve("dark", .default, raw, &diag);
    try testing.expectEqual(color.rgb(0xff, 0, 0), r.palette.heading1.fg);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    const chain = [_]*const ThemeSpec{ &base, &leaf };
    var folded = foldSpecs(testing.allocator, &chain, null, null, &diag);
    const h1 = folded.slots.get(.heading1).?;
    try testing.expectEqual(color.idx(20), h1.fg.?);
    try testing.expectEqualStrings(">> ", h1.prefix.?);
}

test "canvas merges through the extends chain (absent inherits, present wins)" {
    // Base turns canvas on; a middle spec leaves it absent (inherits true); the
    // leaf turns it off. Fold must end at the leaf's explicit false.
    const base = ThemeSpec{ .name = "cbase", .canvas = true };
    const mid = ThemeSpec{ .name = "cmid", .extends = "cbase" }; // canvas absent
    const leaf = ThemeSpec{ .name = "cleaf", .extends = "cmid", .canvas = false };
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    // Inherit-through-absent: base(true) → mid(absent) folds to true.
    const chain_inherit = [_]*const ThemeSpec{ &base, &mid };
    const folded_inherit = foldSpecs(testing.allocator, &chain_inherit, null, null, &diag);
    try testing.expectEqual(@as(?bool, true), folded_inherit.canvas);

    // Explicit override: leaf(false) wins over inherited true.
    const chain_override = [_]*const ThemeSpec{ &base, &mid, &leaf };
    const folded_override = foldSpecs(testing.allocator, &chain_override, null, null, &diag);
    try testing.expectEqual(@as(?bool, false), folded_override.canvas);
}

test "canvas preset defaults + canvasBg gating" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    var diag = Collector.init(testing.allocator);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    // dark is canvas=false by default; the inline override flips it on.
    var raw = try rawFrom(testing.allocator, "canvas = true\n");
    defer raw.deinit(testing.allocator);
    const r = try reg.resolve("dark", .default, raw, &diag);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    const chain = [_]*const ThemeSpec{ &base, &leaf };
    var folded = foldSpecs(testing.allocator, &chain, null, null, &diag);
    const d = bakeDecor(&folded);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    const chain = [_]*const ThemeSpec{ &base, &leaf };
    var folded = foldSpecs(testing.allocator, &chain, null, null, &diag);
    const d = bakeDecor(&folded);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    const chain = [_]*const ThemeSpec{ &base, &leaf };
    var folded = foldSpecs(testing.allocator, &chain, null, null, &diag);
    const d = bakeDecor(&folded);
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
    var diag = Collector.init(testing.allocator);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("orphan", .default, null, &diag);
    try testing.expect(diag.has(.missing_extends));
    // Base is dark.
    const expected = theme.palette(.dark, .default);
    try testing.expectEqual(expected.body.fg, r.palette.body.fg);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    const r = try reg.resolve("child", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    try testing.expectEqual(color.idx(1), r.palette.body.fg);
    try testing.expectEqual(color.idx(2), r.palette.strong.fg);
    try testing.expectEqual(color.idx(3), r.palette.link.fg);
}

test "specFromRaw reports bad color and unknown key, keeps good ones" {
    var raw = try rawFrom(testing.allocator,
        "[theme.heading1]\nfg = \"notacolor\"\nbold = true\nbogus = \"x\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    const s = specFromRaw(testing.allocator, raw, &diag);
    try testing.expect(diag.has(.bad_color));
    try testing.expect(diag.has(.unknown_key));
    const h1 = s.slots.get(.heading1).?;
    try testing.expect(h1.fg == null); // bad color dropped
    try testing.expectEqual(@as(?bool, true), h1.bold);
}

test "specFromRaw reports unknown slot name" {
    var raw = try rawFrom(testing.allocator, "[theme.not_a_slot]\nfg = \"#fff\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    _ = specFromRaw(testing.allocator, raw, &diag);
    try testing.expect(diag.has(.unknown_key));
}

test "user file as named theme resolves via specFromRaw" {
    var raw = try rawFrom(testing.allocator, "[theme.body]\nfg = \"#010203\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    var spec_val = specFromRaw(testing.allocator, raw, &diag);
    spec_val.name = "usertheme";

    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&spec_val);

    const r = try reg.resolve("usertheme", .default, null, &diag);
    try testing.expectEqual(color.rgb(1, 2, 3), r.palette.body.fg);
}

test "user file as extends= target folds into the chain" {
    // A user base + a user leaf extending it.
    var base_raw = try rawFrom(testing.allocator, "[theme.body]\nfg = \"#0a0b0c\"\n");
    defer base_raw.deinit(testing.allocator);
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    var base_spec = specFromRaw(testing.allocator, base_raw, &diag);
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
    try testing.expectEqual(color.rgb(0x0a, 0x0b, 0x0c), r.palette.body.fg);
    try testing.expectEqual(color.idx(7), r.palette.link.fg);
}

test "user file as extends= built-in preset: non-overridden slots equal the preset" {
    // Mirrors the repro: a user file whose root `extends = "dracula"` plus a
    // single heading1 override. Every non-overridden slot must equal dracula.
    var raw = try rawFrom(testing.allocator,
        "extends = \"dracula\"\n[theme.heading1]\nfg = \"#ff0000\"\n");
    defer raw.deinit(testing.allocator);
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    var user = specFromRaw(testing.allocator, raw, &diag);
    user.name = "tmptest";
    try testing.expectEqualStrings("dracula", user.extends.?);

    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&user);

    const r = try reg.resolve("tmptest", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());

    const drac = try reg.resolve("dracula", .default, null, &diag);
    // Overridden slot differs; everything else matches dracula exactly.
    try testing.expectEqual(color.rgb(0xff, 0, 0), r.palette.heading1.fg);
    try testing.expectEqual(drac.palette.body.fg, r.palette.body.fg);
    try testing.expectEqual(drac.palette.link.fg, r.palette.link.fg);
    try testing.expectEqual(drac.palette.code.fg, r.palette.code.fg);
    try testing.expectEqual(drac.palette.strong.fg, r.palette.strong.fg);
    // And it did NOT collapse to the built-in dark base.
    const dark_base = theme.palette(.dark, .default);
    try testing.expect(!std.meta.eql(r.palette.body.fg, dark_base.body.fg));
}

test "extends chain through a second user file (leaf → user base → built-in)" {
    var base_raw = try rawFrom(testing.allocator,
        "extends = \"dracula\"\n[theme.link]\nfg = \"#010203\"\n");
    defer base_raw.deinit(testing.allocator);
    var leaf_raw = try rawFrom(testing.allocator,
        "extends = \"userbase\"\n[theme.heading1]\nfg = \"#040506\"\n");
    defer leaf_raw.deinit(testing.allocator);
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    var base = specFromRaw(testing.allocator, base_raw, &diag);
    base.name = "userbase";
    var leaf = specFromRaw(testing.allocator, leaf_raw, &diag);
    leaf.name = "userleaf";

    var reg = Registry.init(testing.allocator);
    defer reg.deinit();
    try reg.insertUserSpec(&base);
    try reg.insertUserSpec(&leaf);

    const r = try reg.resolve("userleaf", .default, null, &diag);
    try testing.expectEqual(@as(usize, 0), diag.count());
    // leaf override, user-base override, and inherited built-in dracula slot all present.
    try testing.expectEqual(color.rgb(0x04, 0x05, 0x06), r.palette.heading1.fg);
    try testing.expectEqual(color.rgb(0x01, 0x02, 0x03), r.palette.link.fg);
    const drac = try reg.resolve("dracula", .default, null, &diag);
    try testing.expectEqual(drac.palette.body.fg, r.palette.body.fg);
}

test "user file with missing/cyclic root extends still reports diagnostics" {
    // Missing target.
    var miss_raw = try rawFrom(testing.allocator, "extends = \"ghost\"\n");
    defer miss_raw.deinit(testing.allocator);
    var d1 = Collector.init(testing.allocator);
    defer d1.deinit();
    var miss = specFromRaw(testing.allocator, miss_raw, &d1);
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
    var d2 = Collector.init(testing.allocator);
    defer d2.deinit();
    var a = specFromRaw(testing.allocator, a_raw, &d2);
    a.name = "filea";
    var b = specFromRaw(testing.allocator, b_raw, &d2);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();

    const s = specFromRaw(testing.allocator, raw, &diag);
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
    var diag = Collector.init(testing.allocator);
    defer diag.deinit();
    const s = specFromRaw(testing.allocator, raw, &diag);
    try testing.expectEqual(PaletteMode.ansi16, s.palette_mode.?);
}

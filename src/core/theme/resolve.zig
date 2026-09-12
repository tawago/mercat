//! Stage S3: the theme *engine*. Turns a theme name + inline `[theme.*]`
//! overrides into a concrete `ResolvedTheme{ StyleMap, Decor, mode, accent,
//! base_bg }` by:
//!
//!   1. looking the name up in a `Registry` (built-in presets win the name,
//!      then user-file specs),
//!   2. walking the `extends` chain base→leaf (cycle- and missing-target-aware),
//!   3. folding the sparse specs (absent = inherit, `""` = clear) plus the
//!      optional `classic` syntax-variant delta and the inline overrides,
//!   4. baking the merged spec over a base built-in StyleMap into concrete
//!      `StyleMap` + `Decor`.
//!
//! Every soft failure (unknown key/color/theme, missing/cyclic extends,
//! unreadable file, glyph fallback) is *reported* via a `Diagnostics`, never
//! fatal — resolution always yields a usable theme (dark fallback).
//!
//! The `Diagnostic` type + `Diagnostics` live here (Simplicity #7: no standalone
//! diag.zig). The single RawThemeTables→ThemeSpec conversion (`specFromRaw`)
//! also lives here and is the one typed path for inline overrides, user files
//! selected by name, and user files named as `extends=` targets.

const std = @import("std");
const spec = @import("spec.zig");
const color = @import("color.zig");
const loadfile = @import("loadfile.zig");
const presets = @import("presets.zig");
const fromraw = @import("fromraw.zig");
const decor_mod = @import("../markdown/render/decor.zig");
const theme = @import("../theme.zig");
const types = @import("../markdown/render/types.zig");
const config = @import("../config.zig");
const merge = @import("merge.zig");

pub const Color = color.Color;
pub const ThemeSpec = spec.ThemeSpec;
pub const SlotSpec = spec.SlotSpec;
pub const Slot = spec.Slot;
pub const PaletteMode = spec.PaletteMode;
pub const RawThemeTables = loadfile.RawThemeTables;
pub const Decor = decor_mod.Decor;
pub const StyleMap = theme.StyleMap;
pub const StyleToken = theme.StyleToken;

/// The one typed RawThemeTables→ThemeSpec conversion (split into `fromraw.zig`
/// for the file-size cap). Re-exported so callers and tests keep using
/// `resolve.specFromRaw`.
pub const specFromRaw = fromraw.specFromRaw;
const containsPua = fromraw.containsPua;

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
pub const Diagnostics = struct {
    list: std.ArrayList(Diagnostic) = .empty,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Diagnostics {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Diagnostics) void {
        for (self.list.items) |d| self.alloc.free(d.detail);
        self.list.deinit(self.alloc);
    }

    pub fn warn(self: *Diagnostics, kind: DiagKind, detail: []const u8) void {
        const owned = self.alloc.dupe(u8, detail) catch return;
        self.list.append(self.alloc, .{ .kind = kind, .detail = owned }) catch {
            self.alloc.free(owned);
        };
    }

    pub fn warnFmt(self: *Diagnostics, kind: DiagKind, comptime fmt: []const u8, args: anytype) void {
        const owned = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.list.append(self.alloc, .{ .kind = kind, .detail = owned }) catch {
            self.alloc.free(owned);
        };
    }

    pub fn count(self: *const Diagnostics) usize {
        return self.list.items.len;
    }

    pub fn has(self: *const Diagnostics, kind: DiagKind) bool {
        for (self.list.items) |d| if (d.kind == kind) return true;
        return false;
    }
};

pub const ResolvedTheme = struct {
    styles: StyleMap,
    decor: Decor,
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

const builtins = presets.ALL;

pub const Registry = struct {
    /// In-memory user specs (tests, or specs inserted before resolve). Consulted
    /// after built-ins but before any on-disk file. Built-ins win a name clash.
    user: std.ArrayList(*const ThemeSpec) = .empty,
    /// User theme directory (`~/.config/mercat/themes`), or null when unset or
    /// unresolvable. When set, a name that misses the built-ins and `user` list
    /// is lazily read from `<dir>/<name>.toml` on demand — no eager directory
    /// scan. The path is arena-owned.
    dir: ?[]const u8 = null,
    /// Cache of names already resolved against `dir`. A present entry short-
    /// circuits re-reading the file; a *negative* entry (stored `null`) records
    /// "looked, not found/unreadable" so a missing name isn't re-stat'd and a
    /// load diagnostic fires at most once.
    cache: std.StringHashMapUnmanaged(?*const ThemeSpec) = .empty,
    /// Backs every lazily-loaded spec (its raw tables, duped name, cache keys)
    /// and the resolved `dir` path. Owned by the registry, so file-loaded specs
    /// live exactly as long as the registry — callers no longer plumb a
    /// theme-spec arena of their own.
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Registry) void {
        self.user.deinit(self.alloc);
        self.cache.deinit(self.alloc);
        self.arena.deinit();
    }

    /// Point the registry at the user theme directory (`resolveThemeDir`) so
    /// name lookups that miss the built-ins/`user` list read `<dir>/<name>.toml`
    /// lazily. Best-effort: an unresolvable dir (no HOME/XDG) leaves `dir` null
    /// and lazy loading simply disabled.
    pub fn useThemeDir(self: *Registry) void {
        self.dir = loadfile.resolveThemeDir(self.arena.allocator()) catch null;
    }

    /// Insert an in-memory user spec (already converted via `specFromRaw`). The
    /// pointee must outlive the registry (owned by the caller).
    pub fn insertUserSpec(self: *Registry, s: *const ThemeSpec) !void {
        try self.user.append(self.alloc, s);
    }

    /// Look a theme up by name: built-in presets first, then the in-memory
    /// `user` list, then (lazily, on the first miss) the `<dir>/<name>.toml`
    /// file. File loads are cached — positive and negative alike — and report
    /// `unreadable_file`/parse diagnostics to `diag` at load time.
    pub fn lookup(self: *Registry, name: []const u8, diag: *Diagnostics) ?*const ThemeSpec {
        for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return b;
        for (self.user.items) |u| if (std.mem.eql(u8, u.name, name)) return u;
        if (self.cache.get(name)) |cached| return cached;
        return self.loadUserFile(name, diag);
    }

    /// Read + convert `<dir>/<name>.toml` on a cache miss, caching the outcome
    /// (spec or negative `null`). File identity wins the name. Any read/parse
    /// failure is reported and cached negative so it isn't retried.
    fn loadUserFile(self: *Registry, name: []const u8, diag: *Diagnostics) ?*const ThemeSpec {
        const arena = self.arena.allocator();
        const key = arena.dupe(u8, name) catch return null;

        const dir = self.dir orelse {
            self.cache.put(self.alloc, key, null) catch {};
            return null;
        };

        const raw = loadfile.readThemeFile(arena, dir, name) catch {
            diag.warnFmt(.unreadable_file, "cannot read theme file '{s}.toml'", .{name});
            self.cache.put(self.alloc, key, null) catch {};
            return null;
        } orelse {
            self.cache.put(self.alloc, key, null) catch {};
            return null;
        };

        const s = arena.create(ThemeSpec) catch return null;
        s.* = specFromRaw(arena, raw.view(), diag);
        s.name = key;
        self.cache.put(self.alloc, key, s) catch {};
        return s;
    }

    /// Resolve `name` (+ optional `classic` syntax variant + inline overrides)
    /// into a concrete theme, reporting every soft failure to `diag`. Always
    /// returns a usable theme.
    ///
    /// `syntax_theme` is the legacy #17 code-token variant selector: when
    /// `.classic` **and** the extends-chain root is `dark`/`light`, that
    /// preset's `slots_classic` delta is merged as an extra layer *before* the
    /// inline overrides (so inline `[theme.*]` still wins over the variant).
    pub fn resolve(
        self: *Registry,
        name: []const u8,
        syntax_theme: config.SyntaxTheme,
        inline_overrides: ?RawThemeTables,
        diag: *Diagnostics,
    ) !ResolvedTheme {
        var inline_extends: ?[]const u8 = null;
        if (inline_overrides) |raw| {
            for (raw.top) |kv| {
                if (std.mem.eql(u8, kv.key, "extends")) inline_extends = kv.value;
            }
        }

        var leaf = if (inline_extends) |target| self.lookup(target, diag) else self.lookup(name, diag);
        if (leaf == null) {
            if (inline_extends) |target| {
                diag.warnFmt(.missing_extends, "extends target '{s}' not found (using dark)", .{target});
            } else {
                diag.warnFmt(.unknown_theme, "unknown theme '{s}' (using dark)", .{name});
            }
            leaf = self.lookup("dark", diag).?;
        }

        var chain_buf: [max_chain]*const ThemeSpec = undefined;
        const chain = self.buildChain(leaf.?, &chain_buf, diag);

        const classic_delta: ?spec.SlotMap =
            if (syntax_theme == .classic and chain.len != 0) chain[0].slots_classic else null;

        var merged = mergeChain(self.arena.allocator(), chain, classic_delta, inline_overrides, diag);
        const base_light = std.mem.eql(u8, chain[0].name, "light");
        return bake(&merged, base_light);
    }

    /// Fold `name`'s extends chain into one flattened `ThemeSpec` (no classic
    /// delta, no inline overrides, no palette bake). Returns null for an unknown
    /// name (reporting `unknown_theme`) — used by `--dump-theme`, which must
    /// fail hard rather than silently fall back to dark, and which dumps the
    /// named theme's own data (classic-agnostic). The returned spec borrows
    /// string slices from the registry's specs, so it must not outlive them.
    pub fn mergedSpec(self: *Registry, name: []const u8, diag: *Diagnostics) ?ThemeSpec {
        const leaf = self.lookup(name, diag) orelse {
            diag.warnFmt(.unknown_theme, "unknown theme '{s}'", .{name});
            return null;
        };
        var chain_buf: [max_chain]*const ThemeSpec = undefined;
        const chain = self.buildChain(leaf, &chain_buf, diag);
        return mergeChain(self.arena.allocator(), chain, null, null, diag);
    }

    /// Walk `extends` from leaf to root, returning the chain root-first. Detects
    /// cycles (`cyclic_extends`) and missing targets (`missing_extends`, falls
    /// back to dark as the base).
    fn buildChain(
        self: *Registry,
        leaf: *const ThemeSpec,
        buf: *[max_chain]*const ThemeSpec,
        diag: *Diagnostics,
    ) []const *const ThemeSpec {
        var n: usize = 0;
        var visited: [max_chain][]const u8 = undefined;
        var vn: usize = 0;
        var cur: ?*const ThemeSpec = leaf;

        while (cur) |node| {
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
            if (self.lookup(target, diag)) |next| {
                cur = next;
            } else {
                diag.warnFmt(.missing_extends, "extends target '{s}' not found (using dark)", .{target});
                if (self.lookup("dark", diag)) |dark_spec| {
                    if (n < max_chain and !std.mem.eql(u8, dark_spec.name, node.name)) {
                        buf[n] = dark_spec;
                        n += 1;
                    }
                }
                break;
            }
        }

        std.mem.reverse(*const ThemeSpec, buf[0..n]);
        return buf[0..n];
    }
};

const max_chain = 16;

/// Fold a root→leaf chain (plus an optional `classic` slot delta and inline
/// overrides) into one dense-ish spec. Later layers override earlier: absent
/// field inherits, present field wins (a present `""` prefix/icon deliberately
/// clears — see bake). Order: chain root→leaf, then `classic_slots`, then
/// `inline_overrides` (so inline `[theme.*]` beats the syntax variant).
///
/// `alloc` backs only the glyph-fallback substitution buffers produced while
/// converting `inline_overrides`, and those buffers are referenced by the
/// returned spec (and by anything baked from it) without ever being freed here
/// — so pass an arena that outlives them (`Registry` passes its own).
pub fn mergeChain(
    alloc: std.mem.Allocator,
    chain: []const *const ThemeSpec,
    classic_slots: ?spec.SlotMap,
    inline_overrides: ?RawThemeTables,
    diag: *Diagnostics,
) ThemeSpec {
    var out = ThemeSpec{ .name = if (chain.len > 0) chain[chain.len - 1].name else "dark" };

    for (chain) |s| merge.mergeInto(&out, s);

    if (classic_slots) |cs| {
        const classic_spec = ThemeSpec{ .name = out.name, .slots = cs };
        merge.mergeInto(&out, &classic_spec);
    }

    if (inline_overrides) |raw| {
        const inline_spec = specFromRaw(alloc, raw, diag);
        merge.mergeInto(&out, &inline_spec);
    }
    return out;
}

pub fn bake(merged: *const ThemeSpec, base_light: bool) ResolvedTheme {
    var style_map = theme.overlaySlots(if (base_light) theme.neutralLight else theme.neutralDark, merged.slots);
    applyTokens(&style_map, merged.tokens);
    const decor = bakeDecor(merged);
    const accent: Color = style_map.heading1.fg;
    const base_bg: Color = merged.base_bg orelse (style_map.code_block.bg orelse .default);
    return .{ .styles = style_map, .decor = decor, .accent = accent, .base_bg = base_bg, .canvas = merged.canvas orelse false };
}

/// Convenience: resolve a built-in preset with no overrides (default syntax
/// variant). Built-in glyphs and prefixes are static data, so the returned
/// theme owns no allocations and needs no deinit; `alloc` backs only a
/// throwaway diagnostics collector.
pub fn builtinResolved(alloc: std.mem.Allocator, name: []const u8) ResolvedTheme {
    var reg = Registry.init(alloc);
    defer reg.deinit();
    var d = Diagnostics.init(alloc);
    defer d.deinit();
    return reg.resolve(name, .default, null, &d) catch unreachable;
}

fn applyTokens(style_map: *StyleMap, t: spec.TokenColors) void {
    inline for (@typeInfo(spec.TokenColors).@"struct".fields) |f| {
        if (@field(t, f.name)) |c| {
            @field(style_map, "code_" ++ f.name).fg = c;
            @field(style_map, "code_block_" ++ f.name).fg = c;
        }
    }
}

pub fn bakeDecor(merged: *const ThemeSpec) Decor {
    var d = Decor{};
    var i: usize = 0;
    while (i < spec.slot_count) : (i += 1) {
        if (merged.slots.entries[i]) |ss| {
            var sd = unwrapWithDefaults(decor_mod.SlotDecor, ss);
            if (sd.underline_glyph.len == 0) sd.underline_glyph = "\u{2500}";
            d.slots[i] = sd;
        }
    }
    d.glyphs = unwrapWithDefaults(decor_mod.ResolvedGlyphSet, merged.glyphs);
    return d;
}

/// Bake a sparse spec into the concrete struct `Out`: every field of `Out`
/// takes the same-named optional field of `sparse` when present, otherwise its
/// own declared default. Extra fields on `sparse` (the `SlotSpec` colors/attrs,
/// which bake into the `StyleMap` instead) are ignored.
fn unwrapWithDefaults(comptime Out: type, sparse: anytype) Out {
    var out = Out{};
    inline for (@typeInfo(Out).@"struct".fields) |f| {
        if (@field(sparse, f.name)) |v| @field(out, f.name) = v;
    }
    return out;
}

test {
    _ = @import("resolve_test.zig");
}

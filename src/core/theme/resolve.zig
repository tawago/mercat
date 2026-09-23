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
    accent: Color,
    base_bg: Color,
    canvas: bool,

    pub fn canvasBg(self: *const ResolvedTheme) ?Color {
        if (!self.canvas) return null;
        if (self.base_bg == .default) return null;
        return self.base_bg;
    }
};

const builtins = presets.ALL;

pub const Registry = struct {
    user: std.ArrayList(*const ThemeSpec) = .empty,
    dir: ?[]const u8 = null,
    cache: std.StringHashMapUnmanaged(?*const ThemeSpec) = .empty,
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

    pub fn useThemeDir(self: *Registry) void {
        self.dir = loadfile.resolveThemeDir(self.arena.allocator()) catch null;
    }

    pub fn insertUserSpec(self: *Registry, s: *const ThemeSpec) !void {
        try self.user.append(self.alloc, s);
    }

    pub fn lookup(self: *Registry, name: []const u8, diag: *Diagnostics) ?*const ThemeSpec {
        for (builtins) |b| if (std.mem.eql(u8, b.name, name)) return b;
        for (self.user.items) |u| if (std.mem.eql(u8, u.name, name)) return u;
        if (self.cache.get(name)) |cached| return cached;
        return self.loadUserFile(name, diag);
    }

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

    pub fn mergedSpec(self: *Registry, name: []const u8, diag: *Diagnostics) ?ThemeSpec {
        const leaf = self.lookup(name, diag) orelse {
            diag.warnFmt(.unknown_theme, "unknown theme '{s}'", .{name});
            return null;
        };
        var chain_buf: [max_chain]*const ThemeSpec = undefined;
        const chain = self.buildChain(leaf, &chain_buf, diag);
        return mergeChain(self.arena.allocator(), chain, null, null, diag);
    }

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

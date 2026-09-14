const std = @import("std");
const prim = @import("prim");
pub const loadfile = @import("theme/loadfile.zig");
pub const RawThemeBuilder = loadfile.RawThemeBuilder;

pub const SyntaxTheme = enum { default, classic };
/// How YAML front matter at the top of a document is displayed (issue #9):
///   panel   — banded card with half-block caps (default)
///   dim     — chrome-free muted key/value list
///   compact — single status-bar-like line of key:value pairs
///   raw     — verbatim YAML including the `---` fences
///   hidden  — stripped entirely
pub const FrontmatterStyle = enum { panel, dim, compact, raw, hidden };
/// Subgraph frame-border notation (owner ruling 2026-07-19): `bridge`
/// (default) draws the frame solid and bridges crossing edges; `cross`
/// reproduces the legacy junction-weld render. The shared mermaid_v2
/// vocabulary (`prim.SubgraphEdges`, itself std-only pure data) is stored
/// directly here — no config-local twin — so it flows to the render options
/// with no enum translation, matching how `ForceLayout` is handled.
pub const Config = struct {
    general: General = .{},
    display: Display = .{},
    mermaid: Mermaid = .{},
    files: Files = .{},
    /// Sparse, uninterpreted inline `[theme]` / `[theme.<slot>]` tables from
    /// config.toml. Wired but inert in S1: nothing consumes it yet — S3 folds
    /// it as the inline-override layer of the theme resolver.
    raw_theme: RawThemeBuilder = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.general.editor);
        allocator.free(self.general.pager);
        allocator.free(self.display.theme);
        allocator.free(self.mermaid.style);
        for (self.files.extensions) |extension| allocator.free(extension);
        allocator.free(self.files.extensions);
        self.raw_theme.deinit(allocator);
    }

    pub const General = struct {
        editor: []const u8 = "",
        pager: []const u8 = "",
    };

    pub const Display = struct {
        /// Theme *name*: a built-in preset (`dark`, `light`, `ansi`,
        /// `dracula`, `tokyo-night`, `pink`, `markview`) or a user theme-file
        /// name under `~/.config/mercat/themes/`. Validation is deferred to the
        /// registry, which falls back to `dark` (with an `unknown_theme`
        /// diagnostic) for names it cannot resolve. Owned; freed in `deinit`.
        theme: []const u8 = "dark",
        /// Code-token syntax variant: `default` or `classic`. `classic` folds an
        /// alternate code-block/inline-code recolor delta over the resolved theme
        /// (see `theme/resolve.zig`); other elements are unaffected.
        syntax_theme: SyntaxTheme = .default,
        width: usize = 0,
        line_numbers: bool = false,
        heading_markers: bool = true,
        frontmatter: FrontmatterStyle = .panel,
    };

    pub const Mermaid = struct {
        enabled: bool = true,
        style: []const u8 = "",
        subgraph_edges: prim.SubgraphEdges = .bridge,
    };

    pub const Files = struct {
        show_hidden: bool = false,
        extensions: []const []const u8 = &.{},
    };
};

pub const default_config_text = @embedFile("default_config.toml");

pub fn load(allocator: std.mem.Allocator) !Config {
    var cfg = try parseTomlLike(allocator, default_config_text);
    errdefer cfg.deinit(allocator);

    const path = try resolveConfigPath(allocator);
    defer allocator.free(path);

    if (openConfigFile(path)) |file| {
        defer file.close();
        const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(contents);
        try applyTomlLike(allocator, &cfg, contents);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    try applyEnvOverrides(allocator, &cfg);
    return cfg;
}

fn openConfigFile(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, .{});
    }
    return std.fs.cwd().openFile(path, .{});
}

pub fn resolveConfigPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        return std.fs.path.join(allocator, &.{ xdg, "mercat", "config.toml" });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "mercat", "config.toml" });
    } else |_| {}

    return allocator.dupe(u8, ".config/mercat/config.toml");
}

pub fn parseTomlLike(allocator: std.mem.Allocator, source: []const u8) !Config {
    var cfg = try initDefaults(allocator);
    errdefer cfg.deinit(allocator);
    try applyTomlLike(allocator, &cfg, source);
    return cfg;
}

fn initDefaults(allocator: std.mem.Allocator) !Config {
    const default_extensions = [_][]const u8{ "md", "markdown", "mdown", "mkd" };
    var extensions = try allocator.alloc([]const u8, default_extensions.len);
    for (default_extensions, 0..) |extension, index| {
        extensions[index] = try allocator.dupe(u8, extension);
    }

    return .{
        .general = .{
            .editor = try allocator.dupe(u8, "vim"),
            .pager = try allocator.dupe(u8, "less -R"),
        },
        .display = .{ .theme = try allocator.dupe(u8, "dark") },
        .mermaid = .{
            .enabled = true,
            .style = try allocator.dupe(u8, "rounded"),
        },
        .files = .{
            .show_hidden = false,
            .extensions = extensions,
        },
    };
}

pub fn applyTomlLike(allocator: std.mem.Allocator, cfg: *Config, source: []const u8) !void {
    var scanner = loadfile.scanLines(source, "");
    while (scanner.next()) |event| {
        if (std.mem.eql(u8, event.table, "theme")) {
            try loadfile.assignThemeValue(allocator, &cfg.raw_theme, event.subtable, event.key, event.value);
        } else {
            try assignValue(allocator, cfg, event.section, event.key, event.value);
        }
    }
}

fn assignValue(allocator: std.mem.Allocator, cfg: *Config, section: []const u8, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, section, "general")) {
        if (std.mem.eql(u8, key, "editor")) try replaceString(allocator, &cfg.general.editor, value);
        if (std.mem.eql(u8, key, "pager")) try replaceString(allocator, &cfg.general.pager, value);
        return;
    }

    if (std.mem.eql(u8, section, "display")) {
        if (std.mem.eql(u8, key, "theme")) try replaceString(allocator, &cfg.display.theme, value);
        if (std.mem.eql(u8, key, "syntax_theme")) cfg.display.syntax_theme = try parseSyntaxTheme(stripQuotes(value));
        if (std.mem.eql(u8, key, "width")) cfg.display.width = try std.fmt.parseUnsigned(usize, value, 10);
        if (std.mem.eql(u8, key, "line_numbers")) cfg.display.line_numbers = parseBool(value);
        if (std.mem.eql(u8, key, "heading_markers")) cfg.display.heading_markers = parseBool(value);
        if (std.mem.eql(u8, key, "frontmatter")) cfg.display.frontmatter = try parseFrontmatterStyle(stripQuotes(value));
        return;
    }

    if (std.mem.eql(u8, section, "mermaid")) {
        if (std.mem.eql(u8, key, "enabled")) cfg.mermaid.enabled = parseBool(value);
        if (std.mem.eql(u8, key, "style")) try replaceString(allocator, &cfg.mermaid.style, value);
        if (std.mem.eql(u8, key, "subgraph_edges")) cfg.mermaid.subgraph_edges = try parseSubgraphEdges(stripQuotes(value));
        return;
    }

    if (std.mem.eql(u8, section, "files")) {
        if (std.mem.eql(u8, key, "show_hidden")) cfg.files.show_hidden = parseBool(value);
        if (std.mem.eql(u8, key, "extensions")) try replaceExtensions(allocator, cfg, value);
    }
}

fn replaceExtensions(allocator: std.mem.Allocator, cfg: *Config, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, "[] ");

    var count: usize = 0;
    var count_iter = std.mem.splitScalar(u8, trimmed, ',');
    while (count_iter.next()) |_| count += 1;

    var index: usize = 0;
    var extensions = try allocator.alloc([]const u8, count);
    errdefer {
        for (extensions[0..index]) |extension| allocator.free(extension);
        allocator.free(extensions);
    }

    var iter = std.mem.splitScalar(u8, trimmed, ',');
    while (iter.next()) |item| {
        extensions[index] = try decodeQuotedString(allocator, std.mem.trim(u8, item, " \t"));
        index += 1;
    }

    for (cfg.files.extensions) |extension| allocator.free(extension);
    allocator.free(cfg.files.extensions);
    cfg.files.extensions = extensions;
}

fn parseSyntaxTheme(value: []const u8) !SyntaxTheme {
    if (std.mem.eql(u8, value, "default")) return .default;
    if (std.mem.eql(u8, value, "classic")) return .classic;
    return error.InvalidSyntaxTheme;
}

pub fn parseSubgraphEdges(value: []const u8) !prim.SubgraphEdges {
    if (std.mem.eql(u8, value, "bridge")) return .bridge;
    if (std.mem.eql(u8, value, "cross")) return .cross;
    return error.InvalidSubgraphEdges;
}

pub fn parseFrontmatterStyle(value: []const u8) !FrontmatterStyle {
    return std.meta.stringToEnum(FrontmatterStyle, value) orelse error.InvalidFrontmatterStyle;
}

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "true");
}

/// Shared with the theme-file parser so quote handling stays identical.
const stripQuotes = loadfile.stripQuotes;

fn replaceString(allocator: std.mem.Allocator, target: *[]const u8, value: []const u8) !void {
    const dup = try decodeQuotedString(allocator, value);
    allocator.free(target.*);
    target.* = dup;
}

/// Shared with the theme-file parser (and the dumper's `writeQuoted` inverse)
/// so escape decoding stays identical across both TOML surfaces.
const decodeQuotedString = loadfile.decodeQuotedString;

fn applyEnvOverrides(allocator: std.mem.Allocator, cfg: *Config) !void {
    const width = std.process.getEnvVarOwned(std.heap.page_allocator, "MERCAT_WIDTH") catch null;
    defer if (width) |value| std.heap.page_allocator.free(value);
    if (width) |value| {
        cfg.display.width = std.fmt.parseUnsigned(usize, value, 10) catch cfg.display.width;
    }

    const theme = std.process.getEnvVarOwned(std.heap.page_allocator, "MERCAT_THEME") catch null;
    defer if (theme) |value| std.heap.page_allocator.free(value);
    if (theme) |value| {
        try replaceString(allocator, &cfg.display.theme, value);
    }

    const syntax_theme = std.process.getEnvVarOwned(std.heap.page_allocator, "MERCAT_SYNTAX_THEME") catch null;
    defer if (syntax_theme) |value| std.heap.page_allocator.free(value);
    if (syntax_theme) |value| {
        cfg.display.syntax_theme = parseSyntaxTheme(value) catch cfg.display.syntax_theme;
    }

    const fm_style = std.process.getEnvVarOwned(std.heap.page_allocator, "MERCAT_FRONTMATTER") catch null;
    defer if (fm_style) |value| std.heap.page_allocator.free(value);
    if (fm_style) |value| {
        cfg.display.frontmatter = parseFrontmatterStyle(value) catch cfg.display.frontmatter;
    }

    const subgraph_edges = std.process.getEnvVarOwned(std.heap.page_allocator, "MERCAT_SUBGRAPH_EDGES") catch null;
    defer if (subgraph_edges) |value| std.heap.page_allocator.free(value);
    if (subgraph_edges) |value| {
        cfg.mermaid.subgraph_edges = parseSubgraphEdges(value) catch cfg.mermaid.subgraph_edges;
    }
}

test {
    _ = @import("theme/loadfile.zig");
    _ = @import("theme/color.zig");
    _ = @import("theme/spec.zig");
    _ = @import("theme/resolve.zig");
    _ = @import("theme/fromraw.zig");
    _ = @import("theme/presets.zig");
    _ = @import("theme/dump.zig");
    _ = @import("markdown/render/decor.zig");
    _ = @import("config_test.zig");
}

const std = @import("std");
const prim = @import("prim");

pub const Theme = enum { auto, dark, light };
pub const SyntaxTheme = enum { default, classic };
/// How YAML front matter at the top of a document is displayed (issue #9):
///   panel   — banded card with half-block caps (default)
///   dim     — chrome-free muted key/value list
///   compact — single status-bar-like line of key:value pairs
///   table   — boxed two-column table
///   raw     — verbatim YAML including the `---` fences
///   hidden  — stripped entirely
pub const FrontmatterStyle = enum { panel, dim, compact, table, raw, hidden };
/// Subgraph frame-border notation (owner ruling 2026-07-19): `bridge`
/// (default) draws the frame solid and bridges crossing edges; `cross`
/// reproduces the legacy junction-weld render. The shared mermaid_v2
/// vocabulary (`prim.SubgraphEdges`, itself std-only pure data) is stored
/// directly here — no config-local twin — so it flows to the render options
/// with no enum translation, matching how `ForceLayout` is handled. (`Theme`
/// keeps a config-local enum only because it has no downstream twin to share.)

pub const Config = struct {
    general: General = .{},
    display: Display = .{},
    mermaid: Mermaid = .{},
    files: Files = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.general.editor);
        allocator.free(self.general.pager);
        allocator.free(self.mermaid.style);
        for (self.files.extensions) |extension| allocator.free(extension);
        allocator.free(self.files.extensions);
    }

    pub const General = struct {
        editor: []const u8 = "",
        pager: []const u8 = "",
    };

    pub const Display = struct {
        theme: Theme = .auto,
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

const default_config_text = @embedFile("default_config.toml");

pub fn load(allocator: std.mem.Allocator) !Config {
    var cfg = try parseTomlLike(allocator, default_config_text);

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

    applyEnvOverrides(&cfg);
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

fn parseTomlLike(allocator: std.mem.Allocator, source: []const u8) !Config {
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
        .display = .{},
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

fn applyTomlLike(allocator: std.mem.Allocator, cfg: *Config, source: []const u8) !void {
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
            section = trimmed[1 .. trimmed.len - 1];
            continue;
        }

        const equals_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..equals_index], " \t");
        const value = std.mem.trim(u8, trimmed[equals_index + 1 ..], " \t");
        try assignValue(allocator, cfg, section, key, value);
    }
}

fn assignValue(allocator: std.mem.Allocator, cfg: *Config, section: []const u8, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, section, "general")) {
        if (std.mem.eql(u8, key, "editor")) try replaceString(allocator, &cfg.general.editor, stripQuotes(value));
        if (std.mem.eql(u8, key, "pager")) try replaceString(allocator, &cfg.general.pager, stripQuotes(value));
        return;
    }

    if (std.mem.eql(u8, section, "display")) {
        if (std.mem.eql(u8, key, "theme")) cfg.display.theme = try parseTheme(stripQuotes(value));
        if (std.mem.eql(u8, key, "syntax_theme")) cfg.display.syntax_theme = try parseSyntaxTheme(stripQuotes(value));
        if (std.mem.eql(u8, key, "width")) cfg.display.width = try std.fmt.parseUnsigned(usize, value, 10);
        if (std.mem.eql(u8, key, "line_numbers")) cfg.display.line_numbers = parseBool(value);
        if (std.mem.eql(u8, key, "heading_markers")) cfg.display.heading_markers = parseBool(value);
        if (std.mem.eql(u8, key, "frontmatter")) cfg.display.frontmatter = try parseFrontmatterStyle(stripQuotes(value));
        return;
    }

    if (std.mem.eql(u8, section, "mermaid")) {
        if (std.mem.eql(u8, key, "enabled")) cfg.mermaid.enabled = parseBool(value);
        if (std.mem.eql(u8, key, "style")) try replaceString(allocator, &cfg.mermaid.style, stripQuotes(value));
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
        extensions[index] = try allocator.dupe(u8, stripQuotes(std.mem.trim(u8, item, " \t")));
        index += 1;
    }

    for (cfg.files.extensions) |extension| allocator.free(extension);
    allocator.free(cfg.files.extensions);
    cfg.files.extensions = extensions;
}

fn parseTheme(value: []const u8) !Theme {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "dark")) return .dark;
    if (std.mem.eql(u8, value, "light")) return .light;
    return error.InvalidTheme;
}

fn parseSyntaxTheme(value: []const u8) !SyntaxTheme {
    if (std.mem.eql(u8, value, "default")) return .default;
    if (std.mem.eql(u8, value, "classic")) return .classic;
    return error.InvalidSyntaxTheme;
}

fn parseSubgraphEdges(value: []const u8) !prim.SubgraphEdges {
    if (std.mem.eql(u8, value, "bridge")) return .bridge;
    if (std.mem.eql(u8, value, "cross")) return .cross;
    return error.InvalidSubgraphEdges;
}

fn parseFrontmatterStyle(value: []const u8) !FrontmatterStyle {
    return std.meta.stringToEnum(FrontmatterStyle, value) orelse error.InvalidFrontmatterStyle;
}

fn parseBool(value: []const u8) bool {
    return std.mem.eql(u8, value, "true");
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn replaceString(allocator: std.mem.Allocator, target: *[]const u8, value: []const u8) !void {
    allocator.free(target.*);
    target.* = try allocator.dupe(u8, value);
}

fn applyEnvOverrides(cfg: *Config) void {
    const width = std.process.getEnvVarOwned(std.heap.page_allocator, "MERCAT_WIDTH") catch null;
    defer if (width) |value| std.heap.page_allocator.free(value);
    if (width) |value| {
        cfg.display.width = std.fmt.parseUnsigned(usize, value, 10) catch cfg.display.width;
    }

    const theme = std.process.getEnvVarOwned(std.heap.page_allocator, "MERCAT_THEME") catch null;
    defer if (theme) |value| std.heap.page_allocator.free(value);
    if (theme) |value| {
        cfg.display.theme = parseTheme(value) catch cfg.display.theme;
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

test "parses default config" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(Theme.auto, cfg.display.theme);
    try std.testing.expectEqual(SyntaxTheme.default, cfg.display.syntax_theme);
    try std.testing.expectEqualStrings("vim", cfg.general.editor);
    try std.testing.expect(cfg.mermaid.enabled);
    try std.testing.expect(cfg.display.heading_markers);
    try std.testing.expectEqual(FrontmatterStyle.panel, cfg.display.frontmatter);
    // Frame-solid bridging is the default notation (owner ruling 2026-07-19).
    try std.testing.expectEqual(prim.SubgraphEdges.bridge, cfg.mermaid.subgraph_edges);
}

test "overrides config values from file content" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(
        std.testing.allocator,
        &cfg,
        \\[display]
        \\theme = "dark"
        \\syntax_theme = "classic"
        \\frontmatter = "dim"
        \\width = 88
        \\[general]
        \\editor = "nvim"
        \\[mermaid]
        \\subgraph_edges = "cross"
        ,
    );

    try std.testing.expectEqual(Theme.dark, cfg.display.theme);
    try std.testing.expectEqual(SyntaxTheme.classic, cfg.display.syntax_theme);
    try std.testing.expectEqual(@as(usize, 88), cfg.display.width);
    try std.testing.expectEqualStrings("nvim", cfg.general.editor);
    try std.testing.expectEqual(prim.SubgraphEdges.cross, cfg.mermaid.subgraph_edges);
    try std.testing.expectEqual(FrontmatterStyle.dim, cfg.display.frontmatter);
}

test "frontmatter style parses every notation; invalid errors" {
    try std.testing.expectEqual(FrontmatterStyle.panel, try parseFrontmatterStyle("panel"));
    try std.testing.expectEqual(FrontmatterStyle.dim, try parseFrontmatterStyle("dim"));
    try std.testing.expectEqual(FrontmatterStyle.compact, try parseFrontmatterStyle("compact"));
    try std.testing.expectEqual(FrontmatterStyle.table, try parseFrontmatterStyle("table"));
    try std.testing.expectEqual(FrontmatterStyle.raw, try parseFrontmatterStyle("raw"));
    try std.testing.expectEqual(FrontmatterStyle.hidden, try parseFrontmatterStyle("hidden"));
    // The env-override path (`catch <old>`) keeps the prior value on typos.
    try std.testing.expectError(error.InvalidFrontmatterStyle, parseFrontmatterStyle("fancy"));
}

test "subgraph_edges parses both notations; bridge round-trips; invalid errors" {
    // `bridge` and `cross` map to the two enum tags.
    try std.testing.expectEqual(prim.SubgraphEdges.bridge, try parseSubgraphEdges("bridge"));
    try std.testing.expectEqual(prim.SubgraphEdges.cross, try parseSubgraphEdges("cross"));
    // An unrecognized value errors — the env-override path
    // (MERCAT_SUBGRAPH_EDGES, `parseSubgraphEdges(value) catch <old>`) therefore
    // keeps the prior value rather than corrupting it.
    try std.testing.expectError(error.InvalidSubgraphEdges, parseSubgraphEdges("weld"));

    // File parse of the explicit default value round-trips to `.bridge`.
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);
    try applyTomlLike(std.testing.allocator, &cfg,
        \\[mermaid]
        \\subgraph_edges = "bridge"
    );
    try std.testing.expectEqual(prim.SubgraphEdges.bridge, cfg.mermaid.subgraph_edges);
}

const std = @import("std");
const prim = @import("prim");

pub const Theme = enum { auto, dark, light };
pub const SyntaxTheme = enum { default, classic };

/// Glyph set for table borders. Each variant maps to a (horizontal, vertical,
/// cross) triple; every glyph is display-width 1 so column math is unchanged.
pub const TableBorderSet = enum {
    light,
    heavy,
    double,
    ascii,

    pub const Triple = struct {
        horizontal: []const u8,
        vertical: []const u8,
        cross: []const u8,
    };

    pub fn glyphs(self: TableBorderSet) Triple {
        return switch (self) {
            .light => .{ .horizontal = "\u{2500}", .vertical = "\u{2502}", .cross = "\u{253c}" },
            .heavy => .{ .horizontal = "\u{2501}", .vertical = "\u{2503}", .cross = "\u{254b}" },
            .double => .{ .horizontal = "\u{2550}", .vertical = "\u{2551}", .cross = "\u{256c}" },
            .ascii => .{ .horizontal = "-", .vertical = "|", .cross = "+" },
        };
    }
};
/// Subgraph frame-border notation (owner ruling 2026-07-19): `bridge`
/// (default) draws the frame solid and bridges crossing edges; `cross`
/// reproduces the legacy junction-weld render. The shared mermaid_v2
/// vocabulary (`prim.SubgraphEdges`, itself std-only pure data) is stored
/// directly here — no config-local twin — so it flows to the render options
/// with no enum translation, matching how `ForceLayout` is handled. (`Theme`
/// keeps a config-local enum only because it has no downstream twin to share.)

/// A single-slot color override parsed from a `[theme.<slot>]` table.
/// Every attribute is optional: a null field leaves the palette default
/// untouched during the merge in theme.palette().
pub const StyleOverride = struct {
    fg: ?u8 = null,
    bg: ?u8 = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: ?bool = null,
    strikethrough: ?bool = null,
};

/// One optional override per palette slot. Field names MUST match the
/// `theme.Palette` field names exactly — the merge in theme.palette()
/// comptime-iterates these fields and `@field`s into the palette, so a
/// mismatch fails compilation.
pub const ThemeOverrides = struct {
    heading1: ?StyleOverride = null,
    heading2: ?StyleOverride = null,
    heading3: ?StyleOverride = null,
    heading4: ?StyleOverride = null,
    heading5: ?StyleOverride = null,
    heading6: ?StyleOverride = null,
    body: ?StyleOverride = null,
    muted: ?StyleOverride = null,
    emphasis: ?StyleOverride = null,
    strong: ?StyleOverride = null,
    strong_emphasis: ?StyleOverride = null,
    code: ?StyleOverride = null,
    code_block: ?StyleOverride = null,
    code_block_keyword: ?StyleOverride = null,
    code_block_string: ?StyleOverride = null,
    code_block_number: ?StyleOverride = null,
    code_block_comment: ?StyleOverride = null,
    code_keyword: ?StyleOverride = null,
    code_string: ?StyleOverride = null,
    code_number: ?StyleOverride = null,
    code_comment: ?StyleOverride = null,
    quote: ?StyleOverride = null,
    link: ?StyleOverride = null,
    strikethrough: ?StyleOverride = null,
    image_alt: ?StyleOverride = null,
    superscript: ?StyleOverride = null,
    subscript: ?StyleOverride = null,
    highlight: ?StyleOverride = null,
    // Structural slots (Layer 1b): default to the same token their emit site
    // borrowed before, so untouched output stays byte-identical.
    list_marker: ?StyleOverride = null,
    table_border: ?StyleOverride = null,
    table_header: ?StyleOverride = null,
    task_checkbox_done: ?StyleOverride = null,
    task_checkbox_todo: ?StyleOverride = null,
    hr: ?StyleOverride = null,
    code_fence_banner: ?StyleOverride = null,
};

pub const Config = struct {
    general: General = .{},
    display: Display = .{},
    mermaid: Mermaid = .{},
    files: Files = .{},
    theme_overrides: ThemeOverrides = .{},

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.general.editor);
        allocator.free(self.general.pager);
        allocator.free(self.mermaid.style);
        for (self.files.extensions) |extension| allocator.free(extension);
        allocator.free(self.files.extensions);
        // Display glyph strings are heap-owned once a Config comes from load()/
        // initDefaults() (the embedded default parse allocates every one), so
        // freeing them here mirrors the general/mermaid/files strings above.
        allocator.free(self.display.quote_bar);
        allocator.free(self.display.hr_glyph);
        allocator.free(self.display.task_checked);
        allocator.free(self.display.task_todo);
        allocator.free(self.display.heading_prefix);
        for (self.display.bullet_glyphs) |glyph| allocator.free(glyph);
        allocator.free(self.display.bullet_glyphs);
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
        // Structural glyphs (Issue 17 Layer 2). Defaults are the literals the
        // renderer used before; the space that follows a bullet/checkbox marker
        // is appended by the renderer, so it is NOT part of these strings.
        quote_bar: []const u8 = "\u{258E}",
        bullet_glyphs: []const []const u8 = &.{ "\u{2022}", "\u{25E6}", "\u{2023}" },
        hr_glyph: []const u8 = "\u{2500}",
        task_checked: []const u8 = "[x]",
        task_todo: []const u8 = "[ ]",
        table_border_set: TableBorderSet = .light,
        heading_prefix: []const u8 = "#",
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

    const default_bullets = [_][]const u8{ "\u{2022}", "\u{25E6}", "\u{2023}" };
    var bullets = try allocator.alloc([]const u8, default_bullets.len);
    for (default_bullets, 0..) |glyph, index| {
        bullets[index] = try allocator.dupe(u8, glyph);
    }

    return .{
        .general = .{
            .editor = try allocator.dupe(u8, "vim"),
            .pager = try allocator.dupe(u8, "less -R"),
        },
        // Every heap-owned Display string is allocated here so deinit() can free
        // them uniformly (see Config.deinit).
        .display = .{
            .quote_bar = try allocator.dupe(u8, "\u{258E}"),
            .bullet_glyphs = bullets,
            .hr_glyph = try allocator.dupe(u8, "\u{2500}"),
            .task_checked = try allocator.dupe(u8, "[x]"),
            .task_todo = try allocator.dupe(u8, "[ ]"),
            .heading_prefix = try allocator.dupe(u8, "#"),
        },
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
    if (std.mem.startsWith(u8, section, "theme.")) {
        assignThemeOverride(cfg, section["theme.".len..], key, value);
        return;
    }

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
        if (std.mem.eql(u8, key, "quote_bar")) try replaceString(allocator, &cfg.display.quote_bar, stripQuotes(value));
        if (std.mem.eql(u8, key, "bullet_glyphs")) try replaceStringArray(allocator, &cfg.display.bullet_glyphs, value);
        if (std.mem.eql(u8, key, "hr_glyph")) try replaceString(allocator, &cfg.display.hr_glyph, stripQuotes(value));
        if (std.mem.eql(u8, key, "task_checked")) try replaceString(allocator, &cfg.display.task_checked, stripQuotes(value));
        if (std.mem.eql(u8, key, "task_todo")) try replaceString(allocator, &cfg.display.task_todo, stripQuotes(value));
        if (std.mem.eql(u8, key, "table_border_set")) cfg.display.table_border_set = parseTableBorderSet(stripQuotes(value)) catch return;
        if (std.mem.eql(u8, key, "heading_prefix")) try replaceString(allocator, &cfg.display.heading_prefix, stripQuotes(value));
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

/// Apply one `[theme.<slot>]` key/value onto the matching ThemeOverrides slot.
/// Unknown slot names and unknown keys are silently ignored, matching the
/// parser's policy for unknown sections/keys elsewhere. Unparseable scalar
/// values leave the attribute untouched.
fn assignThemeOverride(cfg: *Config, slot: []const u8, key: []const u8, value: []const u8) void {
    inline for (std.meta.fields(ThemeOverrides)) |field| {
        if (std.mem.eql(u8, field.name, slot)) {
            if (@field(cfg.theme_overrides, field.name) == null) {
                @field(cfg.theme_overrides, field.name) = .{};
            }
            const ov = &@field(cfg.theme_overrides, field.name).?;
            if (std.mem.eql(u8, key, "fg")) {
                ov.fg = std.fmt.parseUnsigned(u8, stripQuotes(value), 10) catch return;
            } else if (std.mem.eql(u8, key, "bg")) {
                ov.bg = std.fmt.parseUnsigned(u8, stripQuotes(value), 10) catch return;
            } else if (std.mem.eql(u8, key, "bold")) {
                ov.bold = parseBool(value);
            } else if (std.mem.eql(u8, key, "italic")) {
                ov.italic = parseBool(value);
            } else if (std.mem.eql(u8, key, "underline")) {
                ov.underline = parseBool(value);
            } else if (std.mem.eql(u8, key, "strikethrough")) {
                ov.strikethrough = parseBool(value);
            }
            return;
        }
    }
}

fn replaceExtensions(allocator: std.mem.Allocator, cfg: *Config, value: []const u8) !void {
    return replaceStringArray(allocator, &cfg.files.extensions, value);
}

/// Parse a `["a", "b", ...]` inline array, dupe each element, and swap it into
/// `target` (freeing the previous heap-owned array). Shared by `files.extensions`
/// and `display.bullet_glyphs`.
fn replaceStringArray(allocator: std.mem.Allocator, target: *[]const []const u8, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, "[] \t");

    // An empty bracket body (`[]`) yields a zero-length array — this is a
    // distinct, valid value (e.g. the renderer's len==0 bullet fallback), not a
    // one-element array containing the empty string.
    if (trimmed.len == 0) {
        for (target.*) |item| allocator.free(item);
        allocator.free(target.*);
        target.* = try allocator.alloc([]const u8, 0);
        return;
    }

    // Split on commas, but only when OUTSIDE a double-quoted element, so a comma
    // inside a quoted glyph/extension does not split the element.
    const count = countArrayElements(trimmed);

    var index: usize = 0;
    var items = try allocator.alloc([]const u8, count);
    errdefer {
        for (items[0..index]) |item| allocator.free(item);
        allocator.free(items);
    }

    var start: usize = 0;
    var in_quotes = false;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];
        if (ch == '"') {
            in_quotes = !in_quotes;
        } else if (ch == ',' and !in_quotes) {
            items[index] = try allocator.dupe(u8, stripQuotes(std.mem.trim(u8, trimmed[start..i], " \t")));
            index += 1;
            start = i + 1;
        }
    }
    items[index] = try allocator.dupe(u8, stripQuotes(std.mem.trim(u8, trimmed[start..], " \t")));
    index += 1;

    for (target.*) |item| allocator.free(item);
    allocator.free(target.*);
    target.* = items;
}

/// Count comma-separated elements, ignoring commas inside double quotes.
fn countArrayElements(trimmed: []const u8) usize {
    var count: usize = 1;
    var in_quotes = false;
    for (trimmed) |ch| {
        if (ch == '"') {
            in_quotes = !in_quotes;
        } else if (ch == ',' and !in_quotes) {
            count += 1;
        }
    }
    return count;
}

fn parseTableBorderSet(value: []const u8) !TableBorderSet {
    if (std.mem.eql(u8, value, "light")) return .light;
    if (std.mem.eql(u8, value, "heavy")) return .heavy;
    if (std.mem.eql(u8, value, "double")) return .double;
    if (std.mem.eql(u8, value, "ascii")) return .ascii;
    return error.InvalidTableBorderSet;
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
    // Dupe into a temp first so an OOM leaves the prior value intact (no
    // dangling pointer, no double-free): only free the old value once the new
    // allocation has succeeded.
    const dup = try allocator.dupe(u8, value);
    allocator.free(target.*);
    target.* = dup;
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
}

test "parses [theme.<slot>] color overrides" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme.heading1]
        \\fg = 81
        \\bold = true
    );

    const ov = cfg.theme_overrides.heading1.?;
    try std.testing.expectEqual(@as(?u8, 81), ov.fg);
    try std.testing.expectEqual(@as(?bool, true), ov.bold);
    try std.testing.expectEqual(@as(?u8, null), ov.bg);
    try std.testing.expectEqual(@as(?bool, null), ov.italic);
    // A slot that was never mentioned stays null.
    try std.testing.expectEqual(@as(?StyleOverride, null), cfg.theme_overrides.body);
}

test "unknown theme slot and unknown key are ignored silently" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme.nope]
        \\fg = 42
        \\[theme.heading2]
        \\mystery = 7
    );

    // Unknown slot never creates an entry, and an unknown key on a known slot
    // leaves every attribute null (the slot is still initialized on match).
    try std.testing.expectEqual(@as(?u8, null), cfg.theme_overrides.heading2.?.fg);
}

test "parses structural-slot overrides" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme.hr]
        \\fg = 200
        \\[theme.table_header]
        \\bold = true
    );

    try std.testing.expectEqual(@as(?u8, 200), cfg.theme_overrides.hr.?.fg);
    try std.testing.expectEqual(@as(?bool, true), cfg.theme_overrides.table_header.?.bold);
}

test "parses [display] structure glyph keys" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\quote_bar = "|"
        \\bullet_glyphs = ["*", "-", "+"]
        \\hr_glyph = "="
        \\task_checked = "[X]"
        \\task_todo = "[_]"
        \\table_border_set = "ascii"
        \\heading_prefix = ">"
    );

    try std.testing.expectEqualStrings("|", cfg.display.quote_bar);
    try std.testing.expectEqual(@as(usize, 3), cfg.display.bullet_glyphs.len);
    try std.testing.expectEqualStrings("*", cfg.display.bullet_glyphs[0]);
    try std.testing.expectEqualStrings("-", cfg.display.bullet_glyphs[1]);
    try std.testing.expectEqualStrings("+", cfg.display.bullet_glyphs[2]);
    try std.testing.expectEqualStrings("=", cfg.display.hr_glyph);
    try std.testing.expectEqualStrings("[X]", cfg.display.task_checked);
    try std.testing.expectEqualStrings("[_]", cfg.display.task_todo);
    try std.testing.expectEqual(TableBorderSet.ascii, cfg.display.table_border_set);
    try std.testing.expectEqualStrings(">", cfg.display.heading_prefix);

    // The ascii border set maps to the plain triple.
    const triple = cfg.display.table_border_set.glyphs();
    try std.testing.expectEqualStrings("-", triple.horizontal);
    try std.testing.expectEqualStrings("|", triple.vertical);
    try std.testing.expectEqualStrings("+", triple.cross);
}

test "display glyph defaults survive the embedded default parse" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("\u{258E}", cfg.display.quote_bar);
    try std.testing.expectEqual(@as(usize, 3), cfg.display.bullet_glyphs.len);
    try std.testing.expectEqualStrings("\u{2022}", cfg.display.bullet_glyphs[0]);
    try std.testing.expectEqualStrings("\u{2500}", cfg.display.hr_glyph);
    try std.testing.expectEqualStrings("[x]", cfg.display.task_checked);
    try std.testing.expectEqualStrings("[ ]", cfg.display.task_todo);
    try std.testing.expectEqual(TableBorderSet.light, cfg.display.table_border_set);
    try std.testing.expectEqualStrings("#", cfg.display.heading_prefix);
}

test "table_border_set parses each variant; invalid errors" {
    try std.testing.expectEqual(TableBorderSet.light, try parseTableBorderSet("light"));
    try std.testing.expectEqual(TableBorderSet.heavy, try parseTableBorderSet("heavy"));
    try std.testing.expectEqual(TableBorderSet.double, try parseTableBorderSet("double"));
    try std.testing.expectEqual(TableBorderSet.ascii, try parseTableBorderSet("ascii"));
    try std.testing.expectError(error.InvalidTableBorderSet, parseTableBorderSet("fancy"));
}

test "a failing apply leaves the config safely deinit-able (no leak/double-free)" {
    // Mirrors load()'s `errdefer cfg.deinit(allocator)`: a user file that fails
    // to parse (here an unparseable width) must leave `cfg` fully owned and
    // freeable. std.testing.allocator flags any leak or double-free.
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidCharacter, applyTomlLike(
        std.testing.allocator,
        &cfg,
        \\[display]
        \\width = notanumber
        ,
    ));
}

test "invalid table_border_set is lenient and keeps the prior value" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    // A bogus value must NOT error (matches the theme-override leniency) and
    // must leave the previously-set value untouched.
    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\table_border_set = "heavy"
        \\table_border_set = "fancy"
    );
    try std.testing.expectEqual(TableBorderSet.heavy, cfg.display.table_border_set);
}

test "empty bracket bullet_glyphs yields a zero-length array" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\bullet_glyphs = []
    );
    // Distinct from a one-element array of "": reaches the renderer's len==0
    // bullet fallback.
    try std.testing.expectEqual(@as(usize, 0), cfg.display.bullet_glyphs.len);
}

test "array split is quote-aware: commas inside quotes do not split" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\bullet_glyphs = ["a,b", "c"]
        \\[files]
        \\extensions = ["md", "x,y"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.display.bullet_glyphs.len);
    try std.testing.expectEqualStrings("a,b", cfg.display.bullet_glyphs[0]);
    try std.testing.expectEqualStrings("c", cfg.display.bullet_glyphs[1]);

    try std.testing.expectEqual(@as(usize, 2), cfg.files.extensions.len);
    try std.testing.expectEqualStrings("md", cfg.files.extensions[0]);
    try std.testing.expectEqualStrings("x,y", cfg.files.extensions[1]);
}

test "theme override fg/bg strip surrounding quotes before parsing" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme.body]
        \\fg = "81"
        \\bg = "16"
    );
    try std.testing.expectEqual(@as(?u8, 81), cfg.theme_overrides.body.?.fg);
    try std.testing.expectEqual(@as(?u8, 16), cfg.theme_overrides.body.?.bg);
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

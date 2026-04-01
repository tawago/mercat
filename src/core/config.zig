const std = @import("std");

pub const Theme = enum { auto, dark, light };
pub const SyntaxTheme = enum { default, classic };

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
    };

    pub const Mermaid = struct {
        enabled: bool = true,
        style: []const u8 = "",
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
        return std.fs.path.join(allocator, &.{ xdg, "mdv", "config.toml" });
    } else |_| {}

    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, ".config", "mdv", "config.toml" });
    } else |_| {}

    return allocator.dupe(u8, ".config/mdv/config.toml");
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
        return;
    }

    if (std.mem.eql(u8, section, "mermaid")) {
        if (std.mem.eql(u8, key, "enabled")) cfg.mermaid.enabled = parseBool(value);
        if (std.mem.eql(u8, key, "style")) try replaceString(allocator, &cfg.mermaid.style, stripQuotes(value));
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
    const width = std.process.getEnvVarOwned(std.heap.page_allocator, "MDV_WIDTH") catch null;
    defer if (width) |value| std.heap.page_allocator.free(value);
    if (width) |value| {
        cfg.display.width = std.fmt.parseUnsigned(usize, value, 10) catch cfg.display.width;
    }

    const theme = std.process.getEnvVarOwned(std.heap.page_allocator, "MDV_THEME") catch null;
    defer if (theme) |value| std.heap.page_allocator.free(value);
    if (theme) |value| {
        cfg.display.theme = parseTheme(value) catch cfg.display.theme;
    }

    const syntax_theme = std.process.getEnvVarOwned(std.heap.page_allocator, "MDV_SYNTAX_THEME") catch null;
    defer if (syntax_theme) |value| std.heap.page_allocator.free(value);
    if (syntax_theme) |value| {
        cfg.display.syntax_theme = parseSyntaxTheme(value) catch cfg.display.syntax_theme;
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
        ,
    );

    try std.testing.expectEqual(Theme.dark, cfg.display.theme);
    try std.testing.expectEqual(SyntaxTheme.classic, cfg.display.syntax_theme);
    try std.testing.expectEqual(@as(usize, 88), cfg.display.width);
    try std.testing.expectEqualStrings("nvim", cfg.general.editor);
}

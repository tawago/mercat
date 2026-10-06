const std = @import("std");
const config = @import("config.zig");

const Warnings = config.Warnings;

fn load(source: []const u8, warnings: *Warnings) !config.Config {
    var cfg = try config.parseTomlLike(std.testing.allocator, config.default_config_text);
    errdefer cfg.deinit(std.testing.allocator);
    try config.applySource(std.testing.allocator, &cfg, source, "/home/u/.config/mercat/config.toml", warnings);
    return cfg;
}

fn expectWarnings(source: []const u8, expected: []const []const u8) !config.Config {
    var warnings = Warnings.init(std.testing.allocator);
    defer warnings.deinit();
    var cfg = try load(source, &warnings);
    errdefer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(expected.len, warnings.items().len);
    for (expected, warnings.items()) |want, got| try std.testing.expectEqualStrings(want, got);
    return cfg;
}

test "invalid width warns with path:line and keeps the default" {
    var cfg = try expectWarnings(
        \\[display]
        \\width = "eighty"
    , &.{"/home/u/.config/mercat/config.toml:2: invalid value \"eighty\" for 'width' in [display] (expected 0 for auto, or an integer from 20 to 1000); keeping the default"});
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cfg.display.width);
}

test "out-of-range width warns" {
    var cfg = try expectWarnings(
        \\[display]
        \\width = 5
    , &.{"/home/u/.config/mercat/config.toml:2: invalid value 5 for 'width' in [display] (expected 0 for auto, or an integer from 20 to 1000); keeping the default"});
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cfg.display.width);
}

test "quoted \"true\"/\"false\" booleans are honored, not silently flipped off" {
    var cfg = try expectWarnings(
        \\[display]
        \\heading_markers = "true"
    , &.{});
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.display.heading_markers);
}

test "non-boolean booleans warn and keep the default" {
    var cfg = try expectWarnings(
        \\[display]
        \\heading_markers = yes
    , &.{"/home/u/.config/mercat/config.toml:2: invalid value yes for 'heading_markers' in [display] (expected true or false); keeping the default"});
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expect(cfg.display.heading_markers);
}

test "unknown key gets a did-you-mean" {
    var cfg = try expectWarnings(
        \\[display]
        \\them = "light"
    , &.{"/home/u/.config/mercat/config.toml:2: unknown key 'them' in [display] (did you mean 'theme'?)"});
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dark", cfg.display.theme);
}

test "unknown section warns once at its header line" {
    var cfg = try expectWarnings(
        \\# comment
        \\[dispaly]
        \\theme = "light"
        \\width = 80
    , &.{"/home/u/.config/mercat/config.toml:2: unknown section [dispaly] (did you mean [display]?); its keys are ignored"});
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dark", cfg.display.theme);
}

test "invalid enum values warn and list the valid ones" {
    var cfg = try expectWarnings(
        \\[display]
        \\frontmatter = "fancy"
        \\color = "sometimes"
        \\[mermaid]
        \\subgraph_edges = "weld"
    , &.{
        "/home/u/.config/mercat/config.toml:2: invalid value \"fancy\" for 'frontmatter' in [display] (expected one of: panel, dim, compact, raw, hidden); keeping the default",
        "/home/u/.config/mercat/config.toml:3: invalid value \"sometimes\" for 'color' in [display] (expected one of: auto, always, never); keeping the default",
        "/home/u/.config/mercat/config.toml:5: invalid value \"weld\" for 'subgraph_edges' in [mermaid] (expected \"bridge\" or \"cross\"); keeping the default",
    });
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.FrontmatterStyle.panel, cfg.display.frontmatter);
    try std.testing.expectEqual(config.ColorMode.auto, cfg.display.color);
}

test "valid keys after a bad one still apply" {
    var warnings = Warnings.init(std.testing.allocator);
    defer warnings.deinit();
    var cfg = try load(
        \\[display]
        \\width = "eighty"
        \\theme = "light"
        \\color = "never"
    , &warnings);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("light", cfg.display.theme);
    try std.testing.expectEqual(config.ColorMode.never, cfg.display.color);
    try std.testing.expectEqualStrings("/home/u/.config/mercat/config.toml:3", cfg.theme_origin);
}

test "legacy keys still load silently" {
    var cfg = try expectWarnings(
        \\[display]
        \\line_numbers = false
        \\[mermaid]
        \\enabled = true
        \\style = "rounded"
        \\[files]
        \\show_hidden = false
        \\extensions = ["md"]
        \\[general]
        \\editor = "nvim"
        \\pager = "less -R"
    , &.{});
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("nvim", cfg.general.editor);
}

test "[theme.*] tables are not reported as unknown sections" {
    var cfg = try expectWarnings(
        \\[theme]
        \\extends = "dracula"
        \\[theme.heading1]
        \\fg = 81
    , &.{});
    defer cfg.deinit(std.testing.allocator);
}

test "a key outside any section warns" {
    var cfg = try expectWarnings(
        \\theme = "light"
    , &.{"/home/u/.config/mercat/config.toml:1: key 'theme' is outside any section (did you mean to put it under [display]?)"});
    defer cfg.deinit(std.testing.allocator);
}

const FakeEnv = struct {
    var width: ?[]const u8 = null;
    var theme: ?[]const u8 = null;
    var frontmatter: ?[]const u8 = null;
    var edges: ?[]const u8 = null;

    fn get(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "MERCAT_WIDTH")) return width;
        if (std.mem.eql(u8, name, "MERCAT_THEME")) return theme;
        if (std.mem.eql(u8, name, "MERCAT_FRONTMATTER")) return frontmatter;
        if (std.mem.eql(u8, name, "MERCAT_SUBGRAPH_EDGES")) return edges;
        return null;
    }
};

test "invalid env values warn and are ignored; valid ones apply" {
    var warnings = Warnings.init(std.testing.allocator);
    defer warnings.deinit();
    var cfg = try config.parseTomlLike(std.testing.allocator, config.default_config_text);
    defer cfg.deinit(std.testing.allocator);

    FakeEnv.width = "abc";
    FakeEnv.theme = "pink";
    FakeEnv.frontmatter = "fancy";
    FakeEnv.edges = "cross";
    defer {
        FakeEnv.width = null;
        FakeEnv.theme = null;
        FakeEnv.frontmatter = null;
        FakeEnv.edges = null;
    }
    try config.applyEnv(std.testing.allocator, &cfg, &warnings, FakeEnv.get);

    try std.testing.expectEqual(@as(usize, 2), warnings.items().len);
    try std.testing.expectEqualStrings("ignoring MERCAT_WIDTH='abc' (expected 0 for auto, or an integer from 20 to 1000)", warnings.items()[0]);
    try std.testing.expectEqualStrings("ignoring MERCAT_FRONTMATTER='fancy' (expected one of: panel, dim, compact, raw, hidden)", warnings.items()[1]);
    try std.testing.expectEqual(@as(usize, 0), cfg.display.width);
    try std.testing.expectEqualStrings("pink", cfg.display.theme);
    try std.testing.expectEqualStrings("MERCAT_THEME", cfg.theme_origin);
    try std.testing.expectEqual(config.FrontmatterStyle.panel, cfg.display.frontmatter);
}

test "parseBool and parseWidthValue" {
    try std.testing.expectEqual(@as(?bool, true), config.parseBool("true"));
    try std.testing.expectEqual(@as(?bool, false), config.parseBool("\"false\""));
    try std.testing.expectEqual(@as(?bool, null), config.parseBool("TRUE"));
    try std.testing.expectEqual(@as(?bool, null), config.parseBool("1"));
    try std.testing.expectEqual(@as(?usize, 0), config.parseWidthValue("0"));
    try std.testing.expectEqual(@as(?usize, 80), config.parseWidthValue("\"80\""));
    try std.testing.expectEqual(@as(?usize, null), config.parseWidthValue("19"));
    try std.testing.expectEqual(@as(?usize, null), config.parseWidthValue("eighty"));
}

test "the embedded default config loads without warnings" {
    var cfg = try expectWarnings(config.default_config_text, &.{});
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(config.ColorMode.auto, cfg.display.color);
}

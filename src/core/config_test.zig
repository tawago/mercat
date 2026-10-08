const std = @import("std");
const SubgraphEdges = @import("mermaid/mermaid.zig").SubgraphEdges;
const config = @import("config.zig");
const loadfile = @import("theme/loadfile.zig");

const parseTomlLike = config.parseTomlLike;
const applyTomlLike = config.applyTomlLike;
const decodeQuotedString = loadfile.decodeQuotedString;
const default_config_text = config.default_config_text;
const SyntaxTheme = config.SyntaxTheme;
const FrontmatterStyle = config.FrontmatterStyle;

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
        \\width = 88 # columns
        \\line_numbers = true # x
        \\[general]
        \\editor = "nvim" # my editor
        \\[mermaid]
        \\subgraph_edges = "cross"
        ,
    );

    try std.testing.expectEqualStrings("dark", cfg.display.theme);
    try std.testing.expectEqual(SyntaxTheme.classic, cfg.display.syntax_theme);
    try std.testing.expectEqual(@as(usize, 88), cfg.display.width);
    try std.testing.expectEqualStrings("nvim", cfg.general.editor);
    try std.testing.expectEqual(SubgraphEdges.cross, cfg.mermaid.subgraph_edges);
    try std.testing.expectEqual(FrontmatterStyle.dim, cfg.display.frontmatter);
    try std.testing.expect(cfg.display.line_numbers);
}

test "frontmatter: file value is stripped of quotes before enum parse, quoted and bare both apply" {
    var quoted = try parseTomlLike(std.testing.allocator, default_config_text);
    defer quoted.deinit(std.testing.allocator);
    try applyTomlLike(std.testing.allocator, &quoted,
        \\[display]
        \\frontmatter = "compact"
    );
    try std.testing.expectEqual(FrontmatterStyle.compact, quoted.display.frontmatter);

    var bare = try parseTomlLike(std.testing.allocator, default_config_text);
    defer bare.deinit(std.testing.allocator);
    try applyTomlLike(std.testing.allocator, &bare,
        \\[display]
        \\frontmatter = raw
    );
    try std.testing.expectEqual(FrontmatterStyle.raw, bare.display.frontmatter);
}

test "[theme] and [theme.x] sections route into raw_theme alongside [display]" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme]
        \\extends = "dark"
        \\[theme.heading1]
        \\fg = "#ff0000"
        \\bold = true
        \\prefix = "> "
        \\[display]
        \\theme = "light"
    );

    try std.testing.expectEqualStrings("light", cfg.display.theme);
    try std.testing.expectEqual(@as(usize, 1), cfg.raw_theme.top.items.len);
    try std.testing.expectEqualStrings("extends", cfg.raw_theme.top.items[0].key);
    try std.testing.expectEqualStrings("dark", cfg.raw_theme.top.items[0].value);
    try std.testing.expectEqual(@as(usize, 1), cfg.raw_theme.slots.items.len);
    try std.testing.expectEqualStrings("heading1", cfg.raw_theme.slots.items[0].name);
    try std.testing.expectEqual(@as(usize, 3), cfg.raw_theme.slots.items[0].kvs.items.len);
    try std.testing.expectEqualStrings("> ", cfg.raw_theme.slots.items[0].kvs.items[2].value);
}

test "a `#` inside quotes is literal, including after an escaped quote" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[general]
        \\editor = "a\"#b" # trailing comment
    );

    try std.testing.expectEqualStrings("a\"#b", cfg.general.editor);
}

test "string values decode TOML escape sequences" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[general]
        \\editor = "tab\there\nline"
        \\pager = "\u2713 \\ done"
    );

    try std.testing.expectEqualStrings("tab\there\nline", cfg.general.editor);
    try std.testing.expectEqualStrings("\u{2713} \\ done", cfg.general.pager);
}

test "unknown and malformed escapes keep the backslash verbatim" {
    const alloc = std.testing.allocator;
    const kept = try decodeQuotedString(alloc, "\"a\\qb\"");
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("a\\qb", kept);

    const truncated = try decodeQuotedString(alloc, "\"\\u12\"");
    defer alloc.free(truncated);
    try std.testing.expectEqualStrings("\\u12", truncated);
}

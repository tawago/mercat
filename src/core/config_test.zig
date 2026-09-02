//! Tests for config.zig (split out to keep the module under the
//! line-count limit).
const std = @import("std");
const prim = @import("prim");
const config = @import("config.zig");
const loadfile = @import("theme/loadfile.zig");

const parseTomlLike = config.parseTomlLike;
const applyTomlLike = config.applyTomlLike;
const parseFrontmatterStyle = config.parseFrontmatterStyle;
const parseSubgraphEdges = config.parseSubgraphEdges;
const decodeQuotedString = loadfile.decodeQuotedString;
const default_config_text = config.default_config_text;
const SyntaxTheme = config.SyntaxTheme;
const FrontmatterStyle = config.FrontmatterStyle;

test "parses default config" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("dark", cfg.display.theme);
    try std.testing.expectEqual(SyntaxTheme.default, cfg.display.syntax_theme);
    try std.testing.expectEqualStrings("vim", cfg.general.editor);
    try std.testing.expect(cfg.mermaid.enabled);
    try std.testing.expect(cfg.display.heading_markers);
    try std.testing.expectEqual(FrontmatterStyle.panel, cfg.display.frontmatter);
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

    try std.testing.expectEqualStrings("dark", cfg.display.theme);
    try std.testing.expectEqual(SyntaxTheme.classic, cfg.display.syntax_theme);
    try std.testing.expectEqual(@as(usize, 88), cfg.display.width);
    try std.testing.expectEqualStrings("nvim", cfg.general.editor);
    try std.testing.expectEqual(prim.SubgraphEdges.cross, cfg.mermaid.subgraph_edges);
    try std.testing.expectEqual(FrontmatterStyle.dim, cfg.display.frontmatter);
}

test "theme is a free-form name (preset names pass through unvalidated)" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);
    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\theme = "pink"
    );
    try std.testing.expectEqualStrings("pink", cfg.display.theme);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\theme = "not-a-real-theme"
    );
    try std.testing.expectEqualStrings("not-a-real-theme", cfg.display.theme);
}

test "frontmatter style parses every notation; invalid errors" {
    try std.testing.expectEqual(FrontmatterStyle.panel, try parseFrontmatterStyle("panel"));
    try std.testing.expectEqual(FrontmatterStyle.dim, try parseFrontmatterStyle("dim"));
    try std.testing.expectEqual(FrontmatterStyle.compact, try parseFrontmatterStyle("compact"));
    try std.testing.expectEqual(FrontmatterStyle.raw, try parseFrontmatterStyle("raw"));
    try std.testing.expectEqual(FrontmatterStyle.hidden, try parseFrontmatterStyle("hidden"));
    try std.testing.expectError(error.InvalidFrontmatterStyle, parseFrontmatterStyle("fancy"));
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

test "frontmatter: invalid value in a config file surfaces the error instead of defaulting" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidFrontmatterStyle, applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\frontmatter = "fancy"
    ));
    try std.testing.expectEqual(FrontmatterStyle.panel, cfg.display.frontmatter);
}

test "inline [theme.heading1] collects raw KVs under the slot" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme.heading1]
        \\fg = "#ff0000"
        \\bold = true
        \\prefix = "> "
    );

    try std.testing.expectEqual(@as(usize, 1), cfg.raw_theme.slots.items.len);
    try std.testing.expectEqualStrings("heading1", cfg.raw_theme.slots.items[0].name);
    try std.testing.expectEqual(@as(usize, 3), cfg.raw_theme.slots.items[0].kvs.items.len);
    try std.testing.expectEqualStrings("#ff0000", cfg.raw_theme.slots.items[0].kvs.items[0].value);
    try std.testing.expectEqualStrings("> ", cfg.raw_theme.slots.items[0].kvs.items[2].value);
}

test "top-level [theme] extends lands in raw_theme.top; [display] still routes flat" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme]
        \\extends = "dark"
        \\[display]
        \\theme = "light"
    );

    try std.testing.expectEqualStrings("light", cfg.display.theme);
    try std.testing.expectEqual(@as(usize, 1), cfg.raw_theme.top.items.len);
    try std.testing.expectEqualStrings("extends", cfg.raw_theme.top.items[0].key);
    try std.testing.expectEqualStrings("dark", cfg.raw_theme.top.items[0].value);
    try std.testing.expectEqual(@as(usize, 0), cfg.raw_theme.slots.items.len);
}

test "repeated inline [theme.link] blocks merge last-wins" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme.link]
        \\fg = "#111111"
        \\[theme.link]
        \\fg = "#222222"
    );

    try std.testing.expectEqual(@as(usize, 1), cfg.raw_theme.slots.items.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.raw_theme.slots.items[0].kvs.items.len);
    try std.testing.expectEqualStrings("#222222", cfg.raw_theme.slots.items[0].kvs.items[0].value);
}

test "default config produces an empty raw_theme" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), cfg.raw_theme.top.items.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.raw_theme.slots.items.len);
}

test "subgraph_edges parses both notations; bridge round-trips; invalid errors" {
    try std.testing.expectEqual(prim.SubgraphEdges.bridge, try parseSubgraphEdges("bridge"));
    try std.testing.expectEqual(prim.SubgraphEdges.cross, try parseSubgraphEdges("cross"));
    try std.testing.expectError(error.InvalidSubgraphEdges, parseSubgraphEdges("weld"));

    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);
    try applyTomlLike(std.testing.allocator, &cfg,
        \\[mermaid]
        \\subgraph_edges = "bridge"
    );
    try std.testing.expectEqual(prim.SubgraphEdges.bridge, cfg.mermaid.subgraph_edges);
}

test "inline comments are stripped from config values" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\width = 80 # columns
        \\line_numbers = true # x
        \\[general]
        \\editor = "nvim" # my editor
    );

    try std.testing.expectEqual(@as(usize, 80), cfg.display.width);
    try std.testing.expect(cfg.display.line_numbers);
    try std.testing.expectEqualStrings("nvim", cfg.general.editor);
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

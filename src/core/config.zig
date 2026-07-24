const std = @import("std");
const prim = @import("prim");

pub const Theme = enum { dark, light };
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
        theme: Theme = .dark,
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

    // Dupe every heap-owned Display string from a default-constructed Display's
    // own defaults, so this init cannot drift from the struct field defaults.
    const default_display = Config.Display{};
    var bullets = try allocator.alloc([]const u8, default_display.bullet_glyphs.len);
    for (default_display.bullet_glyphs, 0..) |glyph, index| {
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
            .quote_bar = try allocator.dupe(u8, default_display.quote_bar),
            .bullet_glyphs = bullets,
            .hr_glyph = try allocator.dupe(u8, default_display.hr_glyph),
            .task_checked = try allocator.dupe(u8, default_display.task_checked),
            .task_todo = try allocator.dupe(u8, default_display.task_todo),
            .heading_prefix = try allocator.dupe(u8, default_display.heading_prefix),
            .table_border_set = default_display.table_border_set,
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
        // Strip any inline `# comment` before dispatching, so documented lines
        // like `theme = "dark"  # dark, light` reach the field parsers as
        // just the value. Quote-aware so a `#` inside a string (heading_prefix)
        // stays literal (see stripInlineComment).
        const value = stripInlineComment(std.mem.trim(u8, trimmed[equals_index + 1 ..], " \t"));
        try assignValue(allocator, cfg, section, key, value);
    }
}

fn assignValue(allocator: std.mem.Allocator, cfg: *Config, section: []const u8, key: []const u8, value: []const u8) !void {
    if (std.mem.startsWith(u8, section, "theme.")) {
        assignThemeOverride(cfg, section["theme.".len..], key, value);
        return;
    }

    if (std.mem.eql(u8, section, "general")) {
        if (std.mem.eql(u8, key, "editor")) try replaceString(allocator, &cfg.general.editor, value);
        if (std.mem.eql(u8, key, "pager")) try replaceString(allocator, &cfg.general.pager, value);
        return;
    }

    if (std.mem.eql(u8, section, "display")) {
        if (std.mem.eql(u8, key, "theme")) {
            if (parseTheme(stripQuotes(value))) |t| cfg.display.theme = t;
        }
        if (std.mem.eql(u8, key, "syntax_theme")) {
            if (parseSyntaxTheme(stripQuotes(value))) |t| cfg.display.syntax_theme = t;
        }
        if (std.mem.eql(u8, key, "width")) cfg.display.width = try std.fmt.parseUnsigned(usize, value, 10);
        if (std.mem.eql(u8, key, "line_numbers")) {
            if (parseBool(value)) |b| cfg.display.line_numbers = b;
        }
        if (std.mem.eql(u8, key, "heading_markers")) {
            if (parseBool(value)) |b| cfg.display.heading_markers = b;
        }
        if (std.mem.eql(u8, key, "quote_bar")) try replaceString(allocator, &cfg.display.quote_bar, value);
        if (std.mem.eql(u8, key, "bullet_glyphs")) try replaceStringArray(allocator, &cfg.display.bullet_glyphs, value);
        if (std.mem.eql(u8, key, "hr_glyph")) try replaceString(allocator, &cfg.display.hr_glyph, value);
        if (std.mem.eql(u8, key, "task_checked")) try replaceString(allocator, &cfg.display.task_checked, value);
        if (std.mem.eql(u8, key, "task_todo")) try replaceString(allocator, &cfg.display.task_todo, value);
        if (std.mem.eql(u8, key, "table_border_set")) cfg.display.table_border_set = parseTableBorderSet(stripQuotes(value)) catch return;
        if (std.mem.eql(u8, key, "heading_prefix")) try replaceString(allocator, &cfg.display.heading_prefix, value);
        if (std.mem.eql(u8, key, "frontmatter")) cfg.display.frontmatter = try parseFrontmatterStyle(stripQuotes(value));
        return;
    }

    if (std.mem.eql(u8, section, "mermaid")) {
        if (std.mem.eql(u8, key, "enabled")) {
            if (parseBool(value)) |b| cfg.mermaid.enabled = b;
        }
        if (std.mem.eql(u8, key, "style")) try replaceString(allocator, &cfg.mermaid.style, value);
        if (std.mem.eql(u8, key, "subgraph_edges")) cfg.mermaid.subgraph_edges = try parseSubgraphEdges(stripQuotes(value));
        return;
    }

    if (std.mem.eql(u8, section, "files")) {
        if (std.mem.eql(u8, key, "show_hidden")) {
            if (parseBool(value)) |b| cfg.files.show_hidden = b;
        }
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
                if (parseBool(value)) |b| ov.bold = b;
            } else if (std.mem.eql(u8, key, "italic")) {
                if (parseBool(value)) |b| ov.italic = b;
            } else if (std.mem.eql(u8, key, "underline")) {
                if (parseBool(value)) |b| ov.underline = b;
            } else if (std.mem.eql(u8, key, "strikethrough")) {
                if (parseBool(value)) |b| ov.strikethrough = b;
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
        if (in_quotes and ch == '\\') {
            i += 1; // skip the escaped char so a \" does not toggle quote state
            continue;
        }
        if (ch == '"') {
            in_quotes = !in_quotes;
        } else if (ch == ',' and !in_quotes) {
            items[index] = try decodeQuotedString(allocator, std.mem.trim(u8, trimmed[start..i], " \t"));
            index += 1;
            start = i + 1;
        }
    }
    items[index] = try decodeQuotedString(allocator, std.mem.trim(u8, trimmed[start..], " \t"));
    index += 1;

    for (target.*) |item| allocator.free(item);
    allocator.free(target.*);
    target.* = items;
}

/// Count comma-separated elements, ignoring commas inside double quotes.
fn countArrayElements(trimmed: []const u8) usize {
    var count: usize = 1;
    var in_quotes = false;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const ch = trimmed[i];
        if (in_quotes and ch == '\\') {
            i += 1; // skip the escaped char so a \" does not toggle quote state
            continue;
        }
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

/// Unknown values yield null so callers leave the current/default value
/// untouched, matching the parser's leniency for bad booleans and fg/bg.
fn parseTheme(value: []const u8) ?Theme {
    if (std.mem.eql(u8, value, "dark")) return .dark;
    if (std.mem.eql(u8, value, "light")) return .light;
    return null;
}

fn parseSyntaxTheme(value: []const u8) ?SyntaxTheme {
    if (std.mem.eql(u8, value, "default")) return .default;
    if (std.mem.eql(u8, value, "classic")) return .classic;
    return null;
}

fn parseSubgraphEdges(value: []const u8) !prim.SubgraphEdges {
    if (std.mem.eql(u8, value, "bridge")) return .bridge;
    if (std.mem.eql(u8, value, "cross")) return .cross;
    return error.InvalidSubgraphEdges;
}

/// Strip an inline TOML comment from an already-trimmed value: a `#` outside a
/// double-quoted string begins a comment; inside quotes it is literal (so
/// `heading_prefix = "#"` keeps its glyph). Quote tracking is escape-aware — a
/// `\"` inside a string does not end the string and expose a following `#`.
/// Whitespace between the value and the comment is trimmed off.
fn stripInlineComment(value: []const u8) []const u8 {
    var in_quotes = false;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const ch = value[i];
        if (in_quotes and ch == '\\') {
            i += 1; // skip the escaped char so a \" cannot toggle quote state
            continue;
        }
        if (ch == '"') {
            in_quotes = !in_quotes;
        } else if (ch == '#' and !in_quotes) {
            return std.mem.trim(u8, value[0..i], " \t");
        }
    }
    return value;
}

/// Parse a TOML boolean. Only the exact literals `true`/`false` are recognized;
/// anything else yields null so callers can leave the target attribute
/// untouched (matching the "unparseable scalar values leave the attribute
/// untouched" contract) rather than silently coercing to false.
fn parseBool(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return null;
}

fn parseFrontmatterStyle(value: []const u8) !FrontmatterStyle {
    return std.meta.stringToEnum(FrontmatterStyle, value) orelse error.InvalidFrontmatterStyle;
}

fn stripQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

/// Strip surrounding quotes and decode the basic TOML escape sequences a string
/// value may contain: \" \\ \n \t \r \uXXXX \UXXXXXXXX. Returns freshly-owned
/// bytes the caller must free. A malformed or unknown escape is kept verbatim
/// (backslash preserved) — this is a deliberately small TOML-like parser, not a
/// validator. Decoded output is never longer than the input (every escape
/// shrinks: \n's two chars -> 1 byte, \uXXXX's six -> at most 3 UTF-8 bytes,
/// \U's ten -> at most 4), so a single input-sized buffer always suffices.
fn decodeQuotedString(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const inner = stripQuotes(raw);
    var buf = try allocator.alloc(u8, inner.len);
    errdefer allocator.free(buf);

    var len: usize = 0;
    var i: usize = 0;
    while (i < inner.len) {
        const ch = inner[i];
        if (ch != '\\' or i + 1 >= inner.len) {
            buf[len] = ch;
            len += 1;
            i += 1;
            continue;
        }
        switch (inner[i + 1]) {
            '"' => {
                buf[len] = '"';
                len += 1;
                i += 2;
            },
            '\\' => {
                buf[len] = '\\';
                len += 1;
                i += 2;
            },
            'n' => {
                buf[len] = '\n';
                len += 1;
                i += 2;
            },
            't' => {
                buf[len] = '\t';
                len += 1;
                i += 2;
            },
            'r' => {
                buf[len] = '\r';
                len += 1;
                i += 2;
            },
            'u', 'U' => {
                const digits: usize = if (inner[i + 1] == 'u') 4 else 8;
                const decoded = decodeUnicodeEscape(inner[i..], digits, buf[len..]);
                if (decoded) |n| {
                    len += n;
                    i += 2 + digits;
                } else {
                    // Malformed \u/\U: keep the backslash literal and move on.
                    buf[len] = ch;
                    len += 1;
                    i += 1;
                }
            },
            else => {
                // Unknown escape: keep the backslash literal (lenient).
                buf[len] = ch;
                len += 1;
                i += 1;
            },
        }
    }

    if (len == buf.len) return buf;
    return allocator.realloc(buf, len);
}

/// Decode a `\uXXXX`/`\UXXXXXXXX` escape at the start of `seq` (which points at
/// the leading backslash), writing the UTF-8 encoding into `out`. `digits` is 4
/// or 8. Returns the number of bytes written, or null if the escape is
/// truncated, not valid hex, or not a valid Unicode scalar.
fn decodeUnicodeEscape(seq: []const u8, digits: usize, out: []u8) ?usize {
    if (seq.len < 2 + digits) return null;
    const code = std.fmt.parseInt(u21, seq[2 .. 2 + digits], 16) catch return null;
    return std.unicode.utf8Encode(code, out) catch null;
}

fn replaceString(allocator: std.mem.Allocator, target: *[]const u8, value: []const u8) !void {
    // Decode into a fresh allocation first so an OOM leaves the prior value
    // intact (no dangling pointer, no double-free): only free the old value once
    // the new allocation has succeeded. `value` is the raw TOML value — quotes
    // are stripped and escapes decoded here.
    const dup = try decodeQuotedString(allocator, value);
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
        cfg.display.theme = parseTheme(value) orelse cfg.display.theme;
    }

    const syntax_theme = std.process.getEnvVarOwned(std.heap.page_allocator, "MERCAT_SYNTAX_THEME") catch null;
    defer if (syntax_theme) |value| std.heap.page_allocator.free(value);
    if (syntax_theme) |value| {
        cfg.display.syntax_theme = parseSyntaxTheme(value) orelse cfg.display.syntax_theme;
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

    try std.testing.expectEqual(Theme.dark, cfg.display.theme);
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
    try std.testing.expectEqual(FrontmatterStyle.raw, try parseFrontmatterStyle("raw"));
    try std.testing.expectEqual(FrontmatterStyle.hidden, try parseFrontmatterStyle("hidden"));
    // The env-override path (`catch <old>`) keeps the prior value on typos.
    try std.testing.expectError(error.InvalidFrontmatterStyle, parseFrontmatterStyle("fancy"));
}

test "frontmatter: file value is stripped of quotes before enum parse, quoted and bare both apply" {
    // The TOML-like parser hands the raw right-hand side to assignValue: a
    // double-quoted scalar keeps its quotes (`"compact"`), a bare word does not
    // (`raw`). Both must reach the same enum tag, proving stripQuotes runs
    // ahead of parseFrontmatterStyle on the file path.
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
    // Unlike the env-override path (`catch <old>`), the file path propagates a
    // bad value as error.InvalidFrontmatterStyle rather than silently keeping
    // the default. The style must stay untouched when the error is returned.
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidFrontmatterStyle, applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\frontmatter = "fancy"
    ));
    try std.testing.expectEqual(FrontmatterStyle.panel, cfg.display.frontmatter);
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

test "invalid theme and syntax_theme are lenient and keep the default" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    // "auto" is no longer a valid theme (dark/light auto-detection was
    // dropped); like any unknown value it must NOT error and must leave the
    // default (dark) in place.
    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\theme = "bogus"
        \\syntax_theme = "bogus"
    );
    try std.testing.expectEqual(Theme.dark, cfg.display.theme);
    try std.testing.expectEqual(SyntaxTheme.default, cfg.display.syntax_theme);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\theme = "auto"
    );
    try std.testing.expectEqual(Theme.dark, cfg.display.theme);
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

test "README example config parses verbatim (inline comments stripped)" {
    // The exact commented block from README.md must load without erroring and
    // must not corrupt the trailing array element (F1 regression guard).
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[general]
        \\editor = "vim"
        \\pager = "less -R"
        \\
        \\[display]
        \\theme = "dark"       # dark, light
        \\width = 0            # 0 = terminal width
        \\heading_markers = true
        \\
        \\# Structural glyphs (a trailing space is appended after markers automatically)
        \\quote_bar = "▎"
        \\bullet_glyphs = ["•", "◦", "‣"]   # cycled by nesting depth
        \\hr_glyph = "─"
        \\task_checked = "[x]"
        \\task_todo = "[ ]"
        \\table_border_set = "light"        # light, heavy, double, ascii
        \\heading_prefix = "#"
        \\
        \\[files]
        \\extensions = ["md", "markdown", "mdown", "mkd"]
    );

    try std.testing.expectEqual(Theme.dark, cfg.display.theme);
    try std.testing.expectEqual(@as(usize, 0), cfg.display.width);
    try std.testing.expect(cfg.display.heading_markers);
    try std.testing.expectEqualStrings("vim", cfg.general.editor);
    try std.testing.expectEqualStrings("▎", cfg.display.quote_bar);
    try std.testing.expectEqual(@as(usize, 3), cfg.display.bullet_glyphs.len);
    try std.testing.expectEqualStrings("•", cfg.display.bullet_glyphs[0]);
    try std.testing.expectEqualStrings("◦", cfg.display.bullet_glyphs[1]);
    // The trailing element must survive intact — before F1 the unstripped
    // `# comment` fused onto or replaced this glyph.
    try std.testing.expectEqualStrings("‣", cfg.display.bullet_glyphs[2]);
    try std.testing.expectEqual(TableBorderSet.light, cfg.display.table_border_set);
    // A `#` inside quotes is literal, not a comment introducer.
    try std.testing.expectEqualStrings("#", cfg.display.heading_prefix);
}

test "inline comment stripping is quote-aware" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\heading_prefix = "#"      # kept: the # inside quotes is literal
        \\quote_bar = "a#b"         # kept whole; only the outside # is a comment
    );
    try std.testing.expectEqualStrings("#", cfg.display.heading_prefix);
    try std.testing.expectEqualStrings("a#b", cfg.display.quote_bar);
}

test "boolean contract: unrecognized value leaves the attribute untouched" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    // `bold = tru` must NOT write an explicit false override; the attribute
    // stays null (F2). A trailing comment on a valid value still sets it.
    try applyTomlLike(std.testing.allocator, &cfg,
        \\[theme.heading1]
        \\bold = tru
        \\[theme.heading2]
        \\bold = true # c
        \\[theme.heading3]
        \\bold = false
    );
    try std.testing.expectEqual(@as(?bool, null), cfg.theme_overrides.heading1.?.bold);
    try std.testing.expectEqual(@as(?bool, true), cfg.theme_overrides.heading2.?.bold);
    try std.testing.expectEqual(@as(?bool, false), cfg.theme_overrides.heading3.?.bold);
}

test "parseBool only recognizes the exact true/false literals" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("true"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("false"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("tru"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("True"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("1"));
    try std.testing.expectEqual(@as(?bool, null), parseBool(""));
}

test "string escapes decode: unicode escape and escaped quotes in arrays" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[display]
        \\quote_bar = "\u2502"
        \\bullet_glyphs = ["\"", "a\tb", "‣"]
    );
    // The │ escape decodes to the light vertical bar │.
    try std.testing.expectEqualStrings("\u{2502}", cfg.display.quote_bar);
    try std.testing.expectEqual(@as(usize, 3), cfg.display.bullet_glyphs.len);
    // A `\"` is one literal double-quote and does NOT toggle quote state, so it
    // neither splits the array nor ends the element early (F3).
    try std.testing.expectEqualStrings("\"", cfg.display.bullet_glyphs[0]);
    try std.testing.expectEqualStrings("a\tb", cfg.display.bullet_glyphs[1]);
    try std.testing.expectEqualStrings("\u{2023}", cfg.display.bullet_glyphs[2]);
}

test "malformed escapes are kept verbatim (lenient)" {
    var cfg = try parseTomlLike(std.testing.allocator, default_config_text);
    defer cfg.deinit(std.testing.allocator);

    try applyTomlLike(std.testing.allocator, &cfg,
        \\[general]
        \\editor = "a\qb"
        \\pager = "c\u12"
    );
    // Unknown escape \q and truncated \u12 keep their backslash rather than
    // erroring — this is a small TOML-like parser, not a validator.
    try std.testing.expectEqualStrings("a\\qb", cfg.general.editor);
    try std.testing.expectEqualStrings("c\\u12", cfg.general.pager);
}

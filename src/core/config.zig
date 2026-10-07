const std = @import("std");
const SubgraphEdges = @import("mermaid/mermaid.zig").SubgraphEdges;
const suggest = @import("suggest.zig");
pub const loadfile = @import("theme/loadfile.zig");
pub const RawThemeBuilder = loadfile.RawThemeBuilder;

pub const SyntaxTheme = enum { default, classic };
pub const FrontmatterStyle = enum { panel, dim, compact, raw, hidden };
pub const ColorMode = enum { auto, always, never };

/// Width bounds shared by the CLI and config: 0 means "auto"; anything else
/// must fall in min_width..max_width.
pub const min_width: usize = 20;
pub const max_width: usize = 1000;

pub fn widthInRange(value: usize) bool {
    return value == 0 or (value >= min_width and value <= max_width);
}

pub const Config = struct {
    general: General = .{},
    display: Display = .{},
    mermaid: Mermaid = .{},
    files: Files = .{},
    raw_theme: RawThemeBuilder = .{},
    /// Where `display.theme` came from ("MERCAT_THEME", "path:line"), or ""
    /// for the built-in default. Lets callers attribute an unknown theme.
    theme_origin: []const u8 = "",

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.general.editor);
        allocator.free(self.general.pager);
        allocator.free(self.display.theme);
        allocator.free(self.mermaid.style);
        for (self.files.extensions) |extension| allocator.free(extension);
        allocator.free(self.files.extensions);
        self.raw_theme.deinit(allocator);
        allocator.free(self.theme_origin);
    }

    pub const General = struct {
        editor: []const u8 = "",
        pager: []const u8 = "",
    };

    pub const Display = struct {
        theme: []const u8 = "dark",
        syntax_theme: SyntaxTheme = .default,
        width: usize = 0,
        /// Legacy key: parsed so old configs load, not used by any renderer.
        line_numbers: bool = false,
        heading_markers: bool = true,
        frontmatter: FrontmatterStyle = .panel,
        color: ColorMode = .auto,
    };

    /// `enabled` and `style` are legacy keys: parsed so old configs load,
    /// not used by any renderer.
    pub const Mermaid = struct {
        enabled: bool = true,
        style: []const u8 = "",
        subgraph_edges: SubgraphEdges = .bridge,
    };

    /// Legacy section: parsed so old configs load, not used by any renderer.
    pub const Files = struct {
        show_hidden: bool = false,
        extensions: []const []const u8 = &.{},
    };
};

/// Non-fatal problems found while loading config and environment. Each entry
/// is a complete message ("path:3: unknown key …"). Allocation failures drop
/// the message rather than failing the run.
pub const Warnings = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Warnings {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Warnings) void {
        for (self.list.items) |msg| self.alloc.free(msg);
        self.list.deinit(self.alloc);
    }

    pub fn add(self: *Warnings, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        self.list.append(self.alloc, msg) catch self.alloc.free(msg);
    }

    pub fn items(self: *const Warnings) []const []const u8 {
        return self.list.items;
    }
};

pub const default_config_text = @embedFile("default_config.toml");

/// Loads defaults, then the user config file, then environment overrides.
/// Never fails on bad user input: problems become `warnings` and the
/// affected setting keeps its previous value.
pub fn load(allocator: std.mem.Allocator, warnings: *Warnings) !Config {
    var cfg = try parseTomlLike(allocator, default_config_text);
    errdefer cfg.deinit(allocator);

    const path = try resolveConfigPath(allocator);
    defer allocator.free(path);

    if (readConfigFile(allocator, path)) |contents| {
        defer allocator.free(contents);
        try applySource(allocator, &cfg, contents, path, warnings);
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.OutOfMemory => return error.OutOfMemory,
        else => warnings.add("cannot read config file {s}: {s}; using defaults", .{ path, readErrorText(err) }),
    }

    try applyEnvOverrides(allocator, &cfg, warnings);
    return cfg;
}

fn readConfigFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024);
}

fn readErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.FileTooBig, error.StreamTooLong => "file is too large",
        error.NameTooLong => "file name too long",
        error.NotDir => "not a directory",
        error.SymLinkLoop => "too many levels of symbolic links",
        else => "read error",
    };
}

pub fn resolveConfigPath(allocator: std.mem.Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME")) |xdg| {
        defer allocator.free(xdg);
        if (xdg.len != 0) return std.fs.path.join(allocator, &.{ xdg, "mercat", "config.toml" });
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
            .editor = try allocator.dupe(u8, ""),
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
        .theme_origin = try allocator.dupe(u8, ""),
    };
}

/// Applies config text without reporting problems (invalid values are skipped).
pub fn applyTomlLike(allocator: std.mem.Allocator, cfg: *Config, source: []const u8) !void {
    try applySource(allocator, cfg, source, "", null);
}

/// Applies config text from `origin` (a path, used in messages). Unknown
/// sections and keys and invalid values are reported to `warnings` as
/// "origin:line: …" and otherwise ignored. Only allocation failure errors.
pub fn applySource(
    allocator: std.mem.Allocator,
    cfg: *Config,
    source: []const u8,
    origin: []const u8,
    warnings: ?*Warnings,
) !void {
    var ctx = Context{ .origin = origin, .warnings = warnings };
    var scanner = loadfile.scanLines(source, "");
    while (scanner.next()) |event| {
        if (event.malformed) |kind| {
            ctx.line = event.line;
            ctx.warn("cannot parse line ({s})", .{kind.reason()});
            continue;
        }
        if (std.mem.eql(u8, event.table, "theme")) {
            try loadfile.assignThemeValue(allocator, &cfg.raw_theme, event.subtable, event.key, event.value);
            continue;
        }
        ctx.line = event.line;
        const section = sectionOf(event.section) orelse {
            if (event.section_line != ctx.warned_section_line) {
                ctx.warned_section_line = event.section_line;
                ctx.line = event.section_line;
                if (suggest.closest(event.section, &section_names)) |s| {
                    ctx.warn("unknown section [{s}] (did you mean [{s}]?); its keys are ignored", .{ event.section, s });
                } else {
                    ctx.warn("unknown section [{s}]; its keys are ignored", .{event.section});
                }
            }
            continue;
        };
        try assignValue(allocator, cfg, &ctx, section, event.key, event.value);
    }
}

const Section = enum { top, general, display, mermaid, files };
const section_names = [_][]const u8{ "general", "display", "mermaid", "files", "theme" };

fn sectionOf(name: []const u8) ?Section {
    if (name.len == 0) return .top;
    if (std.mem.eql(u8, name, "top")) return null;
    return std.meta.stringToEnum(Section, name);
}

const general_keys = [_][]const u8{ "editor", "pager" };
const display_keys = [_][]const u8{ "theme", "syntax_theme", "width", "line_numbers", "heading_markers", "frontmatter", "color" };
const mermaid_keys = [_][]const u8{ "enabled", "style", "subgraph_edges" };
const files_keys = [_][]const u8{ "show_hidden", "extensions" };

fn sectionHolding(key: []const u8) ?[]const u8 {
    const tables = [_]struct { name: []const u8, keys: []const []const u8 }{
        .{ .name = "general", .keys = &general_keys },
        .{ .name = "display", .keys = &display_keys },
        .{ .name = "mermaid", .keys = &mermaid_keys },
        .{ .name = "files", .keys = &files_keys },
    };
    for (tables) |t| {
        for (t.keys) |k| if (std.mem.eql(u8, k, key)) return t.name;
    }
    return null;
}

const Context = struct {
    origin: []const u8,
    warnings: ?*Warnings,
    line: usize = 0,
    warned_section_line: usize = 0,

    fn warn(self: *const Context, comptime fmt: []const u8, args: anytype) void {
        const w = self.warnings orelse return;
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        w.add("{s}:{d}: {s}", .{ self.origin, self.line, text });
    }

    fn invalid(self: *const Context, section: []const u8, key: []const u8, value: []const u8, expected: []const u8) void {
        self.warn("invalid value {s} for '{s}' in [{s}] (expected {s}); keeping the default", .{ value, key, section, expected });
    }

    fn unknownKey(self: *const Context, section: []const u8, key: []const u8, known: []const []const u8) void {
        if (suggest.closest(key, known)) |s| {
            self.warn("unknown key '{s}' in [{s}] (did you mean '{s}'?)", .{ key, section, s });
        } else {
            self.warn("unknown key '{s}' in [{s}]", .{ key, section });
        }
    }
};

fn assignValue(
    allocator: std.mem.Allocator,
    cfg: *Config,
    ctx: *const Context,
    section: Section,
    key: []const u8,
    value: []const u8,
) !void {
    const eql = std.mem.eql;
    switch (section) {
        .top => {
            if (sectionHolding(key)) |s| {
                ctx.warn("key '{s}' is outside any section (did you mean to put it under [{s}]?)", .{ key, s });
            } else {
                ctx.warn("key '{s}' is outside any section; it is ignored", .{key});
            }
        },
        .general => {
            if (eql(u8, key, "editor")) {
                _ = try setString(allocator, &cfg.general.editor, ctx, "general", key, value);
            } else if (eql(u8, key, "pager")) {
                _ = try setString(allocator, &cfg.general.pager, ctx, "general", key, value);
            } else ctx.unknownKey("general", key, &general_keys);
        },
        .display => {
            if (eql(u8, key, "theme")) {
                if (!try setString(allocator, &cfg.display.theme, ctx, "display", key, value)) return;
                if (ctx.warnings != null) {
                    const origin = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ ctx.origin, ctx.line });
                    allocator.free(cfg.theme_origin);
                    cfg.theme_origin = origin;
                }
            } else if (eql(u8, key, "syntax_theme")) {
                setEnum(SyntaxTheme, &cfg.display.syntax_theme, ctx, "display", key, value, "one of: default, classic");
            } else if (eql(u8, key, "width")) {
                if (parseWidthValue(value)) |w| {
                    cfg.display.width = w;
                } else ctx.invalid("display", key, value, "0 for auto, or an integer from 20 to 1000");
            } else if (eql(u8, key, "line_numbers")) {
                setBool(&cfg.display.line_numbers, ctx, "display", key, value);
            } else if (eql(u8, key, "heading_markers")) {
                setBool(&cfg.display.heading_markers, ctx, "display", key, value);
            } else if (eql(u8, key, "frontmatter")) {
                setEnum(FrontmatterStyle, &cfg.display.frontmatter, ctx, "display", key, value, "one of: panel, dim, compact, raw, hidden");
            } else if (eql(u8, key, "color")) {
                setEnum(ColorMode, &cfg.display.color, ctx, "display", key, value, "one of: auto, always, never");
            } else ctx.unknownKey("display", key, &display_keys);
        },
        .mermaid => {
            if (eql(u8, key, "enabled")) {
                setBool(&cfg.mermaid.enabled, ctx, "mermaid", key, value);
            } else if (eql(u8, key, "style")) {
                _ = try setString(allocator, &cfg.mermaid.style, ctx, "mermaid", key, value);
            } else if (eql(u8, key, "subgraph_edges")) {
                setEnum(SubgraphEdges, &cfg.mermaid.subgraph_edges, ctx, "mermaid", key, value, "one of: bridge, cross");
            } else ctx.unknownKey("mermaid", key, &mermaid_keys);
        },
        .files => {
            if (eql(u8, key, "show_hidden")) {
                setBool(&cfg.files.show_hidden, ctx, "files", key, value);
            } else if (eql(u8, key, "extensions")) {
                try replaceExtensions(allocator, cfg, value);
            } else ctx.unknownKey("files", key, &files_keys);
        },
    }
}

fn setBool(target: *bool, ctx: *const Context, section: []const u8, key: []const u8, value: []const u8) void {
    if (parseBool(value)) |b| {
        target.* = b;
    } else ctx.invalid(section, key, value, "true or false");
}

fn setEnum(
    comptime E: type,
    target: *E,
    ctx: *const Context,
    section: []const u8,
    key: []const u8,
    value: []const u8,
    expected: []const u8,
) void {
    if (std.meta.stringToEnum(E, stripQuotes(value))) |v| {
        target.* = v;
    } else ctx.invalid(section, key, value, expected);
}

/// Accepts `true`/`false`, bare or quoted. Anything else is not a boolean.
pub fn parseBool(value: []const u8) ?bool {
    const v = stripQuotes(value);
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    return null;
}

/// Accepts 0 or 20..1000, bare or quoted.
pub fn parseWidthValue(value: []const u8) ?usize {
    const n = std.fmt.parseUnsigned(usize, stripQuotes(value), 10) catch return null;
    return if (widthInRange(n)) n else null;
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
    return std.meta.stringToEnum(SyntaxTheme, value) orelse error.InvalidSyntaxTheme;
}

pub fn parseSubgraphEdges(value: []const u8) !SubgraphEdges {
    if (std.mem.eql(u8, value, "bridge")) return .bridge;
    if (std.mem.eql(u8, value, "cross")) return .cross;
    return error.InvalidSubgraphEdges;
}

pub fn parseFrontmatterStyle(value: []const u8) !FrontmatterStyle {
    return std.meta.stringToEnum(FrontmatterStyle, value) orelse error.InvalidFrontmatterStyle;
}

const stripQuotes = loadfile.stripQuotes;

/// Sets a string key from a quoted value (`"basic"` or `'literal'`). Any
/// other value (`pager = 5`, `theme = dark`) warns and keeps the old value.
/// Returns whether the value was applied.
fn setString(
    allocator: std.mem.Allocator,
    target: *[]const u8,
    ctx: *const Context,
    section: []const u8,
    key: []const u8,
    value: []const u8,
) !bool {
    if (!isQuoted(value)) {
        ctx.invalid(section, key, value, "a quoted string");
        return false;
    }
    try replaceString(allocator, target, value);
    return true;
}

fn isQuoted(value: []const u8) bool {
    if (value.len < 2) return false;
    const q = value[0];
    return (q == '"' or q == '\'') and value[value.len - 1] == q;
}

fn replaceString(allocator: std.mem.Allocator, target: *[]const u8, value: []const u8) !void {
    // TOML literal strings take their contents verbatim (no escapes).
    const literal = value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'';
    const dup = if (literal) try allocator.dupe(u8, value[1 .. value.len - 1]) else try decodeQuotedString(allocator, value);
    allocator.free(target.*);
    target.* = dup;
}

const decodeQuotedString = loadfile.decodeQuotedString;

/// Reads one environment variable. Empty values count as unset.
pub const EnvLookup = *const fn (name: []const u8) ?[]const u8;

fn processEnv(name: []const u8) ?[]const u8 {
    return std.posix.getenv(name);
}

fn applyEnvOverrides(allocator: std.mem.Allocator, cfg: *Config, warnings: *Warnings) !void {
    try applyEnv(allocator, cfg, warnings, processEnv);
}

/// Applies MERCAT_* overrides from `env`; invalid values warn and are ignored.
pub fn applyEnv(allocator: std.mem.Allocator, cfg: *Config, warnings: *Warnings, env: EnvLookup) !void {
    if (nonEmpty(env("MERCAT_WIDTH"))) |value| {
        if (parseWidthValue(value)) |w| {
            cfg.display.width = w;
        } else warnings.add("ignoring MERCAT_WIDTH='{s}' (expected 0 for auto, or an integer from 20 to 1000)", .{value});
    }

    if (nonEmpty(env("MERCAT_THEME"))) |value| {
        try replaceString(allocator, &cfg.display.theme, value);
        const origin = try allocator.dupe(u8, "MERCAT_THEME");
        allocator.free(cfg.theme_origin);
        cfg.theme_origin = origin;
    }

    if (nonEmpty(env("MERCAT_SYNTAX_THEME"))) |value| {
        if (std.meta.stringToEnum(SyntaxTheme, value)) |v| {
            cfg.display.syntax_theme = v;
        } else warnings.add("ignoring MERCAT_SYNTAX_THEME='{s}' (expected one of: default, classic)", .{value});
    }

    if (nonEmpty(env("MERCAT_FRONTMATTER"))) |value| {
        if (std.meta.stringToEnum(FrontmatterStyle, value)) |v| {
            cfg.display.frontmatter = v;
        } else warnings.add("ignoring MERCAT_FRONTMATTER='{s}' (expected one of: panel, dim, compact, raw, hidden)", .{value});
    }

    if (nonEmpty(env("MERCAT_SUBGRAPH_EDGES"))) |value| {
        if (parseSubgraphEdges(value)) |v| {
            cfg.mermaid.subgraph_edges = v;
        } else |_| warnings.add("ignoring MERCAT_SUBGRAPH_EDGES='{s}' (expected one of: bridge, cross)", .{value});
    }
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    return if (v.len == 0) null else v;
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
    _ = @import("suggest.zig");
    _ = @import("config_test.zig");
    _ = @import("config_warn_test.zig");
}

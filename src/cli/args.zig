const std = @import("std");
const config = @import("../core/config.zig");
const mermaid_types = @import("../core/mermaid/types.zig");
pub const BoxDrawingStyle = mermaid_types.BoxDrawingStyle;
pub const CrossingReductionHeuristic = mermaid_types.CrossingReductionHeuristic;
pub const ForceLayout = mermaid_types.ForceLayout;

pub const usage_text =
    \\mercat - Mermaid & Markdown Viewer on Terminal.
    \\
    \\Usage:
    \\  mercat [options] <file>        Render a file to stdout
    \\  cat file.md | mercat           Render piped stdin (no "-" needed)
    \\  mercat -t <path>               Interactive TUI viewer/browser
    \\
    \\Run mercat -h for all options, input rules and examples.
    \\
;

pub const help_text =
    \\mercat - Mermaid & Markdown Viewer on Terminal.
    \\
    \\Usage:
    \\  mercat [options] <file>        Render a file to stdout
    \\  cat file.md | mercat           Render piped stdin (no "-" needed)
    \\  mercat [options] -             Read stdin explicitly
    \\  mercat -t <path>               Interactive TUI viewer/browser
    \\
    \\Input:
    \\  A .mmd/.mermaid file, or piped input whose first non-blank, non-"%%"
    \\  line begins at a diagram keyword (eg: flowchart/graph plus a
    \\  direction like TD/LR), is rendered as one bare Mermaid diagram; 
    \\
    \\Output:
    \\  Writes to stdout. When stdout is not a TTY (pipe/redirect), the pager is
    \\  skipped even with -p, and TUI mode refuses to start; colors are still
    \\  emitted, so use --format plain for clean text.
    \\
    \\Options:
    \\  -h, --help           Show this help and exit
    \\  -v, -V, --version    Show version and exit
    \\  -w, --width <n>      Wrap width in columns (0 = terminal width; plain/png
    \\                       default to 120)
    \\      --style <name>   Theme: dark, light, ansi, dracula, tokyo-night, pink,
    \\                       markview, or a user theme
    \\                       (~/.config/mercat/themes/<name>.toml)
    \\      --dump-theme <name>
    \\                       Print a theme as editable TOML to stdout and exit
    \\      --heading-markers / --no-heading-markers
    \\                       Show / hide the leading # markers on headings
    \\      --frontmatter <s>
    \\                       YAML front matter: panel (default), dim, compact,
    \\                       raw, hidden
    \\      --format <f>     Output format: terminal (default, ANSI), plain (no
    \\                       escapes), png (requires -o)
    \\  -o, --output <path>  Write output to a file instead of stdout
    \\      --monochrome     Black-on-white output (png only)
    \\  -p, --pager          Page output through $PAGER (ignored unless stdout is
    \\                       a TTY)
    \\  -t, --tui            Launch the TUI viewer (needs an interactive terminal)
    \\      --box-style <s>  Mermaid box glyphs: standard, rounded, heavy, double,
    \\                       ascii
    \\      --layout <a>     Mermaid layout: auto (default), sugiyama, tree, force
    \\      --crossing-heuristic <h>
    \\                       Mermaid crossing reduction: median (default),
    \\                       barycenter
    \\      --aspect-ratio <n>
    \\                       Mermaid horizontal cell multiplier (default 1.0; try
    \\                       2.0 on 2:1 terminals)
    \\      --debug-mermaid  Print layout debug info for each Mermaid diagram
    \\
    \\Examples:
    \\  cat README.md | mercat
    \\  printf 'flowchart LR\n  A-->B\n' | mercat
    \\  mercat -w 80 --style light README.md
    \\  mercat --format plain README.md > README.txt
    \\
    \\Config: ~/.config/mercat/config.toml (TOML; CLI flags win).
    \\
;

pub const ParseError = std.mem.Allocator.Error || error{
    ShowHelp,
    ShowVersion,
    UnknownFlag,
    MissingValue,
    InvalidWidth,
    InvalidStyle,
    InvalidFrontmatterStyle,
    InvalidBoxStyle,
    InvalidCrossingHeuristic,
    InvalidLayout,
    InvalidAspectRatio,
    InvalidFormat,
    MultipleInputs,
    IncompatibleModes,
    PngRequiresOutput,
    PngWithPager,
    FormatRequiresCliMode,
    TerminalWithOutput,
};

pub const Mode = enum { cli, tui };
pub const OutputFormat = enum {
    terminal,
    plain,
    png,
};
pub const Input = union(enum) {
    none,
    stdin,
    file: []const u8,

    pub fn filePath(self: Input) ?[]const u8 {
        return switch (self) {
            .file => |path| path,
            .stdin, .none => null,
        };
    }
};

pub const Parsed = struct {
    input: Input = .none,
    mode: Mode = .cli,
    width: ?usize = null,
    style: ?[]const u8 = null,
    dump_theme: ?[]const u8 = null,
    heading_markers: ?bool = null,
    frontmatter: ?config.FrontmatterStyle = null,
    pager: bool = false,
    box_style: ?BoxDrawingStyle = null,
    crossing_heuristic: ?CrossingReductionHeuristic = null,
    force_layout: ?ForceLayout = null,
    aspect_ratio: ?f32 = null,
    debug_mermaid: bool = false,
    format: OutputFormat = .terminal,
    output_path: ?[]u8 = null,
    monochrome: bool = false,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        switch (self.input) {
            .file => |path| allocator.free(path),
            else => {},
        }
        if (self.output_path) |path| allocator.free(path);
    }

    pub fn effectiveWidth(self: Parsed, config_width: usize) usize {
        return if (self.width) |value|
            value
        else if (config_width == 0)
            0
        else
            config_width;
    }

    pub fn nonTerminalWidth(self: Parsed, config_width: usize) usize {
        if (self.width) |value| return value;
        if (config_width != 0) return config_width;
        return 120;
    }

    pub fn effectiveTheme(self: Parsed, config_theme: []const u8) []const u8 {
        return self.style orelse config_theme;
    }

    pub fn effectiveHeadingMarkers(self: Parsed, config_value: bool) bool {
        return self.heading_markers orelse config_value;
    }

    pub fn effectiveFrontmatter(self: Parsed, config_value: config.FrontmatterStyle) config.FrontmatterStyle {
        return self.frontmatter orelse config_value;
    }
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Parsed {
    var result = Parsed{};
    errdefer result.deinit(allocator);

    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return error.ShowHelp;
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) return error.ShowVersion;

        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pager")) {
            if (result.mode == .tui) return error.IncompatibleModes;
            result.pager = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tui")) {
            if (result.pager) return error.IncompatibleModes;
            result.mode = .tui;
            continue;
        }

        if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--width")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.width = try parseWidth(argv[index]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--dump-theme")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.dump_theme = argv[index];
            continue;
        }

        if (std.mem.eql(u8, arg, "--style")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.style = argv[index];
            continue;
        }

        if (std.mem.eql(u8, arg, "--no-heading-markers")) {
            result.heading_markers = false;
            continue;
        }

        if (std.mem.eql(u8, arg, "--heading-markers")) {
            result.heading_markers = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--frontmatter")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.frontmatter = std.meta.stringToEnum(config.FrontmatterStyle, argv[index]) orelse return error.InvalidFrontmatterStyle;
            continue;
        }

        if (std.mem.eql(u8, arg, "--box-style")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.box_style = try parseBoxStyle(argv[index]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--crossing-heuristic")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.crossing_heuristic = try parseCrossingHeuristic(argv[index]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--layout") or std.mem.eql(u8, arg, "--force-layout")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.force_layout = try parseLayout(argv[index]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--aspect-ratio")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.aspect_ratio = try parseAspectRatio(argv[index]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--debug-mermaid")) {
            result.debug_mermaid = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--format")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.format = try parseFormat(argv[index]);
            continue;
        }

        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            if (result.output_path) |old| allocator.free(old);
            result.output_path = try allocator.dupe(u8, argv[index]);
            continue;
        }

        if (std.mem.eql(u8, arg, "--monochrome")) {
            result.monochrome = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-")) {
                try trySetInput(&result, .stdin);
                continue;
            }
            return error.UnknownFlag;
        }

        switch (result.input) {
            .none => {},
            else => return error.MultipleInputs,
        }
        result.input = .{ .file = try allocator.dupe(u8, arg) };
    }

    try validateCombinations(result);

    return result;
}

fn validateCombinations(result: Parsed) ParseError!void {
    if (result.mode == .tui and result.format != .terminal) {
        return error.FormatRequiresCliMode;
    }

    switch (result.format) {
        .terminal => {
            if (result.output_path != null) return error.TerminalWithOutput;
        },
        .plain => {},
        .png => {
            if (result.output_path == null) return error.PngRequiresOutput;
            if (result.pager) return error.PngWithPager;
        },
    }
}

fn trySetInput(result: *Parsed, input: Input) ParseError!void {
    switch (result.input) {
        .none => result.input = input,
        else => return error.MultipleInputs,
    }
}

fn parseWidth(raw: []const u8) ParseError!usize {
    return std.fmt.parseUnsigned(usize, raw, 10) catch error.InvalidWidth;
}

fn parseBoxStyle(raw: []const u8) ParseError!BoxDrawingStyle {
    if (std.mem.eql(u8, raw, "standard")) return .standard;
    if (std.mem.eql(u8, raw, "rounded")) return .rounded;
    if (std.mem.eql(u8, raw, "heavy")) return .heavy;
    if (std.mem.eql(u8, raw, "double")) return .double;
    if (std.mem.eql(u8, raw, "ascii")) return .ascii;
    return error.InvalidBoxStyle;
}

fn parseCrossingHeuristic(raw: []const u8) ParseError!CrossingReductionHeuristic {
    if (std.mem.eql(u8, raw, "median")) return .median;
    if (std.mem.eql(u8, raw, "barycenter")) return .barycenter;
    return error.InvalidCrossingHeuristic;
}

fn parseAspectRatio(raw: []const u8) ParseError!f32 {
    const val = std.fmt.parseFloat(f32, raw) catch return error.InvalidAspectRatio;
    if (val <= 0.0) return error.InvalidAspectRatio;
    return val;
}

fn parseFormat(raw: []const u8) ParseError!OutputFormat {
    if (std.mem.eql(u8, raw, "terminal")) return .terminal;
    if (std.mem.eql(u8, raw, "plain")) return .plain;
    if (std.mem.eql(u8, raw, "png")) return .png;
    return error.InvalidFormat;
}

fn parseLayout(raw: []const u8) ParseError!ForceLayout {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "sugiyama")) return .sugiyama;
    if (std.mem.eql(u8, raw, "tree")) return .tree;
    if (std.mem.eql(u8, raw, "force")) return .force;
    return error.InvalidLayout;
}

test "parses cli arguments" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--style", "dark", "-w", "88", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(Mode.cli, parsed.mode);
    try std.testing.expectEqual(@as(?usize, 88), parsed.width);
    try std.testing.expectEqualStrings("dark", parsed.style.?);
    try std.testing.expectEqualStrings("README.md", parsed.input.file);
}

test "--dump-theme captures the theme name" {
    const argv = [_][]const u8{ "mercat", "--dump-theme", "dracula" };
    const parsed = try parse(std.testing.allocator, &argv);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("dracula", parsed.dump_theme.?);
}

test "--dump-theme without a value errors" {
    const argv = [_][]const u8{ "mercat", "--dump-theme" };
    try std.testing.expectError(error.MissingValue, parse(std.testing.allocator, &argv));
}

test "--style accepts any name; validation is deferred to the registry" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--style", "dracula", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("dracula", parsed.style.?);
    try std.testing.expectEqualStrings("dracula", parsed.effectiveTheme("light"));
    try std.testing.expectEqualStrings("light", (Parsed{}).effectiveTheme("light"));
}

test "supports heading marker override" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--no-heading-markers", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(?bool, false), parsed.heading_markers);
}

test "parses frontmatter style flag and rejects invalid values" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--frontmatter", "compact", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(config.FrontmatterStyle.compact, parsed.frontmatter.?);
    try std.testing.expectEqual(config.FrontmatterStyle.compact, parsed.effectiveFrontmatter(.panel));
    try std.testing.expectEqual(config.FrontmatterStyle.dim, (Parsed{}).effectiveFrontmatter(.dim));

    const bad = [_][]const u8{ "mercat", "--frontmatter", "table", "README.md" };
    try std.testing.expectError(error.InvalidFrontmatterStyle, parse(allocator, &bad));
}

test "frontmatter: missing value at end of argv errors MissingValue" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--frontmatter" };
    try std.testing.expectError(error.MissingValue, parse(allocator, &argv));
}

test "frontmatter: accepts every valid style spelling" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { text: []const u8, style: config.FrontmatterStyle }{
        .{ .text = "panel", .style = .panel },
        .{ .text = "dim", .style = .dim },
        .{ .text = "compact", .style = .compact },
        .{ .text = "raw", .style = .raw },
        .{ .text = "hidden", .style = .hidden },
    };
    for (cases) |case| {
        const argv = [_][]const u8{ "mercat", "--frontmatter", case.text, "README.md" };
        const parsed = try parse(allocator, &argv);
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(case.style, parsed.frontmatter.?);
    }
}

test "frontmatter: effectiveFrontmatter honors config when flag absent and flag wins when present" {
    const styles = [_]config.FrontmatterStyle{ .panel, .dim, .compact, .raw, .hidden };
    for (styles) |style| {
        try std.testing.expectEqual(style, (Parsed{}).effectiveFrontmatter(style));
    }
    const with_flag = Parsed{ .frontmatter = .hidden };
    for (styles) |config_value| {
        try std.testing.expectEqual(config.FrontmatterStyle.hidden, with_flag.effectiveFrontmatter(config_value));
    }
}

test "rejects pager plus tui" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "-p", "-t", "README.md" };
    try std.testing.expectError(error.IncompatibleModes, parse(allocator, &argv));
}

test "falls back to default width" {
    const parsed = Parsed{};
    try std.testing.expectEqual(@as(usize, 0), parsed.effectiveWidth(0));
    try std.testing.expectEqual(@as(usize, 92), parsed.effectiveWidth(92));
}

test "defaults to terminal format" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(OutputFormat.terminal, parsed.format);
    try std.testing.expectEqual(@as(?[]u8, null), parsed.output_path);
    try std.testing.expectEqual(false, parsed.monochrome);
}

test "parses plain format with output path and monochrome" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "plain", "-o", "out.txt", "--monochrome", "in.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(OutputFormat.plain, parsed.format);
    try std.testing.expectEqualStrings("out.txt", parsed.output_path.?);
    try std.testing.expectEqual(true, parsed.monochrome);
}

test "parses png format with long output flag" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "png", "--output", "out.png", "in.mmd" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(OutputFormat.png, parsed.format);
    try std.testing.expectEqualStrings("out.png", parsed.output_path.?);
}

test "rejects invalid format value" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "svg", "in.md" };
    try std.testing.expectError(error.InvalidFormat, parse(allocator, &argv));
}

test "rejects missing format value" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format" };
    try std.testing.expectError(error.MissingValue, parse(allocator, &argv));
}

test "rejects png without output" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "png", "in.mmd" };
    try std.testing.expectError(error.PngRequiresOutput, parse(allocator, &argv));
}

test "rejects png with pager" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "png", "-o", "out.png", "-p", "in.mmd" };
    try std.testing.expectError(error.PngWithPager, parse(allocator, &argv));
}

test "rejects tui with plain format" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "-t", "--format", "plain", "." };
    try std.testing.expectError(error.FormatRequiresCliMode, parse(allocator, &argv));
}

test "rejects tui with png format" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "png", "-o", "out.png", "-t", "." };
    try std.testing.expectError(error.FormatRequiresCliMode, parse(allocator, &argv));
}

test "rejects terminal format with output" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "-o", "out.txt", "in.md" };
    try std.testing.expectError(error.TerminalWithOutput, parse(allocator, &argv));
}

test "accepts monochrome with terminal format" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--monochrome", "in.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(OutputFormat.terminal, parsed.format);
    try std.testing.expectEqual(true, parsed.monochrome);
}

test "non-terminal width resolution" {
    var parsed = Parsed{ .width = 60 };
    try std.testing.expectEqual(@as(usize, 60), parsed.nonTerminalWidth(90));
    parsed = Parsed{};
    try std.testing.expectEqual(@as(usize, 90), parsed.nonTerminalWidth(90));
    try std.testing.expectEqual(@as(usize, 120), parsed.nonTerminalWidth(0));
}

test "output path is freed on deinit" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "--format", "plain", "-o", "out.txt", "in.md" };
    const parsed = try parse(allocator, &argv);
    parsed.deinit(allocator);
}

test "no arguments leaves input unset so stdin can be read implicitly" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"mercat"};
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(Input.none, std.meta.activeTag(parsed.input));
}

test "explicit dash still selects stdin" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mercat", "-" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);
    try std.testing.expectEqual(Input.stdin, std.meta.activeTag(parsed.input));
}

test "help text documents the contract an agent needs" {
    for ([_][]const u8{
        "cat file.md | mercat",
        "flowchart",
        "Examples:",
        "--format",
        "not a TTY",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, help_text, needle) != null);
    }
}

const std = @import("std");
const config = @import("../core/config.zig");
const help = @import("help.zig");
const color = @import("color.zig");
const suggest_mod = @import("../core/suggest.zig");

pub const usage_text = help.usage_text;
pub const help_text = help.help_text;
pub const ColorMode = color.Mode;

/// Accepted and validated for compatibility; no longer changes a render.
pub const BoxDrawingStyle = enum { standard, rounded, heavy, double, ascii };

/// Accepted and validated for compatibility; no longer changes a render.
pub const CrossingReductionHeuristic = enum { median, barycenter };

/// Accepted and validated for compatibility; the TUI still shows and cycles it (`l`), but it no
/// longer changes a render.
pub const ForceLayout = enum {
    auto,
    sugiyama,
    tree,
    force,

    pub fn displayName(self: ForceLayout) []const u8 {
        return @tagName(self);
    }

    pub fn next(self: ForceLayout) ForceLayout {
        return switch (self) {
            .auto => .sugiyama,
            .sugiyama => .tree,
            .tree => .force,
            .force => .auto,
        };
    }
};

pub const ParseError = std.mem.Allocator.Error || error{
    ShowHelp,
    ShowVersion,
    UnknownFlag,
    MissingValue,
    UnexpectedValue,
    InvalidWidth,
    InvalidFrontmatterStyle,
    InvalidBoxStyle,
    InvalidCrossingHeuristic,
    InvalidLayout,
    InvalidAspectRatio,
    InvalidFormat,
    InvalidColor,
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

pub const min_width = config.min_width;
pub const max_width = config.max_width;
pub const widthInRange = config.widthInRange;
/// Width used by plain/png export when nothing (or 0) is configured.
pub const default_export_width: usize = 120;

pub const Parsed = struct {
    input: Input = .none,
    mode: Mode = .cli,
    width: ?usize = null,
    style: ?[]const u8 = null,
    dump_theme: ?[]const u8 = null,
    list_themes: bool = false,
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
    color: ?ColorMode = null,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        switch (self.input) {
            .file => |path| allocator.free(path),
            else => {},
        }
        if (self.output_path) |path| allocator.free(path);
    }

    pub fn effectiveWidth(self: Parsed, config_width: usize) usize {
        return self.width orelse config_width;
    }

    /// Plain and PNG have no terminal to measure, so 0 ("auto") means the
    /// export default rather than a literal zero-column wrap.
    pub fn nonTerminalWidth(self: Parsed, config_width: usize) usize {
        if (self.width) |value| return if (value == 0) default_export_width else value;
        if (config_width != 0) return config_width;
        return default_export_width;
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

const Flag = enum {
    help,
    version,
    pager,
    tui,
    width,
    theme,
    dump_theme,
    list_themes,
    color,
    heading_markers,
    no_heading_markers,
    frontmatter,
    format,
    output,
    monochrome,
    box_style,
    layout,
    crossing_heuristic,
    aspect_ratio,
    debug_mermaid,
};

const FlagSpec = struct {
    /// Spelled with its dashes: "--width" or "-w".
    name: []const u8,
    flag: Flag,
    takes_value: bool = false,
};

/// Every option mercat accepts. Aliases are separate rows with the same flag.
pub const flag_table = [_]FlagSpec{
    .{ .name = "--help", .flag = .help },
    .{ .name = "-h", .flag = .help },
    .{ .name = "--version", .flag = .version },
    .{ .name = "-v", .flag = .version },
    .{ .name = "-V", .flag = .version },
    .{ .name = "--pager", .flag = .pager },
    .{ .name = "-p", .flag = .pager },
    .{ .name = "--tui", .flag = .tui },
    .{ .name = "-t", .flag = .tui },
    .{ .name = "--width", .flag = .width, .takes_value = true },
    .{ .name = "-w", .flag = .width, .takes_value = true },
    .{ .name = "--theme", .flag = .theme, .takes_value = true },
    .{ .name = "--style", .flag = .theme, .takes_value = true },
    .{ .name = "--dump-theme", .flag = .dump_theme, .takes_value = true },
    .{ .name = "--list-themes", .flag = .list_themes },
    .{ .name = "--color", .flag = .color, .takes_value = true },
    .{ .name = "--heading-markers", .flag = .heading_markers },
    .{ .name = "--no-heading-markers", .flag = .no_heading_markers },
    .{ .name = "--frontmatter", .flag = .frontmatter, .takes_value = true },
    .{ .name = "--format", .flag = .format, .takes_value = true },
    .{ .name = "--output", .flag = .output, .takes_value = true },
    .{ .name = "-o", .flag = .output, .takes_value = true },
    .{ .name = "--monochrome", .flag = .monochrome },
    .{ .name = "--box-style", .flag = .box_style, .takes_value = true },
    .{ .name = "--layout", .flag = .layout, .takes_value = true },
    .{ .name = "--force-layout", .flag = .layout, .takes_value = true },
    .{ .name = "--crossing-heuristic", .flag = .crossing_heuristic, .takes_value = true },
    .{ .name = "--aspect-ratio", .flag = .aspect_ratio, .takes_value = true },
    .{ .name = "--debug-mermaid", .flag = .debug_mermaid },
};

/// Context for a parse error, filled by `parseDiag`. Slices borrow argv or
/// static strings; `short_buf` backs a synthesized "-x" spelling.
pub const Diagnostic = struct {
    option: []const u8 = "",
    value: []const u8 = "",
    other: []const u8 = "",
    suggestion: ?[]const u8 = null,
    /// The whole argv token that failed (lets callers hint at `--`).
    token: []const u8 = "",
    short_buf: [2]u8 = .{ '-', 0 },
    /// The argv token that set the input (argv outlives the parse result).
    first_input: []const u8 = "",
    pager_spelling: []const u8 = "--pager",
    tui_spelling: []const u8 = "--tui",
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Parsed {
    var d: Diagnostic = .{};
    return parseDiag(allocator, argv, &d);
}

pub fn parseDiag(allocator: std.mem.Allocator, argv: []const []const u8, d: *Diagnostic) ParseError!Parsed {
    var result = Parsed{};
    errdefer result.deinit(allocator);

    var options_done = false;
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        d.token = arg;

        if (options_done or arg.len < 2 or arg[0] != '-') {
            if (!options_done and std.mem.eql(u8, arg, "-")) {
                try setInput(allocator, &result, .stdin, arg, d);
            } else {
                try setInput(allocator, &result, .{ .file = arg }, arg, d);
            }
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            options_done = true;
            continue;
        }

        if (arg[1] == '-') {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const name = if (eq) |i| arg[0..i] else arg;
            const spec = findFlag(name) orelse {
                d.option = name;
                d.suggestion = suggest(name);
                return error.UnknownFlag;
            };
            var value: ?[]const u8 = null;
            if (eq) |i| {
                if (!spec.takes_value) {
                    d.option = spec.name;
                    return error.UnexpectedValue;
                }
                value = arg[i + 1 ..];
            } else if (spec.takes_value) {
                index += 1;
                if (index >= argv.len) {
                    d.option = spec.name;
                    return error.MissingValue;
                }
                value = argv[index];
            }
            try apply(allocator, &result, spec, value, d);
            continue;
        }

        // A cluster of short options: "-pt", "-w80", "-w 80".
        var pos: usize = 1;
        while (pos < arg.len) : (pos += 1) {
            d.short_buf[1] = arg[pos];
            const spec = findFlag(&d.short_buf) orelse {
                d.option = &d.short_buf;
                d.suggestion = null;
                return error.UnknownFlag;
            };
            if (!spec.takes_value) {
                try apply(allocator, &result, spec, null, d);
                continue;
            }
            var value: []const u8 = undefined;
            if (pos + 1 < arg.len) {
                value = arg[pos + 1 ..];
            } else {
                index += 1;
                if (index >= argv.len) {
                    d.option = spec.name;
                    return error.MissingValue;
                }
                value = argv[index];
            }
            try apply(allocator, &result, spec, value, d);
            break;
        }
    }

    try validateCombinations(result, d);
    return result;
}

fn findFlag(name: []const u8) ?FlagSpec {
    for (flag_table) |spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

fn apply(allocator: std.mem.Allocator, result: *Parsed, spec: FlagSpec, value: ?[]const u8, d: *Diagnostic) ParseError!void {
    d.option = spec.name;
    d.value = value orelse "";
    const v = value orelse "";
    switch (spec.flag) {
        .help => return error.ShowHelp,
        .version => return error.ShowVersion,
        .pager => {
            result.pager = true;
            d.pager_spelling = spec.name;
        },
        .tui => {
            result.mode = .tui;
            d.tui_spelling = spec.name;
        },
        .width => result.width = try parseWidth(v),
        .theme => result.style = v,
        .dump_theme => result.dump_theme = v,
        .list_themes => result.list_themes = true,
        .color => result.color = color.parseMode(v) orelse return error.InvalidColor,
        .heading_markers => result.heading_markers = true,
        .no_heading_markers => result.heading_markers = false,
        .frontmatter => result.frontmatter = std.meta.stringToEnum(config.FrontmatterStyle, v) orelse return error.InvalidFrontmatterStyle,
        .format => result.format = std.meta.stringToEnum(OutputFormat, v) orelse return error.InvalidFormat,
        .output => {
            const dup = try allocator.dupe(u8, v);
            if (result.output_path) |old| allocator.free(old);
            result.output_path = dup;
        },
        .monochrome => result.monochrome = true,
        .box_style => result.box_style = std.meta.stringToEnum(BoxDrawingStyle, v) orelse return error.InvalidBoxStyle,
        .layout => result.force_layout = std.meta.stringToEnum(ForceLayout, v) orelse return error.InvalidLayout,
        .crossing_heuristic => result.crossing_heuristic = std.meta.stringToEnum(CrossingReductionHeuristic, v) orelse return error.InvalidCrossingHeuristic,
        .aspect_ratio => result.aspect_ratio = try parseAspectRatio(v),
        .debug_mermaid => result.debug_mermaid = true,
    }
}

fn setInput(allocator: std.mem.Allocator, result: *Parsed, input: Input, arg: []const u8, d: *Diagnostic) ParseError!void {
    switch (result.input) {
        .none => {},
        .stdin, .file => {
            d.value = d.first_input;
            d.other = arg;
            return error.MultipleInputs;
        },
    }
    d.first_input = arg;
    result.input = switch (input) {
        .file => |path| .{ .file = try allocator.dupe(u8, path) },
        else => input,
    };
}

fn validateCombinations(result: Parsed, d: *Diagnostic) ParseError!void {
    if (result.mode == .tui and result.pager) {
        d.option = d.pager_spelling;
        d.other = d.tui_spelling;
        return error.IncompatibleModes;
    }
    if (result.mode == .tui and result.format != .terminal) {
        d.option = d.tui_spelling;
        d.value = @tagName(result.format);
        return error.FormatRequiresCliMode;
    }

    switch (result.format) {
        .terminal => {
            if (result.output_path != null) return error.TerminalWithOutput;
        },
        .plain => {},
        .png => {
            if (result.output_path == null) return error.PngRequiresOutput;
            if (result.pager) {
                d.option = d.pager_spelling;
                return error.PngWithPager;
            }
        },
    }
}

/// Accepts 0 (auto) or min_width..max_width.
pub fn parseWidth(raw: []const u8) ParseError!usize {
    const value = std.fmt.parseUnsigned(usize, raw, 10) catch return error.InvalidWidth;
    if (!widthInRange(value)) return error.InvalidWidth;
    return value;
}

fn parseAspectRatio(raw: []const u8) ParseError!f32 {
    const val = std.fmt.parseFloat(f32, raw) catch return error.InvalidAspectRatio;
    if (!(val > 0.0) or std.math.isInf(val)) return error.InvalidAspectRatio;
    return val;
}

const long_names = blk: {
    var n: usize = 0;
    for (flag_table) |spec| {
        if (spec.name.len > 2) n += 1;
    }
    var names: [n][]const u8 = undefined;
    var i: usize = 0;
    for (flag_table) |spec| {
        if (spec.name.len > 2) {
            names[i] = spec.name;
            i += 1;
        }
    }
    break :blk names;
};

/// The closest long option to an unknown one, if it is plausibly a typo.
pub fn suggest(name: []const u8) ?[]const u8 {
    return suggest_mod.closest(name, &long_names);
}

/// The user-facing message (without the "mercat: error: " prefix) for a parse
/// error. Help/version are not errors and have no message.
pub fn describe(buf: []u8, err: ParseError, d: *const Diagnostic) []const u8 {
    const r = switch (err) {
        error.UnknownFlag => if (d.suggestion) |s|
            std.fmt.bufPrint(buf, "unknown option '{s}' (did you mean '{s}'?)", .{ d.option, s })
        else
            std.fmt.bufPrint(buf, "unknown option '{s}'", .{d.option}),
        error.MissingValue => std.fmt.bufPrint(buf, "option '{s}' requires an argument", .{d.option}),
        error.UnexpectedValue => std.fmt.bufPrint(buf, "option '{s}' does not take an argument", .{d.option}),
        error.InvalidWidth => std.fmt.bufPrint(
            buf,
            "invalid width '{s}' for '{s}' (expected 0 for auto, or {d}..{d})",
            .{ d.value, d.option, min_width, max_width },
        ),
        error.InvalidFrontmatterStyle => invalidChoice(buf, d, "panel, dim, compact, raw, hidden"),
        error.InvalidBoxStyle => invalidChoice(buf, d, "standard, rounded, heavy, double, ascii"),
        error.InvalidCrossingHeuristic => invalidChoice(buf, d, "median, barycenter"),
        error.InvalidLayout => invalidChoice(buf, d, "auto, sugiyama, tree, force"),
        error.InvalidFormat => invalidChoice(buf, d, "terminal, plain, png"),
        error.InvalidColor => invalidChoice(buf, d, color.valid_values),
        error.InvalidAspectRatio => std.fmt.bufPrint(
            buf,
            "invalid value '{s}' for '{s}' (expected a positive number, e.g. 2.0)",
            .{ d.value, d.option },
        ),
        error.MultipleInputs => std.fmt.bufPrint(
            buf,
            "more than one input given ('{s}' and '{s}'); mercat renders one file at a time",
            .{ d.value, d.other },
        ),
        error.IncompatibleModes => std.fmt.bufPrint(buf, "'{s}' and '{s}' cannot be used together", .{ d.option, d.other }),
        error.FormatRequiresCliMode => std.fmt.bufPrint(buf, "'{s}' cannot be used with --format {s}", .{ d.option, d.value }),
        error.PngRequiresOutput => std.fmt.bufPrint(buf, "--format png needs an output file; add -o <file>.png", .{}),
        error.PngWithPager => std.fmt.bufPrint(buf, "'{s}' cannot be used with --format png", .{d.option}),
        error.TerminalWithOutput => std.fmt.bufPrint(buf, "-o needs --format plain or --format png (terminal output goes to stdout)", .{}),
        error.OutOfMemory => std.fmt.bufPrint(buf, "out of memory", .{}),
        error.ShowHelp, error.ShowVersion => std.fmt.bufPrint(buf, "", .{}),
    };
    return r catch buf[0..0];
}

fn invalidChoice(buf: []u8, d: *const Diagnostic, choices: []const u8) std.fmt.BufPrintError![]u8 {
    return std.fmt.bufPrint(buf, "invalid value '{s}' for '{s}' (expected one of: {s})", .{ d.value, d.option, choices });
}

/// Whether the error is a usage mistake (exit 2) rather than a runtime failure.
pub fn isUsageError(err: ParseError) bool {
    return switch (err) {
        error.ShowHelp, error.ShowVersion, error.OutOfMemory => false,
        else => true,
    };
}

test {
    _ = @import("args_test.zig");
}

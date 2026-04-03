const std = @import("std");
const config = @import("../core/config.zig");

pub const help_text =
    \\mdv - Zig terminal markdown viewer
    \\
    \\Usage:
    \\  mdv [options] <file>
    \\  mdv [options] -
    \\  cat README.md | mdv -
    \\  mdv -t <path>
    \\
    \\Options:
    \\  -h, --help           Show this help and exit
    \\  -v, -V, --version    Show version and exit
    \\  -w, --width <n>      Override wrap width (0 uses terminal width)
    \\      --style <name>   Select theme: auto, dark, light
    \\      --no-heading-markers
    \\                      Hide leading # markers in headings
    \\  -p, --pager          Pipe rendered output through pager
    \\  -t, --tui            Launch TUI browser/viewer mode
;

pub const ParseError = std.mem.Allocator.Error || error{
    ShowHelp,
    ShowVersion,
    UnknownFlag,
    MissingValue,
    InvalidWidth,
    InvalidStyle,
    MultipleInputs,
    IncompatibleModes,
};

pub const Mode = enum { cli, tui };
pub const ThemeOverride = enum { auto, dark, light };
pub const Input = union(enum) {
    none,
    stdin,
    file: []const u8,
};

pub const Parsed = struct {
    input: Input = .none,
    mode: Mode = .cli,
    width: ?usize = null,
    style: ?ThemeOverride = null,
    heading_markers: ?bool = null,
    pager: bool = false,

    pub fn deinit(self: Parsed, allocator: std.mem.Allocator) void {
        switch (self.input) {
            .file => |path| allocator.free(path),
            else => {},
        }
    }

    pub fn effectiveWidth(self: Parsed, config_width: usize) usize {
        return if (self.width) |value|
            value
        else if (config_width == 0)
            0
        else
            config_width;
    }

    pub fn effectiveTheme(self: Parsed, config_theme: config.Theme) config.Theme {
        return if (self.style) |style| switch (style) {
            .auto => .auto,
            .dark => .dark,
            .light => .light,
        } else config_theme;
    }

    pub fn effectiveHeadingMarkers(self: Parsed, config_value: bool) bool {
        return self.heading_markers orelse config_value;
    }
};

pub fn parse(allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Parsed {
    var result = Parsed{};

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

        if (std.mem.eql(u8, arg, "--style")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            result.style = try parseStyle(argv[index]);
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

    return result;
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

fn parseStyle(raw: []const u8) ParseError!ThemeOverride {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "dark")) return .dark;
    if (std.mem.eql(u8, raw, "light")) return .light;
    return error.InvalidStyle;
}

test "parses cli arguments" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mdv", "--style", "dark", "-w", "88", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(Mode.cli, parsed.mode);
    try std.testing.expectEqual(@as(?usize, 88), parsed.width);
    try std.testing.expectEqual(ThemeOverride.dark, parsed.style.?);
    try std.testing.expectEqualStrings("README.md", parsed.input.file);
}

test "supports heading marker override" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mdv", "--no-heading-markers", "README.md" };
    const parsed = try parse(allocator, &argv);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(?bool, false), parsed.heading_markers);
}

test "rejects pager plus tui" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "mdv", "-p", "-t", "README.md" };
    try std.testing.expectError(error.IncompatibleModes, parse(allocator, &argv));
}

test "falls back to default width" {
    const parsed = Parsed{};
    try std.testing.expectEqual(@as(usize, 0), parsed.effectiveWidth(0));
    try std.testing.expectEqual(@as(usize, 92), parsed.effectiveWidth(92));
}

const std = @import("std");
const args = @import("cli/args.zig");
const renderer = @import("cli/renderer.zig");
const pager = @import("cli/pager.zig");
const stdin = @import("cli/stdin.zig");
const config = @import("core/config.zig");
const markdown = @import("core/markdown.zig");
const theme = @import("core/theme.zig");
const terminal = @import("platform/terminal.zig");
const tui = @import("tui/app.zig");

const VERSION = @import("build_options").version;

fn showVersion(allocator: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("mdv ");
    try stdout.writeAll(VERSION);

    // Try to fetch latest version from GitHub API
    if (fetchLatestVersion(allocator)) |latest| {
        defer allocator.free(latest);
        try stdout.writeAll(" (latest: ");
        try stdout.writeAll(latest);
        try stdout.writeAll(")");
    } else |_| {
        // Silently continue if latest version check fails
    }

    try stdout.writeAll("\n");
}

fn fetchLatestVersion(allocator: std.mem.Allocator) ![]u8 {
    // Try using curl if available
    var child = std.process.Child.init(&.{
        "curl",
        "-s",
        "--max-time",
        "2",
        "https://api.github.com/repos/tawago/mdv/releases/latest",
    }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 8192);
    defer allocator.free(stdout);

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        return error.FetchFailed;
    }

    // Parse JSON to find tag_name
    if (std.mem.indexOf(u8, stdout, "\"tag_name\":\"")) |start| {
        const begin = start + 12; // Length of "\"tag_name\":\""
        if (std.mem.indexOf(u8, stdout[begin..], "\"")) |end| {
            const tag = stdout[begin .. begin + end];
            // Return the tag without the 'v' prefix if present
            const version = if (std.mem.startsWith(u8, tag, "v"))
                tag[1..]
            else
                tag;
            return try allocator.dupe(u8, version);
        }
    }

    return error.ParseFailed;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    const parsed = args.parse(allocator, argv) catch |err| switch (err) {
        error.ShowHelp => {
            try std.fs.File.stdout().writeAll(args.help_text);
            return;
        },
        error.ShowVersion => {
            try showVersion(allocator);
            return;
        },
        else => return err,
    };
    defer parsed.deinit(allocator);

    var loaded_config = try config.load(allocator);
    defer loaded_config.deinit(allocator);

    const content = try readInput(allocator, parsed.input);
    defer allocator.free(content);

    const active_theme = parsed.effectiveTheme(loaded_config.display.theme);
    const show_heading_markers = parsed.effectiveHeadingMarkers(loaded_config.display.heading_markers);
    const render_width = blk: {
        const configured = parsed.effectiveWidth(loaded_config.display.width);
        break :blk if (configured == 0) terminal.stdoutWidth() else configured;
    };
    if (parsed.mode == .tui) {
        if (!terminal.stdinIsTty() or !terminal.stdoutIsTty() or !terminal.hasControllingTty()) {
            try std.fs.File.stderr().writeAll("TUI mode requires an interactive terminal with /dev/tty available.\n");
            return;
        }
        try tui.run(allocator, inputTitle(parsed.input), parsed.input, content, loaded_config.general.editor, active_theme, loaded_config.display.syntax_theme, show_heading_markers);
        return;
    }

    var document = try markdown.parse(allocator, content);
    defer document.deinit(allocator);

    const rendered = try renderer.renderDocument(allocator, document, .{
        .width = render_width,
        .palette = theme.palette(active_theme, loaded_config.display.syntax_theme),
        .show_heading_markers = show_heading_markers,
    });
    defer allocator.free(rendered);

    try pager.writeOutput(allocator, rendered, loaded_config.general.pager, parsed.pager);
}

fn inputTitle(input: args.Input) []const u8 {
    return switch (input) {
        .file => |path| path,
        .stdin, .none => "stdin",
    };
}

fn readInput(allocator: std.mem.Allocator, input: args.Input) ![]u8 {
    return switch (input) {
        .stdin => std.fs.File.stdin().readToEndAlloc(allocator, std.math.maxInt(usize)),
        .file => |path| blk: {
            const cwd = std.fs.cwd();
            break :blk try cwd.readFileAlloc(allocator, path, std.math.maxInt(usize));
        },
        .none => if (stdin.shouldReadImplicitStdin())
            std.fs.File.stdin().readToEndAlloc(allocator, std.math.maxInt(usize))
        else
            error.MissingInput,
    };
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const process = @import("../platform/process.zig");
const terminal = @import("../platform/terminal.zig");
const diag = @import("diag.zig");

/// Writes rendered output to stdout, through a pager when asked and stdout is
/// a terminal. Empty output writes nothing. A reader that goes away early
/// (`mercat x.md | head -1`) ends the run successfully and silently.
pub fn writeOutput(allocator: std.mem.Allocator, output: []const u8, configured_pager: []const u8, prefer_pager: bool) !void {
    if (output.len == 0) return;
    if (!prefer_pager or !terminal.stdoutIsTty()) {
        return writeDirect(output);
    }

    const pager_command = try resolvePagerCommand(allocator, configured_pager);
    defer allocator.free(pager_command);

    const argv = process.splitCommand(allocator, pager_command) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.warn("cannot parse pager command '{s}' (unterminated quote); writing directly", .{pager_command});
            return writeDirect(output);
        },
    };
    defer argv.deinit(allocator);

    const pager_input = try ensureTrailingNewline(allocator, output);
    defer allocator.free(pager_input);

    runPager(allocator, argv.argv, pager_input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.warn("cannot run pager '{s}': {s}; writing directly", .{ pager_command, spawnErrorText(err) });
            return writeDirect(output);
        },
    };
}

fn spawnErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.EmptyCommand => "empty command",
        error.FileNotFound => "command not found",
        else => diag.describeError(err),
    };
}

/// Spawns the pager and feeds it `content`. Only a failure to start the pager
/// is an error: once it runs, quitting early or a non-zero exit is the
/// pager's business and must not cause the output to be written twice.
fn runPager(allocator: std.mem.Allocator, argv: []const []const u8, content: []const u8) !void {
    if (argv.len == 0) return error.EmptyCommand;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    if (child.stdin) |stdin_pipe| {
        stdin_pipe.writeAll(content) catch {};
        stdin_pipe.close();
        child.stdin = null;
    }

    // An exec failure (command not found) surfaces here, not from spawn().
    _ = try child.wait();
}

fn resolvePagerCommand(allocator: std.mem.Allocator, configured_pager: []const u8) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "PAGER")) |value| {
        if (std.mem.trim(u8, value, " \t").len != 0) return value;
        allocator.free(value);
    } else |_| {}

    if (std.mem.trim(u8, configured_pager, " \t").len != 0) {
        return allocator.dupe(u8, configured_pager);
    }

    return allocator.dupe(u8, "less -R");
}

/// Writes to stdout, adding a final newline if missing. A closed pipe exits 0.
pub fn writeDirect(output: []const u8) !void {
    if (output.len == 0) return;
    try writeStdout(output);
    if (output[output.len - 1] != '\n') try writeStdout("\n");
}

/// Writes all bytes to stdout. If the reader has gone away (EPIPE), exits 0
/// without a message, like other well-behaved filters.
pub fn writeStdout(bytes: []const u8) !void {
    std.fs.File.stdout().writeAll(bytes) catch |err| switch (err) {
        error.BrokenPipe => std.process.exit(0),
        else => return err,
    };
}

fn ensureTrailingNewline(allocator: std.mem.Allocator, output: []const u8) ![]const u8 {
    if (output.len == 0 or output[output.len - 1] != '\n') {
        return std.fmt.allocPrint(allocator, "{s}\n", .{output});
    }
    return allocator.dupe(u8, output);
}

test "falls back to configured pager when env missing" {
    const allocator = std.testing.allocator;
    const value = try resolvePagerCommand(allocator, "less -R");
    defer allocator.free(value);

    try std.testing.expectEqualStrings("less -R", value);
}

test "runPager reports a missing command as a spawn failure" {
    const argv = [_][]const u8{"/nonexistent/mercat-pager-xyz"};
    try std.testing.expectError(error.FileNotFound, runPager(std.testing.allocator, &argv, "x\n"));
    try std.testing.expectEqualStrings("command not found", spawnErrorText(error.FileNotFound));
}

test "runPager ignores a pager that exits non-zero" {
    const argv = [_][]const u8{ "sh", "-c", "exit 3" };
    try runPager(std.testing.allocator, &argv, "x\n");
}

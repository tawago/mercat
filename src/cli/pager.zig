const std = @import("std");
const process = @import("../platform/process.zig");
const terminal = @import("../platform/terminal.zig");

pub fn writeOutput(allocator: std.mem.Allocator, output: []const u8, configured_pager: []const u8, prefer_pager: bool) !void {
    if (!prefer_pager or !terminal.stdoutIsTty()) {
        return writeDirect(output);
    }

    const pager_command = try resolvePagerCommand(allocator, configured_pager);
    defer allocator.free(pager_command);

    const argv = try process.splitCommand(allocator, pager_command);
    defer argv.deinit(allocator);

    const pager_input = try ensureTrailingNewline(allocator, output);
    defer allocator.free(pager_input);

    process.writeToPager(allocator, argv.argv, pager_input) catch {
        return writeDirect(output);
    };
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

fn writeDirect(output: []const u8) !void {
    try std.fs.File.stdout().writeAll(output);
    if (output.len == 0 or output[output.len - 1] != '\n') {
        try std.fs.File.stdout().writeAll("\n");
    }
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

const std = @import("std");
const process = @import("process.zig");

pub fn openFile(allocator: std.mem.Allocator, editor_command: []const u8, file_path: []const u8) !void {
    var command = try process.splitCommand(allocator, editor_command);
    defer command.deinit(allocator);

    const argv = try allocator.alloc([]const u8, command.argv.len + 1);
    defer allocator.free(argv);
    for (command.argv, 0..) |part, index| argv[index] = part;
    argv[command.argv.len] = file_path;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
}

test "editor command splits and appends path" {
    const allocator = std.testing.allocator;
    var command = try process.splitCommand(allocator, "nvim -u NONE");
    defer command.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), command.argv.len);
    try std.testing.expectEqualStrings("nvim", command.argv[0]);
}

const std = @import("std");

pub const Command = struct {
    argv: [][]const u8,

    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        for (self.argv) |part| allocator.free(part);
        allocator.free(self.argv);
    }
};

pub fn splitCommand(allocator: std.mem.Allocator, raw: []const u8) !Command {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (parts.items) |part| allocator.free(part);
        parts.deinit(allocator);
    }

    var token: std.ArrayList(u8) = .empty;
    defer token.deinit(allocator);

    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < raw.len) : (index += 1) {
        const char = raw[index];
        if (quote) |active| {
            if (char == active) {
                quote = null;
            } else if (char == '\\' and index + 1 < raw.len and raw[index + 1] == active) {
                index += 1;
                try token.append(allocator, raw[index]);
            } else {
                try token.append(allocator, char);
            }
            continue;
        }

        switch (char) {
            ' ', '\t' => {
                if (token.items.len != 0) {
                    try parts.append(allocator, try allocator.dupe(u8, token.items));
                    token.clearRetainingCapacity();
                }
            },
            '\'', '"' => quote = char,
            else => try token.append(allocator, char),
        }
    }

    if (quote != null) return error.UnterminatedQuote;
    if (token.items.len != 0) try parts.append(allocator, try allocator.dupe(u8, token.items));
    return .{ .argv = try parts.toOwnedSlice(allocator) };
}

pub fn writeToPager(allocator: std.mem.Allocator, argv: []const []const u8, content: []const u8) !void {
    if (argv.len == 0) return error.EmptyCommand;

    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    if (child.stdin) |stdin_pipe| {
        defer stdin_pipe.close();
        try stdin_pipe.writeAll(content);
    }

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ChildProcessFailed,
        else => return error.ChildProcessFailed,
    }
}

test "splits simple command" {
    const allocator = std.testing.allocator;
    const command = try splitCommand(allocator, "less -R");
    defer command.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), command.argv.len);
    try std.testing.expectEqualStrings("less", command.argv[0]);
    try std.testing.expectEqualStrings("-R", command.argv[1]);
}

test "splits quoted command argument" {
    const allocator = std.testing.allocator;
    const command = try splitCommand(allocator, "pager --prompt 'hello world'");
    defer command.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), command.argv.len);
    try std.testing.expectEqualStrings("hello world", command.argv[2]);
}

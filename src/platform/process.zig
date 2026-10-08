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

test "splitCommand: words, quotes, escapes and errors" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { raw: []const u8, argv: []const []const u8 }{
        .{ .raw = "less -R", .argv = &.{ "less", "-R" } },
        .{ .raw = "pager --prompt 'hello world'", .argv = &.{ "pager", "--prompt", "hello world" } },
        .{ .raw = "ed \"a b\"\tc", .argv = &.{ "ed", "a b", "c" } },
        .{ .raw = "  vi\t\t-n  ", .argv = &.{ "vi", "-n" } },
        .{ .raw = "say 'it\\'s'", .argv = &.{ "say", "it's" } },
        .{ .raw = "say \"a\\\"b\"", .argv = &.{ "say", "a\"b" } },
        .{ .raw = "", .argv = &.{} },
    };
    for (cases) |case| {
        const command = try splitCommand(allocator, case.raw);
        defer command.deinit(allocator);
        try std.testing.expectEqual(case.argv.len, command.argv.len);
        for (case.argv, command.argv) |want, got| try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectError(error.UnterminatedQuote, splitCommand(allocator, "vim 'oops"));
    try std.testing.expectError(error.UnterminatedQuote, splitCommand(allocator, "vim \"oops"));
}

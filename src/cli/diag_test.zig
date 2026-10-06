const std = @import("std");
const diag = @import("diag.zig");

test "formatLine: plain error/warning/note lines have the conventional prefix" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "mercat: error: nonexist.md: no such file or directory\n",
        diag.formatLine(&buf, false, .err, "nonexist.md: no such file or directory"),
    );
    try std.testing.expectEqualStrings(
        "mercat: warning: something odd\n",
        diag.formatLine(&buf, false, .warning, "something odd"),
    );
    try std.testing.expectEqualStrings("mercat: note: fyi\n", diag.formatLine(&buf, false, .note, "fyi"));
}

test "formatLine: color wraps only the level label" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "mercat: \x1b[1;31merror:\x1b[0m boom\n",
        diag.formatLine(&buf, true, .err, "boom"),
    );
    try std.testing.expectEqualStrings(
        "mercat: \x1b[1;33mwarning:\x1b[0m hm\n",
        diag.formatLine(&buf, true, .warning, "hm"),
    );
}

test "formatLine: no stray '#' prefix and no escapes when color is off" {
    var buf: [256]u8 = undefined;
    const line = diag.formatLine(&buf, false, .warning, "unknown theme 'x' (using dark)");
    try std.testing.expect(line[0] != '#');
    try std.testing.expect(std.mem.indexOfScalar(u8, line, 0x1b) == null);
}

test "formatLine: overlong text is truncated but still newline-terminated" {
    var buf: [24]u8 = undefined;
    const line = diag.formatLine(&buf, false, .err, "a very long message that does not fit");
    try std.testing.expectEqual(@as(usize, 24), line.len);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    try std.testing.expect(std.mem.startsWith(u8, line, "mercat: error: "));
}

test "describeError maps common IO errors to conventional phrases" {
    try std.testing.expectEqualStrings("no such file or directory", diag.describeError(error.FileNotFound));
    try std.testing.expectEqualStrings("permission denied", diag.describeError(error.AccessDenied));
    try std.testing.expectEqualStrings("is a directory", diag.describeError(error.IsDir));
    try std.testing.expectEqualStrings("no space left on device", diag.describeError(error.NoSpaceLeft));
    try std.testing.expectEqualStrings("read-only file system", diag.describeError(error.ReadOnlyFileSystem));
}

test "describeError: a closed standard stream is a bad file descriptor" {
    try std.testing.expectEqualStrings("bad file descriptor", diag.describeError(error.NotOpenForWriting));
    try std.testing.expectEqualStrings("bad file descriptor", diag.describeError(error.NotOpenForReading));
}

test "describeError never leaks a raw Zig error name" {
    const msg = diag.describeError(error.SomethingNobodyHandles);
    try std.testing.expect(std.mem.indexOf(u8, msg, "SomethingNobodyHandles") == null);
    try std.testing.expectEqualStrings("unexpected system error", msg);
}

test "exit codes follow the convention" {
    try std.testing.expectEqual(@as(u8, 0), diag.exit_ok);
    try std.testing.expectEqual(@as(u8, 1), diag.exit_failure);
    try std.testing.expectEqual(@as(u8, 2), diag.exit_usage);
}

test "formatLine: a trailing newline in the message does not add a blank line" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "mercat: warning: pcre_exec: -10\n",
        diag.formatLine(&buf, false, .warning, "pcre_exec: -10\n"),
    );
}

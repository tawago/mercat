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

test "formatLine: overlong text is truncated but still newline-terminated" {
    var buf: [24]u8 = undefined;
    const line = diag.formatLine(&buf, false, .err, "a very long message that does not fit");
    try std.testing.expectEqual(@as(usize, 24), line.len);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    try std.testing.expect(std.mem.startsWith(u8, line, "mercat: error: "));
}

test "describeError never leaks a raw Zig error name" {
    const msg = diag.describeError(error.SomethingNobodyHandles);
    try std.testing.expect(std.mem.indexOf(u8, msg, "SomethingNobodyHandles") == null);
    try std.testing.expectEqualStrings("unexpected system error", msg);
}

test "formatLine: a trailing newline in the message does not add a blank line" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "mercat: warning: pcre_exec: -10\n",
        diag.formatLine(&buf, false, .warning, "pcre_exec: -10\n"),
    );
}

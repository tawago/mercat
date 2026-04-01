const std = @import("std");

pub const HelpView = struct {
    pub fn lines() []const []const u8 {
        return &.{
            "mdv help",
            "",
            "q / Ctrl-C  quit",
            "e           edit current file",
            "r           reload current file",
            "j / Down    scroll down",
            "k / Up      scroll up",
            "Space       page down",
            "b           page up",
            "g / Home    top",
            "G / End     bottom",
            "? / h       toggle help",
        };
    }

    pub fn width() usize {
        var max: usize = 0;
        for (lines()) |line| max = @max(max, line.len);
        return max;
    }
};

test "has help lines" {
    try std.testing.expect(HelpView.lines().len > 0);
    try std.testing.expect(HelpView.width() >= 8);
}

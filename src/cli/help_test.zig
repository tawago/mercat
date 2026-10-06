const std = @import("std");
const help = @import("help.zig");

test "help text documents the contract an agent needs" {
    for ([_][]const u8{
        "cat file.md | mercat",
        "flowchart",
        "Examples:",
        "--format",
        "--color <when>",
        "--theme <name>",
        "--list-themes",
        "NO_COLOR",
        "Exit status:",
        "anything else is rendered as Markdown.",
        "mercat -t <file>",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, help.help_text, needle) != null);
    }
}

test "help no longer claims colors are emitted when piped" {
    try std.testing.expect(std.mem.indexOf(u8, help.help_text, "colors are still") == null);
    try std.testing.expect(std.mem.indexOf(u8, help.help_text, "-t <path>") == null);
}

test "help lines fit in 80 columns and have no trailing spaces" {
    var lines = std.mem.splitScalar(u8, help.help_text, '\n');
    while (lines.next()) |line| {
        try std.testing.expect(line.len <= 80);
        if (line.len != 0) try std.testing.expect(line[line.len - 1] != ' ');
    }
}

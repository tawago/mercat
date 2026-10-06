const std = @import("std");
const tui_entry = @import("tui_entry.zig");
const args = @import("args.zig");

const tty = tui_entry.Terminal{ .stdin_tty = true, .stdout_tty = true, .has_controlling_tty = true };

fn expectRefusal(input: args.Input, term: tui_entry.Terminal, files: tui_entry.Files, want: tui_entry.Refusal, text: []const u8) !void {
    const outcome = tui_entry.decide(input, term, files);
    try std.testing.expectEqual(want, outcome.refuse);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(text, tui_entry.message(&buf, want, input));
}

test "stdout not a terminal is refused before anything is read" {
    var term = tty;
    term.stdout_tty = false;
    try expectRefusal(.{ .file = "x.md" }, term, .{}, .stdout_not_tty, "--tui needs an interactive terminal; drop -t to render to stdout");
    try expectRefusal(.none, term, .{}, .stdout_not_tty, "--tui needs an interactive terminal; drop -t to render to stdout");
}

test "piped stdin without a file is refused (does not hang reading the pipe)" {
    var term = tty;
    term.stdin_tty = false;
    try expectRefusal(.none, term, .{}, .stdin_pipe, "--tui needs a file argument when stdin is a pipe");
    try expectRefusal(.stdin, tty, .{}, .stdin_pipe, "--tui needs a file argument when stdin is a pipe");
}

test "a directory is refused with a pointer to a file" {
    try expectRefusal(.{ .file = "." }, tty, .{ .input_is_dir = true }, .directory, "'.' is a directory; directory browsing is not available yet \u{2014} pass a file, e.g. mercat -t README.md");
}

test "bare -t opens ./README.md when present, else refuses" {
    const outcome = tui_entry.decide(.none, tty, .{ .readme_exists = true });
    try std.testing.expectEqualStrings("README.md", outcome.open);
    try expectRefusal(.none, tty, .{}, .no_file, "--tui needs a file argument (no README.md in the current directory)");
}

test "a file with a terminal opens" {
    const outcome = tui_entry.decide(.{ .file = "doc.md" }, tty, .{});
    try std.testing.expectEqualStrings("doc.md", outcome.open);
}

test "a file with stdin redirected from a non-terminal is refused" {
    var term = tty;
    term.stdin_tty = false;
    try expectRefusal(.{ .file = "doc.md" }, term, .{}, .no_terminal, "--tui needs an interactive terminal (stdin is not a terminal)");
}

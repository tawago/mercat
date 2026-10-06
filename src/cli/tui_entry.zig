//! Decides, before any input is read, whether `-t` can start and on which
//! file. Pure so every refusal message is unit-tested.
const std = @import("std");
const args = @import("args.zig");

pub const Terminal = struct {
    stdin_tty: bool,
    stdout_tty: bool,
    has_controlling_tty: bool,
};

pub const Files = struct {
    /// Whether the named input is a directory.
    input_is_dir: bool = false,
    /// Whether ./README.md exists (the default for a bare `-t`).
    readme_exists: bool = false,
};

pub const default_file = "README.md";

pub const Refusal = enum {
    stdout_not_tty,
    stdin_pipe,
    no_terminal,
    directory,
    no_file,
};

pub const Outcome = union(enum) {
    /// Open this file in the TUI.
    open: []const u8,
    refuse: Refusal,
};

pub fn decide(input: args.Input, term: Terminal, files: Files) Outcome {
    if (!term.stdout_tty) return .{ .refuse = .stdout_not_tty };
    switch (input) {
        .stdin => return .{ .refuse = .stdin_pipe },
        .none => {
            if (!term.stdin_tty) return .{ .refuse = .stdin_pipe };
            if (!term.has_controlling_tty) return .{ .refuse = .no_terminal };
            if (!files.readme_exists) return .{ .refuse = .no_file };
            return .{ .open = default_file };
        },
        .file => |path| {
            if (files.input_is_dir) return .{ .refuse = .directory };
            if (!term.stdin_tty or !term.has_controlling_tty) return .{ .refuse = .no_terminal };
            return .{ .open = path };
        },
    }
}

/// The message for a refusal (without the "mercat: error: " prefix).
pub fn message(buf: []u8, refusal: Refusal, input: args.Input) []const u8 {
    const r = switch (refusal) {
        .stdout_not_tty => std.fmt.bufPrint(buf, "--tui needs an interactive terminal; drop -t to render to stdout", .{}),
        .stdin_pipe => std.fmt.bufPrint(buf, "--tui needs a file argument when stdin is a pipe", .{}),
        .no_terminal => std.fmt.bufPrint(buf, "--tui needs an interactive terminal (stdin is not a terminal)", .{}),
        .directory => std.fmt.bufPrint(
            buf,
            "'{s}' is a directory; directory browsing is not available yet \u{2014} pass a file, e.g. mercat -t README.md",
            .{input.filePath() orelse "."},
        ),
        .no_file => std.fmt.bufPrint(buf, "--tui needs a file argument (no README.md in the current directory)", .{}),
    };
    return r catch buf[0..0];
}

test {
    _ = @import("tui_entry_test.zig");
}

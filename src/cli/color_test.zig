const std = @import("std");
const color = @import("color.zig");

const Row = struct { flag: ?color.Mode, config: color.Mode, env: color.Env, tty: bool, want: bool };

fn expectRows(comptime f: fn (?color.Mode, color.Mode, color.Env, bool) bool, rows: []const Row) !void {
    for (rows, 0..) |r, i| {
        if (f(r.flag, r.config, r.env, r.tty) != r.want) {
            std.debug.print("row {d} expected {}\n", .{ i, r.want });
            return error.TestUnexpectedResult;
        }
    }
}

// Precedence: flag > NO_COLOR > CLICOLOR_FORCE/FORCE_COLOR > config > TERM=dumb > tty.
test "resolve: color precedence for stdout" {
    try expectRows(color.resolve, &.{
        // The flag wins over every environment variable and the config.
        .{ .flag = .always, .config = .never, .env = .{ .no_color = "1", .force_color = "1", .term = "dumb" }, .tty = false, .want = true },
        .{ .flag = .never, .config = .always, .env = .{ .force_color = "1" }, .tty = true, .want = false },
        // --color auto still honors TERM=dumb and the tty check.
        .{ .flag = .auto, .config = .never, .env = .{}, .tty = true, .want = true },
        .{ .flag = .auto, .config = .always, .env = .{}, .tty = false, .want = false },
        .{ .flag = .auto, .config = .auto, .env = .{ .term = "dumb" }, .tty = true, .want = false },
        // NO_COLOR (non-empty) disables color, even over forcing; empty is ignored.
        .{ .flag = null, .config = .auto, .env = .{ .no_color = "1" }, .tty = true, .want = false },
        .{ .flag = null, .config = .auto, .env = .{ .no_color = "1", .force_color = "1" }, .tty = true, .want = false },
        .{ .flag = null, .config = .auto, .env = .{ .no_color = "" }, .tty = true, .want = true },
        // CLICOLOR_FORCE / FORCE_COLOR force color when not "0" or empty.
        .{ .flag = null, .config = .auto, .env = .{ .clicolor_force = "1" }, .tty = false, .want = true },
        .{ .flag = null, .config = .never, .env = .{ .force_color = "3" }, .tty = false, .want = true },
        .{ .flag = null, .config = .auto, .env = .{ .force_color = "0" }, .tty = false, .want = false },
        .{ .flag = null, .config = .auto, .env = .{ .clicolor_force = "" }, .tty = false, .want = false },
        // The config mode applies after env, before TERM=dumb.
        .{ .flag = null, .config = .always, .env = .{ .term = "dumb" }, .tty = false, .want = true },
        .{ .flag = null, .config = .never, .env = .{}, .tty = true, .want = false },
        .{ .flag = null, .config = .always, .env = .{ .no_color = "x" }, .tty = true, .want = false },
        // auto: color only on a tty.
        .{ .flag = null, .config = .auto, .env = .{ .term = "xterm-256color" }, .tty = true, .want = true },
        .{ .flag = null, .config = .auto, .env = .{ .term = "xterm-256color" }, .tty = false, .want = false },
    });
}

test "resolveStderr: diagnostics follow stderr's own terminal" {
    try expectRows(color.resolveStderr, &.{
        // never (flag or config) turns color off even on a terminal; a flag overrides config.
        .{ .flag = .never, .config = .auto, .env = .{ .force_color = "1" }, .tty = true, .want = false },
        .{ .flag = null, .config = .never, .env = .{ .clicolor_force = "1" }, .tty = true, .want = false },
        .{ .flag = .auto, .config = .never, .env = .{}, .tty = true, .want = true },
        // always and forcing variables never force color onto a non-terminal.
        .{ .flag = .always, .config = .auto, .env = .{}, .tty = false, .want = false },
        .{ .flag = null, .config = .always, .env = .{}, .tty = false, .want = false },
        .{ .flag = null, .config = .auto, .env = .{ .force_color = "1", .clicolor_force = "1" }, .tty = false, .want = false },
        .{ .flag = .always, .config = .auto, .env = .{}, .tty = true, .want = true },
        // NO_COLOR and TERM=dumb apply to stderr's own terminal.
        .{ .flag = null, .config = .auto, .env = .{}, .tty = true, .want = true },
        .{ .flag = .always, .config = .auto, .env = .{ .no_color = "1" }, .tty = true, .want = false },
        .{ .flag = null, .config = .auto, .env = .{ .term = "dumb" }, .tty = true, .want = false },
        .{ .flag = null, .config = .auto, .env = .{ .no_color = "" }, .tty = true, .want = true },
    });
}

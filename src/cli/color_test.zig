const std = @import("std");
const color = @import("color.zig");

const resolve = color.resolve;

test "flag wins over every environment variable" {
    const env = color.Env{ .no_color = "1", .force_color = "1", .term = "dumb" };
    try std.testing.expect(resolve(.always, .never, env, false));
    try std.testing.expect(!resolve(.never, .always, .{ .force_color = "1" }, true));
}

test "stderr: never (flag or config) turns diagnostics color off even on a terminal" {
    const stderr = color.resolveStderr;
    try std.testing.expect(!stderr(.never, .auto, .{ .force_color = "1" }, true));
    try std.testing.expect(!stderr(null, .never, .{ .clicolor_force = "1" }, true));
    // A flag overrides the config key.
    try std.testing.expect(stderr(.auto, .never, .{}, true));
}

test "stderr: always and forcing variables do not force color onto a non-terminal stderr" {
    const stderr = color.resolveStderr;
    try std.testing.expect(!stderr(.always, .auto, .{}, false));
    try std.testing.expect(!stderr(null, .always, .{}, false));
    try std.testing.expect(!stderr(null, .auto, .{ .force_color = "1", .clicolor_force = "1" }, false));
    try std.testing.expect(stderr(.always, .auto, .{}, true));
}

test "stderr: NO_COLOR and TERM=dumb apply to stderr's own terminal" {
    const stderr = color.resolveStderr;
    try std.testing.expect(stderr(null, .auto, .{}, true));
    try std.testing.expect(!stderr(.always, .auto, .{ .no_color = "1" }, true));
    try std.testing.expect(!stderr(null, .auto, .{ .term = "dumb" }, true));
    try std.testing.expect(stderr(null, .auto, .{ .no_color = "" }, true));
}

test "--color auto still honors TERM=dumb and the tty check" {
    try std.testing.expect(resolve(.auto, .never, .{}, true));
    try std.testing.expect(!resolve(.auto, .always, .{}, false));
    try std.testing.expect(!resolve(.auto, .auto, .{ .term = "dumb" }, true));
}

test "NO_COLOR (non-empty) disables color; empty NO_COLOR is ignored" {
    try std.testing.expect(!resolve(null, .auto, .{ .no_color = "1" }, true));
    try std.testing.expect(!resolve(null, .auto, .{ .no_color = "1", .force_color = "1" }, true));
    try std.testing.expect(resolve(null, .auto, .{ .no_color = "" }, true));
}

test "CLICOLOR_FORCE / FORCE_COLOR force color when not '0'" {
    try std.testing.expect(resolve(null, .auto, .{ .clicolor_force = "1" }, false));
    try std.testing.expect(resolve(null, .never, .{ .force_color = "3" }, false));
    try std.testing.expect(!resolve(null, .auto, .{ .force_color = "0" }, false));
    try std.testing.expect(!resolve(null, .auto, .{ .clicolor_force = "" }, false));
}

test "config mode applies after env, before TERM=dumb" {
    try std.testing.expect(resolve(null, .always, .{ .term = "dumb" }, false));
    try std.testing.expect(!resolve(null, .never, .{}, true));
    try std.testing.expect(!resolve(null, .always, .{ .no_color = "x" }, true));
}

test "auto: color only on a tty, never with TERM=dumb" {
    try std.testing.expect(resolve(null, .auto, .{ .term = "xterm-256color" }, true));
    try std.testing.expect(!resolve(null, .auto, .{ .term = "xterm-256color" }, false));
    try std.testing.expect(!resolve(null, .auto, .{ .term = "dumb" }, true));
}

test "hyperlinks need color and a tty stdout" {
    try std.testing.expect(color.Emit.init(true, true).hyperlinks);
    try std.testing.expect(!color.Emit.init(true, false).hyperlinks);
    try std.testing.expect(!color.Emit.init(false, true).hyperlinks);
    try std.testing.expect(!color.Emit.init(false, true).color);
}

test "parseMode accepts exactly auto/always/never" {
    try std.testing.expectEqual(color.Mode.always, color.parseMode("always").?);
    try std.testing.expectEqual(color.Mode.never, color.parseMode("never").?);
    try std.testing.expectEqual(color.Mode.auto, color.parseMode("auto").?);
    try std.testing.expectEqual(@as(?color.Mode, null), color.parseMode("yes"));
}

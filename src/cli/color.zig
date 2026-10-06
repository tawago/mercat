//! Decides whether output carries SGR color and OSC 8 hyperlinks.
//!
//! Precedence: `--color` flag, then `NO_COLOR` (non-empty means never), then
//! `CLICOLOR_FORCE` / `FORCE_COLOR` (non-empty and not "0" means always), then
//! the `[display] color` config key, then `TERM=dumb` (never), and finally
//! `auto`: color only when the stream is a terminal.
const std = @import("std");

pub const Mode = @import("../core/config.zig").ColorMode;

pub const valid_values = "auto, always, never";

pub fn parseMode(raw: []const u8) ?Mode {
    return std.meta.stringToEnum(Mode, raw);
}

pub const Env = struct {
    no_color: ?[]const u8 = null,
    clicolor_force: ?[]const u8 = null,
    force_color: ?[]const u8 = null,
    term: ?[]const u8 = null,

    pub fn fromProcess() Env {
        return .{
            .no_color = std.posix.getenv("NO_COLOR"),
            .clicolor_force = std.posix.getenv("CLICOLOR_FORCE"),
            .force_color = std.posix.getenv("FORCE_COLOR"),
            .term = std.posix.getenv("TERM"),
        };
    }
};

fn forced(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len != 0 and !std.mem.eql(u8, v, "0");
}

/// Whether a stream should carry color. `is_tty` describes that stream.
pub fn resolve(flag: ?Mode, config_mode: Mode, env: Env, is_tty: bool) bool {
    if (flag) |mode| switch (mode) {
        .always => return true,
        .never => return false,
        .auto => return autoDecision(env, is_tty),
    };
    if (env.no_color) |v| if (v.len != 0) return false;
    if (forced(env.clicolor_force) or forced(env.force_color)) return true;
    switch (config_mode) {
        .always => return true,
        .never => return false,
        .auto => {},
    }
    return autoDecision(env, is_tty);
}

fn autoDecision(env: Env, is_tty: bool) bool {
    if (env.term) |t| if (std.mem.eql(u8, t, "dumb")) return false;
    return is_tty;
}

/// What the terminal renderer may emit.
pub const Emit = struct {
    color: bool = true,
    hyperlinks: bool = true,

    /// OSC 8 hyperlinks need color on and a terminal on stdout.
    pub fn init(color: bool, stdout_is_tty: bool) Emit {
        return .{ .color = color, .hyperlinks = color and stdout_is_tty };
    }
};

test {
    _ = @import("color_test.zig");
}

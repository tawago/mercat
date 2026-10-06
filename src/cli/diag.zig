//! The single path for everything mercat prints to stderr.
//!
//! Every message has the shape `mercat: <level>: <text>`; the level label is
//! colored only when stderr is a terminal and color is allowed. Callers never
//! print Zig error names: `describeError` turns an error into a short,
//! conventional phrase ("no such file or directory").
const std = @import("std");

pub const Level = enum {
    err,
    warning,
    note,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }

    fn sgr(self: Level) []const u8 {
        return switch (self) {
            .err => "\x1b[1;31m",
            .warning => "\x1b[1;33m",
            .note => "\x1b[1;36m",
        };
    }
};

/// Conventional exit codes.
pub const exit_ok: u8 = 0;
pub const exit_failure: u8 = 1;
pub const exit_usage: u8 = 2;

pub const help_hint = "Try 'mercat --help' for more information.\n";

var color_enabled: bool = false;
var muted: bool = false;

/// Enables or disables the colored level label for subsequent messages.
pub fn setColor(enabled: bool) void {
    color_enabled = enabled;
}

pub fn colorEnabled() bool {
    return color_enabled;
}

/// Suppresses all output while a full-screen UI owns the terminal.
pub fn setMuted(value: bool) void {
    muted = value;
}

/// Formats one complete diagnostic line (with trailing newline) into `buf`.
/// Overlong text is truncated rather than dropped.
pub fn formatLine(buf: []u8, color: bool, level: Level, text: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    // Library log calls sometimes end their format with "\n"; one line each.
    writeLine(&w, color, level, std.mem.trimRight(u8, text, "\r\n")) catch {};
    const out = w.buffered();
    if (out.len == 0 or out[out.len - 1] != '\n') {
        if (out.len == buf.len) {
            buf[buf.len - 1] = '\n';
            return buf;
        }
        buf[out.len] = '\n';
        return buf[0 .. out.len + 1];
    }
    return out;
}

fn writeLine(w: *std.Io.Writer, color: bool, level: Level, text: []const u8) !void {
    try w.writeAll("mercat: ");
    if (color) try w.writeAll(level.sgr());
    try w.writeAll(level.label());
    try w.writeAll(":");
    if (color) try w.writeAll("\x1b[0m");
    try w.writeAll(" ");
    try w.writeAll(text);
    try w.writeAll("\n");
}

/// Writes raw bytes to stderr, ignoring failures (there is nowhere left to report them).
pub fn writeRaw(bytes: []const u8) void {
    if (muted) return;
    std.fs.File.stderr().writeAll(bytes) catch {};
}

pub fn print(level: Level, comptime fmt: []const u8, args: anytype) void {
    var text_buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, fmt, args) catch blk: {
        const ellipsis = "...";
        @memcpy(text_buf[text_buf.len - ellipsis.len ..], ellipsis);
        break :blk text_buf[0..];
    };
    var line_buf: [2200]u8 = undefined;
    writeRaw(formatLine(&line_buf, color_enabled, level, text));
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    print(.err, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    print(.warning, fmt, args);
}

pub fn note(comptime fmt: []const u8, args: anytype) void {
    print(.note, fmt, args);
}

/// Reports a runtime failure and exits 1.
pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    err(fmt, args);
    std.process.exit(exit_failure);
}

/// Reports a usage error, points at --help, and exits 2.
pub fn usage(comptime fmt: []const u8, args: anytype) noreturn {
    err(fmt, args);
    writeRaw(help_hint);
    std.process.exit(exit_usage);
}

/// Reports a failure on `path` ("mercat: error: x.md: permission denied") and exits 1.
pub fn failPath(path: []const u8, e: anyerror) noreturn {
    fail("{s}: {s}", .{ path, describeError(e) });
}

/// A short, conventional description of an error, never the raw Zig name.
pub fn describeError(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        error.NotDir => "not a directory",
        error.FileTooBig, error.StreamTooLong => "file is too large",
        error.NoSpaceLeft => "no space left on device",
        error.DiskQuota => "disk quota exceeded",
        error.ReadOnlyFileSystem => "read-only file system",
        error.NameTooLong => "file name too long",
        error.SymLinkLoop => "too many levels of symbolic links",
        error.FileBusy, error.DeviceBusy => "device or resource busy",
        error.NoDevice => "no such device",
        error.InputOutput => "input/output error",
        error.BrokenPipe => "broken pipe",
        error.WouldBlock => "resource temporarily unavailable",
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => "too many open files",
        error.InvalidUtf8 => "invalid UTF-8",
        error.OutOfMemory => "out of memory",
        error.BadPathName, error.InvalidWtf8 => "invalid file name",
        error.FileLocksNotSupported, error.Unsupported => "operation not supported",
        error.ConnectionResetByPeer => "connection reset by peer",
        else => "unexpected system error",
    };
}

test {
    _ = @import("diag_test.zig");
}

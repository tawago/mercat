//! Copying text to the system clipboard: OSC 52 through the terminal, and
//! the platform's clipboard tool (pbcopy, wl-copy, xclip, xsel). Each path
//! reports whether it delivered, and `decide` turns both reports into what
//! the user is told — "Copied" only when one of them worked.
const std = @import("std");
const builtin = @import("builtin");

const osc52_base64_cap = 74000;
/// GNU screen caps a DCS string; the payload goes out in chunks this long.
const screen_chunk = 76;

/// How an OSC 52 sequence reaches the outer terminal.
pub const Mux = enum {
    none,
    /// tmux with `set-clipboard on`: it forwards plain OSC 52.
    tmux,
    /// tmux with `set-clipboard` off or external (the default): OSC 52 from
    /// applications is dropped.
    tmux_clipboard_off,
    /// GNU screen: needs a DCS passthrough wrapper.
    screen,
};

pub const Osc52Status = enum { sent, empty, too_large, write_failed };

pub const NativeStatus = union(enum) {
    copied: []const u8,
    /// No clipboard tool could be started.
    no_tool,
    /// A tool ran but failed (for example xclip without a display).
    failed: []const u8,
};

pub const Failure = enum {
    too_large,
    tmux_clipboard_off,
    no_tool,
    tool_failed,
    write_failed,
};

pub const Outcome = union(enum) {
    copied: enum { native, osc52 },
    failed: Failure,
};

/// Whether the copy happened. A sent OSC 52 counts unless tmux is known to
/// drop it; a working clipboard tool always counts.
pub fn decide(osc52: Osc52Status, native: NativeStatus, mux: Mux) Outcome {
    if (native == .copied) return .{ .copied = .native };
    if (osc52 == .sent and mux != .tmux_clipboard_off) return .{ .copied = .osc52 };
    if (osc52 == .too_large) return .{ .failed = .too_large };
    if (osc52 == .sent) return .{ .failed = .tmux_clipboard_off };
    if (osc52 == .write_failed) return .{ .failed = .write_failed };
    return .{ .failed = if (native == .failed) .tool_failed else .no_tool };
}

/// The status-line text for a failed copy, with a hint at the fix.
pub fn failureMessage(failure: Failure) []const u8 {
    return switch (failure) {
        .too_large => "Copy failed: too large for OSC 52 and no " ++ native_tools,
        .tmux_clipboard_off => "Copy failed: tmux drops OSC 52; run tmux set -s set-clipboard on",
        .no_tool => "Copy failed: no " ++ native_tools ++ " found",
        .tool_failed => "Copy failed: the clipboard tool returned an error",
        .write_failed => "Copy failed: could not write to the terminal",
    };
}

const native_tools = switch (builtin.os.tag) {
    .macos => "pbcopy",
    .windows => "clip.exe",
    else => "wl-copy, xclip or xsel",
};

pub const Env = struct {
    tmux: bool,
    screen: bool,

    pub fn fromProcess() Env {
        return .{ .tmux = std.posix.getenv("TMUX") != null, .screen = std.posix.getenv("STY") != null };
    }
};

/// The multiplexer between us and the terminal. tmux wins when both are set
/// (mercat runs in the innermost one); `askTmux` (`tmuxClipboardOn`) is only asked under
/// tmux.
pub fn detectMux(env: Env, askTmux: *const fn () bool) Mux {
    if (env.tmux) return if (askTmux()) .tmux else .tmux_clipboard_off;
    if (env.screen) return .screen;
    return .none;
}

/// Asks the tmux server whether `set-clipboard` is `on`; assumes so when it
/// cannot tell.
pub fn tmuxClipboardOn() bool {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "tmux", "show-options", "-sv", "set-clipboard" },
    }) catch return true;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    const value = std.mem.trim(u8, result.stdout, " \r\n");
    return value.len == 0 or std.mem.eql(u8, value, "on");
}

/// Writes `text` as OSC 52 (DCS-wrapped for GNU screen) and reports whether
/// the sequence was written; the caller flushes.
pub fn writeOsc52(writer: anytype, allocator: std.mem.Allocator, text: []const u8, mux: Mux) !Osc52Status {
    if (text.len == 0) return .empty;
    if (std.base64.standard.Encoder.calcSize(text.len) > osc52_base64_cap) return .too_large;

    const seq = try buildOsc52(allocator, text, mux == .screen);
    defer allocator.free(seq);
    writer.writeAll(seq) catch return .write_failed;
    return .sent;
}

/// Pipes `text` to the first clipboard tool that starts.
pub fn writeNative(allocator: std.mem.Allocator, text: []const u8) NativeStatus {
    if (text.len == 0) return .no_tool;
    var failed: ?[]const u8 = null;
    for (nativeCandidates()) |argv| {
        switch (pipeToChild(allocator, argv, text)) {
            .ok => return .{ .copied = argv[0] },
            .not_started => {},
            .failed => if (failed == null) {
                failed = argv[0];
            },
        }
    }
    return if (failed) |tool| .{ .failed = tool } else .no_tool;
}

fn buildOsc52(allocator: std.mem.Allocator, text: []const u8, screen: bool) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64 = try allocator.alloc(u8, encoder.calcSize(text.len));
    defer allocator.free(b64);
    _ = encoder.encode(b64, text);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (!screen) {
        try buf.appendSlice(allocator, "\x1b]52;c;");
        try buf.appendSlice(allocator, b64);
        try buf.append(allocator, 0x07);
        return buf.toOwnedSlice(allocator);
    }

    // GNU screen forwards the body of each `ESC P … ESC \` string verbatim.
    const plain = try std.mem.concat(allocator, u8, &.{ "\x1b]52;c;", b64, "\x07" });
    defer allocator.free(plain);
    var start: usize = 0;
    while (start < plain.len) : (start += screen_chunk) {
        try buf.appendSlice(allocator, "\x1bP");
        try buf.appendSlice(allocator, plain[start..@min(start + screen_chunk, plain.len)]);
        try buf.appendSlice(allocator, "\x1b\\");
    }
    return buf.toOwnedSlice(allocator);
}

fn nativeCandidates() []const []const []const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{
            &.{"pbcopy"},
        },
        .windows => &.{
            &.{"clip.exe"},
        },
        else => blk: {
            if (std.posix.getenv("WAYLAND_DISPLAY") != null) {
                break :blk &.{
                    &.{"wl-copy"},
                    &.{ "xclip", "-selection", "clipboard" },
                    &.{ "xsel", "--clipboard", "--input" },
                };
            }
            break :blk &.{
                &.{ "xclip", "-selection", "clipboard" },
                &.{ "xsel", "--clipboard", "--input" },
                &.{"wl-copy"},
            };
        },
    };
}

const PipeResult = enum { ok, not_started, failed };

fn pipeToChild(allocator: std.mem.Allocator, argv: []const []const u8, text: []const u8) PipeResult {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return .not_started;
    if (child.stdin) |stdin_pipe| {
        stdin_pipe.writeAll(text) catch {
            stdin_pipe.close();
            child.stdin = null;
            _ = child.wait() catch {};
            return .failed;
        };
        stdin_pipe.close();
        child.stdin = null;
    }
    const term = child.wait() catch return .failed;
    return switch (term) {
        .Exited => |code| if (code == 0) .ok else .failed,
        else => .failed,
    };
}

test {
    _ = @import("clipboard_test.zig");
}

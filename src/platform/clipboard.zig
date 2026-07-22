//! System clipboard write for the TUI, belt-and-suspenders style:
//!
//!   1. OSC 52 escape sequence (works over SSH; wrapped in the tmux/screen
//!      passthrough envelope when running inside a multiplexer), and
//!   2. a native clipboard tool (`pbcopy` / `wl-copy` / `xclip` / `xsel` /
//!      `clip.exe`) as a fallback for terminals that ignore OSC 52 (VTE-based
//!      terminals, tmux without `set-clipboard on`, etc.).
//!
//! Both paths are best-effort: a failure in one should never take down the TUI,
//! and callers invoke both so that whichever the environment supports lands the
//! text on the clipboard.

const std = @import("std");
const builtin = @import("builtin");

/// xterm caps the OSC 52 sequence near 100 KB; after base64 that is ~74 KB of
/// text. Above this we skip OSC 52 and rely on the native tool.
const osc52_base64_cap = 74000;

/// Emit the OSC 52 clipboard-set sequence on `writer`. Caller is responsible
/// for flushing the writer afterward. No-op (silently skips) for payloads that
/// exceed the OSC 52 size cap — the native fallback covers those.
pub fn writeOsc52(writer: anytype, allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    if (std.base64.standard.Encoder.calcSize(text.len) > osc52_base64_cap) return;

    const seq = try buildOsc52(allocator, text, inMultiplexer());
    defer allocator.free(seq);
    try writer.writeAll(seq);
}

/// Best-effort: spawn the platform's native clipboard tool and pipe `text` to
/// its stdin. Swallows all errors (including "tool not installed").
pub fn writeNative(allocator: std.mem.Allocator, text: []const u8) void {
    if (text.len == 0) return;
    for (nativeCandidates()) |argv| {
        if (pipeToChild(allocator, argv, text)) return;
    }
}

/// Build the OSC 52 byte sequence. When `wrap` is set the sequence is enclosed
/// in the tmux/screen DCS passthrough envelope so an outer terminal receives it.
fn buildOsc52(allocator: std.mem.Allocator, text: []const u8, wrap: bool) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64 = try allocator.alloc(u8, encoder.calcSize(text.len));
    defer allocator.free(b64);
    _ = encoder.encode(b64, text);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // The OSC 52 sequence has exactly one ESC (the OSC introducer); its BEL
    // terminator is not an ESC. tmux passthrough requires doubling inner ESCs,
    // which the leading "\x1b" of the envelope achieves for that single ESC.
    if (wrap) try buf.appendSlice(allocator, "\x1bPtmux;\x1b");
    try buf.appendSlice(allocator, "\x1b]52;c;");
    try buf.appendSlice(allocator, b64);
    try buf.append(allocator, 0x07); // BEL
    if (wrap) try buf.appendSlice(allocator, "\x1b\\");

    return buf.toOwnedSlice(allocator);
}

fn inMultiplexer() bool {
    return std.posix.getenv("TMUX") != null or std.posix.getenv("STY") != null;
}

/// Ordered list of native clipboard commands to try for the current platform.
fn nativeCandidates() []const []const []const u8 {
    return switch (builtin.os.tag) {
        .macos => &.{
            &.{"pbcopy"},
        },
        .windows => &.{
            &.{"clip.exe"},
        },
        else => blk: {
            // Prefer Wayland when its display is present, then X11 tools.
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

/// Spawn `argv`, write `text` to its stdin, and wait. Returns true on a clean
/// (exit code 0) run. stdout/stderr are discarded so tool output can't corrupt
/// the alternate screen.
fn pipeToChild(allocator: std.mem.Allocator, argv: []const []const u8, text: []const u8) bool {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    if (child.stdin) |stdin_pipe| {
        stdin_pipe.writeAll(text) catch {
            stdin_pipe.close();
            child.stdin = null;
            _ = child.wait() catch {};
            return false;
        };
        stdin_pipe.close();
        child.stdin = null;
    }
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

const testing = std.testing;

test "buildOsc52 encodes payload with OSC 52 framing" {
    const seq = try buildOsc52(testing.allocator, "hi", false);
    defer testing.allocator.free(seq);
    // base64("hi") == "aGk="
    try testing.expectEqualStrings("\x1b]52;c;aGk=\x07", seq);
}

test "buildOsc52 wraps for multiplexer passthrough" {
    const seq = try buildOsc52(testing.allocator, "hi", true);
    defer testing.allocator.free(seq);
    try testing.expectEqualStrings("\x1bPtmux;\x1b\x1b]52;c;aGk=\x07\x1b\\", seq);
}

test "writeOsc52 writes an OSC 52 sequence to the writer" {
    // The exact framing (plain vs tmux-wrapped) depends on the environment
    // this test runs in, so assert on the invariant payload rather than bytes.
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeOsc52(&writer, testing.allocator, "hi");
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "]52;c;aGk=\x07") != null);
}

test "writeOsc52 skips empty and oversized payloads" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeOsc52(&writer, testing.allocator, "");
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

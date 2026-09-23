const std = @import("std");
const builtin = @import("builtin");

const osc52_base64_cap = 74000;

pub fn writeOsc52(writer: anytype, allocator: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return;
    if (std.base64.standard.Encoder.calcSize(text.len) > osc52_base64_cap) return;

    const seq = try buildOsc52(allocator, text, inMultiplexer());
    defer allocator.free(seq);
    try writer.writeAll(seq);
}

pub fn writeNative(allocator: std.mem.Allocator, text: []const u8) void {
    if (text.len == 0) return;
    for (nativeCandidates()) |argv| {
        if (pipeToChild(allocator, argv, text)) return;
    }
}

fn buildOsc52(allocator: std.mem.Allocator, text: []const u8, wrap: bool) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const b64 = try allocator.alloc(u8, encoder.calcSize(text.len));
    defer allocator.free(b64);
    _ = encoder.encode(b64, text);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (wrap) try buf.appendSlice(allocator, "\x1bPtmux;\x1b");
    try buf.appendSlice(allocator, "\x1b]52;c;");
    try buf.appendSlice(allocator, b64);
    try buf.append(allocator, 0x07);
    if (wrap) try buf.appendSlice(allocator, "\x1b\\");

    return buf.toOwnedSlice(allocator);
}

fn inMultiplexer() bool {
    return std.posix.getenv("TMUX") != null or std.posix.getenv("STY") != null;
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
    try testing.expectEqualStrings("\x1b]52;c;aGk=\x07", seq);
}

test "buildOsc52 wraps for multiplexer passthrough" {
    const seq = try buildOsc52(testing.allocator, "hi", true);
    defer testing.allocator.free(seq);
    try testing.expectEqualStrings("\x1bPtmux;\x1b\x1b]52;c;aGk=\x07\x1b\\", seq);
}

test "writeOsc52 writes an OSC 52 sequence to the writer" {
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

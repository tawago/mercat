const std = @import("std");
const clipboard = @import("clipboard.zig");

const testing = std.testing;
const decide = clipboard.decide;

test "plain OSC 52 outside screen, including under tmux" {
    var buf: [128]u8 = undefined;
    for ([_]clipboard.Mux{ .none, .tmux, .tmux_clipboard_off }) |mux| {
        var writer = std.Io.Writer.fixed(&buf);
        try testing.expectEqual(clipboard.Osc52Status.sent, try clipboard.writeOsc52(&writer, testing.allocator, "hi", mux));
        try testing.expectEqualStrings("\x1b]52;c;aGk=\x07", writer.buffered());
    }
}

test "GNU screen gets DCS passthrough, chunked" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    _ = try clipboard.writeOsc52(&writer, testing.allocator, "hi", .screen);
    try testing.expectEqualStrings("\x1bP\x1b]52;c;aGk=\x07\x1b\\", writer.buffered());

    var big_buf: [512]u8 = undefined;
    var big = std.Io.Writer.fixed(&big_buf);
    _ = try clipboard.writeOsc52(&big, testing.allocator, "x" ** 100, .screen);
    const out = big.buffered();
    try testing.expect(std.mem.count(u8, out, "\x1bP") >= 2);
    try testing.expect(std.mem.indexOf(u8, out, "tmux;") == null);
    try testing.expect(std.mem.endsWith(u8, out, "\x1b\\"));
}

test "writeOsc52 reports empty, oversized and failed writes" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try testing.expectEqual(clipboard.Osc52Status.empty, try clipboard.writeOsc52(&writer, testing.allocator, "", .none));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    const huge = try testing.allocator.alloc(u8, 60_000);
    defer testing.allocator.free(huge);
    @memset(huge, 'a');
    try testing.expectEqual(clipboard.Osc52Status.too_large, try clipboard.writeOsc52(&writer, testing.allocator, huge, .none));
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    try testing.expectEqual(clipboard.Osc52Status.write_failed, try clipboard.writeOsc52(&writer, testing.allocator, "more than sixteen bytes", .none));
}

test "decide: a working clipboard tool always counts" {
    const outcome = decide(.too_large, .{ .copied = "wl-copy" }, .tmux_clipboard_off);
    try testing.expect(outcome == .copied);
    try testing.expect(outcome.copied == .native);
}

test "decide: a sent OSC 52 counts unless tmux drops it" {
    try testing.expect(decide(.sent, .no_tool, .none).copied == .osc52);
    try testing.expect(decide(.sent, .no_tool, .tmux).copied == .osc52);
    try testing.expect(decide(.sent, .no_tool, .screen).copied == .osc52);
    try testing.expectEqual(clipboard.Failure.tmux_clipboard_off, decide(.sent, .no_tool, .tmux_clipboard_off).failed);
}

test "decide: failures name the reason" {
    try testing.expectEqual(clipboard.Failure.too_large, decide(.too_large, .no_tool, .none).failed);
    try testing.expectEqual(clipboard.Failure.too_large, decide(.too_large, .{ .failed = "xclip" }, .tmux).failed);
    try testing.expectEqual(clipboard.Failure.write_failed, decide(.write_failed, .no_tool, .none).failed);
    try testing.expectEqual(clipboard.Failure.no_tool, decide(.empty, .no_tool, .none).failed);
    try testing.expectEqual(clipboard.Failure.tool_failed, decide(.empty, .{ .failed = "xclip" }, .none).failed);
}

test "failure messages carry a hint" {
    try testing.expect(std.mem.indexOf(u8, clipboard.failureMessage(.too_large), "OSC 52") != null);
    try testing.expect(std.mem.indexOf(u8, clipboard.failureMessage(.tmux_clipboard_off), "set-clipboard on") != null);
    inline for (std.meta.fields(clipboard.Failure)) |field| {
        try testing.expect(std.mem.startsWith(u8, clipboard.failureMessage(@enumFromInt(field.value)), "Copy failed: "));
    }
}

fn clipboardOn() bool {
    return true;
}

fn clipboardOff() bool {
    return false;
}

fn mustNotAsk() bool {
    @panic("tmux was asked outside tmux");
}

test "detectMux: tmux first, then screen; tmux is asked only under tmux" {
    try testing.expectEqual(clipboard.Mux.none, clipboard.detectMux(.{ .tmux = false, .screen = false }, mustNotAsk));
    try testing.expectEqual(clipboard.Mux.screen, clipboard.detectMux(.{ .tmux = false, .screen = true }, mustNotAsk));
    try testing.expectEqual(clipboard.Mux.tmux, clipboard.detectMux(.{ .tmux = true, .screen = true }, clipboardOn));
    try testing.expectEqual(clipboard.Mux.tmux_clipboard_off, clipboard.detectMux(.{ .tmux = true, .screen = false }, clipboardOff));
}

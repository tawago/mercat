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

test "decide: a working tool always counts, OSC 52 counts unless tmux drops it, failures name the reason" {
    const Row = struct { osc52: clipboard.Osc52Status, native: clipboard.NativeStatus, mux: clipboard.Mux, want: clipboard.Outcome };
    const rows = [_]Row{
        .{ .osc52 = .too_large, .native = .{ .copied = "wl-copy" }, .mux = .tmux_clipboard_off, .want = .{ .copied = .native } },
        .{ .osc52 = .sent, .native = .no_tool, .mux = .none, .want = .{ .copied = .osc52 } },
        .{ .osc52 = .sent, .native = .no_tool, .mux = .tmux, .want = .{ .copied = .osc52 } },
        .{ .osc52 = .sent, .native = .no_tool, .mux = .screen, .want = .{ .copied = .osc52 } },
        .{ .osc52 = .sent, .native = .no_tool, .mux = .tmux_clipboard_off, .want = .{ .failed = .tmux_clipboard_off } },
        .{ .osc52 = .too_large, .native = .no_tool, .mux = .none, .want = .{ .failed = .too_large } },
        .{ .osc52 = .too_large, .native = .{ .failed = "xclip" }, .mux = .tmux, .want = .{ .failed = .too_large } },
        .{ .osc52 = .write_failed, .native = .no_tool, .mux = .none, .want = .{ .failed = .write_failed } },
        .{ .osc52 = .empty, .native = .no_tool, .mux = .none, .want = .{ .failed = .no_tool } },
        .{ .osc52 = .empty, .native = .{ .failed = "xclip" }, .mux = .none, .want = .{ .failed = .tool_failed } },
    };
    for (rows) |row| try testing.expectEqual(row.want, decide(row.osc52, row.native, row.mux));
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

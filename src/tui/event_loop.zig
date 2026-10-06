//! The TUI input loop: `vaxis.Loop` with a pre-decoder in front of the
//! parser. vaxis 0.5.1 drops `CSI 1 ~` / `CSI 4 ~` (Home/End from tmux, GNU
//! screen and the Linux console), so each sequence is passed through
//! `input.normalizeHomeEnd` before parsing. Everything else — the queue, the
//! winsize signal and event dispatch — is vaxis's own.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const input = @import("input.zig");

pub fn Loop(comptime T: type) type {
    return struct {
        const Self = @This();

        tty: *vaxis.Tty,
        vaxis: *vaxis.Vaxis,

        queue: vaxis.Queue(T, 512) = .{},
        thread: ?std.Thread = null,
        should_quit: bool = false,

        pub fn init(self: *Self) !void {
            if (builtin.os.tag == .windows or builtin.is_test) return;
            try vaxis.Tty.notifyWinsize(.{ .context = self, .callback = winsizeCallback });
        }

        pub fn start(self: *Self) !void {
            if (self.thread != null) return;
            self.thread = try std.Thread.spawn(.{}, ttyRun, .{ self, self.vaxis.opts.system_clipboard_allocator });
        }

        pub fn stop(self: *Self) void {
            const thread = self.thread orelse return;
            self.should_quit = true;
            // Ask the terminal for a report so the blocked read returns.
            self.vaxis.deviceStatusReport(self.tty.writer()) catch {};
            thread.join();
            self.thread = null;
            self.should_quit = false;
        }

        pub fn nextEvent(self: *Self) T {
            return self.queue.pop();
        }

        pub fn tryEvent(self: *Self) ?T {
            return self.queue.tryPop();
        }

        pub fn postEvent(self: *Self, event: T) void {
            self.queue.push(event);
        }

        pub fn tryPostEvent(self: *Self, event: T) bool {
            return self.queue.tryPush(event);
        }

        fn winsizeCallback(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.vaxis.state.in_band_resize) return;
            const winsize = vaxis.Tty.getWinsize(self.tty.fd) catch return;
            if (@hasField(T, "winsize")) self.postEvent(.{ .winsize = winsize });
        }

        fn ttyRun(self: *Self, paste_allocator: ?std.mem.Allocator) !void {
            if (builtin.is_test) return;
            var cache: vaxis.GraphemeCache = .{};
            if (@hasField(T, "winsize")) self.postEvent(.{ .winsize = try vaxis.Tty.getWinsize(self.tty.fd) });

            var parser: vaxis.Parser = .{};
            var buf: [1024]u8 = undefined;
            var len: usize = 0;
            while (!self.should_quit) {
                len += try self.tty.read(buf[len..]);
                var head: usize = 0;
                while (head < len) {
                    input.normalizeHomeEnd(buf[head..len]);
                    const result = try parser.parse(buf[head..len], paste_allocator);
                    if (result.n == 0) break; // incomplete: wait for more bytes
                    head += result.n;
                    const event = result.event orelse continue;
                    try vaxis.loop.handleEventGeneric(self, self.vaxis, &cache, T, event, paste_allocator);
                }
                std.mem.copyForwards(u8, buf[0 .. len - head], buf[head..len]);
                len -= head;
                // A sequence that fills the whole buffer never completes; drop it.
                if (len == buf.len) len = 0;
            }
        }
    };
}

const std = @import("std");
const vaxis = @import("vaxis");
const help = @import("help.zig");
const input = @import("../input.zig");
const theme = @import("../../core/theme.zig");

const HelpOverlay = help.HelpOverlay;

/// A screen-backed window, and its rows read back as text.
pub const TestScreen = struct {
    screen: vaxis.Screen,

    pub fn init(width: u16, height: u16) !TestScreen {
        return .{ .screen = try vaxis.Screen.init(std.testing.allocator, .{ .rows = height, .cols = width, .x_pixel = 0, .y_pixel = 0 }) };
    }

    pub fn deinit(self: *TestScreen) void {
        self.screen.deinit(std.testing.allocator);
    }

    pub fn window(self: *TestScreen) vaxis.Window {
        return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = self.screen.width, .height = self.screen.height, .screen = &self.screen };
    }

    /// The screen's text, one line per row.
    pub fn text(self: *TestScreen, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var y: u16 = 0;
        while (y < self.screen.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.screen.width) : (x += 1) {
                const cell = self.screen.readCell(x, y) orelse continue;
                if (cell.char.width == 0 and cell.char.grapheme.len == 0) continue;
                try out.appendSlice(allocator, if (cell.char.grapheme.len == 0) " " else cell.char.grapheme);
            }
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
    }
};

const style = theme.panelStyle(.default, .default, false);

fn drawText(overlay: *HelpOverlay, screen: *TestScreen) ![]u8 {
    const win = screen.window();
    win.clear();
    overlay.draw(win, win.height - 1, style);
    return screen.text(std.testing.allocator);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

fn expectContains(screen_text: []const u8, needle: []const u8) !void {
    if (contains(screen_text, needle)) return;
    std.debug.print("screen lacks '{s}':\n{s}\n", .{ needle, screen_text });
    return error.TestExpectedText;
}

fn expectLacks(screen_text: []const u8, needle: []const u8) !void {
    if (!contains(screen_text, needle)) return;
    std.debug.print("screen has '{s}':\n{s}\n", .{ needle, screen_text });
    return error.TestUnexpectedText;
}

test "80x24: the whole key table fits, titled, without scrolling" {
    var screen = try TestScreen.init(80, 24);
    defer screen.deinit();
    var overlay: HelpOverlay = .{};
    const text = try drawText(&overlay, &screen);
    defer std.testing.allocator.free(text);

    try std.testing.expectEqual(@as(usize, 0), overlay.max_scroll);
    try expectContains(text, help.title);
    for (std.enums.values(input.Section)) |section| try expectContains(text, section.title());
    for (input.bindings) |binding| try expectContains(text, binding.description);
    try expectContains(text, "q Ctrl-C");
    try expectLacks(text, "↓ more");
    try expectLacks(text, "…");
}

test "50x15: the card scrolls, marks more below, and the last entry is reachable" {
    var screen = try TestScreen.init(50, 15);
    defer screen.deinit();
    var overlay: HelpOverlay = .{};

    const first = try drawText(&overlay, &screen);
    defer std.testing.allocator.free(first);
    try std.testing.expect(overlay.max_scroll > 0);
    try expectContains(first, "↓ more");
    try expectContains(first, "Line down");
    try expectLacks(first, "Quit");
    try expectLacks(first, "…");

    // Page down until the end, as PgDn would.
    var pages: usize = 0;
    while (overlay.scroll < overlay.max_scroll and pages < 10) : (pages += 1) {
        overlay.scrollBy(@intCast(overlay.page_rows));
    }
    const last = try drawText(&overlay, &screen);
    defer std.testing.allocator.free(last);
    try expectContains(last, "Quit");
    try expectContains(last, "q Ctrl-C");
    try expectLacks(last, "↓ more");
    try expectContains(last, "↑");
    for (input.bindings[input.bindings.len - 3 ..]) |binding| try expectContains(last, binding.description);
}

test "resizing larger clamps the scroll offset" {
    var screen = try TestScreen.init(50, 15);
    defer screen.deinit();
    var overlay: HelpOverlay = .{};
    const small = try drawText(&overlay, &screen);
    std.testing.allocator.free(small);
    overlay.scrollTo(std.math.maxInt(usize));
    try std.testing.expect(overlay.scroll > 0);

    var big = try TestScreen.init(100, 40);
    defer big.deinit();
    const text = try drawText(&overlay, &big);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqual(@as(usize, 0), overlay.scroll);
    try expectContains(text, "Line down");
}

test "the document behind the card is dimmed, the status row is not" {
    var screen = try TestScreen.init(80, 24);
    defer screen.deinit();
    const win = screen.window();
    _ = win.print(&.{.{ .text = "document text" }}, .{ .row_offset = 0 });
    _ = win.print(&.{.{ .text = "status" }}, .{ .row_offset = 23 });
    var overlay: HelpOverlay = .{};
    overlay.draw(win, 23, style);
    try std.testing.expect(win.readCell(0, 0).?.style.dim);
    try std.testing.expectEqualStrings("d", win.readCell(0, 0).?.char.grapheme);
    try std.testing.expect(!win.readCell(0, 23).?.style.dim);
}

test "a very small screen draws nothing rather than crashing" {
    var screen = try TestScreen.init(5, 3);
    defer screen.deinit();
    var overlay: HelpOverlay = .{};
    const text = try drawText(&overlay, &screen);
    defer std.testing.allocator.free(text);
}

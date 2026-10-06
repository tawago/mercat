const std = @import("std");
const unicode = @import("unicode");
const statusbar = @import("statusbar.zig");
const Viewport = @import("viewport.zig").Viewport;

const allocator = std.testing.allocator;

fn view(top: usize, height: usize, total: usize) Viewport {
    var v = Viewport{};
    v.setMetrics(height, total);
    v.top = top;
    return v;
}

fn expectBar(bar: statusbar.Bar, width: usize) !void {
    try std.testing.expect(std.unicode.utf8ValidateSlice(bar.text));
    try std.testing.expectEqual(width, try unicode.rawDisplayWidth(bar.text));
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "position: line range with percent, or Top / Bot / All" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("L 30-58/897 6%", statusbar.position(&buf, view(29, 29, 897), 80));
    try std.testing.expectEqualStrings("L 1-23/241 Top", statusbar.position(&buf, view(0, 23, 241), 80));
    try std.testing.expectEqualStrings("L 219-241/241 Bot", statusbar.position(&buf, view(218, 23, 241), 80));
    try std.testing.expectEqualStrings("L 1-5/5 All", statusbar.position(&buf, view(0, 23, 5), 80));
    try std.testing.expectEqualStrings("6%", statusbar.position(&buf, view(29, 29, 897), 10));
}

test "full width: file name left, position right" {
    const bar = try statusbar.render(allocator, .{ .title = "/tmp/README.md", .width = 64, .view = view(5, 10, 30) });
    defer bar.deinit(allocator);
    try expectBar(bar, 64);
    try std.testing.expect(std.mem.startsWith(u8, bar.text, " README.md"));
    try std.testing.expect(std.mem.endsWith(u8, bar.text, "L 6-15/30 50% "));
    try std.testing.expect(contains(bar.text, "? help"));
    try std.testing.expect(bar.cursor_col == null);
}

test "a message never hides the position" {
    const long = "Copy failed: selection too large for OSC 52 — install wl-copy, xclip or xsel";
    const bar = try statusbar.render(allocator, .{ .title = "README.md", .width = 50, .view = view(0, 14, 300), .message = long });
    defer bar.deinit(allocator);
    try expectBar(bar, 50);
    try std.testing.expect(std.mem.startsWith(u8, bar.text, " Copy failed"));
    try std.testing.expect(contains(bar.text, "…"));
    try std.testing.expect(std.mem.endsWith(u8, bar.text, "L 1-14/300 Top "));
    try std.testing.expect(!contains(bar.text, "? help"));
}

test "a short message follows the file name" {
    const bar = try statusbar.render(allocator, .{ .title = "doc.md", .width = 80, .view = view(0, 10, 5), .message = "Reloaded doc.md" });
    defer bar.deinit(allocator);
    try expectBar(bar, 80);
    try std.testing.expect(std.mem.startsWith(u8, bar.text, " doc.md  Reloaded doc.md "));
}

test "CJK file names and messages are clipped by display width, never mid-character" {
    const title = "日本語のとても長いファイル名のドキュメントです.md";
    for ([_]usize{ 20, 21, 30, 31, 40, 50, 80 }) |width| {
        const bar = try statusbar.render(allocator, .{ .title = title, .width = width, .view = view(10, 10, 100) });
        defer bar.deinit(allocator);
        try expectBar(bar, width);
        try std.testing.expect(contains(bar.text, "%"));

        const with_message = try statusbar.render(allocator, .{ .title = title, .width = width, .view = view(10, 10, 100), .message = "検索：一致するものがありません" });
        defer with_message.deinit(allocator);
        try expectBar(with_message, width);
    }
}

test "the search prompt keeps the typed tail visible and places the cursor after it" {
    const query = "とても長い検索語句をここに入力しています末尾";
    const bar = try statusbar.render(allocator, .{ .title = "README.md", .width = 40, .view = view(0, 10, 100), .prompt = query });
    defer bar.deinit(allocator);
    try expectBar(bar, 40);
    try std.testing.expect(std.mem.startsWith(u8, bar.text, " …"));
    const left_end = std.mem.indexOf(u8, bar.text, "末尾").? + "末尾".len;
    try std.testing.expectEqual(unicode.displayWidth(bar.text[0..left_end]), bar.cursor_col.?);
    try std.testing.expect(std.mem.endsWith(u8, bar.text, "Top "));

    const short = try statusbar.render(allocator, .{ .title = "README.md", .width = 40, .view = view(0, 10, 100), .prompt = "日本" });
    defer short.deinit(allocator);
    try expectBar(short, 40);
    try std.testing.expect(std.mem.startsWith(u8, short.text, " /日本 "));
    try std.testing.expectEqual(@as(usize, 6), short.cursor_col.?);
}

test "tailToWidth keeps whole graphemes" {
    try std.testing.expectEqualStrings("語", statusbar.tailToWidth("日本語", 3));
    try std.testing.expectEqualStrings("本語", statusbar.tailToWidth("日本語", 4));
    try std.testing.expectEqualStrings("abc", statusbar.tailToWidth("abc", 5));
    try std.testing.expectEqualStrings("", statusbar.tailToWidth("日", 1));
}

test "tiny widths do not crash" {
    for ([_]usize{ 0, 1, 2, 3, 5, 8 }) |width| {
        const bar = try statusbar.render(allocator, .{ .title = "README.md", .width = width, .view = view(3, 10, 100), .prompt = "abc" });
        defer bar.deinit(allocator);
        try std.testing.expect(unicode.displayWidth(bar.text) <= @max(width, 1));
    }
}

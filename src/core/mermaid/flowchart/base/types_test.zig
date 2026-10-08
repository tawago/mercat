const std = @import("std");
const prim = @import("types.zig");

const displayWidth = prim.displayWidth;
const wrapToWidth = prim.wrapToWidth;

test "prim: wrapToWidth splits on spaces, hard breaks and grapheme boundaries" {
    const a = std.testing.allocator;
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const Row = struct { text: []const u8, cap: u32, want: ?[]const []const u8 = null, first: ?[]const u8 = null };
    const rows = [_]Row{
        .{ .text = "the quick brown fox", .cap = 10, .want = &.{ "the quick", "brown fox" } },
        // Width 0 is the "do not wrap" guard.
        .{ .text = "anything here", .cap = 0, .want = &.{"anything here"} },
        .{ .text = "alpha\nbeta gamma", .cap = 99, .want = &.{ "alpha", "beta gamma" } },
        .{ .text = "one two\nthree four five", .cap = 8, .want = &.{ "one two", "three", "four", "five" } },
        .{ .text = "abcdefghij", .cap = 4, .want = &.{ "abcd", "efgh", "ij" } },
        .{ .text = "hi superlongword", .cap = 6, .first = "hi" },
        .{ .text = "日本語テスト", .cap = 4 },
        .{ .text = "e\u{0301}e\u{0301}e\u{0301}", .cap = 2, .want = &.{ "e\u{0301}e\u{0301}", "e\u{0301}" } },
        // A cluster wider than the cap still advances one glyph per line.
        .{ .text = family ++ family, .cap = 1, .want = &.{ family, family } },
    };
    for (rows) |row| {
        const lines = try wrapToWidth(a, row.text, row.cap);
        defer a.free(lines);
        if (row.want) |want| {
            try std.testing.expectEqual(want.len, lines.len);
            for (want, lines) |w, l| try std.testing.expectEqualStrings(w, l);
        }
        if (row.first) |first| try std.testing.expectEqualStrings(first, lines[0]);
        if (row.cap > 1) for (lines) |l| try std.testing.expect(displayWidth(l) <= row.cap);
    }
}

test "prim: wrapToWidth never exceeds its cap on text the strict measure rejects" {
    const a = std.testing.allocator;
    const inputs = [_][]const u8{
        "e\u{0301}\u{200B}e\u{0301}e\u{0301}",
        "\u{00AD}e\u{0301}e\u{0301}e\u{0301}",
        "e\u{0301}\x01e\u{0301}e\u{0301}",
        "e\u{0301}\xffe\u{0301}e\u{0301} \x80\x80e\u{0301}",
    };
    for (inputs) |text| {
        var cap: u32 = 1;
        while (cap <= 4) : (cap += 1) {
            const lines = try wrapToWidth(a, text, cap);
            defer a.free(lines);
            for (lines) |line| try std.testing.expect(displayWidth(line) <= cap);
        }
    }
    const three = try wrapToWidth(a, "\u{00AD}e\u{0301}e\u{0301}e\u{0301}", 3);
    defer a.free(three);
    try std.testing.expectEqual(@as(usize, 2), three.len);
    try std.testing.expectEqualStrings("\u{00AD}e\u{0301}e\u{0301}", three[0]);
    try std.testing.expectEqualStrings("e\u{0301}", three[1]);
}

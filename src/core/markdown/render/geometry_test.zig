const std = @import("std");
const unicode = @import("unicode");
const geometry = @import("geometry.zig");

test "Markdown geometry covers emoji CJK variation keycap and regional indicators" {
    const cases = [_]struct { text: []const u8, width: usize }{
        .{ .text = "日", .width = 2 },
        .{ .text = "👩‍💻", .width = 2 },
        .{ .text = "🇯🇵", .width = 2 },
        .{ .text = "©️", .width = 2 },
        .{ .text = "©︎", .width = 1 },
        .{ .text = "#️⃣", .width = 2 },
    };
    for (cases) |case| try std.testing.expectEqual(case.width, try geometry.displayWidth(case.text));
}

test "Markdown preparation keeps precomposed and decomposed bytes with equal geometry" {
    var composed = try unicode.PreparedLine.init(std.testing.allocator, "é");
    defer composed.deinit();
    var decomposed = try unicode.PreparedLine.init(std.testing.allocator, "e\u{0301}");
    defer decomposed.deinit();
    try std.testing.expectEqual(composed.total_columns, decomposed.total_columns);
    try std.testing.expectEqualStrings("é", composed.bytes);
    try std.testing.expectEqualStrings("e\u{0301}", decomposed.bytes);
}

test "Markdown clipping is inward around a width-two grapheme" {
    const text = "A日B";
    try std.testing.expectEqual(@as(usize, 1), try geometry.takeWidth(text, 1, 0));
    try std.testing.expectEqual(@as(usize, 1), try geometry.takeWidth(text, 2, 0));
    try std.testing.expectEqual(@as(usize, 4), try geometry.takeWidth(text, 3, 0));
}

test "Markdown strict geometry propagates invalid input" {
    try std.testing.expectError(error.InvalidUtf8, geometry.displayWidth("\x80"));
    try std.testing.expectError(error.DisallowedControl, geometry.displayWidth("a\x1bb"));
}

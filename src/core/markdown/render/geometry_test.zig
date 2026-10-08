const std = @import("std");
const geometry = @import("geometry.zig");

test "Markdown clipping is inward around a width-two grapheme" {
    const text = "A日B";
    try std.testing.expectEqual(@as(usize, 1), try geometry.takeWidth(text, 1, 0));
    try std.testing.expectEqual(@as(usize, 1), try geometry.takeWidth(text, 2, 0));
    try std.testing.expectEqual(@as(usize, 4), try geometry.takeWidth(text, 3, 0));
}

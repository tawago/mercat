const std = @import("std");
const tb_text = @import("tb_text.zig");

const testing = std.testing;

fn expectLines(texts: *const tb_text.Texts, t: u32, want: []const []const u8) !void {
    const lines = texts.of(t);
    try testing.expectEqual(want.len, lines.len);
    for (want, lines) |w, line| try testing.expectEqualStrings(w, line.bytes);
}

test "a break splits the widest line at the space nearest its middle, the left one on a tie" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var texts = try tb_text.Texts.init(arena.allocator(), &.{ "upload a very large file", "ab cd ef", "one<br>two words here", "nospace" });
    try testing.expect(try texts.breakOnce(0));
    try expectLines(&texts, 0, &.{ "upload a very", "large file" });
    try testing.expect(try texts.breakOnce(1));
    try expectLines(&texts, 1, &.{ "ab", "cd ef" });
    try testing.expect(try texts.breakOnce(2));
    try expectLines(&texts, 2, &.{ "one", "two words", "here" });
    try testing.expect(!texts.canBreak(3));
    try testing.expect(!try texts.breakOnce(3));
    try expectLines(&texts, 3, &.{"nospace"});
}

test "breaks repeat until the widest line has no space, and no word is ever split" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var texts = try tb_text.Texts.init(arena.allocator(), &.{"Commit normalized value + Domain event"});
    while (try texts.breakOnce(0)) {}
    try testing.expectEqual(@as(u32, 10), texts.widest(0));
    try testing.expect(!texts.canBreak(0));
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(testing.allocator);
    for (texts.of(0), 0..) |line, i| {
        if (i > 0) try joined.append(testing.allocator, ' ');
        try joined.appendSlice(testing.allocator, line.bytes);
    }
    try testing.expectEqualStrings("Commit normalized value + Domain event", joined.items);
}

test "an empty text has no lines; br tags force lines; widths are display columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const texts = try tb_text.Texts.init(arena.allocator(), &.{ "", "a<br/>b", "日本 語" });
    try testing.expectEqual(@as(u32, 0), texts.count(0));
    try testing.expectEqual(@as(u32, 2), texts.count(1));
    try testing.expectEqual(@as(u32, 7), texts.widest(2));
}

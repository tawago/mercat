const std = @import("std");
const prim = @import("prim");
const scanner = @import("scanner.zig");

const Scanner = scanner.Scanner;
const Kind = scanner.Kind;
const t = std.testing;

test "tokens" {
    var sc = Scanner.init("ab_1 \"q r\" [x]\r\n>| %% note");
    const want = [_]struct { Kind, []const u8 }{
        .{ .word, "ab_1" }, .{ .string, "q r" },   .{ .open, "[" },  .{ .word, "x" },
        .{ .close, "]" },   .{ .newline, "\r\n" }, .{ .other, ">" }, .{ .pipe, "|" },
        .{ .eof, "" },
    };
    for (want) |w| {
        const tok = sc.next();
        try t.expectEqual(w[0], tok.kind);
        try t.expectEqualStrings(w[1], tok.text);
    }
}

test "a bracket token carries its byte" {
    var sc = Scanner.init("{)");
    try t.expectEqual(@as(u8, '{'), sc.next().bracket);
    try t.expectEqual(@as(u8, ')'), sc.next().bracket);
}

test "a string stops at the closing quote or the end of the line" {
    var sc = Scanner.init("\"open\nnext");
    const s = sc.next();
    try t.expectEqual(Kind.string, s.kind);
    try t.expectEqualStrings("open", s.text);
    try t.expectEqual(Kind.newline, sc.next().kind);
}

test "a comment runs to the end of the line and keeps the newline" {
    var sc = Scanner.init("a %% c ; | x\nb");
    try t.expectEqualStrings("a", sc.next().text);
    try t.expectEqual(Kind.newline, sc.next().kind);
    try t.expectEqualStrings("b", sc.next().text);
}

test "a byte outside the word set is one other token" {
    var sc = Scanner.init("\xc3\xa9");
    try t.expectEqual(Kind.other, sc.next().kind);
    try t.expectEqual(Kind.other, sc.next().kind);
    try t.expectEqual(Kind.eof, sc.next().kind);
}

test "raw spans keep quoted text opaque" {
    var sc = Scanner.init("\"a]b\"] rest");
    try t.expectEqualStrings("a]b", sc.rawUntil(']'));
    try t.expectEqualStrings(" rest", sc.src[sc.pos..]);
}

test "a raw span stops at the end of the line and leaves it" {
    var sc = Scanner.init("abc\nd]");
    try t.expectEqualStrings("abc", sc.rawUntil(']'));
    try t.expectEqual(@as(u8, '\n'), sc.at(0));
}

test "a raw span with a string terminator skips the terminator" {
    var sc = Scanner.init("a]b]]c");
    try t.expectEqualStrings("a]b", sc.rawUntilStr("]]"));
    try t.expectEqualStrings("c", sc.src[sc.pos..]);
}

test "an unterminated string terminator span skips past the line end" {
    var sc = Scanner.init("ab\ncd");
    try t.expectEqualStrings("ab", sc.rawUntilStr("))"));
    try t.expectEqual(@as(usize, 4), sc.pos);
}

test "skipping the rest of a line stops at a semicolon, quoted or not, and at a newline" {
    var sc = Scanner.init("fill:#f \"a;b\"; next\nmore");
    sc.skipRest();
    try t.expectEqual(@as(u8, 'a'), sc.src[sc.pos - 1]);
    try t.expectEqual(@as(u8, ';'), sc.at(0));
    sc.skip(1);
    sc.skipRest();
    try t.expectEqual(@as(u8, '"'), sc.src[sc.pos - 1]);
    try t.expectEqual(@as(u8, ';'), sc.at(0));
    sc.skip(1);
    sc.skipRest();
    try t.expectEqual(@as(u8, '\n'), sc.at(0));
    sc.skip(1);
    sc.skipRest();
    try t.expect(sc.done());
}

test "unquote trims blanks and one matching pair of quotes" {
    try t.expectEqualStrings("a b", scanner.unquote("  \"a b\" \r"));
    try t.expectEqualStrings("a b", scanner.unquote("'a b'"));
    try t.expectEqualStrings("\"a'", scanner.unquote("\"a'"));
    try t.expectEqualStrings("\"", scanner.unquote("\""));
}

test "line breaks become the label line break" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try scanner.breaks(arena.allocator(), "a<br>b<BR />c\\nd<br");
    try t.expectEqualStrings("a" ++ [_]u8{prim.LINE_BREAK} ++ "b" ++ [_]u8{prim.LINE_BREAK} ++ "c" ++ [_]u8{prim.LINE_BREAK} ++ "d<br", got);
}

test "text without a line break is returned as it is" {
    const text = "plain <b> text";
    try t.expectEqual(text.ptr, (try scanner.breaks(t.failing_allocator, text)).ptr);
}

test "a break marker tolerates blanks and a slash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try scanner.breaks(arena.allocator(), "a<br  />b<br/>c<br\t>d");
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, got, &.{prim.LINE_BREAK}));
    try t.expectEqualStrings("abcd", try std.mem.replaceOwned(u8, arena.allocator(), got, &.{prim.LINE_BREAK}, ""));
}

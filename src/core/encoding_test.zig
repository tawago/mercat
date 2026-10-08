const std = @import("std");
const encoding = @import("encoding.zig");

const testing = std.testing;

fn expectDecoded(input: []const u8, want: []const u8, issue: ?encoding.Issue) !void {
    const decoded = try encoding.decode(testing.allocator, input);
    defer decoded.deinit(testing.allocator);
    try testing.expectEqualStrings(want, decoded.text);
    try testing.expect(std.unicode.utf8ValidateSlice(decoded.text));
    try testing.expectEqual(issue, decoded.issue);
}

test "UTF-8 byte order mark is dropped" {
    try expectDecoded("\xEF\xBB\xBF# hi\n", "# hi\n", null);
}

test "maximal subpart replacement (Unicode Table 3-8 examples)" {
    // Unicode 15 §3.9, Table 3-8: 61 F1 80 80 E1 80 C2 62 80 63 80 BF 64
    // decodes to a FFFD FFFD FFFD b FFFD c FFFD FFFD d.
    try expectDecoded(
        "a\xF1\x80\x80\xE1\x80\xC2b\x80c\x80\xBFd",
        "a\u{FFFD}\u{FFFD}\u{FFFD}b\u{FFFD}c\u{FFFD}\u{FFFD}d",
        .{ .line = 1, .column = 2, .replaced = 9 },
    );
}

test "repro byte patterns decode to one U+FFFD per maximal subpart" {
    // 01: lone FF.
    try expectDecoded("ok \xFF bye\n", "ok \u{FFFD} bye\n", .{ .line = 1, .column = 4, .replaced = 1 });
    // 03: Windows-1252 quotes and dash, each one byte.
    try expectDecoded("said \x93hi\x94 \x96 x", "said \u{FFFD}hi\u{FFFD} \u{FFFD} x", .{ .line = 1, .column = 6, .replaced = 3 });
    // 04: truncated three-byte sequence at end of line is one subpart.
    try expectDecoded("5 \xE2\x82\nnext\n", "5 \u{FFFD}\nnext\n", .{ .line = 1, .column = 3, .replaced = 2 });
    // 05: overlong C0 AF: C0 is never a valid lead, so two replacements.
    try expectDecoded("/:\xC0\xAF.", "/:\u{FFFD}\u{FFFD}.", .{ .line = 1, .column = 3, .replaced = 2 });
    // 06: encoded surrogate ED A0 80: ED only takes 80..9F, so three.
    try expectDecoded("s \xED\xA0\x80 h", "s \u{FFFD}\u{FFFD}\u{FFFD} h", .{ .line = 1, .column = 3, .replaced = 3 });
    // Truncated four-byte sequence at end of input.
    try expectDecoded("x\xF0\x9F\x98", "x\u{FFFD}", .{ .line = 1, .column = 2, .replaced = 3 });
    // Bytes above F4 never start a sequence.
    try expectDecoded("\xF5\xF8\xFE", "\u{FFFD}\u{FFFD}\u{FFFD}", .{ .line = 1, .column = 1, .replaced = 3 });
}

test "issue position is the first replacement, counted in characters" {
    // Line 3; "é" before the bad byte is one character.
    try expectDecoded("a\nb\n\u{e9}x\xFFy\n\xFF\n", "a\nb\n\u{e9}x\u{FFFD}y\n\u{FFFD}\n", .{ .line = 3, .column = 3, .replaced = 2 });
}

test "UTF-16 with a byte order mark is transcoded" {
    try expectDecoded("\xFF\xFE#\x00 \x00H\x00i\x00\n\x00", "# Hi\n", null);
    try expectDecoded("\xFE\xFF\x00#\x00 \x00H\x00i\x00\n", "# Hi\n", null);
    // U+1F600 as a surrogate pair, little endian.
    try expectDecoded("\xFF\xFE\x3D\xD8\x00\xDE", "\u{1F600}", null);
    const decoded = try encoding.decode(testing.allocator, "\xFF\xFEa\x00");
    defer decoded.deinit(testing.allocator);
    try testing.expectEqual(encoding.Encoding.utf16le, decoded.encoding);
}

test "UTF-16 unpaired surrogates and an odd byte are replaced" {
    try expectDecoded("\xFF\xFEa\x00\x00\xD8b\x00", "a\u{FFFD}b", .{ .line = 1, .column = 2, .replaced = 1 });
    try expectDecoded("\xFF\xFEa\x00\x00\xDC", "a\u{FFFD}", .{ .line = 1, .column = 2, .replaced = 1 });
    try expectDecoded("\xFF\xFEa\x00b", "a\u{FFFD}", .{ .line = 1, .column = 2, .replaced = 1 });
}

test "describeIssue formats the warning" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "doc.md: invalid UTF-8 at line 3, column 7 (2 bytes replaced with U+FFFD)",
        encoding.describeIssue(&buf, "doc.md", .utf8, .{ .line = 3, .column = 7, .replaced = 2 }),
    );
    try testing.expectEqualStrings(
        "stdin: invalid UTF-8 at line 1, column 1 (1 byte replaced with U+FFFD)",
        encoding.describeIssue(&buf, "stdin", .utf8, .{ .line = 1, .column = 1, .replaced = 1 }),
    );
    try testing.expectEqualStrings(
        "x.md: invalid UTF-16 at line 1, column 2 (1 code unit replaced with U+FFFD)",
        encoding.describeIssue(&buf, "x.md", .utf16le, .{ .line = 1, .column = 2, .replaced = 1 }),
    );
}

const std = @import("std");
const unicode = @import("../unicode.zig");
const segmentation = @import("segmentation.zig");
const tables = @import("tables.zig");

const testing = std.testing;

test "Unicode 17 official GraphemeBreakTest boundaries" {
    const data = try std.fs.cwd().readFileAlloc(testing.allocator, "vendor/unicode/17.0.0/GraphemeBreakTest.txt", 1024 * 1024);
    defer testing.allocator.free(data);
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var cases: usize = 0;
    while (lines.next()) |raw| {
        const hash = std.mem.indexOfScalar(u8, raw, '#') orelse raw.len;
        const body = std.mem.trim(u8, raw[0..hash], " \t\r");
        if (body.len == 0) continue;
        cases += 1;

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(testing.allocator);
        var expected: std.ArrayList(usize) = .empty;
        defer expected.deinit(testing.allocator);
        var tokens = std.mem.tokenizeAny(u8, body, " \t");
        var expect_boundary = false;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "÷")) {
                expect_boundary = true;
                continue;
            }
            if (std.mem.eql(u8, token, "×")) {
                expect_boundary = false;
                continue;
            }
            if (expect_boundary) try expected.append(testing.allocator, bytes.items.len);
            const cp: u21 = @intCast(try std.fmt.parseInt(u32, token, 16));
            var encoded: [4]u8 = undefined;
            const len = try std.unicode.utf8Encode(cp, &encoded);
            try bytes.appendSlice(testing.allocator, encoded[0..len]);
            expect_boundary = false;
        }
        if (expect_boundary) try expected.append(testing.allocator, bytes.items.len);

        var actual: std.ArrayList(usize) = .empty;
        defer actual.deinit(testing.allocator);
        try actual.append(testing.allocator, 0);
        var byte_index: usize = 0;
        while (byte_index < bytes.items.len) {
            byte_index = try segmentation.nextBoundary(bytes.items, byte_index);
            try actual.append(testing.allocator, byte_index);
        }
        try testing.expectEqualSlices(usize, expected.items, actual.items);
    }
    try testing.expectEqual(@as(usize, 766), cases);
}

test "Indic conjuncts follow GB9c over whole strings" {
    const conjunct = "क्\u{0937}";
    var iterator = unicode.Iterator.init(conjunct);
    const first = (try iterator.next()).?;
    try testing.expectEqualStrings(conjunct, first.bytes);
    try testing.expect((try iterator.next()) == null);

    var broken = unicode.Iterator.init("क्a");
    try testing.expectEqualStrings("क्", (try broken.next()).?.bytes);
    try testing.expectEqualStrings("a", (try broken.next()).?.bytes);
}

test "EAW W and F are two while ambiguous is one" {
    try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth("⌚"));
    try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth("✅"));
    try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth("⭐"));
    try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth("ꥠ")); // U+A960
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("·"));
    try testing.expectEqual(@as(usize, 4), try unicode.rawDisplayWidth("日本"));
    try testing.expect(!tables.wide.contains(0x2309));
    try testing.expect(tables.wide.contains(0x231a));
    try testing.expect(tables.wide.contains(0x2e80));
    try testing.expect(tables.wide.contains(0x2fffd));
    try testing.expect(!tables.wide.contains(0x2fffe));
    try testing.expect(tables.wide.contains(0x30000));
    try testing.expect(!tables.wide.contains(0x2704));
    try testing.expect(!tables.wide.contains(0x2b4f));
    try testing.expect(!tables.wide.contains(0xa95f));
    try testing.expect(tables.wide.contains(0xa97c));
    try testing.expect(!tables.wide.contains(0xa97d));
}

test "text and emoji presentation policy" {
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("©"));
    try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth("©️"));
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("©︎"));
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("1"));
    try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth("1️"));
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("1︎"));
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("#"));
    try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth("#️"));
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("#︎"));
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("⌚︎"));
}

test "RGI modifiers keycaps tags flags and ZWJ sequences are width two" {
    const cases = [_][]const u8{
        "👍🏽",
        "#️⃣",
        "🏴\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}",
        "🇯🇵",
        "👩‍💻",
        "👨‍👩‍👧‍👦",
    };
    for (cases) |case| try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth(case));
    try testing.expectEqual(@as(usize, 2), try unicode.rawDisplayWidth("🏽"));
    try testing.expectEqual(@as(usize, 4), try unicode.rawDisplayWidth("🇯🇵🇺🇸"));
}

test "standalone combining mark is a one-cell defective grapheme" {
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("\u{0301}"));
    try testing.expectEqual(@as(usize, 1), try unicode.rawDisplayWidth("e\u{0301}"));
}

test "precomposed and decomposed text keep bytes but have equal geometry" {
    var composed = try unicode.PreparedLine.init(testing.allocator, "é");
    defer composed.deinit();
    var decomposed = try unicode.PreparedLine.init(testing.allocator, "e\u{0301}");
    defer decomposed.deinit();
    try testing.expectEqual(composed.total_columns, decomposed.total_columns);
    try testing.expectEqualStrings("é", composed.bytes);
    try testing.expectEqualStrings("e\u{0301}", decomposed.bytes);
    try testing.expect(!std.mem.eql(u8, composed.bytes, decomposed.bytes));
}

test "PreparedLine expands tabs at four-column stops" {
    const cases = [_]struct { text: []const u8, bytes: []const u8, columns: usize }{
        .{ .text = "\t", .bytes = "    ", .columns = 4 },
        .{ .text = "a\t", .bytes = "a   ", .columns = 4 },
        .{ .text = "ab\t", .bytes = "ab  ", .columns = 4 },
        .{ .text = "abc\t", .bytes = "abc ", .columns = 4 },
        .{ .text = "abcd\t", .bytes = "abcd    ", .columns = 8 },
        .{ .text = "日\t", .bytes = "日  ", .columns = 4 },
    };
    for (cases) |case| {
        var line = try unicode.PreparedLine.init(testing.allocator, case.text);
        defer line.deinit();
        try testing.expectEqualStrings(case.bytes, line.bytes);
        try testing.expectEqual(case.columns, line.total_columns);
    }
}

test "strict APIs reject malformed UTF-8 and controls" {
    const invalid = [_][]const u8{ "\x80", "\xc0\xaf", "\xe2\x82", "\xed\xa0\x80" };
    for (invalid) |text| try testing.expectError(error.InvalidUtf8, unicode.rawDisplayWidth(text));
    const controls = [_][]const u8{ "\x00", "\x1b", "\x7f", "\xc2\x80", "a\nb", "a\rb", "a\u{2028}b" };
    for (controls) |text| try testing.expectError(error.DisallowedControl, unicode.rawDisplayWidth(text));
    try testing.expectEqual(@as(usize, 4), try unicode.rawDisplayWidth("\t"));
    try testing.expectError(error.Overflow, unicode.rawDisplayWidthFrom("a", std.math.maxInt(usize)));
}

test "format controls are rejected while sanctioned shaping controls remain" {
    const rejected = [_][]const u8{
        "\u{00ad}", // GCB Control
        "\u{061c}", // Arabic letter mark
        "\u{200b}", // Zero-width space
        "\u{200e}", // Left-to-right mark
        "\u{202e}", // Right-to-left override
        "\u{2060}", // Word joiner
        "\u{2066}", // Left-to-right isolate
        "\u{feff}", // Zero-width no-break space
        "\u{e0001}", // Language tag
        "\u{e0061}", // Isolated emoji tag component
        "🏴\u{e0061}\u{e007f}", // Not an RGI tag sequence
    };
    for (rejected) |text| try testing.expectError(error.DisallowedControl, unicode.rawDisplayWidth(text));

    const allowed = [_][]const u8{
        "a\u{200c}", // ZWNJ, GCB Extend
        "a\u{200d}", // ZWJ
        "a\u{180b}", // Mongolian variation selector
        "a\u{fe0f}", // Emoji variation selector
        "a\u{e0100}", // Supplementary variation selector
        "🏴\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}",
    };
    for (allowed) |text| _ = try unicode.rawDisplayWidth(text);
}

test "strict clipping validates suffixes before returning" {
    try testing.expectError(error.InvalidUtf8, unicode.rawPrefixToWidth("a\x80", 1));
    try testing.expectError(error.DisallowedControl, unicode.rawPrefixToWidth("a\u{2060}", 1));
    try testing.expectError(error.InvalidUtf8, unicode.rawColumnRange("a\x80", 0, 0));
    try testing.expectError(error.DisallowedControl, unicode.rawColumnRange("a\u{2060}", 0, 1));

    var iterator = unicode.Iterator.init("a\x80");
    try testing.expectError(error.InvalidUtf8, iterator.next());
}

test "prefix and column ranges never split graphemes" {
    const text = "A👩‍💻e\u{0301}日Z";
    try testing.expectEqualStrings("A", try unicode.rawPrefixToWidth(text, 2));
    try testing.expectEqualStrings("A👩‍💻", try unicode.rawPrefixToWidth(text, 3));
    try testing.expectEqualStrings("👩‍💻e\u{0301}", try unicode.rawColumnRange(text, 1, 4));
    try testing.expectEqualStrings("", try unicode.rawColumnRange(text, 2, 3));
    try testing.expectEqualStrings("日", try unicode.rawColumnRange(text, 4, 6));

    var line = try unicode.PreparedLine.init(testing.allocator, text);
    defer line.deinit();
    try testing.expectEqualStrings("A👩‍💻", line.prefixToWidth(3));
    try testing.expectEqualStrings("👩‍💻e\u{0301}", line.columnRange(1, 4));
}

test "legacy wrappers remain available during migration" {
    const glyph = unicode.nextGlyph("e\u{0301}日", 0);
    try testing.expectEqualStrings("e\u{0301}", glyph.bytes);
    try testing.expectEqual(@as(usize, 1), glyph.width);
    try testing.expectEqual(@as(usize, 3), unicode.displayWidth("e\u{0301}日"));
    try testing.expectEqualStrings("e\u{0301}", unicode.clipToWidth("e\u{0301}日", 1));
}

test "legacy boundaries stop before malformed UTF-8 without splitting graphemes" {
    const scalar = "日\x80";
    const scalar_glyph = unicode.nextGlyph(scalar, 0);
    try testing.expectEqualStrings("日", scalar_glyph.bytes);
    try testing.expectEqual(@as(usize, 2), scalar_glyph.width);
    try testing.expect(std.unicode.utf8ValidateSlice(scalar_glyph.bytes));
    const scalar_bad = unicode.nextGlyph(scalar, "日".len);
    try testing.expectEqual(@as(usize, 0), scalar_bad.bytes.len);
    try testing.expectEqual(@as(usize, 0), scalar_bad.width);
    try testing.expect(std.unicode.utf8ValidateSlice(scalar_bad.bytes));
    try testing.expectError(error.InvalidUtf8, unicode.rawDisplayWidth(scalar));

    const grapheme = "👩‍💻\x80";
    const grapheme_glyph = unicode.nextGlyph(grapheme, 0);
    try testing.expectEqualStrings("👩‍💻", grapheme_glyph.bytes);
    try testing.expectEqual(@as(usize, 2), grapheme_glyph.width);
    try testing.expect(std.unicode.utf8ValidateSlice(grapheme_glyph.bytes));
    try testing.expectError(error.InvalidUtf8, unicode.rawPrefixToWidth(grapheme, 2));

    const malformed_first = "\x80a";
    const malformed_glyph = unicode.nextGlyph(malformed_first, 0);
    try testing.expectEqual(@as(usize, 0), malformed_glyph.bytes.len);
    try testing.expectEqual(@as(usize, 0), malformed_glyph.width);
    try testing.expect(std.unicode.utf8ValidateSlice(malformed_glyph.bytes));

    const truncated = "\xe2\x82";
    const truncated_glyph = unicode.nextGlyph(truncated, 0);
    try testing.expectEqual(@as(usize, 0), truncated_glyph.bytes.len);
    try testing.expectEqual(@as(usize, 0), truncated_glyph.width);
    try testing.expect(std.unicode.utf8ValidateSlice(truncated_glyph.bytes));
    try testing.expectError(error.InvalidUtf8, unicode.rawDisplayWidth(truncated));
}

test "legacy clipping returns only valid UTF-8 around malformed boundaries" {
    const Case = struct {
        text: []const u8,
        expected: []const []const u8,
    };
    const cases = [_]Case{
        .{ .text = "日\x80", .expected = &.{ "", "", "日", "日" } },
        .{ .text = "👩‍💻\x80", .expected = &.{ "", "", "👩‍💻", "👩‍💻" } },
        .{ .text = "\x80a", .expected = &.{ "", "", "", "" } },
        .{ .text = "\xe2\x82", .expected = &.{ "", "", "", "" } },
        .{ .text = "A\xe2\x82", .expected = &.{ "", "A", "A", "A" } },
    };
    for (cases) |case| {
        for (case.expected, 0..) |expected, width| {
            const clipped = unicode.clipToWidth(case.text, width);
            try testing.expectEqualStrings(expected, clipped);
            try testing.expect(std.unicode.utf8ValidateSlice(clipped));
        }
    }

    const wrapped = try unicode.wrapLine(testing.allocator, "ok 日\x80bad", 80, "\x80");
    defer {
        for (wrapped) |line| testing.allocator.free(line);
        testing.allocator.free(wrapped);
    }
    try testing.expectEqual(@as(usize, 1), wrapped.len);
    try testing.expectEqualStrings("ok 日", wrapped[0]);
    try testing.expect(std.unicode.utf8ValidateSlice(wrapped[0]));
}

test "legacy cursor walks long input with linear counted work" {
    const text = "a" ** 4096;
    var cursor = unicode.LegacyCursor.init(text);
    var glyphs: usize = 0;
    while (cursor.next()) |_| glyphs += 1;
    try testing.expectEqual(text.len, glyphs);
    try testing.expectEqual(text.len * 3 - 1, cursor.scalar_operations);

    var tabs = unicode.LegacyCursor.init("a\tb");
    try testing.expectEqual(@as(usize, 1), tabs.next().?.width);
    try testing.expectEqual(@as(usize, 3), tabs.next().?.width);
    try testing.expectEqual(@as(usize, 1), tabs.next().?.width);
}

test "legacy cursor traversal is linear and remains stopped at malformed input" {
    const scalar_count = 1024;
    const text = ("日" ** scalar_count) ++ "\x80ignored";
    for (0..3) |_| {
        var cursor = unicode.LegacyCursor.init(text);
        var count: usize = 0;
        while (cursor.next()) |glyph| {
            try testing.expectEqualStrings("日", glyph.bytes);
            try testing.expect(std.unicode.utf8ValidateSlice(glyph.bytes));
            count += 1;
        }
        try testing.expectEqual(@as(usize, scalar_count), count);
        try testing.expectEqual("日".len * scalar_count, cursor.index);
        try testing.expectEqual(@as(usize, scalar_count * 3 + 1), cursor.scalar_operations);

        const stopped_operations = cursor.scalar_operations;
        for (0..16) |_| try testing.expect(cursor.next() == null);
        try testing.expectEqual(stopped_operations, cursor.scalar_operations);
    }

    var malformed_first = unicode.LegacyCursor.init("\x80a");
    try testing.expect(malformed_first.next() == null);
    try testing.expectEqual(@as(usize, 1), malformed_first.scalar_operations);
    try testing.expect(malformed_first.next() == null);
    try testing.expectEqual(@as(usize, 1), malformed_first.scalar_operations);
}

test "public iterator starts spans at the requested slice boundary" {
    var iterator = unicode.Iterator.init("a👩‍💻");
    try testing.expectEqualStrings("a", (try iterator.next()).?.bytes);
    try testing.expectEqualStrings("👩‍💻", (try iterator.next()).?.bytes);

    var suffix = unicode.Iterator.init("👩‍💻");
    const grapheme = (try suffix.next()).?;
    try testing.expectEqual(@as(usize, 0), grapheme.byte_start);
    try testing.expectEqualStrings("👩‍💻", grapheme.bytes);
}

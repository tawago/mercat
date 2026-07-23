const std = @import("std");

/// YAML front matter detection and lightweight key/value extraction.
///
/// A front matter block is only recognized at byte offset 0: an opening
/// `---` line, then anything up to the next line that is exactly `---`.
/// A `---` later in the document is a thematic break and is never touched.

pub const Split = struct {
    /// Text between the fences, excluding both `---` lines. Null when the
    /// source has no front matter block.
    yaml: ?[]const u8,
    /// Remaining document after the closing fence (the whole source when
    /// there is no front matter).
    body: []const u8,
};

pub fn split(source: []const u8) Split {
    const no_match: Split = .{ .yaml = null, .body = source };
    const opening = fenceLineLength(source) orelse return no_match;

    var index: usize = opening;
    while (index < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, index, '\n') orelse source.len;
        const line = std.mem.trimRight(u8, source[index..line_end], "\r");
        if (std.mem.eql(u8, line, "---")) {
            const body_start = @min(line_end + 1, source.len);
            return .{ .yaml = source[opening..index], .body = source[body_start..] };
        }
        index = @min(line_end + 1, source.len);
        if (line_end == source.len) break;
    }
    return no_match;
}

/// Length of the opening `---` line including its newline, or null when the
/// source does not open with a front matter fence.
fn fenceLineLength(source: []const u8) ?usize {
    if (!std.mem.startsWith(u8, source, "---")) return null;
    var index: usize = 3;
    if (index < source.len and source[index] == '\r') index += 1;
    if (index >= source.len or source[index] != '\n') return null;
    return index + 1;
}

pub const Entry = struct {
    /// Empty for lines that are not a simple `key: value` pair (nested YAML,
    /// list items, continuations); `value` then holds the raw line.
    key: []const u8,
    value: []const u8,
};

/// Split the YAML text into display entries. Slices point into `yaml`; no
/// allocation is done for the text itself, only for the entry list.
/// This is deliberately not a YAML parser: top-level `key: value` lines are
/// split, everything else is kept verbatim so no information is lost.
pub fn parseEntries(allocator: std.mem.Allocator, yaml: []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    var lines = std.mem.splitScalar(u8, yaml, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;

        if (topLevelKeyLength(line)) |key_len| {
            try entries.append(allocator, .{
                .key = line[0..key_len],
                .value = std.mem.trim(u8, line[key_len + 1 ..], " \t"),
            });
        } else {
            try entries.append(allocator, .{ .key = "", .value = line });
        }
    }
    return entries.toOwnedSlice(allocator);
}

/// Byte length of a top-level YAML key on `line` (the text before the mapping
/// colon), or null when the line is indented, a list item, or has no colon in
/// key position. A quoted key (`"a:b": value`) keeps its quotes so a colon
/// inside the quotes is not mistaken for the separator.
fn topLevelKeyLength(line: []const u8) ?usize {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '-' or line[0] == '#') return null;

    var colon: usize = undefined;
    if (line[0] == '"' or line[0] == '\'') {
        const close = quotedScalarEnd(line, line[0]) orelse return null;
        // The mapping colon must immediately follow the closing quote.
        if (close + 1 >= line.len or line[close + 1] != ':') return null;
        colon = close + 1;
    } else {
        colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        if (colon == 0) return null;
    }
    // `key:` must be followed by a space, a tab, or the end of the line
    // (an empty value). YAML permits a tab after the colon just like a space.
    if (colon + 1 < line.len and line[colon + 1] != ' ' and line[colon + 1] != '\t') return null;
    return colon;
}

/// Index of the closing quote of the quoted scalar that begins at `line[0]`,
/// or null when the quote is never closed. Handles `\"` escapes in double
/// quotes and `''` doubling in single quotes.
fn quotedScalarEnd(line: []const u8, quote: u8) ?usize {
    var i: usize = 1;
    while (i < line.len) : (i += 1) {
        if (quote == '"' and line[i] == '\\') {
            i += 1; // skip the escaped character
            continue;
        }
        if (line[i] == quote) {
            if (quote == '\'' and i + 1 < line.len and line[i + 1] == '\'') {
                i += 1; // '' is an escaped single quote, not the terminator
                continue;
            }
            return i;
        }
    }
    return null;
}

test "split extracts front matter and body" {
    const result = split("---\ntitle: Test\nauthor: Foo\n---\n\n# Heading\n");
    try std.testing.expectEqualStrings("title: Test\nauthor: Foo\n", result.yaml.?);
    try std.testing.expectEqualStrings("\n# Heading\n", result.body);
}

test "split requires the fence at offset zero" {
    const source = "# Heading\n\n---\n";
    const result = split(source);
    try std.testing.expect(result.yaml == null);
    try std.testing.expectEqualStrings(source, result.body);
}

test "split without closing fence is not front matter" {
    const source = "---\ntitle: Test\n";
    const result = split(source);
    try std.testing.expect(result.yaml == null);
    try std.testing.expectEqualStrings(source, result.body);
}

test "split handles CRLF and closing fence at EOF" {
    const crlf = split("---\r\ntitle: Test\r\n---\r\nbody");
    try std.testing.expectEqualStrings("title: Test\r\n", crlf.yaml.?);
    try std.testing.expectEqualStrings("body", crlf.body);

    const at_eof = split("---\ntitle: Test\n---");
    try std.testing.expectEqualStrings("title: Test\n", at_eof.yaml.?);
    try std.testing.expectEqualStrings("", at_eof.body);
}

test "split of empty front matter yields empty yaml" {
    const result = split("---\n---\nbody");
    try std.testing.expectEqualStrings("", result.yaml.?);
    try std.testing.expectEqualStrings("body", result.body);
}

test "parseEntries splits simple pairs and keeps complex lines raw" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator,
        \\title: Test
        \\tags: [a, b]
        \\authors:
        \\  - Foo
        \\url: https://example.com/x
        \\
    );
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expectEqualStrings("title", entries[0].key);
    try std.testing.expectEqualStrings("Test", entries[0].value);
    try std.testing.expectEqualStrings("tags", entries[1].key);
    try std.testing.expectEqualStrings("[a, b]", entries[1].value);
    try std.testing.expectEqualStrings("authors", entries[2].key);
    try std.testing.expectEqualStrings("", entries[2].value);
    // Indented list item stays a raw line.
    try std.testing.expectEqualStrings("", entries[3].key);
    try std.testing.expectEqualStrings("  - Foo", entries[3].value);
    // The colon inside the URL does not re-split the value.
    try std.testing.expectEqualStrings("url", entries[4].key);
    try std.testing.expectEqualStrings("https://example.com/x", entries[4].value);
}

test "parseEntries handles quoted keys and tab-after-colon" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "\"a:b\": value\nkey:\tvalue\n'q': v\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    // A colon inside a quoted key is not the mapping separator.
    try std.testing.expectEqualStrings("\"a:b\"", entries[0].key);
    try std.testing.expectEqualStrings("value", entries[0].value);
    // A tab after the colon is a valid mapping separator.
    try std.testing.expectEqualStrings("key", entries[1].key);
    try std.testing.expectEqualStrings("value", entries[1].value);
    // Single-quoted keys work too.
    try std.testing.expectEqualStrings("'q'", entries[2].key);
    try std.testing.expectEqualStrings("v", entries[2].value);
}

test "frontmatter: opening fence with trailing content is rejected" {
    // A trailing space on the opener means it is not exactly "---\n".
    const source = "--- \ntitle: x\n---\n";
    const result = split(source);
    try std.testing.expect(result.yaml == null);
    try std.testing.expectEqualStrings(source, result.body);
}

test "frontmatter: four dashes is not a fence opener" {
    const source = "----\ntitle: x\n---\n";
    const result = split(source);
    try std.testing.expect(result.yaml == null);
    try std.testing.expectEqualStrings(source, result.body);
}

test "frontmatter: closing fence with trailing space does not match" {
    // Only \r is trimmed from the candidate closing line, not spaces, so
    // "--- " is not recognized as the closing fence and no block is found.
    const source = "---\ntitle: x\n--- \nbody";
    const result = split(source);
    try std.testing.expect(result.yaml == null);
    try std.testing.expectEqualStrings(source, result.body);
}

test "frontmatter: opener with no closing fence before EOF is not front matter" {
    const source = "---\n";
    const result = split(source);
    try std.testing.expect(result.yaml == null);
    try std.testing.expectEqualStrings(source, result.body);
}

test "frontmatter: parseEntries keeps duplicate keys as separate entries" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "a: 1\na: 2\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a", entries[0].key);
    try std.testing.expectEqualStrings("1", entries[0].value);
    try std.testing.expectEqualStrings("a", entries[1].key);
    try std.testing.expectEqualStrings("2", entries[1].value);
}

test "frontmatter: parseEntries treats a comment line as raw" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "# comment\nkey: val\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    // A leading '#' makes topLevelKeyLength return null, so the whole line is raw.
    try std.testing.expectEqualStrings("", entries[0].key);
    try std.testing.expectEqualStrings("# comment", entries[0].value);
    try std.testing.expectEqualStrings("key", entries[1].key);
    try std.testing.expectEqualStrings("val", entries[1].value);
}

test "frontmatter: parseEntries empty value with colon at end of line" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "key:\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("key", entries[0].key);
    try std.testing.expectEqualStrings("", entries[0].value);
}

test "frontmatter: parseEntries rejects colon with no following space" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "a:b\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    // The mapping colon must be followed by space, tab, or EOL, so this is raw.
    try std.testing.expectEqualStrings("", entries[0].key);
    try std.testing.expectEqualStrings("a:b", entries[0].value);
}

test "frontmatter: parseEntries unterminated quoted key falls back to raw" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "\"unclosed: value\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    // quotedScalarEnd returns null for the unclosed quote, so the line is raw.
    try std.testing.expectEqualStrings("", entries[0].key);
    try std.testing.expectEqualStrings("\"unclosed: value", entries[0].value);
}

test "frontmatter: parseEntries single-quote doubling inside key" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "'it''s': v\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    // The '' is an escaped quote, so the key includes it and the value is v.
    try std.testing.expectEqualStrings("'it''s'", entries[0].key);
    try std.testing.expectEqualStrings("v", entries[0].value);
}

test "frontmatter: parseEntries rejects colon at position zero" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, ":value\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("", entries[0].key);
    try std.testing.expectEqualStrings(":value", entries[0].value);
}

test "frontmatter: parseEntries skips blank and whitespace-only lines" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "a: 1\n   \n\t\nb: 2\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a", entries[0].key);
    try std.testing.expectEqualStrings("1", entries[0].value);
    try std.testing.expectEqualStrings("b", entries[1].key);
    try std.testing.expectEqualStrings("2", entries[1].value);
}

test "frontmatter: parseEntries splits non-ASCII keys correctly" {
    const allocator = std.testing.allocator;
    const entries = try parseEntries(allocator, "café: value\n");
    defer allocator.free(entries);

    try std.testing.expectEqual(@as(usize, 1), entries.len);
    // The key slice is the raw multibyte bytes, unmodified.
    try std.testing.expectEqualStrings("café", entries[0].key);
    try std.testing.expectEqualStrings("value", entries[0].value);
}

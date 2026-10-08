const std = @import("std");

pub const Split = struct {
    yaml: ?[]const u8,
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

fn fenceLineLength(source: []const u8) ?usize {
    if (!std.mem.startsWith(u8, source, "---")) return null;
    var index: usize = 3;
    if (index < source.len and source[index] == '\r') index += 1;
    if (index >= source.len or source[index] != '\n') return null;
    return index + 1;
}

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

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

fn topLevelKeyLength(line: []const u8) ?usize {
    if (line.len == 0 or line[0] == ' ' or line[0] == '\t' or line[0] == '-' or line[0] == '#') return null;

    var colon: usize = undefined;
    if (line[0] == '"' or line[0] == '\'') {
        const close = quotedScalarEnd(line, line[0]) orelse return null;
        if (close + 1 >= line.len or line[close + 1] != ':') return null;
        colon = close + 1;
    } else {
        colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
        if (colon == 0) return null;
    }
    if (colon + 1 < line.len and line[colon + 1] != ' ' and line[colon + 1] != '\t') return null;
    return colon;
}

fn quotedScalarEnd(line: []const u8, quote: u8) ?usize {
    var i: usize = 1;
    while (i < line.len) : (i += 1) {
        if (quote == '"' and line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == quote) {
            if (quote == '\'' and i + 1 < line.len and line[i + 1] == '\'') {
                i += 1;
                continue;
            }
            return i;
        }
    }
    return null;
}

test "split recognizes only an exact leading --- fence pair" {
    const cases = [_]struct { source: []const u8, yaml: ?[]const u8, body: ?[]const u8 = null }{
        .{ .source = "---\ntitle: Test\nauthor: Foo\n---\n\n# Heading\n", .yaml = "title: Test\nauthor: Foo\n", .body = "\n# Heading\n" },
        .{ .source = "---\r\ntitle: Test\r\n---\r\nbody", .yaml = "title: Test\r\n", .body = "body" },
        .{ .source = "---\ntitle: Test\n---", .yaml = "title: Test\n", .body = "" },
        .{ .source = "---\n---\nbody", .yaml = "", .body = "body" },
        // Not front matter: the whole source stays the body.
        .{ .source = "# Heading\n\n---\n", .yaml = null },
        .{ .source = "---\ntitle: Test\n", .yaml = null },
        .{ .source = "--- \ntitle: x\n---\n", .yaml = null },
        .{ .source = "----\ntitle: x\n---\n", .yaml = null },
        .{ .source = "---\ntitle: x\n--- \nbody", .yaml = null },
        .{ .source = "---\n", .yaml = null },
    };
    for (cases) |case| {
        errdefer std.debug.print("source: {s}\n", .{case.source});
        const result = split(case.source);
        if (case.yaml) |yaml| {
            try std.testing.expectEqualStrings(yaml, result.yaml.?);
        } else {
            try std.testing.expect(result.yaml == null);
        }
        try std.testing.expectEqualStrings(case.body orelse case.source, result.body);
    }
}

test "parseEntries splits top-level key: value and keeps everything else raw" {
    const cases = [_]struct { yaml: []const u8, want: []const Entry }{
        .{ .yaml = "title: Test\ntags: [a, b]\nauthors:\n  - Foo\nurl: https://example.com/x\n", .want = &.{
            .{ .key = "title", .value = "Test" },                .{ .key = "tags", .value = "[a, b]" },
            .{ .key = "authors", .value = "" },                  .{ .key = "", .value = "  - Foo" },
            .{ .key = "url", .value = "https://example.com/x" },
        } },
        .{ .yaml = "\"a:b\": value\nkey:\tvalue\n'q': v\n", .want = &.{
            .{ .key = "\"a:b\"", .value = "value" }, .{ .key = "key", .value = "value" }, .{ .key = "'q'", .value = "v" },
        } },
        .{ .yaml = "a: 1\na: 2\n", .want = &.{ .{ .key = "a", .value = "1" }, .{ .key = "a", .value = "2" } } },
        .{ .yaml = "# comment\nkey: val\n", .want = &.{ .{ .key = "", .value = "# comment" }, .{ .key = "key", .value = "val" } } },
        .{ .yaml = "key:\n", .want = &.{.{ .key = "key", .value = "" }} },
        .{ .yaml = "a:b\n", .want = &.{.{ .key = "", .value = "a:b" }} },
        .{ .yaml = "\"unclosed: value\n", .want = &.{.{ .key = "", .value = "\"unclosed: value" }} },
        .{ .yaml = "'it''s': v\n", .want = &.{.{ .key = "'it''s'", .value = "v" }} },
        .{ .yaml = ":value\n", .want = &.{.{ .key = "", .value = ":value" }} },
        .{ .yaml = "a: 1\n   \n\t\nb: 2\n", .want = &.{ .{ .key = "a", .value = "1" }, .{ .key = "b", .value = "2" } } },
        .{ .yaml = "café: value\n", .want = &.{.{ .key = "café", .value = "value" }} },
    };
    for (cases) |case| {
        errdefer std.debug.print("yaml: {s}\n", .{case.yaml});
        const entries = try parseEntries(std.testing.allocator, case.yaml);
        defer std.testing.allocator.free(entries);
        try std.testing.expectEqual(case.want.len, entries.len);
        for (case.want, entries) |want, got| {
            try std.testing.expectEqualStrings(want.key, got.key);
            try std.testing.expectEqualStrings(want.value, got.value);
        }
    }
}

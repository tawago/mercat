//! Canonical plain UTF-8 serialization of a `Rendered` value.
//!
//! This is the byte-exact text artifact consumed by external tooling,
//! so it must be free of all presentation escapes. The rules are:
//!
//! - concatenate each line's span text before grapheme segmentation;
//! - place one LF between adjacent `Line` values;
//! - include one final LF when at least one line exists;
//! - expand tabs to spaces at four-column stops;
//! - reject controls under the Unicode authority's strict policy. Line
//!   boundaries are structural, so no line-break scalar belongs in span text;
//! - preserve every other grapheme's exact UTF-8 bytes, including leading and
//!   trailing spaces and normalization form;
//! - reject invalid UTF-8;
//! - do not trim blank lines.

const std = @import("std");
const render_model = @import("../core/markdown/render/types.zig");
const unicode = @import("unicode");

pub const Error = std.mem.Allocator.Error || error{
    /// A span carried a control scalar the plain artifact must never contain.
    /// Tabs are the one exception and expand to spaces at four-column stops.
    InvalidPlainByte,
    /// A span carried bytes that are not valid UTF-8.
    InvalidUtf8,
};

/// Serialize `rendered` into the canonical plain byte sequence. Caller owns
/// the returned slice.
pub fn serialize(allocator: std.mem.Allocator, rendered: render_model.Rendered) Error![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    for (rendered.lines, 0..) |line, line_index| {
        if (line_index != 0) try buffer.append(allocator, '\n');
        const logical_line = try line.joinedText(allocator);
        defer allocator.free(logical_line);

        var graphemes = unicode.Iterator.init(logical_line);
        while (try nextGrapheme(&graphemes)) |grapheme| {
            if (grapheme.bytes.len == 1 and grapheme.bytes[0] == '\t') {
                try buffer.appendNTimes(allocator, ' ', grapheme.width);
            } else {
                try buffer.appendSlice(allocator, grapheme.bytes);
            }
        }
    }

    if (rendered.lines.len != 0) try buffer.append(allocator, '\n');

    return buffer.toOwnedSlice(allocator);
}

fn nextGrapheme(iterator: *unicode.Iterator) Error!?unicode.GraphemeSlice {
    return iterator.next() catch |err| switch (err) {
        error.InvalidUtf8 => error.InvalidUtf8,
        error.DisallowedControl, error.Overflow => error.InvalidPlainByte,
    };
}

const testing = std.testing;

const Span = render_model.Span;
const Line = render_model.Line;
const Rendered = render_model.Rendered;

fn makeSpan(text: []const u8) Span {
    return .{ .text = text, .style = .body };
}

test "empty document produces no bytes" {
    const rendered = Rendered{ .lines = &.{} };
    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "single line gets one trailing newline" {
    var spans = [_]Span{makeSpan("hello")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };

    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello\n", out);
}

test "spans concatenate in order and lines join with lf" {
    var spans0 = [_]Span{ makeSpan("foo"), makeSpan("bar") };
    var spans1 = [_]Span{makeSpan("baz")};
    var lines = [_]Line{ .{ .spans = &spans0 }, .{ .spans = &spans1 } };
    const rendered = Rendered{ .lines = &lines };

    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("foobar\nbaz\n", out);
}

test "blank lines are preserved not trimmed" {
    var spans0 = [_]Span{makeSpan("a")};
    var spans_empty = [_]Span{};
    var spans2 = [_]Span{makeSpan("b")};
    var lines = [_]Line{
        .{ .spans = &spans0 },
        .{ .spans = &spans_empty },
        .{ .spans = &spans2 },
    };
    const rendered = Rendered{ .lines = &lines };

    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a\n\nb\n", out);
}

test "leading and trailing spaces are preserved" {
    var spans = [_]Span{makeSpan("  indented text  ")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };

    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("  indented text  \n", out);
}

test "a line of only empty spans still contributes a row" {
    var spans_empty = [_]Span{};
    var lines = [_]Line{ .{ .spans = &spans_empty }, .{ .spans = &spans_empty } };
    const rendered = Rendered{ .lines = &lines };

    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("\n\n", out);
}

test "multibyte utf8 is preserved" {
    var spans = [_]Span{makeSpan("├─ café →")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };

    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("├─ café →\n", out);
}

test "printable ASCII remains byte-identical" {
    const ascii = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
    var spans = [_]Span{makeSpan(ascii)};
    var lines = [_]Line{.{ .spans = &spans }};
    const out = try serialize(testing.allocator, .{ .lines = &lines });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(ascii ++ "\n", out);
}

test "rejects esc byte" {
    var spans = [_]Span{makeSpan("\x1b[31mred")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects nul byte" {
    var spans = [_]Span{makeSpan("a\x00b")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects carriage return byte" {
    var spans = [_]Span{makeSpan("a\rb")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "tabs expand at four-column stops including after wide graphemes" {
    var spans = [_]Span{makeSpan("\ta\t日\tx")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("    a   日  x\n", out);
}

test "rejects a generic C0 control (bell)" {
    var spans = [_]Span{makeSpan("a\x07b")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects DEL" {
    var spans = [_]Span{makeSpan("a\x7fb")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects a bare LF inside span text (line breaks are structural)" {
    var spans = [_]Span{makeSpan("a\nb")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects utf8-encoded c1 csi introducer" {
    var spans = [_]Span{makeSpan("\xc2\x9b[31mred")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects utf8-encoded c1 osc introducer" {
    var spans = [_]Span{makeSpan("a\xc2\x9db")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects a Unicode format control with the existing typed error" {
    var spans = [_]Span{makeSpan("a\u{2060}b")};
    var lines = [_]Line{.{ .spans = &spans }};
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, .{ .lines = &lines }));
}

test "rejects invalid utf8" {
    var spans = [_]Span{makeSpan("\xff\xfe")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidUtf8, serialize(testing.allocator, rendered));
}

test "preserves grapheme bytes across spans without normalization" {
    var split = [_]Span{ makeSpan("e"), makeSpan("\u{0301}") };
    var split_lines = [_]Line{.{ .spans = &split }};
    const decomposed = try serialize(testing.allocator, .{ .lines = &split_lines });
    defer testing.allocator.free(decomposed);

    var joined = [_]Span{makeSpan("é")};
    var joined_lines = [_]Line{.{ .spans = &joined }};
    const composed = try serialize(testing.allocator, .{ .lines = &joined_lines });
    defer testing.allocator.free(composed);

    try testing.expectEqualStrings("e\u{0301}\n", decomposed);
    try testing.expectEqualStrings("é\n", composed);
    try testing.expect(!std.mem.eql(u8, decomposed, composed));
}

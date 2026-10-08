const std = @import("std");
const render_model = @import("../core/markdown/render/types.zig");
const unicode = @import("unicode");

pub const Error = std.mem.Allocator.Error || error{
    InvalidPlainByte,
    InvalidUtf8,
};

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

test "tabs expand at four-column stops including after wide graphemes" {
    var spans = [_]Span{makeSpan("\ta\t日\tx")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    const out = try serialize(testing.allocator, rendered);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("    a   日  x\n", out);
}

test "rejects terminal escapes, embedded line feeds and invalid utf8" {
    const cases = [_]struct { text: []const u8, err: Error }{
        .{ .text = "\x1b[31mred", .err = error.InvalidPlainByte },
        .{ .text = "\xc2\x9b[31mred", .err = error.InvalidPlainByte },
        .{ .text = "a\nb", .err = error.InvalidPlainByte },
        .{ .text = "\xff\xfe", .err = error.InvalidUtf8 },
    };
    for (cases) |case| {
        var spans = [_]Span{makeSpan(case.text)};
        var lines = [_]Line{.{ .spans = &spans }};
        try testing.expectError(case.err, serialize(testing.allocator, .{ .lines = &lines }));
    }
}

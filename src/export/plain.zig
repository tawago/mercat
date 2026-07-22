//! Canonical plain UTF-8 serialization of a `Rendered` value.
//!
//! This is the byte-exact text artifact consumed by external tooling,
//! so it must be free of all presentation escapes. The rules are:
//!
//! - concatenate span text in order;
//! - place one LF between adjacent `Line` values;
//! - include one final LF when at least one line exists;
//! - reject the exact same control scalars the PNG layout rejects
//!   (`export/layout.zig` `scalarCells`): tab, every C0 control, DEL, and the
//!   C1 controls U+0080–U+009F (whose UTF-8 encodings xterm-family terminals
//!   interpret as one-byte CSI/OSC introducers). Line boundaries are
//!   structural (between `Line` values), so no control scalar — not even LF —
//!   ever belongs inside span text. Keeping this identical to the layout
//!   policy guarantees the paired text/PNG artifacts accept the same corpus;
//! - preserve all other span text bytes, including leading and trailing spaces;
//! - reject invalid UTF-8;
//! - do not trim blank lines.

const std = @import("std");
const render_model = @import("../core/render_model.zig");

pub const Error = std.mem.Allocator.Error || error{
    /// A span carried a control scalar the plain artifact must never contain:
    /// tab, any C0 control (NUL, CR, the ESC that introduces ANSI/OSC
    /// sequences, ...), DEL, or a C1 control (U+0080–U+009F) whose UTF-8 form
    /// is a live terminal introducer. Identical to the PNG layout policy.
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
        for (line.spans) |span| {
            try validateSpan(span.text);
            try buffer.appendSlice(allocator, span.text);
        }
    }

    // One final LF when at least one line exists.
    if (rendered.lines.len != 0) try buffer.append(allocator, '\n');

    return buffer.toOwnedSlice(allocator);
}

fn validateSpan(text: []const u8) Error!void {
    // Decode as UTF-8 so C1 controls encoded as multi-byte scalars
    // (U+0080–U+009F, e.g. UTF-8 0xC2 0x9B = CSI, 0xC2 0x9D = OSC) are caught
    // rather than slipping through a byte-only scan. The rejected set is
    // identical to `export/layout.zig` `scalarCells`: tab + all C0 + DEL + C1.
    const view = std.unicode.Utf8View.init(text) catch return error.InvalidUtf8;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        // C0 controls (incl. tab, LF, CR, ESC), DEL, and C1 controls. Line
        // boundaries are structural, so no control scalar belongs in span text.
        if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return error.InvalidPlainByte;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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

test "rejects tab (aligned with layout scalar policy)" {
    var spans = [_]Span{makeSpan("a\tb")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
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
    // U+009B (CSI) encodes as 0xC2 0x9B; xterm interprets it as a live control.
    var spans = [_]Span{makeSpan("\xc2\x9b[31mred")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects utf8-encoded c1 osc introducer" {
    // U+009D (OSC) encodes as 0xC2 0x9D.
    var spans = [_]Span{makeSpan("a\xc2\x9db")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidPlainByte, serialize(testing.allocator, rendered));
}

test "rejects invalid utf8" {
    var spans = [_]Span{makeSpan("\xff\xfe")};
    var lines = [_]Line{.{ .spans = &spans }};
    const rendered = Rendered{ .lines = &lines };
    try testing.expectError(error.InvalidUtf8, serialize(testing.allocator, rendered));
}

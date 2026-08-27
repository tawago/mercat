//! Mouse text selection for the TUI pager.
//!
//! A selection is a linear span of rendered text expressed in
//! (document line, display column) coordinates.  It is deliberately decoupled
//! from vaxis: highlighting reads `rangeForLine`, and copy reads `extractText`,
//! both operating on the already-rendered lines that the pager owns. Columns
//! are 0-based display columns. Selection bounds are half-open;
//! copying includes every displayed grapheme that overlaps `[start, end)`.
//! Copied text preserves the render model's original bytes. Tabs therefore
//! remain tabs on the clipboard, but their selection geometry uses the actual
//! four-column stop of the full displayed line.

const std = @import("std");
const unicode = @import("unicode");

const copy_preview_cols: usize = 40;

pub const Point = struct {
    line: usize = 0,
    col: usize = 0,

    fn lessThan(self: Point, other: Point) bool {
        if (self.line != other.line) return self.line < other.line;
        return self.col < other.col;
    }
};

pub const Range = struct { start: usize, end: usize };

pub const Selection = struct {
    active: bool = false,
    anchor: Point = .{},
    cursor: Point = .{},

    pub fn begin(self: *Selection, line: usize, col: usize) void {
        self.active = true;
        self.anchor = .{ .line = line, .col = col };
        self.cursor = self.anchor;
    }

    pub fn extendTo(self: *Selection, line: usize, col: usize) void {
        self.cursor = .{ .line = line, .col = col };
    }

    pub fn clear(self: *Selection) void {
        self.active = false;
    }

    /// Normalize anchor/cursor so start precedes (or equals) end.
    fn ordered(self: Selection) struct { start: Point, end: Point } {
        if (self.cursor.lessThan(self.anchor)) {
            return .{ .start = self.cursor, .end = self.anchor };
        }
        return .{ .start = self.anchor, .end = self.cursor };
    }

    /// Half-open display-column range `[start, end)` selected on `line_idx`,
    /// clamped to `content_width`, or null if this line contributes nothing
    /// visible (outside the selection, or a zero-width range).
    pub fn rangeForLine(self: Selection, line_idx: usize, content_width: usize) ?Range {
        if (!self.active) return null;
        const bounds = self.columnBounds(line_idx, content_width) orelse return null;
        if (bounds.end <= bounds.start) return null;
        return bounds;
    }

    /// Grapheme-aligned highlight range for a complete rendered line.
    pub fn rangeForRenderedLine(
        self: Selection,
        allocator: std.mem.Allocator,
        line_idx: usize,
        line: anytype,
    ) !?Range {
        if (!self.active) return null;
        var prepared = try prepareRenderedLine(allocator, line);
        defer prepared.deinit();
        const bounds = self.columnBounds(line_idx, prepared.prepared.total_columns) orelse return null;
        if (bounds.end <= bounds.start) return null;
        return try overlappingColumnBounds(prepared.source, bounds.start, bounds.end);
    }

    /// Raw column bounds for a line, clamped to `width`.  Unlike `rangeForLine`
    /// this keeps empty ranges (start == end) so that extraction can still emit
    /// a blank line for a fully-selected empty middle line.
    fn columnBounds(self: Selection, line_idx: usize, width: usize) ?Range {
        const ord = self.ordered();
        if (line_idx < ord.start.line or line_idx > ord.end.line) return null;

        var c0: usize = 0;
        var c1: usize = width;
        if (ord.start.line == ord.end.line) {
            c0 = ord.start.col;
            c1 = ord.end.col;
        } else if (line_idx == ord.start.line) {
            c0 = ord.start.col;
            c1 = width;
        } else if (line_idx == ord.end.line) {
            c0 = 0;
            c1 = ord.end.col;
        }

        // ordered() guarantees start precedes end, so after clamping both to
        // width the invariant c0 <= c1 still holds.
        return .{ .start = @min(c0, width), .end = @min(c1, width) };
    }

    /// Concatenate the selected text across lines, joined with '\n'.  Each
    /// line's slice is right-trimmed of trailing spaces (rendered padding).
    /// Caller owns the returned slice.
    pub fn extractText(self: Selection, allocator: std.mem.Allocator, lines: anytype) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (!self.active) return out.toOwnedSlice(allocator);

        const ord = self.ordered();
        var line_idx = ord.start.line;
        while (line_idx <= ord.end.line and line_idx < lines.len) : (line_idx += 1) {
            var prepared = try prepareRenderedLine(allocator, lines[line_idx]);
            defer prepared.deinit();
            const bounds = self.columnBounds(line_idx, prepared.prepared.total_columns) orelse continue;

            const line_start = out.items.len;
            try out.appendSlice(allocator, try overlappingColumnRange(prepared.source, bounds.start, bounds.end));
            // Right-trim trailing spaces from this line's contribution only.
            while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') {
                out.items.len -= 1;
            }

            if (line_idx != ord.end.line) try out.append(allocator, '\n');
        }

        return out.toOwnedSlice(allocator);
    }
};

const PreparedRenderedLine = struct {
    allocator: std.mem.Allocator,
    source: []u8,
    prepared: unicode.PreparedLine,

    fn deinit(self: *PreparedRenderedLine) void {
        self.prepared.deinit();
        self.allocator.free(self.source);
    }
};

/// Styled spans are only presentation boundaries. Preparing their concatenated
/// bytes lets an extended grapheme cross a style boundary without being split.
fn prepareRenderedLine(allocator: std.mem.Allocator, line: anytype) !PreparedRenderedLine {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (line.spans) |span| {
        try text.appendSlice(allocator, span.text);
    }
    const source = try text.toOwnedSlice(allocator);
    errdefer allocator.free(source);
    return .{
        .allocator = allocator,
        .source = source,
        .prepared = try unicode.PreparedLine.init(allocator, source),
    };
}

/// Return complete source graphemes whose cell ranges overlap `[start, end)`.
/// The start is inclusive and the end is exclusive. A bound inside a two-cell
/// grapheme expands outward to include that grapheme in full.
fn overlappingColumnRange(source: []const u8, start: usize, end: usize) ![]const u8 {
    if (start >= end) return source[0..0];
    var byte_start: ?usize = null;
    var byte_end: usize = 0;
    var iterator = unicode.Iterator.init(source);
    while (try iterator.next()) |grapheme| {
        if (grapheme.column_end <= start) continue;
        if (grapheme.column_start >= end) break;
        if (byte_start == null) byte_start = grapheme.byte_start;
        byte_end = grapheme.byte_end;
    }
    const first = byte_start orelse return source[0..0];
    return source[first..byte_end];
}

fn overlappingColumnBounds(source: []const u8, start: usize, end: usize) !?Range {
    var column_start: ?usize = null;
    var column_end: usize = 0;
    var iterator = unicode.Iterator.init(source);
    while (try iterator.next()) |grapheme| {
        if (grapheme.column_end <= start) continue;
        if (grapheme.column_start >= end) break;
        if (column_start == null) column_start = grapheme.column_start;
        column_end = grapheme.column_end;
    }
    return .{ .start = column_start orelse return null, .end = column_end };
}

/// Build the copy-toast label. ASCII whitespace collapses to one space and the
/// displayed preview clips inward at a complete grapheme boundary.
pub fn formatCopyPreview(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var collapsed: std.ArrayList(u8) = .empty;
    defer collapsed.deinit(allocator);
    var previous_space = true;
    for (text) |byte| {
        const is_space = switch (byte) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        };
        if (is_space) {
            if (!previous_space) try collapsed.append(allocator, ' ');
            previous_space = true;
        } else {
            try collapsed.append(allocator, byte);
            previous_space = false;
        }
    }
    if (collapsed.items.len > 0 and collapsed.items[collapsed.items.len - 1] == ' ') {
        collapsed.items.len -= 1;
    }

    var prepared = try unicode.PreparedLine.init(allocator, collapsed.items);
    defer prepared.deinit();
    const truncated = prepared.total_columns > copy_preview_cols;
    return std.fmt.allocPrint(allocator, "Copied \"{s}{s}\"", .{
        prepared.prefixToWidth(copy_preview_cols),
        if (truncated) " …" else "",
    });
}

const testing = std.testing;

const TestStyle = enum { body, emphasis, strong };
const TestSpan = struct { text: []const u8, style: TestStyle = .body };
const TestLine = struct { spans: []const TestSpan };

fn bodySpan(text: []const u8) TestSpan {
    return .{ .text = text };
}

test "single line partial range extracts substring" {
    var spans = [_]TestSpan{bodySpan("hello world")};
    const lines = [_]TestLine{.{ .spans = &spans }};

    var sel = Selection{};
    sel.begin(0, 2);
    sel.extendTo(0, 7);
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("llo w", text);
}

test "multi line join with trailing-space trim" {
    var s0 = [_]TestSpan{bodySpan("first line    ")}; // trailing padding
    var s1 = [_]TestSpan{bodySpan("middle")};
    var s2 = [_]TestSpan{bodySpan("last")};
    const lines = [_]TestLine{
        .{ .spans = &s0 },
        .{ .spans = &s1 },
        .{ .spans = &s2 },
    };

    var sel = Selection{};
    sel.begin(0, 6); // start mid-first-line
    sel.extendTo(2, 3); // end mid-last-line
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("line\nmiddle\nlas", text);
}

test "rangeForLine clamps to content width and rejects empty" {
    var sel = Selection{};
    sel.begin(0, 3);
    sel.extendTo(0, 100); // past end of a short line
    const r = sel.rangeForLine(0, 5).?;
    try testing.expectEqual(@as(usize, 3), r.start);
    try testing.expectEqual(@as(usize, 5), r.end);

    // Zero-width (click without drag) yields no highlight.
    var click = Selection{};
    click.begin(0, 2);
    try testing.expect(click.rangeForLine(0, 10) == null);
}

test "wide glyphs are copied whole at boundaries" {
    // "日本語" occupies columns 0..6 (2 each). Select columns 1..3 — should
    // still pull both leading glyphs because each overlaps the range.
    var spans = [_]TestSpan{bodySpan("日本語")};
    const lines = [_]TestLine{.{ .spans = &spans }};

    var sel = Selection{};
    sel.begin(0, 1);
    sel.extendTo(0, 3);
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("日本", text);
}

test "selection bounds are inclusive at start exclusive at end and expand inside wide graphemes" {
    var spans = [_]TestSpan{bodySpan("A日B")};
    const lines = [_]TestLine{.{ .spans = &spans }};

    const cases = [_]struct { start: usize, end: usize, expected: []const u8 }{
        .{ .start = 0, .end = 1, .expected = "A" },
        .{ .start = 0, .end = 2, .expected = "A日" },
        .{ .start = 1, .end = 2, .expected = "日" },
        .{ .start = 2, .end = 3, .expected = "日" },
        .{ .start = 3, .end = 4, .expected = "B" },
    };
    for (cases) |case| {
        var sel = Selection{};
        sel.begin(0, case.start);
        sel.extendTo(0, case.end);
        const text = try sel.extractText(testing.allocator, &lines);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case.expected, text);
    }
}

test "selection preserves complete Unicode grapheme families" {
    const cases = [_]struct { text: []const u8, start: usize, end: usize }{
        .{ .text = "e\u{0301}", .start = 0, .end = 1 },
        .{ .text = "👩‍💻", .start = 1, .end = 2 },
        .{ .text = "🇯🇵", .start = 1, .end = 2 },
        .{ .text = "©️", .start = 1, .end = 2 },
        .{ .text = "日", .start = 1, .end = 2 },
    };
    for (cases) |case| {
        var spans = [_]TestSpan{bodySpan(case.text)};
        const lines = [_]TestLine{.{ .spans = &spans }};
        var sel = Selection{};
        sel.begin(0, case.start);
        sel.extendTo(0, case.end);
        const text = try sel.extractText(testing.allocator, &lines);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(case.text, text);
    }
}

test "graphemes may cross style boundaries" {
    var combining_spans = [_]TestSpan{
        bodySpan("e"),
        .{ .text = "\u{0301}", .style = .emphasis },
    };
    var zwj_spans = [_]TestSpan{
        bodySpan("👩‍"),
        .{ .text = "💻", .style = .strong },
    };
    const lines = [_]TestLine{
        .{ .spans = &combining_spans },
        .{ .spans = &zwj_spans },
    };

    var combining = Selection{};
    combining.begin(0, 0);
    combining.extendTo(0, 1);
    const combining_text = try combining.extractText(testing.allocator, &lines);
    defer testing.allocator.free(combining_text);
    try testing.expectEqualStrings("e\u{0301}", combining_text);

    var zwj = Selection{};
    zwj.begin(1, 1);
    zwj.extendTo(1, 2);
    const zwj_text = try zwj.extractText(testing.allocator, &lines);
    defer testing.allocator.free(zwj_text);
    try testing.expectEqualStrings("👩‍💻", zwj_text);
}

test "selection preserves raw tabs while using actual line stops" {
    var first_spans = [_]TestSpan{ bodySpan("a"), bodySpan("\tb") };
    var wide_spans = [_]TestSpan{ bodySpan("日"), bodySpan("\tX") };
    var stop_spans = [_]TestSpan{ bodySpan("abcd"), bodySpan("\tX") };
    const lines = [_]TestLine{
        .{ .spans = &first_spans },
        .{ .spans = &wide_spans },
        .{ .spans = &stop_spans },
    };

    var first = Selection{};
    first.begin(0, 0);
    first.extendTo(0, 5);
    const first_text = try first.extractText(testing.allocator, &lines);
    defer testing.allocator.free(first_text);
    try testing.expectEqualStrings("a\tb", first_text);

    var wide = Selection{};
    wide.begin(1, 0);
    wide.extendTo(1, 5);
    const wide_text = try wide.extractText(testing.allocator, &lines);
    defer testing.allocator.free(wide_text);
    try testing.expectEqualStrings("日\tX", wide_text);

    var tab_cell = Selection{};
    tab_cell.begin(1, 3);
    tab_cell.extendTo(1, 4);
    const tab_text = try tab_cell.extractText(testing.allocator, &lines);
    defer testing.allocator.free(tab_text);
    try testing.expectEqualStrings("\t", tab_text);

    var at_stop = Selection{};
    at_stop.begin(2, 6);
    at_stop.extendTo(2, 7);
    const stop_text = try at_stop.extractText(testing.allocator, &lines);
    defer testing.allocator.free(stop_text);
    try testing.expectEqualStrings("\t", stop_text);
    const stop_range = (try at_stop.rangeForRenderedLine(testing.allocator, 2, lines[2])).?;
    try testing.expectEqual(Range{ .start = 4, .end = 8 }, stop_range);
}

test "highlight ranges expand to complete grapheme and tab cells" {
    var spans = [_]TestSpan{ bodySpan("A\t"), bodySpan("日B") };
    const line: TestLine = .{ .spans = &spans };

    var wide = Selection{};
    wide.begin(0, 5);
    wide.extendTo(0, 6);
    const wide_range = (try wide.rangeForRenderedLine(testing.allocator, 0, line)).?;
    try testing.expectEqual(Range{ .start = 4, .end = 6 }, wide_range);

    var tab = Selection{};
    tab.begin(0, 2);
    tab.extendTo(0, 3);
    const tab_range = (try tab.rangeForRenderedLine(testing.allocator, 0, line)).?;
    try testing.expectEqual(Range{ .start = 1, .end = 4 }, tab_range);
}

test "selection rejects invalid UTF-8 and disallowed controls" {
    var invalid_spans = [_]TestSpan{bodySpan("ok\x80")};
    const invalid_lines = [_]TestLine{.{ .spans = &invalid_spans }};
    var invalid = Selection{};
    invalid.begin(0, 0);
    invalid.extendTo(0, 8);
    try testing.expectError(error.InvalidUtf8, invalid.extractText(testing.allocator, &invalid_lines));

    var control_spans = [_]TestSpan{bodySpan("a\x01b")};
    const control_lines = [_]TestLine{.{ .spans = &control_spans }};
    var control = Selection{};
    control.begin(0, 0);
    control.extendTo(0, 3);
    try testing.expectError(error.DisallowedControl, control.extractText(testing.allocator, &control_lines));
}

test "selection prepares a long line in one linear pass" {
    const long = "a" ** 32768;
    var spans = [_]TestSpan{bodySpan(long)};
    const lines = [_]TestLine{.{ .spans = &spans }};
    var sel = Selection{};
    sel.begin(0, long.len - 8);
    sel.extendTo(0, long.len);
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("aaaaaaaa", text);
}

test "copy preview preserves ASCII behavior and collapses whitespace" {
    const short = try formatCopyPreview(testing.allocator, "hello");
    defer testing.allocator.free(short);
    try testing.expectEqualStrings("Copied \"hello\"", short);

    const spaced = try formatCopyPreview(testing.allocator, "  first\nsecond\t third  ");
    defer testing.allocator.free(spaced);
    try testing.expectEqualStrings("Copied \"first second third\"", spaced);
}

test "copy preview clips complete graphemes by display columns" {
    const message = try formatCopyPreview(testing.allocator, ("a" ** 39) ++ "日tail");
    defer testing.allocator.free(message);
    try testing.expectEqualStrings("Copied \"" ++ ("a" ** 39) ++ " …\"", message);

    const families = [_][]const u8{ "e\u{0301}", "👩‍💻", "🇯🇵", "©️", "日" };
    for (families) |grapheme| {
        const family_message = try formatCopyPreview(testing.allocator, grapheme);
        defer testing.allocator.free(family_message);
        const expected = try std.fmt.allocPrint(testing.allocator, "Copied \"{s}\"", .{grapheme});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, family_message);
    }
}

test "copy preview truncates long ASCII and rejects invalid input" {
    const long = try formatCopyPreview(testing.allocator, "a" ** 60);
    defer testing.allocator.free(long);
    try testing.expectEqualStrings("Copied \"" ++ ("a" ** copy_preview_cols) ++ " …\"", long);
    try testing.expectError(error.InvalidUtf8, formatCopyPreview(testing.allocator, "ok\x80"));
    try testing.expectError(error.DisallowedControl, formatCopyPreview(testing.allocator, "ok\x01bad"));
}

test "inactive selection extracts nothing" {
    var spans = [_]TestSpan{bodySpan("hello")};
    const lines = [_]TestLine{.{ .spans = &spans }};

    const sel = Selection{};
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 0), text.len);
}

test "reversed drag (cursor before anchor) normalizes" {
    var spans = [_]TestSpan{bodySpan("abcdefghij")};
    const lines = [_]TestLine{.{ .spans = &spans }};

    var sel = Selection{};
    sel.begin(0, 8);
    sel.extendTo(0, 2); // dragged leftwards
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("cdefgh", text);
}

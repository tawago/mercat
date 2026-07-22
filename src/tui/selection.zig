//! Mouse text selection for the TUI pager.
//!
//! A selection is a linear span of rendered text expressed in
//! (document line, display column) coordinates.  It is deliberately decoupled
//! from vaxis: highlighting reads `rangeForLine`, and copy reads `extractText`,
//! both operating on the already-rendered `[]render_model.Line` that the pager
//! owns.  Columns are 0-based display columns (wide/CJK glyphs count as 2),
//! consistent with `unicode.displayWidth`.

const std = @import("std");
const render_model = @import("../core/render_model.zig");
const unicode = @import("../lib/unicode.zig");

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
    pub fn extractText(self: Selection, allocator: std.mem.Allocator, lines: []const render_model.Line) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        if (!self.active) return out.toOwnedSlice(allocator);

        const ord = self.ordered();
        var line_idx = ord.start.line;
        while (line_idx <= ord.end.line and line_idx < lines.len) : (line_idx += 1) {
            const line = lines[line_idx];
            const bounds = self.columnBounds(line_idx, line.displayWidth()) orelse continue;

            const line_start = out.items.len;
            try appendSliceByDisplayCols(&out, allocator, line, bounds.start, bounds.end);
            // Right-trim trailing spaces from this line's contribution only.
            while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') {
                out.items.len -= 1;
            }

            if (line_idx != ord.end.line) try out.append(allocator, '\n');
        }

        return out.toOwnedSlice(allocator);
    }
};

/// Append the bytes of `line` whose glyphs fall within display columns
/// `[c0, c1)`.  A glyph occupying cells `[p, p+w)` is included if that range
/// overlaps `[c0, c1)`, so wide glyphs are copied whole rather than split.
fn appendSliceByDisplayCols(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    line: render_model.Line,
    c0: usize,
    c1: usize,
) !void {
    var col: usize = 0;
    for (line.spans) |span| {
        const text = span.text;
        var index: usize = 0;
        while (index < text.len) {
            if (col >= c1) return; // spans are laid out left-to-right; done.
            const glyph = unicode.nextGlyph(text, index);
            // Overlap test: [col, col+width) intersects [c0, c1); col < c1 holds.
            if (col + glyph.width > c0) try out.appendSlice(allocator, glyph.bytes);
            col += glyph.width;
            index += glyph.bytes.len;
        }
    }
}

const testing = std.testing;

fn bodySpan(text: []const u8) render_model.Span {
    return .{ .text = text, .style = .body };
}

test "single line partial range extracts substring" {
    var spans = [_]render_model.Span{bodySpan("hello world")};
    const lines = [_]render_model.Line{.{ .spans = &spans }};

    var sel = Selection{};
    sel.begin(0, 2);
    sel.extendTo(0, 7);
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("llo w", text);
}

test "multi line join with trailing-space trim" {
    var s0 = [_]render_model.Span{bodySpan("first line    ")}; // trailing padding
    var s1 = [_]render_model.Span{bodySpan("middle")};
    var s2 = [_]render_model.Span{bodySpan("last")};
    const lines = [_]render_model.Line{
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
    var spans = [_]render_model.Span{bodySpan("日本語")};
    const lines = [_]render_model.Line{.{ .spans = &spans }};

    var sel = Selection{};
    sel.begin(0, 1);
    sel.extendTo(0, 3);
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("日本", text);
}

test "inactive selection extracts nothing" {
    var spans = [_]render_model.Span{bodySpan("hello")};
    const lines = [_]render_model.Line{.{ .spans = &spans }};

    const sel = Selection{};
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqual(@as(usize, 0), text.len);
}

test "reversed drag (cursor before anchor) normalizes" {
    var spans = [_]render_model.Span{bodySpan("abcdefghij")};
    const lines = [_]render_model.Line{.{ .spans = &spans }};

    var sel = Selection{};
    sel.begin(0, 8);
    sel.extendTo(0, 2); // dragged leftwards
    const text = try sel.extractText(testing.allocator, &lines);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("cdefgh", text);
}

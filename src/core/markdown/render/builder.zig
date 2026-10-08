const std = @import("std");
const unicode = @import("unicode");
const line_mod = @import("line.zig");
const Line = line_mod.Line;
const Span = line_mod.Span;
const SpanStyle = line_mod.SpanStyle;

pub const Builder = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList(Line),
    current: std.ArrayList(Span),
    tail: std.ArrayList(u8),
    tail_style: SpanStyle = .body,
    tail_url: ?[]const u8 = null,
    tail_open: bool = false,
    left_padding: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{
            .allocator = allocator,
            .lines = .empty,
            .current = .empty,
            .tail = .empty,
        };
    }

    pub fn deinit(self: *Builder) void {
        for (self.current.items) |span| {
            self.allocator.free(span.text);
            if (span.url) |url| self.allocator.free(url);
        }
        self.current.deinit(self.allocator);
        self.tail.deinit(self.allocator);
        if (self.tail_url) |u| self.allocator.free(u);
        for (self.lines.items) |line| line.deinit(self.allocator);
        self.lines.deinit(self.allocator);
    }

    pub fn hasPending(self: *const Builder) bool {
        return self.current.items.len != 0 or self.tail_open;
    }

    fn flushTail(self: *Builder) !void {
        if (!self.tail_open) return;
        const text = try self.allocator.dupe(u8, self.tail.items);
        errdefer self.allocator.free(text);
        try self.current.append(self.allocator, .{ .text = text, .style = self.tail_style, .url = self.tail_url });
        self.tail_url = null;
        self.tail_open = false;
        self.tail.clearRetainingCapacity();
    }

    pub fn appendSpan(self: *Builder, style: SpanStyle, text: []const u8) !void {
        try self.appendSpanWithUrl(style, text, null);
    }

    pub fn appendRepeated(self: *Builder, style: SpanStyle, glyph: []const u8, count: usize) !void {
        if (count == 0 or glyph.len == 0) return;
        const run = try self.allocator.alloc(u8, count * glyph.len);
        defer self.allocator.free(run);
        if (glyph.len == 1) {
            @memset(run, glyph[0]);
        } else {
            var index: usize = 0;
            while (index < count) : (index += 1) {
                @memcpy(run[index * glyph.len ..][0..glyph.len], glyph);
            }
        }
        try self.appendSpan(style, run);
    }

    pub fn appendSpanWithUrl(self: *Builder, style: SpanStyle, text: []const u8, url: ?[]const u8) !void {
        if (text.len == 0) return;
        if (!self.hasPending() and self.left_padding != 0) {
            try self.tail.appendNTimes(self.allocator, ' ', self.left_padding);
            self.tail_style = .body;
            self.tail_url = null;
            self.tail_open = true;
        }
        if (self.tail_open) {
            const urls_match = (self.tail_url == null and url == null) or
                (self.tail_url != null and url != null and std.mem.eql(u8, self.tail_url.?, url.?));
            if (self.tail_style == style and urls_match) {
                try self.tail.appendSlice(self.allocator, text);
                return;
            }
        }
        try self.flushTail();
        const duped_url = if (url) |u| try self.allocator.dupe(u8, u) else null;
        errdefer if (duped_url) |u| self.allocator.free(u);
        try self.tail.appendSlice(self.allocator, text);
        self.tail_style = style;
        self.tail_url = duped_url;
        self.tail_open = true;
    }

    pub fn newline(self: *Builder) !void {
        try self.flushTail();
        const spans = try self.current.toOwnedSlice(self.allocator);
        errdefer {
            for (spans) |span| {
                self.allocator.free(span.text);
                if (span.url) |u| self.allocator.free(u);
            }
            self.allocator.free(spans);
        }
        try self.lines.append(self.allocator, .{ .spans = spans });
        self.current = .empty;
    }

    /// Makes the last finished line pending again, undoing a trailing
    /// `newline()`. Requires that nothing is pending and a line exists.
    pub fn reopenLastLine(self: *Builder) void {
        std.debug.assert(!self.hasPending());
        const line = self.lines.pop().?;
        self.current.deinit(self.allocator);
        self.current = .fromOwnedSlice(line.spans);
    }

    /// Closes the pending line (if any) and prepares every line, which also
    /// validates it (invalid UTF-8 or a control character is an error).
    /// Returns whether a line was pending, for `absorb`.
    pub fn seal(self: *Builder) !bool {
        const pending = self.hasPending();
        if (pending) try self.newline();
        for (self.lines.items) |*line| try line.prepareOwned(self.allocator);
        return pending;
    }

    /// Moves the lines of a sealed `other` onto this builder verbatim: no left
    /// padding is added, so `other` should have been built with the padding
    /// it needs. This builder must be at the start of a line. If `other` had
    /// a pending last line, that line stays pending here; otherwise this
    /// builder ends on a fresh line, as `other` did.
    pub fn absorb(self: *Builder, other: *Builder, other_was_pending: bool) !void {
        std.debug.assert(!self.hasPending());
        for (other.lines.items, 0..) |*line, index| {
            if (index != 0) try self.newline();
            try self.current.ensureUnusedCapacity(self.allocator, line.spans.len);
            self.current.appendSliceAssumeCapacity(line.spans);
            self.allocator.free(line.spans);
            line.spans = &.{};
        }
        if (!other_was_pending and other.lines.items.len != 0) try self.newline();
    }

    pub fn finish(self: *Builder) ![]Line {
        if (self.hasPending() or self.lines.items.len == 0) {
            try self.newline();
        }
        for (self.lines.items) |*line| try line.prepareOwned(self.allocator);
        self.tail.clearAndFree(self.allocator);
        return try self.lines.toOwnedSlice(self.allocator);
    }
};

test "consecutive same-style appends merge into one span, including left padding" {
    const allocator = std.testing.allocator;

    var b = Builder.init(allocator);
    defer b.deinit();
    b.left_padding = 2;
    try b.appendSpan(.body, "ab");
    try b.appendSpan(.body, "cd");
    try b.appendSpan(.emphasis, "ef");
    try b.appendSpanWithUrl(.emphasis, "gh", "u");
    try b.appendSpanWithUrl(.emphasis, "ij", "u");
    try b.newline();
    try b.appendSpan(.body, "z");
    const lines = try b.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqual(@as(usize, 3), lines[0].spans.len);
    try std.testing.expectEqualStrings("  abcd", lines[0].spans[0].text);
    try std.testing.expectEqualStrings("ef", lines[0].spans[1].text);
    try std.testing.expectEqualStrings("ghij", lines[0].spans[2].text);
    try std.testing.expectEqualStrings("u", lines[0].spans[2].url.?);
    try std.testing.expectEqualStrings("  z", lines[1].spans[0].text);

    // A zero count or an empty glyph appends nothing at all.
    var empty = Builder.init(allocator);
    defer empty.deinit();
    try empty.appendRepeated(.body, " ", 0);
    try empty.appendRepeated(.body, "", 4);
    try std.testing.expect(!empty.hasPending());
}

test "building one long span stays linear rather than quadratic" {
    const allocator = std.testing.allocator;

    var b = Builder.init(allocator);
    defer b.deinit();
    var i: usize = 0;
    while (i < 200_000) : (i += 1) try b.appendSpan(.body, "x");
    const lines = try b.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines[0].spans.len);
    try std.testing.expectEqual(@as(usize, 200_000), lines[0].spans[0].text.len);
}

test "whole-line preparation preserves styles across one combining grapheme" {
    const allocator = std.testing.allocator;
    var builder = Builder.init(allocator);
    defer builder.deinit();
    try builder.appendSpan(.emphasis, "e");
    try builder.appendSpan(.strong, "\u{0301}");
    const lines = try builder.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }

    try std.testing.expectEqual(@as(usize, 1), lines[0].displayWidth());
    try std.testing.expectEqual(@as(usize, 2), lines[0].spans.len);
    try std.testing.expectEqualStrings("e", lines[0].spans[0].text);
    try std.testing.expectEqualStrings("\u{0301}", lines[0].spans[1].text);
    try std.testing.expectEqual(SpanStyle.emphasis, lines[0].spans[0].style);
    try std.testing.expectEqual(SpanStyle.strong, lines[0].spans[1].style);
}

test "whole-line tabs use actual columns and keep the tab span style" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { prefix: []const u8, spaces: []const u8, columns: usize }{
        .{ .prefix = "a", .spaces = "   ", .columns = 4 },
        .{ .prefix = "日", .spaces = "  ", .columns = 4 },
    };
    for (cases) |case| {
        var builder = Builder.init(allocator);
        defer builder.deinit();
        try builder.appendSpan(.body, case.prefix);
        try builder.appendSpan(.code, "\t");
        const lines = try builder.finish();
        defer {
            for (lines) |line| line.deinit(allocator);
            allocator.free(lines);
        }
        try std.testing.expectEqual(case.columns, lines[0].displayWidth());
        try std.testing.expectEqualStrings(case.spaces, lines[0].spans[lines[0].spans.len - 1].text);
        try std.testing.expectEqual(SpanStyle.code, lines[0].spans[lines[0].spans.len - 1].style);
    }
}

fn absorbCase(allocator: std.mem.Allocator, pending: bool) !void {
    var outer = Builder.init(allocator);
    defer outer.deinit();
    var inner = Builder.init(allocator);
    defer inner.deinit();
    inner.left_padding = 4;
    try inner.appendSpan(.code, "a");
    try inner.newline();
    try inner.appendSpanWithUrl(.link, "b", "u");
    if (!pending) try inner.newline();
    const was_pending = try inner.seal();
    try std.testing.expectEqual(pending, was_pending);
    try outer.absorb(&inner, was_pending);
    try outer.appendSpan(.body, "z");
    const lines = try outer.finish();
    defer {
        for (lines) |line| line.deinit(allocator);
        allocator.free(lines);
    }
    // A pending last line is continued; a closed one is followed by a new line.
    try std.testing.expectEqual(@as(usize, if (pending) 2 else 3), lines.len);
    try std.testing.expectEqualStrings("    ", lines[0].spans[0].text);
    try std.testing.expectEqualStrings("a", lines[0].spans[1].text);
    try std.testing.expectEqualStrings("b", lines[1].spans[1].text);
    try std.testing.expectEqualStrings("u", lines[1].spans[1].url.?);
    const last = lines[lines.len - 1];
    try std.testing.expectEqualStrings("z", last.spans[last.spans.len - 1].text);
    try std.testing.expectEqual(@as(usize, if (pending) 3 else 1), last.spans.len);
}

test "absorb moves sealed lines verbatim and mirrors the pending state" {
    try absorbCase(std.testing.allocator, true);
    try absorbCase(std.testing.allocator, false);
}

test "invalid text is reported by seal and by finish" {
    var sealed = Builder.init(std.testing.allocator);
    defer sealed.deinit();
    try sealed.appendSpan(.body, "ok\x1b");
    try std.testing.expectError(error.DisallowedControl, sealed.seal());
    inline for (.{ .{ "\x80", error.InvalidUtf8 }, .{ "\x1b", error.DisallowedControl } }) |case| {
        var builder = Builder.init(std.testing.allocator);
        defer builder.deinit();
        try builder.appendSpan(.body, case[0]);
        try std.testing.expectError(case[1], builder.finish());
    }
}

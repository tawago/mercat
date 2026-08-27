const std = @import("std");
const unicode = @import("unicode");

pub const SpanStyle = enum {
    heading1,
    heading2,
    heading3,
    heading4,
    heading5,
    heading6,
    body,
    muted,
    emphasis,
    strong,
    strong_emphasis,
    code,
    code_block,
    code_block_keyword,
    code_block_string,
    code_block_number,
    code_block_comment,
    code_keyword,
    code_string,
    code_number,
    code_comment,
    quote,
    link,
    strikethrough,
    image_alt,
    superscript,
    subscript,
    highlight,
    frontmatter_key,
    frontmatter_value,
    frontmatter_cap,
    bullet,
    ordered,
    task_on,
    task_off,
    list_item,
    table_border,
    table_header,
    hr,
    code_fence_banner,
};

pub const Span = struct {
    text: []const u8,
    style: SpanStyle,
    url: ?[]const u8 = null,
};

pub const Line = struct {
    spans: []Span,
    /// Set by the Markdown builder after preparing the complete rendered line.
    /// Null remains available for hand-built Lines used by downstream tests.
    display_columns: ?usize = null,

    pub fn displayWidth(self: Line) usize {
        if (self.display_columns) |columns| return columns;
        var column: usize = 0;
        for (self.spans) |span| column = unicode.rawDisplayWidthFrom(span.text, column) catch unreachable;
        return column;
    }

    /// Prepare one owned line as a whole, then project each original source
    /// span boundary into the prepared bytes. This keeps style and URL
    /// provenance byte-exact even when one grapheme crosses span boundaries.
    pub fn prepareOwned(self: *Line, allocator: std.mem.Allocator) !void {
        var source: std.ArrayList(u8) = .empty;
        defer source.deinit(allocator);
        for (self.spans) |span| try source.appendSlice(allocator, span.text);

        var prepared = try unicode.PreparedLine.init(allocator, source.items);
        defer prepared.deinit();

        const source_to_prepared = try allocator.alloc(usize, source.items.len + 1);
        defer allocator.free(source_to_prepared);
        source_to_prepared[0] = 0;

        var source_iterator = unicode.Iterator.init(source.items);
        var prepared_index: usize = 0;
        while (try source_iterator.next()) |grapheme| {
            if (grapheme.bytes.len == 1 and grapheme.bytes[0] == '\t') {
                const count: usize = grapheme.width;
                std.debug.assert(count != 0);
                source_to_prepared[grapheme.byte_start] = prepared.entries[prepared_index].byte_start;
                source_to_prepared[grapheme.byte_end] = prepared.entries[prepared_index + count - 1].byte_end;
                prepared_index += count;
                continue;
            }

            const entry = prepared.entries[prepared_index];
            for (grapheme.byte_start..grapheme.byte_end + 1) |source_offset| {
                source_to_prepared[source_offset] = entry.byte_start + source_offset - grapheme.byte_start;
            }
            prepared_index += 1;
        }
        std.debug.assert(prepared_index == prepared.entries.len);

        var mapped: std.ArrayList(Span) = .empty;
        errdefer {
            for (mapped.items) |span| {
                allocator.free(span.text);
                if (span.url) |url| allocator.free(url);
            }
            mapped.deinit(allocator);
        }
        var source_start: usize = 0;
        for (self.spans) |span| {
            const source_end = source_start + span.text.len;
            const byte_start = source_to_prepared[source_start];
            const byte_end = source_to_prepared[source_end];
            if (byte_start != byte_end) {
                const text = try allocator.dupe(u8, prepared.bytes[byte_start..byte_end]);
                errdefer allocator.free(text);
                const url = if (span.url) |value| try allocator.dupe(u8, value) else null;
                errdefer if (url) |value| allocator.free(value);
                try mapped.append(allocator, .{ .text = text, .style = span.style, .url = url });
            }
            source_start = source_end;
        }

        const owned = try mapped.toOwnedSlice(allocator);
        for (self.spans) |span| {
            allocator.free(span.text);
            if (span.url) |url| allocator.free(url);
        }
        allocator.free(self.spans);
        self.spans = owned;
        self.display_columns = prepared.total_columns;
    }

    pub fn reprepareOwned(self: *Line, allocator: std.mem.Allocator) !void {
        self.display_columns = null;
        try self.prepareOwned(allocator);
    }

    pub fn deinit(self: Line, allocator: std.mem.Allocator) void {
        for (self.spans) |span| {
            allocator.free(span.text);
            if (span.url) |url| allocator.free(url);
        }
        allocator.free(self.spans);
    }
};

pub const Rendered = struct {
    lines: []Line,

    pub fn deinit(self: Rendered, allocator: std.mem.Allocator) void {
        for (self.lines) |line| line.deinit(allocator);
        allocator.free(self.lines);
    }
};

test "unprepared Line.displayWidth retains the downstream compatibility surface" {
    var spans = [_]Span{
        .{ .text = "ab", .style = .body },
        .{ .text = "日", .style = .body },
    };
    const line = Line{ .spans = &spans };
    try std.testing.expectEqual(@as(usize, 4), line.displayWidth());
}

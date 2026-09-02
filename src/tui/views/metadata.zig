const std = @import("std");
const vaxis = @import("vaxis");
const markdown = @import("../../core/markdown/document.zig");
const unicode = @import("unicode");

const PreparedMetadataLine = struct {
    line: unicode.PreparedLine,
    key_columns: usize,

    fn deinit(self: *PreparedMetadataLine) void {
        self.line.deinit();
    }

    fn clipped(self: PreparedMetadataLine, width: usize) struct { key: []const u8, rest: []const u8 } {
        const bytes = self.line.prefixToWidth(width);
        const key_end = @min(self.line.prefixToWidth(self.key_columns).len, bytes.len);
        return .{ .key = bytes[0..key_end], .rest = bytes[key_end..] };
    }
};

fn prepareMetadataLine(
    allocator: std.mem.Allocator,
    entry: markdown.Block.FrontMatter.Entry,
    key_width: usize,
) !PreparedMetadataLine {
    var key = try unicode.PreparedLine.init(allocator, entry.key);
    defer key.deinit();

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    if (entry.key.len != 0) {
        try raw.appendSlice(allocator, entry.key);
        try raw.appendNTimes(allocator, ' ', key_width + 2 - key.total_columns);
    }
    try raw.appendSlice(allocator, entry.value);
    return .{
        .line = try unicode.PreparedLine.init(allocator, raw.items),
        .key_columns = key.total_columns,
    };
}

/// Front matter metadata overlay: a top-right panel toggled with `m`, showing
/// one `key  value` row per entry aligned on the key column, scrollable when
/// the entries overflow the window.
pub const MetadataOverlay = struct {
    pub const PanelStyle = struct {
        fill: vaxis.Style,
        border: vaxis.Style,
        text: vaxis.Style,
    };

    /// Screen rectangle (cells) of a drawn overlay, used for mouse hit-testing.
    pub const Rect = struct { x: u16, y: u16, width: u16, height: u16 };

    visible: bool = false,
    /// Scroll offset (first visible entry index).
    scroll: usize = 0,
    visible_rows: usize = 0,
    total: usize = 0,
    rect: ?Rect = null,

    /// Clamp the scroll offset to the last valid page.
    fn maxScroll(self: *MetadataOverlay) usize {
        return self.total -| self.visible_rows;
    }

    pub fn scrollBy(self: *MetadataOverlay, delta: isize) void {
        const magnitude: usize = @abs(delta);
        const next = if (delta < 0)
            self.scroll -| magnitude
        else
            self.scroll +| magnitude;
        self.scroll = @min(next, self.maxScroll());
    }

    pub fn scrollTo(self: *MetadataOverlay, offset: usize) void {
        self.scroll = @min(offset, self.maxScroll());
    }

    /// True when `mouse` falls inside the overlay's drawn rectangle.
    pub fn contains(self: *MetadataOverlay, mouse: vaxis.Mouse) bool {
        const rect = self.rect orelse return false;
        if (mouse.col < 0 or mouse.row < 0) return false;
        const col: u16 = @intCast(mouse.col);
        const row: u16 = @intCast(mouse.row);
        return col >= rect.x and col < rect.x + rect.width and
            row >= rect.y and row < rect.y + rect.height;
    }

    /// Draw the panel in the top-right corner. `frame_allocator` must outlive
    /// `vx.render()` — vaxis stores borrowed grapheme slices in screen cells,
    /// so the row buffers are read at render time. `fm` is null when the
    /// document has no front matter or the style keeps it hidden (`hidden`
    /// keeps the front matter stripped — see config.zig — so the overlay must
    /// not reveal it even if the visible flag somehow got set).
    pub fn draw(
        self: *MetadataOverlay,
        root: vaxis.Window,
        frame_allocator: std.mem.Allocator,
        fm_opt: ?markdown.Block.FrontMatter,
        style: PanelStyle,
    ) !void {
        if (!self.visible) {
            self.rect = null;
            return;
        }
        self.rect = null;
        const fm = fm_opt orelse {
            return;
        };

        const total = fm.entries.len;
        self.total = total;

        const max_inner_rows: usize = (@as(usize, root.height) -| 2) -| 2;
        if (max_inner_rows == 0) {
            self.rect = null;
            return;
        }
        const overflow = total > max_inner_rows;
        const visible_rows = if (overflow) @min(max_inner_rows -| 1, total) else total;
        if (visible_rows == 0) {
            self.rect = null;
            return;
        }
        self.visible_rows = visible_rows;
        if (self.scroll > total -| visible_rows) {
            self.scroll = total -| visible_rows;
        }
        const start = self.scroll;
        const end = @min(start + visible_rows, total);

        var key_width: usize = 0;
        for (fm.entries) |entry| {
            const key = try unicode.PreparedLine.init(frame_allocator, entry.key);
            key_width = @max(key_width, key.total_columns);
        }
        var row_width: usize = 0;
        for (fm.entries) |entry| {
            const line = try prepareMetadataLine(frame_allocator, entry, key_width);
            row_width = @max(row_width, line.line.total_columns);
        }

        const indicator = if (overflow)
            try std.fmt.allocPrint(frame_allocator, "{c} {d}-{d} / {d} {c}", .{
                @as(u8, if (start > 0) '^' else ' '),
                start + 1,
                end,
                total,
                @as(u8, if (end < total) 'v' else ' '),
            })
        else
            "";
        const prepared_indicator = if (overflow)
            try unicode.PreparedLine.init(frame_allocator, indicator)
        else
            null;
        if (prepared_indicator) |prepared| row_width = @max(row_width, prepared.total_columns);

        const width: u16 = @intCast(@min(root.width -| 2, row_width +| 4));
        const inner_rows = visible_rows + @as(usize, if (overflow) 1 else 0);
        const height: u16 = @intCast(inner_rows + 2);
        if (width < 5 or height < 3) {
            self.rect = null;
            return;
        }

        const x_off = root.width -| width;
        self.rect = .{ .x = x_off, .y = 0, .width = width, .height = height };

        const panel = root.child(.{ .x_off = x_off, .y_off = 0, .width = width, .height = height });
        panel.fill(.{ .style = style.fill });
        _ = root.child(.{
            .x_off = x_off,
            .y_off = 0,
            .width = width,
            .height = height,
            .border = .{ .where = .all, .glyphs = .single_rounded, .style = style.border },
        });

        var key_style = style.text;
        key_style.dim = true;
        const inner_width = width -| 4;
        for (fm.entries[start..end], 0..) |entry, row| {
            const prepared = try prepareMetadataLine(frame_allocator, entry, key_width);
            const clipped = prepared.clipped(inner_width);
            _ = root.print(&.{
                .{ .text = clipped.key, .style = key_style },
                .{ .text = clipped.rest, .style = style.text },
            }, .{
                .row_offset = @intCast(row + 1),
                .col_offset = x_off + 2,
                .wrap = .none,
            });
        }

        if (overflow) {
            const clipped = prepared_indicator.?.prefixToWidth(inner_width);
            _ = root.print(&.{.{ .text = clipped, .style = key_style }}, .{
                .row_offset = @intCast(inner_rows),
                .col_offset = x_off + 2,
                .wrap = .none,
            });
        }
    }
};

test "scrollBy clamps to the last page" {
    var overlay = MetadataOverlay{ .total = 20, .visible_rows = 8 };

    overlay.scrollBy(-3);
    try std.testing.expectEqual(@as(usize, 0), overlay.scroll);

    overlay.scrollBy(5);
    try std.testing.expectEqual(@as(usize, 5), overlay.scroll);

    overlay.scrollBy(1000);
    try std.testing.expectEqual(@as(usize, 12), overlay.scroll);

    overlay.scrollTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 12), overlay.scroll);

    overlay.scrollTo(0);
    try std.testing.expectEqual(@as(usize, 0), overlay.scroll);
}

test "scrollTo saturates to zero when everything is visible" {
    var overlay = MetadataOverlay{ .total = 5, .visible_rows = 8 };
    overlay.scrollTo(1000);
    try std.testing.expectEqual(@as(usize, 0), overlay.scroll);
}

test "scrollBy keeps scroll at zero when everything is visible" {
    var overlay = MetadataOverlay{ .total = 3, .visible_rows = 8 };
    overlay.scrollBy(1);
    try std.testing.expectEqual(@as(usize, 0), overlay.scroll);
}

test "contains hit-tests the overlay rectangle" {
    var overlay = MetadataOverlay{ .rect = .{ .x = 10, .y = 0, .width = 20, .height = 6 } };

    const inside: vaxis.Mouse = .{ .col = 15, .row = 2, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(overlay.contains(inside));

    const left: vaxis.Mouse = .{ .col = 9, .row = 2, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(!overlay.contains(left));
    const right: vaxis.Mouse = .{ .col = 30, .row = 2, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(!overlay.contains(right));
    const below: vaxis.Mouse = .{ .col = 15, .row = 6, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(!overlay.contains(below));
    const negative: vaxis.Mouse = .{ .col = -1, .row = -1, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(!overlay.contains(negative));
}

test "metadata line width and clipping use complete display graphemes" {
    const Entry = markdown.Block.FrontMatter.Entry;
    const cases = [_]Entry{
        .{ .key = "e\u{0301}", .value = "value" },
        .{ .key = "👩‍💻", .value = "value" },
        .{ .key = "🇯🇵", .value = "value" },
        .{ .key = "©️", .value = "value" },
        .{ .key = "日", .value = "value" },
    };
    for (cases) |entry| {
        var key = try unicode.PreparedLine.init(std.testing.allocator, entry.key);
        defer key.deinit();
        var line = try prepareMetadataLine(std.testing.allocator, entry, key.total_columns);
        defer line.deinit();

        const before = line.clipped(key.total_columns - 1);
        try std.testing.expectEqual(@as(usize, 0), before.key.len);
        try std.testing.expectEqual(@as(usize, 0), before.rest.len);
        const at_marker = line.clipped(key.total_columns);
        try std.testing.expectEqualStrings(entry.key, at_marker.key);
        try std.testing.expectEqual(@as(usize, 0), at_marker.rest.len);
    }
}

test "metadata tabs expand at stops after the displayed key column" {
    const entry: markdown.Block.FrontMatter.Entry = .{ .key = "日", .value = "\tX" };
    var line = try prepareMetadataLine(std.testing.allocator, entry, 2);
    defer line.deinit();
    try std.testing.expectEqualStrings("日      X", line.line.bytes);
    try std.testing.expectEqual(@as(usize, 9), line.line.total_columns);

    const tab_key: markdown.Block.FrontMatter.Entry = .{ .key = "a\t", .value = "X" };
    var tabbed = try prepareMetadataLine(std.testing.allocator, tab_key, 4);
    defer tabbed.deinit();
    try std.testing.expectEqualStrings("a     X", tabbed.line.bytes);
    try std.testing.expectEqual(@as(usize, 7), tabbed.line.total_columns);
}

test "metadata clipping does not cross a wide marker boundary" {
    const entry: markdown.Block.FrontMatter.Entry = .{ .key = "key", .value = "A日B" };
    var line = try prepareMetadataLine(std.testing.allocator, entry, 3);
    defer line.deinit();

    const before_wide = line.clipped(6);
    try std.testing.expectEqualStrings("key", before_wide.key);
    try std.testing.expectEqualStrings("  A", before_wide.rest);
    const inside_wide = line.clipped(7);
    try std.testing.expectEqualStrings("  A", inside_wide.rest);
    const after_wide = line.clipped(8);
    try std.testing.expectEqualStrings("  A日", after_wide.rest);
}

test "metadata preparation rejects invalid UTF-8 and ASCII controls" {
    const invalid: markdown.Block.FrontMatter.Entry = .{ .key = "key", .value = "bad\x80" };
    try std.testing.expectError(error.InvalidUtf8, prepareMetadataLine(std.testing.allocator, invalid, 3));
    const control: markdown.Block.FrontMatter.Entry = .{ .key = "key", .value = "bad\x01" };
    try std.testing.expectError(error.DisallowedControl, prepareMetadataLine(std.testing.allocator, control, 3));
}

test "metadata prepares long lines without repeated prefix scans" {
    const entry: markdown.Block.FrontMatter.Entry = .{ .key = "key", .value = "a" ** 32768 };
    var line = try prepareMetadataLine(std.testing.allocator, entry, 3);
    defer line.deinit();
    try std.testing.expectEqual(@as(usize, 32773), line.line.total_columns);
    try std.testing.expectEqual(@as(usize, 80), line.line.prefixToWidth(80).len);
}

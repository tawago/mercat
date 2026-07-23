const std = @import("std");
const vaxis = @import("vaxis");
const markdown = @import("../../core/markdown.zig");
const config = @import("../../core/config.zig");
const theme = @import("../../core/theme.zig");
const unicode = @import("../../lib/unicode.zig");

/// Front matter metadata overlay: a top-right panel toggled with `m`, showing
/// one `key  value` row per entry aligned on the key column, scrollable when
/// the entries overflow the window.
pub const MetadataOverlay = struct {
    /// Screen rectangle (cells) of a drawn overlay, used for mouse hit-testing.
    pub const Rect = struct { x: u16, y: u16, width: u16, height: u16 };

    visible: bool = false,
    /// Scroll offset (first visible entry index).
    scroll: usize = 0,
    // Geometry recorded on the last draw, for scroll clamping and mouse
    // hit-testing. `rect` is null while the overlay is hidden.
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
        active_theme: config.Theme,
    ) !void {
        if (!self.visible) {
            self.rect = null;
            return;
        }
        const fm = fm_opt orelse {
            self.rect = null;
            return;
        };

        const total = fm.entries.len;
        self.total = total;

        // Rows available inside the borders, bounded so the panel never covers
        // the status bar at the bottom.
        const max_inner_rows: usize = (@as(usize, root.height) -| 2) -| 2;
        if (max_inner_rows == 0) {
            self.rect = null;
            return;
        }
        // When entries overflow, reserve the bottom inner row for a scroll
        // indicator (e.g. `↑ 3-8 / 20 ↓`).
        const overflow = total > max_inner_rows;
        const visible_rows = if (overflow) @min(max_inner_rows -| 1, total) else total;
        if (visible_rows == 0) {
            self.rect = null;
            return;
        }
        self.visible_rows = visible_rows;
        // Clamp scroll now that we know the geometry (window may have shrunk).
        if (self.scroll > total -| visible_rows) {
            self.scroll = total -| visible_rows;
        }
        const start = self.scroll;
        const end = @min(start + visible_rows, total);

        var key_width: usize = 0;
        for (fm.entries) |entry| key_width = @max(key_width, unicode.displayWidth(entry.key));
        var row_width: usize = 0;
        for (fm.entries) |entry| {
            const w = if (entry.key.len == 0)
                unicode.displayWidth(entry.value)
            else
                key_width + 2 + unicode.displayWidth(entry.value);
            row_width = @max(row_width, w);
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
        if (overflow) row_width = @max(row_width, unicode.displayWidth(indicator));

        // Text + one space padding each side + two border columns.
        const width: u16 = @intCast(@min(root.width -| 2, row_width + 4));
        const inner_rows = visible_rows + @as(usize, if (overflow) 1 else 0);
        const height: u16 = @intCast(inner_rows + 2);
        if (width < 5 or height < 3) {
            self.rect = null;
            return;
        }

        const style = theme.metadataPanelStyle(active_theme);
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
            var line: std.ArrayList(u8) = .empty;
            if (entry.key.len != 0) {
                try line.appendSlice(frame_allocator, entry.key);
                var pad = key_width + 2 - unicode.displayWidth(entry.key);
                while (pad > 0) : (pad -= 1) try line.append(frame_allocator, ' ');
            }
            try line.appendSlice(frame_allocator, entry.value);
            const clipped = unicode.clipToWidth(line.items, inner_width);
            const key_cols = if (entry.key.len == 0) 0 else @min(entry.key.len, clipped.len);
            _ = root.print(&.{
                .{ .text = clipped[0..key_cols], .style = key_style },
                .{ .text = clipped[key_cols..], .style = style.text },
            }, .{
                .row_offset = @intCast(row + 1),
                .col_offset = x_off + 2,
                .wrap = .none,
            });
        }

        if (overflow) {
            const clipped = unicode.clipToWidth(indicator, inner_width);
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
    try std.testing.expectEqual(@as(usize, 12), overlay.scroll); // 20 - 8

    overlay.scrollTo(std.math.maxInt(usize));
    try std.testing.expectEqual(@as(usize, 12), overlay.scroll);

    overlay.scrollTo(0);
    try std.testing.expectEqual(@as(usize, 0), overlay.scroll);
}

test "scrollTo saturates to zero when everything is visible" {
    // Visible rows >= total, so maxScroll() saturates to 0 via -|.
    var overlay = MetadataOverlay{ .total = 5, .visible_rows = 8 };
    overlay.scrollTo(1000);
    try std.testing.expectEqual(@as(usize, 0), overlay.scroll);
}

test "scrollBy keeps scroll at zero when everything is visible" {
    // total < visible: max scroll saturates to 0, so scrolling down is a no-op.
    var overlay = MetadataOverlay{ .total = 3, .visible_rows = 8 };
    overlay.scrollBy(1);
    try std.testing.expectEqual(@as(usize, 0), overlay.scroll);
}

test "contains hit-tests the overlay rectangle" {
    var overlay = MetadataOverlay{ .rect = .{ .x = 10, .y = 0, .width = 20, .height = 6 } };

    const inside: vaxis.Mouse = .{ .col = 15, .row = 2, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(overlay.contains(inside));

    // Just left of the rect.
    const left: vaxis.Mouse = .{ .col = 9, .row = 2, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(!overlay.contains(left));
    // Just past the right edge (x + width = 30, exclusive).
    const right: vaxis.Mouse = .{ .col = 30, .row = 2, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(!overlay.contains(right));
    // Just below the bottom edge (y + height = 6, exclusive).
    const below: vaxis.Mouse = .{ .col = 15, .row = 6, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(!overlay.contains(below));
    // Negative coordinates are never inside.
    const negative: vaxis.Mouse = .{ .col = -1, .row = -1, .button = .none, .mods = .{}, .type = .motion };
    try std.testing.expect(!overlay.contains(negative));
}

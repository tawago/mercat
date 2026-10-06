//! The help overlay: a bordered card listing the key table (`input.bindings`)
//! grouped by section. It uses two columns when the screen is wide enough and
//! scrolls (with a `↓ more` marker) when the card is taller than the screen.
const std = @import("std");
const vaxis = @import("vaxis");
const unicode = @import("unicode");
const input = @import("../input.zig");
const theme = @import("../../core/theme.zig");

const Section = input.Section;

const Row = union(enum) {
    blank,
    header: Section,
    /// Index into `input.bindings`.
    entry: usize,
};

fn rowsFor(comptime sections: []const Section) []const Row {
    comptime {
        var rows: []const Row = &.{};
        for (sections, 0..) |section, i| {
            if (i > 0) rows = rows ++ [_]Row{.blank};
            rows = rows ++ [_]Row{.{ .header = section }};
            for (input.bindings, 0..) |binding, index| {
                if (binding.section == section) rows = rows ++ [_]Row{.{ .entry = index }};
            }
        }
        return rows;
    }
}

const all_sections = std.enums.values(Section);
const single_column = rowsFor(all_sections);
const left_column = rowsFor(&.{ .move, .search });
const right_column = rowsFor(&.{ .file, .view, .other });

comptime {
    // The two-column layout must show every section.
    std.debug.assert(left_column.len + right_column.len + 1 == single_column.len);
}

/// "j ↓ Ctrl-E Ctrl-N": the binding's chord names, or its label.
fn keyLabel(comptime binding: input.Binding) []const u8 {
    if (binding.label) |label| return label;
    var out: []const u8 = "";
    for (binding.chords, 0..) |chord, i| {
        out = out ++ (if (i == 0) "" else " ") ++ chord.name;
    }
    return out;
}

const labels = blk: {
    var out: [input.bindings.len][]const u8 = undefined;
    for (input.bindings, 0..) |binding, i| out[i] = keyLabel(binding);
    break :blk out;
};

const column_gap = 3;
const label_gap = 2;

/// The card title. Comptime so the drawn cells can borrow it until render.
pub const title = " mercat " ++ @import("build_options").version ++ " — keys ";

/// Widths of one column of rows: its key labels, and the whole column.
const ColumnWidth = struct {
    label: usize = 0,
    total: usize = 0,

    fn of(rows: []const Row) ColumnWidth {
        var label: usize = 0;
        var rest: usize = 0;
        var header: usize = 0;
        for (rows) |row| switch (row) {
            .blank => {},
            .header => |section| header = @max(header, section.title().len),
            .entry => |index| {
                label = @max(label, unicode.displayWidth(labels[index]));
                rest = @max(rest, unicode.displayWidth(input.bindings[index].description));
            },
        };
        return .{ .label = label, .total = @max(header, label + label_gap + rest) };
    }
};

pub const Geometry = struct {
    two_columns: bool,
    left: ColumnWidth,
    right: ColumnWidth,
    rows: usize,
    x: usize,
    y: usize,
    width: usize,
    height: usize,

    fn visibleRows(self: Geometry) usize {
        return self.height -| 2;
    }
};

/// Card placement for a `width` x `height` area (the screen above the
/// status bar): two columns when they fit, else one that may scroll.
pub fn geometry(width: usize, height: usize) Geometry {
    const left = ColumnWidth.of(left_column);
    const right = ColumnWidth.of(right_column);
    const single = ColumnWidth.of(single_column);
    const two_columns = left.total + column_gap + right.total + 4 <= width;
    const content_width = if (two_columns) left.total + column_gap + right.total else single.total;
    const rows = if (two_columns) @max(left_column.len, right_column.len) else single_column.len;
    const title_width = unicode.displayWidth(title);
    const card_width = @min(@max(content_width + 4, title_width + 4), width);
    const card_height = @min(rows + 2, height);
    return .{
        .two_columns = two_columns,
        .left = if (two_columns) left else single,
        .right = right,
        .rows = rows,
        .x = (width - card_width) / 2,
        .y = (height - card_height) / 2,
        .width = card_width,
        .height = card_height,
    };
}

pub const HelpOverlay = struct {
    scroll: usize = 0,
    /// Updated by `draw`: how far the card can scroll, and one page of rows.
    max_scroll: usize = 0,
    page_rows: usize = 1,

    pub fn scrollBy(self: *HelpOverlay, delta: isize) void {
        const magnitude: usize = @abs(delta);
        const next = if (delta < 0) self.scroll -| magnitude else self.scroll +| magnitude;
        self.scroll = @min(next, self.max_scroll);
    }

    pub fn scrollTo(self: *HelpOverlay, row: usize) void {
        self.scroll = @min(row, self.max_scroll);
    }

    pub fn reset(self: *HelpOverlay) void {
        self.scroll = 0;
    }

    /// Dims the `area_height` rows of `root` above the status bar and draws
    /// the card over them.
    pub fn draw(self: *HelpOverlay, root: vaxis.Window, area_height: u16, style: theme.ToastStyle) void {
        dim(root, area_height);
        const geo = geometry(root.width, area_height);
        if (geo.width < 6 or geo.height < 3) return;
        const visible = geo.visibleRows();
        self.max_scroll = geo.rows -| visible;
        self.page_rows = @max(visible, 1);
        self.scroll = @min(self.scroll, self.max_scroll);

        const x: u16 = @intCast(geo.x);
        const y: u16 = @intCast(geo.y);
        const card = root.child(.{ .x_off = x, .y_off = y, .width = @intCast(geo.width), .height = @intCast(geo.height) });
        card.fill(.{ .style = style.fill });
        const inner = root.child(.{
            .x_off = x,
            .y_off = y,
            .width = @intCast(geo.width),
            .height = @intCast(geo.height),
            .border = .{ .where = .all, .glyphs = .single_rounded, .style = style.border },
        });
        printClipped(card, title, 2, 0, geo.width -| 4, style.text);
        if (self.scroll > 0) printClipped(card, " ↑ ", geo.width -| 6, 0, 3, style.border);
        if (self.scroll < self.max_scroll) printClipped(card, " ↓ more ", geo.width -| 10, geo.height - 1, 8, style.border);

        const text_width = inner.width -| 2;
        var row: usize = 0;
        while (row < visible) : (row += 1) {
            const index = self.scroll + row;
            if (geo.two_columns) {
                const right_x = 1 + geo.left.total + column_gap;
                if (index < left_column.len) drawRow(inner, left_column[index], 1, row, geo.left.total, geo.left.label, style);
                if (index < right_column.len) drawRow(inner, right_column[index], right_x, row, geo.right.total, geo.right.label, style);
            } else if (index < single_column.len) {
                drawRow(inner, single_column[index], 1, row, text_width, geo.left.label, style);
            }
        }
    }
};

fn drawRow(win: vaxis.Window, row: Row, x: usize, y: usize, width: usize, label_width: usize, style: theme.ToastStyle) void {
    const plain_style: vaxis.Style = .{ .bg = style.fill.bg };
    switch (row) {
        .blank => {},
        .header => |section| {
            var header_style = style.text;
            header_style.bold = true;
            printClipped(win, section.title(), x, y, width, header_style);
        },
        .entry => |index| {
            var key_style = style.border;
            key_style.bold = true;
            printClipped(win, labels[index], x, y, width, key_style);
            const desc_x = label_width + label_gap;
            if (desc_x < width) printClipped(win, input.bindings[index].description, x + desc_x, y, width - desc_x, plain_style);
        },
    }
}

/// Prints `text` at (x, y), clipped to `width` display columns at a grapheme
/// boundary; a clipped text ends in "…" so nothing is cut silently.
fn printClipped(win: vaxis.Window, text: []const u8, x: usize, y: usize, width: usize, style: vaxis.Style) void {
    if (width == 0 or x >= win.width or y >= win.height) return;
    const fits = unicode.displayWidth(text) <= width;
    const shown = if (fits) text else unicode.clipToWidth(text, width - 1);
    const result = win.print(&.{.{ .text = shown, .style = style }}, .{ .col_offset = @intCast(x), .row_offset = @intCast(y), .wrap = .none });
    if (!fits) _ = win.print(&.{.{ .text = "…", .style = style }}, .{ .col_offset = result.col, .row_offset = @intCast(y), .wrap = .none });
}

/// Dims what is already drawn in the top `rows` rows so the overlay reads as
/// a layer above the document.
fn dim(root: vaxis.Window, rows: u16) void {
    var y: u16 = 0;
    while (y < @min(rows, root.height)) : (y += 1) {
        var x: u16 = 0;
        while (x < root.width) : (x += 1) {
            var cell = root.readCell(x, y) orelse continue;
            cell.style.dim = true;
            root.writeCell(x, y, cell);
        }
    }
}

test {
    _ = @import("help_test.zig");
}

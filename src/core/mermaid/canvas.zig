const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Point = types.Point;
const Rect = types.Rect;
const BoxChars = types.BoxChars;
const LineChars = types.LineChars;
const Arrows = types.Arrows;

/// Priority levels for cell drawing
pub const Priority = enum(u8) {
    background = 0,
    subgraph = 1,
    edge = 2,
    edge_label = 3,
    node_border = 4,
    node_text = 5,
};

/// A single cell in the canvas
pub const Cell = struct {
    char: u21 = ' ',
    priority: Priority = .background,

    pub fn set(self: *Cell, char: u21, priority: Priority) void {
        // Only overwrite if new priority is >= current
        if (@intFromEnum(priority) >= @intFromEnum(self.priority)) {
            self.char = char;
            self.priority = priority;
        }
    }
};

/// 2D character canvas for ASCII rendering
pub const Canvas = struct {
    allocator: Allocator,
    cells: [][]Cell,
    width: u32,
    height: u32,

    pub fn init(allocator: Allocator, width: u32, height: u32) !Canvas {
        const cells = try allocator.alloc([]Cell, height);
        errdefer allocator.free(cells);

        for (cells, 0..) |*row, i| {
            row.* = try allocator.alloc(Cell, width);
            errdefer {
                for (cells[0..i]) |r| allocator.free(r);
            }
            @memset(row.*, Cell{});
        }

        return .{
            .allocator = allocator,
            .cells = cells,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *Canvas) void {
        for (self.cells) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(self.cells);
    }

    /// Get cell at position, or null if out of bounds
    pub fn getCell(self: *Canvas, x: i32, y: i32) ?*Cell {
        if (x < 0 or y < 0) return null;
        const ux: usize = @intCast(x);
        const uy: usize = @intCast(y);
        if (ux >= self.width or uy >= self.height) return null;
        return &self.cells[uy][ux];
    }

    /// Set character at position with priority
    pub fn setChar(self: *Canvas, x: i32, y: i32, char: u21, priority: Priority) void {
        if (self.getCell(x, y)) |cell| {
            cell.set(char, priority);
        }
    }

    /// Draw a box with the given style
    pub fn drawBox(self: *Canvas, rect: Rect, style: BoxChars, priority: Priority) void {
        const x = rect.x;
        const y = rect.y;
        const w: i32 = @intCast(rect.width);
        const h: i32 = @intCast(rect.height);

        // Corners
        self.setChar(x, y, style.top_left, priority);
        self.setChar(x + w - 1, y, style.top_right, priority);
        self.setChar(x, y + h - 1, style.bottom_left, priority);
        self.setChar(x + w - 1, y + h - 1, style.bottom_right, priority);

        // Horizontal edges
        var col = x + 1;
        while (col < x + w - 1) : (col += 1) {
            self.setChar(col, y, style.horizontal, priority);
            self.setChar(col, y + h - 1, style.horizontal, priority);
        }

        // Vertical edges
        var row = y + 1;
        while (row < y + h - 1) : (row += 1) {
            self.setChar(x, row, style.vertical, priority);
            self.setChar(x + w - 1, row, style.vertical, priority);
        }
    }

    /// Draw text at position (centered if width provided)
    pub fn drawText(self: *Canvas, x: i32, y: i32, text: []const u8, priority: Priority) void {
        var col = x;
        for (text) |c| {
            self.setChar(col, y, c, priority);
            col += 1;
        }
    }

    /// Draw text centered within a box
    pub fn drawTextCentered(self: *Canvas, rect: Rect, text: []const u8, priority: Priority) void {
        const text_len: i32 = @intCast(text.len);
        const box_width: i32 = @intCast(rect.width);
        const box_height: i32 = @intCast(rect.height);

        const x = rect.x + @divFloor(box_width - text_len, 2);
        const y = rect.y + @divFloor(box_height, 2);

        self.drawText(x, y, text, priority);
    }

    /// Draw a horizontal line
    pub fn drawHorizontalLine(self: *Canvas, y: i32, x1: i32, x2: i32, char: u21, priority: Priority) void {
        const start = @min(x1, x2);
        const end = @max(x1, x2);
        var x = start;
        while (x <= end) : (x += 1) {
            self.setChar(x, y, char, priority);
        }
    }

    /// Draw a vertical line
    pub fn drawVerticalLine(self: *Canvas, x: i32, y1: i32, y2: i32, char: u21, priority: Priority) void {
        const start = @min(y1, y2);
        const end = @max(y1, y2);
        var y = start;
        while (y <= end) : (y += 1) {
            self.setChar(x, y, char, priority);
        }
    }

    /// Draw an orthogonal path (sequence of connected segments)
    pub fn drawPath(self: *Canvas, points: []const Point, style: types.EdgeStyle, priority: Priority) void {
        if (points.len < 2) return;

        const h_char: u21 = switch (style) {
            .solid => LineChars.horizontal,
            .dotted => LineChars.horizontal_dotted,
            .thick => LineChars.horizontal_thick,
        };
        const v_char: u21 = switch (style) {
            .solid => LineChars.vertical,
            .dotted => LineChars.vertical_dotted,
            .thick => LineChars.vertical_thick,
        };

        for (points[0 .. points.len - 1], points[1..]) |p1, p2| {
            if (p1.y == p2.y) {
                // Horizontal segment
                self.drawHorizontalLine(p1.y, p1.x, p2.x, h_char, priority);
            } else if (p1.x == p2.x) {
                // Vertical segment
                self.drawVerticalLine(p1.x, p1.y, p2.y, v_char, priority);
            }
        }

        // Draw corners at turning points
        for (1..points.len - 1) |i| {
            const prev = points[i - 1];
            const curr = points[i];
            const next = points[i + 1];

            const corner = self.getCornerChar(prev, curr, next);
            if (corner) |c| {
                self.setChar(curr.x, curr.y, c, priority);
            }
        }
    }

    fn getCornerChar(self: *Canvas, prev: Point, curr: Point, next: Point) ?u21 {
        _ = self;
        const from_left = prev.x < curr.x;
        const from_right = prev.x > curr.x;
        const from_above = prev.y < curr.y;
        const from_below = prev.y > curr.y;

        const to_left = next.x < curr.x;
        const to_right = next.x > curr.x;
        const to_above = next.y < curr.y;
        const to_below = next.y > curr.y;

        // Determine corner type based on which sides it connects
        // ┌ (corner_se) - openings: RIGHT (east) and DOWN (south)
        if ((from_right and to_below) or (from_below and to_right)) return LineChars.corner_se;
        // ┐ (corner_sw) - openings: LEFT (west) and DOWN (south)
        if ((from_left and to_below) or (from_below and to_left)) return LineChars.corner_sw;
        // └ (corner_ne) - openings: RIGHT (east) and UP (north)
        if ((from_right and to_above) or (from_above and to_right)) return LineChars.corner_ne;
        // ┘ (corner_nw) - openings: LEFT (west) and UP (north)
        if ((from_left and to_above) or (from_above and to_left)) return LineChars.corner_nw;

        return null;
    }

    /// Draw an arrow at the given point
    pub fn drawArrow(self: *Canvas, point: Point, direction: types.Direction, unicode_mode: bool, priority: Priority) void {
        const char: u21 = if (unicode_mode) switch (direction) {
            .LR => Arrows.right_thin,
            .RL => Arrows.left_thin,
            .TD, .TB => Arrows.down_thin,
            .BT => Arrows.up_thin,
        } else switch (direction) {
            .LR => Arrows.right_ascii,
            .RL => Arrows.left_ascii,
            .TD, .TB => Arrows.down_ascii,
            .BT => Arrows.up_ascii,
        };
        self.setChar(point.x, point.y, char, priority);
    }

    /// Draw arrow pointing in direction from p1 to p2
    pub fn drawArrowBetween(self: *Canvas, from: Point, to: Point, unicode_mode: bool, priority: Priority) void {
        const dx = to.x - from.x;
        const dy = to.y - from.y;

        const direction: types.Direction = if (@abs(dx) > @abs(dy)) blk: {
            break :blk if (dx > 0) .LR else .RL;
        } else blk: {
            break :blk if (dy > 0) .TD else .BT;
        };

        self.drawArrow(to, direction, unicode_mode, priority);
    }

    /// Convert canvas to string
    pub fn toString(self: *Canvas, allocator: Allocator) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);

        var encode_buf: [4]u8 = undefined;

        for (self.cells, 0..) |row, y| {
            // Find last non-space character in row (trim trailing spaces)
            var last_non_space: usize = 0;
            for (row, 0..) |cell, x| {
                if (cell.char != ' ') {
                    last_non_space = x + 1;
                }
            }

            // Output characters up to last non-space
            for (row[0..last_non_space]) |cell| {
                const len = std.unicode.utf8Encode(cell.char, &encode_buf) catch 1;
                try result.appendSlice(allocator, encode_buf[0..len]);
            }

            // Add newline (except for last row if it's empty)
            if (y < self.cells.len - 1 or last_non_space > 0) {
                try result.append(allocator, '\n');
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Fill a rectangle with spaces (clear area)
    pub fn clearRect(self: *Canvas, rect: Rect) void {
        var y = rect.y;
        while (y < rect.bottom()) : (y += 1) {
            var x = rect.x;
            while (x < rect.right()) : (x += 1) {
                if (self.getCell(x, y)) |cell| {
                    cell.* = Cell{};
                }
            }
        }
    }
};

test "Canvas basic operations" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 20, 10);
    defer canvas.deinit();

    canvas.setChar(5, 5, 'X', .node_text);
    const cell = canvas.getCell(5, 5).?;
    try testing.expectEqual(@as(u21, 'X'), cell.char);

    // Out of bounds should be null
    try testing.expect(canvas.getCell(-1, 0) == null);
    try testing.expect(canvas.getCell(20, 0) == null);
}

test "Canvas draw box" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 10, 5);
    defer canvas.deinit();

    canvas.drawBox(.{ .x = 0, .y = 0, .width = 5, .height = 3 }, types.unicode_square, .node_border);

    // Check corners
    try testing.expectEqual(types.unicode_square.top_left, canvas.getCell(0, 0).?.char);
    try testing.expectEqual(types.unicode_square.top_right, canvas.getCell(4, 0).?.char);
    try testing.expectEqual(types.unicode_square.bottom_left, canvas.getCell(0, 2).?.char);
    try testing.expectEqual(types.unicode_square.bottom_right, canvas.getCell(4, 2).?.char);
}

test "Canvas toString" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 5, 3);
    defer canvas.deinit();

    canvas.drawText(0, 0, "Hi", .node_text);
    canvas.drawText(0, 2, "Lo", .node_text);

    const str = try canvas.toString(testing.allocator);
    defer testing.allocator.free(str);

    try testing.expectEqualStrings("Hi\n\nLo\n", str);
}

test "Canvas priority" {
    const testing = std.testing;
    var canvas = try Canvas.init(testing.allocator, 10, 5);
    defer canvas.deinit();

    // Draw with lower priority
    canvas.setChar(2, 2, 'A', .edge);
    // Try to overwrite with same priority - should work
    canvas.setChar(2, 2, 'B', .edge);
    try testing.expectEqual(@as(u21, 'B'), canvas.getCell(2, 2).?.char);

    // Try to overwrite with lower priority - should not work
    canvas.setChar(2, 2, 'C', .subgraph);
    try testing.expectEqual(@as(u21, 'B'), canvas.getCell(2, 2).?.char);

    // Overwrite with higher priority - should work
    canvas.setChar(2, 2, 'D', .node_text);
    try testing.expectEqual(@as(u21, 'D'), canvas.getCell(2, 2).?.char);
}

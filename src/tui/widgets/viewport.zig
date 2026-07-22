const std = @import("std");

pub const Viewport = struct {
    top: usize = 0,
    height: usize = 0,
    total: usize = 0,

    pub fn setMetrics(self: *Viewport, height: usize, total: usize) void {
        self.height = height;
        self.total = total;
        self.clamp();
    }

    pub fn lineDown(self: *Viewport, amount: usize) void {
        self.top = @min(self.top + amount, self.maxTop());
    }

    pub fn lineUp(self: *Viewport, amount: usize) void {
        self.top = self.top -| amount;
    }

    pub fn pageDown(self: *Viewport) void {
        self.lineDown(@max(self.height, 1));
    }

    pub fn pageUp(self: *Viewport) void {
        self.lineUp(@max(self.height, 1));
    }

    pub fn toTop(self: *Viewport) void {
        self.top = 0;
    }

    pub fn toBottom(self: *Viewport) void {
        self.top = self.maxTop();
    }

    pub fn visibleEnd(self: Viewport) usize {
        return @min(self.top + self.height, self.total);
    }

    /// Document line index shown at visible `row` (0-based from the top of the
    /// viewport), clamped to the last visible row and the content bounds.
    pub fn lineForRow(self: Viewport, row: usize) usize {
        const clamped_row = if (self.height > 0) @min(row, self.height - 1) else row;
        if (self.total == 0) return 0;
        return @min(self.top + clamped_row, self.total - 1);
    }

    pub fn progressPercent(self: Viewport) usize {
        if (self.total == 0 or self.height >= self.total) return 100;
        return @min((self.visibleEnd() * 100) / self.total, 100);
    }

    fn maxTop(self: Viewport) usize {
        return self.total -| self.height;
    }

    fn clamp(self: *Viewport) void {
        self.top = @min(self.top, self.maxTop());
    }
};

test "lineForRow maps visible rows to document lines" {
    const view = Viewport{ .top = 3, .height = 5, .total = 20 };
    try std.testing.expectEqual(@as(usize, 3), view.lineForRow(0));
    try std.testing.expectEqual(@as(usize, 7), view.lineForRow(4));
    // A row past the visible height clamps to the last visible row.
    try std.testing.expectEqual(@as(usize, 7), view.lineForRow(100));
}

test "lineForRow clamps to content bounds" {
    // Near the bottom, the line index is clamped to total-1.
    const bottom = Viewport{ .top = 18, .height = 5, .total = 20 };
    try std.testing.expectEqual(@as(usize, 19), bottom.lineForRow(4));

    // Empty content maps every row to 0.
    const empty = Viewport{};
    try std.testing.expectEqual(@as(usize, 0), empty.lineForRow(3));
}

test "clamps scrolling to content bounds" {
    var viewport = Viewport{};
    viewport.setMetrics(5, 12);
    viewport.lineDown(20);
    try std.testing.expectEqual(@as(usize, 7), viewport.top);
    viewport.pageUp();
    try std.testing.expectEqual(@as(usize, 2), viewport.top);
    viewport.toBottom();
    try std.testing.expectEqual(@as(usize, 7), viewport.top);
}

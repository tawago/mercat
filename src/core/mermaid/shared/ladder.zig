const std = @import("std");

pub const Fit = union(enum) { drawn: []const u8, too_wide: u32 };

/// Rungs in order; the first that draws wins. too_wide carries the narrowest width any rung needed.
pub fn firstFit(rungs: anytype, painter: anytype, max_width: u32) !Fit {
    std.debug.assert(rungs.len > 0);
    var narrowest: u32 = std.math.maxInt(u32);
    for (rungs) |rung| {
        switch (try painter.draw(rung, max_width)) {
            .drawn => |text| return .{ .drawn = text },
            .too_wide => |width| narrowest = @min(narrowest, width),
        }
    }
    return .{ .too_wide = narrowest };
}

const TestPainter = struct {
    calls: *u32,
    fail_at: ?u32 = null,

    fn draw(self: TestPainter, need: u32, max_width: u32) !Fit {
        self.calls.* += 1;
        if (self.fail_at == need) return error.Boom;
        return if (need <= max_width) .{ .drawn = "ok" } else .{ .too_wide = need };
    }
};

test "the first rung that draws wins and later rungs never run" {
    var calls: u32 = 0;
    const fit = try firstFit(&[_]u32{ 90, 50, 40, 30 }, TestPainter{ .calls = &calls }, 60);
    try std.testing.expectEqualStrings("ok", fit.drawn);
    try std.testing.expectEqual(@as(u32, 2), calls);
}

test "nothing fits: the narrowest width any rung needed, not the last" {
    var calls: u32 = 0;
    const fit = try firstFit(&[_]u32{ 90, 70, 80 }, TestPainter{ .calls = &calls }, 60);
    try std.testing.expectEqual(Fit{ .too_wide = 70 }, fit);
    try std.testing.expectEqual(@as(u32, 3), calls);
}

test "a painter error propagates" {
    var calls: u32 = 0;
    try std.testing.expectError(error.Boom, firstFit(&[_]u32{ 90, 70, 50 }, TestPainter{ .calls = &calls, .fail_at = 70 }, 60));
    try std.testing.expectEqual(@as(u32, 2), calls);
}

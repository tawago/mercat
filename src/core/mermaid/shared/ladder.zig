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

    fn draw(self: TestPainter, need: u32, max_width: u32) !Fit {
        self.calls.* += 1;
        return if (need <= max_width) .{ .drawn = "ok" } else .{ .too_wide = need };
    }
};

test "the first rung that draws wins; when none does, the narrowest width any rung needed" {
    const cases = [_]struct { needs: []const u32, want: Fit, calls: u32 }{
        .{ .needs = &.{ 90, 50, 40, 30 }, .want = .{ .drawn = "ok" }, .calls = 2 },
        .{ .needs = &.{ 90, 70, 80 }, .want = .{ .too_wide = 70 }, .calls = 3 },
    };
    for (cases) |case| {
        var calls: u32 = 0;
        const fit = try firstFit(case.needs, TestPainter{ .calls = &calls }, 60);
        switch (case.want) {
            .drawn => |text| try std.testing.expectEqualStrings(text, fit.drawn),
            .too_wide => try std.testing.expectEqual(case.want, fit),
        }
        try std.testing.expectEqual(case.calls, calls);
    }
}

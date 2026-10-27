const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const seq = @import("seq.zig");
const normalize = @import("normalize.zig");
const fit = @import("fit.zig");
const ladder = @import("../shared/ladder.zig");
const top_down = @import("tb.zig");
const left_right = @import("lr.zig");

pub fn render(allocator: Allocator, source: []const u8, max_width: u32) !ladder.Fit {
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();
    if (diagram.participants.items.len == 0) return .{ .drawn = "" };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const sequence = try normalize.normalize(arena.allocator(), &diagram);

    const painter = Painter{ .allocator = allocator, .sequence = &sequence };
    const rungs = fit.ladder(diagram.direction, diagram.direction_explicit, sequence.hasTopDownOnly());
    return ladder.firstFit(rungs, painter, max_width);
}

const Painter = struct {
    allocator: Allocator,
    sequence: *const seq.Sequence,

    pub fn draw(self: Painter, rung: fit.Rung, max_width: u32) !ladder.Fit {
        return switch (rung) {
            .top_down => top_down.render(self.allocator, self.sequence, max_width),
            .left_right => left_right.render(self.allocator, self.sequence, max_width),
        };
    }
};

test {
    _ = @import("normalize.zig");
    _ = @import("tb.zig");
    _ = @import("tb_text.zig");
    _ = @import("tb_rows.zig");
    _ = @import("tb_columns.zig");
    _ = @import("tb_frames.zig");
    _ = @import("ink.zig");
    _ = @import("tb_paint.zig");
    _ = @import("lr.zig");
    _ = @import("fit.zig");
    _ = @import("parse.zig");
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("parse.zig");
const fit = @import("fit.zig");
const top_down = @import("tb.zig");
const left_right = @import("lr.zig");

pub fn render(allocator: Allocator, source: []const u8, max_width: u32) !?[]const u8 {
    var diagram = try parse.parse(allocator, source);
    defer diagram.deinit();

    for (fit.ladder(diagram.direction, diagram.direction_explicit)) |rung| {
        const spacing = rung orelse continue;
        const drawn = switch (spacing.direction orelse diagram.direction) {
            .LR => try left_right.render(allocator, &diagram, spacing, max_width),
            else => try top_down.render(allocator, &diagram, spacing, max_width),
        };
        if (drawn) |text| return text;
    }
    return null;
}

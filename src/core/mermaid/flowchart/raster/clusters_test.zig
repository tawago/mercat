const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const clusters = @import("clusters.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn makeClusterSketch(frames: []const sketch.ClusterFrame) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = frames,
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 0, .rung = 0 },
    };
}

test "rasterizeClusters: a synthetic frame with a nonzero rect still paints nothing" {
    const allocator = testing.allocator;
    var lat = try makeLattice(allocator, 10, 10);
    defer allocator.free(lat.cells);

    const frames = [_]sketch.ClusterFrame{
        .{
            .id = 1,
            .rect = .{ .x = 1, .y = 1, .w = 6, .h = 6 },
            .parent_id = null,
            .label = "",
            .depth = 0,
            .synthetic = true,
        },
    };
    const s = makeClusterSketch(&frames);

    const n = try clusters.rasterizeClusters(allocator, &lat, s);
    try testing.expectEqual(@as(u32, 0), n);

    for (lat.cells) |c| {
        switch (c.occupant) {
            .empty => {},
            else => return error.UnexpectedNonEmpty,
        }
    }
}

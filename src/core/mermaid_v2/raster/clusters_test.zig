//! Tests for `raster/clusters.zig`'s synthetic-frame invisibility invariant.
//! Split out of the former misc grab-bag test file (since dissolved) into
//! clusters.zig's own sibling, per the mermaid_v2/ test-file convention.
//! Discovered via clusters.zig's top-level
//! `test { _ = @import("clusters_test.zig"); }` block. (Note:
//! `layout/clusters_test.zig` is a DIFFERENT file testing the unrelated
//! layout/clusters.zig — same basename in a different folder.)
//! clusters.zig's own corner/edge/nesting tests stay inline in clusters.zig
//! itself.

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

// ---------------------------------------------------------------------
// clusters.zig: synthetic packing frames never rasterize, even if the
// zero-pad invariant they depend on (stitch.zig) is violated and they
// carry a nonzero rect (near line 46).
// ---------------------------------------------------------------------
test "rasterizeClusters: a synthetic frame with a nonzero rect still paints nothing" {
    const allocator = testing.allocator;
    var lat = try makeLattice(allocator, 10, 10);
    defer allocator.free(lat.cells);

    const frames = [_]sketch.ClusterFrame{
        .{
            .id = 1,
            .rect = .{ .x = 1, .y = 1, .w = 6, .h = 6 }, // nonzero: violates the zero-pad invariant
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

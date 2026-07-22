//! Tests for `mirror.zig`'s `applyDirection`, split out of the former
//! misc grab-bag test file (since dissolved) into mirror.zig's own
//! sibling, per the mermaid_v2/ test-file convention. Discovered via
//! mirror.zig's top-level `test { _ = @import("mirror_test.zig"); }` block.
//! (mirror.zig's own axis-swap/bus-bar/RL tests stay inline in mirror.zig
//! itself.)

const std = @import("std");
const mirror = @import("mirror.zig");
const routing = @import("routing.zig");

const testing = std.testing;
const NodeGeom = routing.NodeGeom;

// ---------------------------------------------------------------------
// back_edges.zig: NodeGeom.layer survives applyDirection (near line 67)
// ---------------------------------------------------------------------
test "mirror.applyDirection swaps x/y/w/h but leaves NodeGeom.layer untouched" {
    var geom = [_]NodeGeom{
        .{ .x = 2, .y = 5, .w = 7, .h = 3, .layer = 4 },
        .{ .x = 10, .y = 1, .w = 4, .h = 9, .layer = 0 },
    };
    mirror.applyDirection(NodeGeom, &geom, .LR);

    // Axes swapped (LR path taken, not the TD no-op path).
    try testing.expectEqual(@as(i32, 5), geom[0].x);
    try testing.expectEqual(@as(i32, 2), geom[0].y);
    try testing.expectEqual(@as(u32, 3), geom[0].w);
    try testing.expectEqual(@as(u32, 7), geom[0].h);

    // `.layer` is untouched by the swap — still the pre-swap logical layer.
    try testing.expectEqual(@as(u32, 4), geom[0].layer);
    try testing.expectEqual(@as(u32, 0), geom[1].layer);
}

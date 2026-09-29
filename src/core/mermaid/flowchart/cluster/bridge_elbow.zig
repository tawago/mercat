const std = @import("std");
const sketch = @import("../sketch.zig");
const scene = @import("bridge_scene.zig");
const types = @import("bridge_types.zig");

const Pending = types.Pending;
const clampBetween = scene.clampBetween;
const polyIntrudes = scene.polyIntrudes;

pub fn rerouted(
    arena: std.mem.Allocator,
    p: Pending,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}!bool {
    if (p.sides.exit != .north and p.sides.exit != .south) return false;
    return polyIntrudes(try buildElbow(arena, p), placements, p.gf, p.gt);
}

pub fn buildElbow(arena: std.mem.Allocator, p: Pending) error{OutOfMemory}![]sketch.Point {
    var poly: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try poly.append(arena, p.start);
    if (p.jog) |j| {
        const jc = switch (p.sides.exit) {
            .south => clampBetween(p.start.y, p.end.y, j),
            .north => clampBetween(p.end.y, p.start.y, j),
            .east => clampBetween(p.start.x, p.end.x, j),
            .west => clampBetween(p.end.x, p.start.x, j),
        };
        const vertical = (p.sides.exit == .north or p.sides.exit == .south);
        if (vertical) {
            try poly.append(arena, .{ .x = p.start.x, .y = jc });
            try poly.append(arena, .{ .x = p.end.x, .y = jc });
        } else {
            try poly.append(arena, .{ .x = jc, .y = p.start.y });
            try poly.append(arena, .{ .x = jc, .y = p.end.y });
        }
    }
    try poly.append(arena, p.end);
    return try poly.toOwnedSlice(arena);
}

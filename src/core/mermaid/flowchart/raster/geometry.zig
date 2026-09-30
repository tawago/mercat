const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");

pub const Move = lattice.Dir4;

pub fn straightMask(dir: Move) lattice.Neighbours {
    return switch (dir) {
        .north, .south => .{ .n = true, .s = true },
        .east, .west => .{ .e = true, .w = true },
    };
}

pub fn bitMask(dir: Move) lattice.Neighbours {
    return switch (dir) {
        .north => .{ .n = true },
        .east => .{ .e = true },
        .south => .{ .s = true },
        .west => .{ .w = true },
    };
}

pub fn reverse(dir: Move) Move {
    return switch (dir) {
        .north => .south,
        .south => .north,
        .east => .west,
        .west => .east,
    };
}

pub fn orMask(a: lattice.Neighbours, b: lattice.Neighbours) lattice.Neighbours {
    return lattice.Neighbours.fromMask(a.toMask() | b.toMask());
}

pub fn segmentDir(a: sketch.Point, b: sketch.Point) ?Move {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if (dx == 0 and dy == 0) return null;
    if (dx != 0 and dy != 0) return null;
    if (dx > 0) return .east;
    if (dx < 0) return .west;
    if (dy > 0) return .south;
    return .north;
}

pub fn step(p: sketch.Point, dir: Move) sketch.Point {
    return switch (dir) {
        .north => .{ .x = p.x, .y = p.y - 1 },
        .south => .{ .x = p.x, .y = p.y + 1 },
        .east => .{ .x = p.x + 1, .y = p.y },
        .west => .{ .x = p.x - 1, .y = p.y },
    };
}

pub fn pointInBounds(p: sketch.Point, lat: *const lattice.Lattice) bool {
    return p.x >= 0 and p.y >= 0 and
        p.x < @as(i32, @intCast(lat.width)) and
        p.y < @as(i32, @intCast(lat.height));
}

pub const Coord = struct { x: u32, y: u32 };

pub fn toCoord(p: sketch.Point) Coord {
    std.debug.assert(p.x >= 0 and p.y >= 0);
    return .{ .x = @intCast(p.x), .y = @intCast(p.y) };
}

const testing = std.testing;

test "directional primitives round-trip (straightMask/bitMask/reverse)" {
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        straightMask(.north).toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        straightMask(.east).toMask(),
    );
    try testing.expectEqual(Move.south, reverse(.north));
    try testing.expectEqual(
        (lattice.Neighbours{ .w = true }).toMask(),
        bitMask(.west).toMask(),
    );
}

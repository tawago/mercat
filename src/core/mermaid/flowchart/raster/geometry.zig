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

pub fn lateralArms(tip: lattice.Dir4, mask: lattice.Neighbours) lattice.Neighbours {
    return switch (tip) {
        .north, .south => .{ .e = mask.e, .w = mask.w },
        .east, .west => .{ .n = mask.n, .s = mask.s },
    };
}

pub fn onSegment(a: sketch.Point, b: sketch.Point, x: i32, y: i32) bool {
    if (a.x != b.x and a.y != b.y) return false;
    return x >= @min(a.x, b.x) and x <= @max(a.x, b.x) and
        y >= @min(a.y, b.y) and y <= @max(a.y, b.y);
}

pub fn cellAt(lat: *const lattice.Lattice, x: i32, y: i32) ?*const lattice.Cell {
    if (x < 0 or y < 0) return null;
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    if (ux >= lat.width or uy >= lat.height) return null;
    return lat.atConst(ux, uy);
}

pub fn rectFitsLattice(r: sketch.Rect, lat: *const lattice.Lattice) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (r.x < 0 or r.y < 0) return false;
    if (r.right() > @as(i32, @intCast(lat.width))) return false;
    if (r.bottom() > @as(i32, @intCast(lat.height))) return false;
    return true;
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

test "lateralArms keeps only the bits off the head's axis" {
    const all: lattice.Neighbours = .{ .n = true, .e = true, .s = true, .w = true };
    try std.testing.expectEqual((lattice.Neighbours{ .e = true, .w = true }).toMask(), lateralArms(.north, all).toMask());
    try std.testing.expectEqual((lattice.Neighbours{ .n = true, .s = true }).toMask(), lateralArms(.west, all).toMask());
    try std.testing.expectEqual(@as(u4, 0), lateralArms(.south, .{ .n = true, .s = true }).toMask());
}

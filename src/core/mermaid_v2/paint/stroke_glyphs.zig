const std = @import("std");
const lattice = @import("../lattice.zig");

pub const dotted_table: [16]u21 = blk: {
    var t: [16]u21 = undefined;
    t[0b0000] = ' ';
    t[0b0001] = '┊';
    t[0b0010] = '╌';
    t[0b0011] = '└';
    t[0b0100] = '┊';
    t[0b0101] = '┊';
    t[0b0110] = '┌';
    t[0b0111] = '├';
    t[0b1000] = '╌';
    t[0b1001] = '┘';
    t[0b1010] = '╌';
    t[0b1011] = '┴';
    t[0b1100] = '┐';
    t[0b1101] = '┤';
    t[0b1110] = '┬';
    t[0b1111] = '┼';
    break :blk t;
};

pub const thick_table: [16]u21 = blk: {
    var t: [16]u21 = undefined;
    t[0b0000] = ' ';
    t[0b0001] = '║';
    t[0b0010] = '═';
    t[0b0011] = '╚';
    t[0b0100] = '║';
    t[0b0101] = '║';
    t[0b0110] = '╔';
    t[0b0111] = '╠';
    t[0b1000] = '═';
    t[0b1001] = '╝';
    t[0b1010] = '═';
    t[0b1011] = '╩';
    t[0b1100] = '╗';
    t[0b1101] = '╣';
    t[0b1110] = '╦';
    t[0b1111] = '╬';
    break :blk t;
};

pub const thick_border_table: [16]u21 = blk: {
    var t: [16]u21 = undefined;
    t[0b0000] = ' ';
    t[0b0001] = '╨';
    t[0b0010] = '╞';
    t[0b0011] = '└';
    t[0b0100] = '╥';
    t[0b0101] = '║';
    t[0b0110] = '┌';
    t[0b0111] = '╞';
    t[0b1000] = '╡';
    t[0b1001] = '┘';
    t[0b1010] = '═';
    t[0b1011] = '╨';
    t[0b1100] = '┐';
    t[0b1101] = '╡';
    t[0b1110] = '╥';
    t[0b1111] = '┼';
    break :blk t;
};

pub fn dottedBorderGlyph(neighbours: lattice.Neighbours) u21 {
    return @import("junction_glyphs.zig").glyphFor(neighbours);
}

pub fn dottedGlyph(neighbours: lattice.Neighbours) u21 {
    return dotted_table[neighbours.toMask()];
}

pub fn thickGlyph(neighbours: lattice.Neighbours) u21 {
    return thick_table[neighbours.toMask()];
}

pub fn thickBorderGlyph(neighbours: lattice.Neighbours) u21 {
    return thick_border_table[neighbours.toMask()];
}

test "dotted_table: straight strokes match goldens" {
    try std.testing.expectEqual(@as(u21, '┊'), dottedGlyph(.{ .n = true, .s = true }));
    try std.testing.expectEqual(@as(u21, '╌'), dottedGlyph(.{ .e = true, .w = true }));
    try std.testing.expectEqual(@as(u21, ' '), dottedGlyph(.{}));
}

test "thick_table: straight strokes match goldens" {
    try std.testing.expectEqual(@as(u21, '║'), thickGlyph(.{ .n = true, .s = true }));
    try std.testing.expectEqual(@as(u21, '═'), thickGlyph(.{ .e = true, .w = true }));
    try std.testing.expectEqual(@as(u21, '╔'), thickGlyph(.{ .e = true, .s = true }));
    try std.testing.expectEqual(@as(u21, '╬'), thickGlyph(.{ .n = true, .e = true, .s = true, .w = true }));
}

test "thick_border_table: south-of-border picks ╥" {
    const n = lattice.Neighbours{ .e = true, .w = true, .s = true };
    try std.testing.expectEqual(@as(u21, '╥'), thickBorderGlyph(n));
}

test "thick_border_table: north-of-border picks ╨" {
    const n = lattice.Neighbours{ .e = true, .w = true, .n = true };
    try std.testing.expectEqual(@as(u21, '╨'), thickBorderGlyph(n));
}

test "dotted/thick tables exhaustive" {
    var i: u5 = 0;
    while (i < 16) : (i += 1) {
        const mask: u4 = @intCast(i);
        const n = lattice.Neighbours.fromMask(mask);
        _ = dottedGlyph(n);
        _ = thickGlyph(n);
        _ = thickBorderGlyph(n);
    }
}

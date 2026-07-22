//! Junction glyph lookup table.
//!
//! Translates a `Neighbours` 4-bit connectivity mask into the single
//! Unicode box-drawing codepoint the painter should emit for that
//! cell. Keyed by the same bit layout `Neighbours` exposes:
//!
//!   bit 0 = N, bit 1 = E, bit 2 = S, bit 3 = W.
//!
//! This file imports only `std` and the lattice types module.

const std = @import("std");
const lattice = @import("../lattice.zig");

/// 16-entry table indexed by `Neighbours.toMask()`.
pub const junction_table: [16]u21 = blk: {
    var t: [16]u21 = undefined;
    t[0b0000] = ' ';
    t[0b0001] = '╵'; // N
    t[0b0010] = '╶'; // E
    t[0b0011] = '└'; // N+E
    t[0b0100] = '╷'; // S
    t[0b0101] = '│'; // N+S
    t[0b0110] = '┌'; // E+S
    t[0b0111] = '├'; // N+E+S
    t[0b1000] = '╴'; // W
    t[0b1001] = '┘'; // N+W
    t[0b1010] = '─'; // E+W
    t[0b1011] = '┴'; // N+E+W
    t[0b1100] = '┐'; // S+W
    t[0b1101] = '┤'; // N+S+W
    t[0b1110] = '┬'; // E+S+W
    t[0b1111] = '┼'; // all
    break :blk t;
};

/// Glyph for a given neighbour set.
pub fn glyphFor(neighbours: lattice.Neighbours) u21 {
    return junction_table[neighbours.toMask()];
}

test "junction_table: exhaustive 16-entry mapping" {
    const expected = [16]u21{
        ' ', // 0000
        '╵', // 0001  N
        '╶', // 0010  E
        '└', // 0011  N+E
        '╷', // 0100  S
        '│', // 0101  N+S
        '┌', // 0110  E+S
        '├', // 0111  N+E+S
        '╴', // 1000  W
        '┘', // 1001  N+W
        '─', // 1010  E+W
        '┴', // 1011  N+E+W
        '┐', // 1100  S+W
        '┤', // 1101  N+S+W
        '┬', // 1110  E+S+W
        '┼', // 1111  all
    };

    var i: u5 = 0;
    while (i < 16) : (i += 1) {
        const mask: u4 = @intCast(i);
        const n = lattice.Neighbours.fromMask(mask);
        try std.testing.expectEqual(expected[i], glyphFor(n));
        try std.testing.expectEqual(expected[i], junction_table[mask]);
    }
}

test "junction_table: glyphFor matches direct table indexing" {
    const n = lattice.Neighbours{ .n = true, .s = true };
    try std.testing.expectEqual(@as(u21, '│'), glyphFor(n));

    const cross = lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true };
    try std.testing.expectEqual(@as(u21, '┼'), glyphFor(cross));

    const empty: lattice.Neighbours = .{};
    try std.testing.expectEqual(@as(u21, ' '), glyphFor(empty));
}

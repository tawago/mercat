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
    t[0b0001] = '╵';
    t[0b0010] = '╶';
    t[0b0011] = '└';
    t[0b0100] = '╷';
    t[0b0101] = '│';
    t[0b0110] = '┌';
    t[0b0111] = '├';
    t[0b1000] = '╴';
    t[0b1001] = '┘';
    t[0b1010] = '─';
    t[0b1011] = '┴';
    t[0b1100] = '┐';
    t[0b1101] = '┤';
    t[0b1110] = '┬';
    t[0b1111] = '┼';
    break :blk t;
};

/// Glyph for a given neighbour set.
pub fn glyphFor(neighbours: lattice.Neighbours) u21 {
    return junction_table[neighbours.toMask()];
}

test "junction_table: exhaustive 16-entry mapping" {
    const expected = [16]u21{
        ' ',
        '╵',
        '╶',
        '└',
        '╷',
        '│',
        '┌',
        '├',
        '╴',
        '┘',
        '─',
        '┴',
        '┐',
        '┤',
        '┬',
        '┼',
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

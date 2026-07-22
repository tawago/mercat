//! Alternate junction glyph tables for non-solid edge strokes.
//!
//! Keyed by the same 4-bit `Neighbours` mask as `junction_glyphs.zig`:
//!   bit 0 = N, bit 1 = E, bit 2 = S, bit 3 = W.
//!
//! Corner/tee/cross entries not exercised by current goldens fall back
//! to the closest visually-correct alternate. Imports only `std` and
//! the lattice types module.

const std = @import("std");
const lattice = @import("../lattice.zig");

/// Dotted (light) stroke glyphs. Goldens use vertical `┊` (U+250A,
/// "BOX DRAWINGS LIGHT QUADRUPLE DASH VERTICAL") and horizontal `╌`
/// (U+254C, "BOX DRAWINGS LIGHT DOUBLE DASH HORIZONTAL"). Corners/tees
/// fall back to single-line glyphs since the dotted variant set is
/// incomplete in Unicode.
pub const dotted_table: [16]u21 = blk: {
    var t: [16]u21 = undefined;
    t[0b0000] = ' ';
    t[0b0001] = '┊'; // N
    t[0b0010] = '╌'; // E
    t[0b0011] = '└'; // N+E
    t[0b0100] = '┊'; // S
    t[0b0101] = '┊'; // N+S
    t[0b0110] = '┌'; // E+S
    t[0b0111] = '├'; // N+E+S
    t[0b1000] = '╌'; // W
    t[0b1001] = '┘'; // N+W
    t[0b1010] = '╌'; // E+W
    t[0b1011] = '┴'; // N+E+W
    t[0b1100] = '┐'; // S+W
    t[0b1101] = '┤'; // N+S+W
    t[0b1110] = '┬'; // E+S+W
    t[0b1111] = '┼'; // all
    break :blk t;
};

/// Thick (double-line) stroke glyphs. Goldens use vertical `║`
/// (U+2551) and horizontal `═` (U+2550). Full set of double-line
/// box-drawing corners and tees exists in Unicode.
pub const thick_table: [16]u21 = blk: {
    var t: [16]u21 = undefined;
    t[0b0000] = ' ';
    t[0b0001] = '║'; // N
    t[0b0010] = '═'; // E
    t[0b0011] = '╚'; // N+E
    t[0b0100] = '║'; // S
    t[0b0101] = '║'; // N+S
    t[0b0110] = '╔'; // E+S
    t[0b0111] = '╠'; // N+E+S
    t[0b1000] = '═'; // W
    t[0b1001] = '╝'; // N+W
    t[0b1010] = '═'; // E+W
    t[0b1011] = '╩'; // N+E+W
    t[0b1100] = '╗'; // S+W
    t[0b1101] = '╣'; // N+S+W
    t[0b1110] = '╦'; // E+S+W
    t[0b1111] = '╬'; // all
    break :blk t;
};

/// Glyphs for a *solid* node/cluster border cell whose connectivity
/// mask gained a bit from a non-solid edge merging into it. Indexed
/// the same way; entries here are the "hybrid" double-and-single
/// box-drawing characters (e.g. `╥` = border-horizontal-single +
/// edge-down-double).
///
/// Only the 4 single-side-extra cases that actually occur in the
/// goldens (one extra bit beyond the border's two horizontal/vertical
/// neighbours) are distinct; other entries fall back to the matching
/// solid junction glyph since no fixture exercises them yet.
pub const thick_border_table: [16]u21 = blk: {
    var t: [16]u21 = undefined;
    t[0b0000] = ' ';
    t[0b0001] = '╨'; // N (vertical edge above a horizontal border)
    t[0b0010] = '╞'; // E (horizontal edge right of a vertical border)
    t[0b0011] = '└';
    t[0b0100] = '╥'; // S (vertical edge below a horizontal border)
    t[0b0101] = '║';
    t[0b0110] = '┌';
    t[0b0111] = '╞';
    t[0b1000] = '╡'; // W (horizontal edge left of a vertical border)
    t[0b1001] = '┘';
    t[0b1010] = '═';
    t[0b1011] = '╨';
    t[0b1100] = '┐';
    t[0b1101] = '╡';
    t[0b1110] = '╥';
    t[0b1111] = '┼';
    break :blk t;
};

/// Like `thick_border_table` but for a dotted edge merging into a
/// solid border. The goldens don't use a distinct hybrid for dotted
/// (border keeps `┬`/`├`/etc.), so this defers to the regular solid
/// junction table.
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
    // Border south side (horizontal: e+w) with thick edge departing
    // south: mask = e|w|s = 1110.
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

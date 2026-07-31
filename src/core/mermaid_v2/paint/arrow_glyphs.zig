//! Arrowhead glyph table keyed by (ArrowKind, Dir4).
//!
//! Every declared head style paints its own glyph instead of collapsing to
//! the filled triangles, so `-->`, `--o` and `--x` stay distinguishable in
//! the painted grid:
//!   * filled → ▲ ▶ ▼ ◀ (the historical direction-only set, unchanged)
//!   * open   → △ ▷ ▽ ◁
//!   * circle → ○ (direction-invariant)
//!   * cross  → ✕ (U+2715; direction-invariant)
//!
//! PIN — forbidden codepoints: U+2716 (✖) and U+2A2F (⨯) map to glyph 0 in
//! the pinned embedded export font and must never appear here. The cross is
//! U+2715 only. // guarded-by: arrow_glyphs.zig "arrow table never contains the tofu crosses U+2716/U+2A2F"
//!
//! All glyphs are display-width 1 (East-Asian narrow/neutral), so swapping
//! a head glyph can never change a row's column count.
//!
//! Imports only `std`, `prim`, and the lattice types module.

const std = @import("std");
const prim = @import("prim");
const lattice = @import("../lattice.zig");

/// Glyph for one arrowhead cell. `.none` never reaches an arrowhead cell:
/// the raster stage writes arrowheads only behind `arrow != .none` guards
/// (raster/edges.zig, raster/busbars.zig).
pub fn glyphFor(kind: lattice.ArrowKind, dir: lattice.Dir4) u21 {
    return switch (kind) {
        .none => unreachable, // raster never emits an arrowhead cell for .none
        .filled => switch (dir) {
            .north => '▲',
            .east => '▶',
            .south => '▼',
            .west => '◀',
        },
        .open => switch (dir) {
            .north => '△',
            .east => '▷',
            .south => '▽',
            .west => '◁',
        },
        .circle => '○',
        .cross => '\u{2715}',
    };
}

const testing = std.testing;

const drawable_kinds = [_]lattice.ArrowKind{ .filled, .open, .circle, .cross };
const all_dirs = [_]lattice.Dir4{ .north, .east, .south, .west };

test "arrow glyph table: exhaustive kind x dir mapping" {
    const cases = [_]struct { kind: lattice.ArrowKind, want: [4]u21 }{
        .{ .kind = .filled, .want = .{ '▲', '▶', '▼', '◀' } },
        .{ .kind = .open, .want = .{ '△', '▷', '▽', '◁' } },
        .{ .kind = .circle, .want = .{ '○', '○', '○', '○' } },
        .{ .kind = .cross, .want = .{ '\u{2715}', '\u{2715}', '\u{2715}', '\u{2715}' } },
    };
    for (cases) |c| {
        for (all_dirs, 0..) |d, i| {
            try testing.expectEqual(c.want[i], glyphFor(c.kind, d));
        }
    }
}

test "arrow table never contains the tofu crosses U+2716/U+2A2F" {
    for (drawable_kinds) |k| {
        for (all_dirs) |d| {
            const g = glyphFor(k, d);
            try testing.expect(g != 0x2716);
            try testing.expect(g != 0x2A2F);
        }
    }
}

test "every arrow glyph is display-width 1" {
    for (drawable_kinds) |k| {
        for (all_dirs) |d| {
            var buf: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(glyphFor(k, d), &buf);
            try testing.expectEqual(@as(usize, 1), prim.displayWidth(buf[0..n]));
        }
    }
}

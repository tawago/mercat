//! Lattice IR — the cell-grid intermediate representation between the
//! rasterizer and the painter. A `Lattice` is a width × height grid of
//! `Cell`s; each cell carries an `Occupant` tag (empty, node/cluster
//! border or interior, edge segment, arrowhead, or label codepoint)
//! and a `Neighbours` bitmask consumed by the painter's junction table.
//!
//! Pure data: must not import `sketch.zig`, `parse.zig`, or `paint.zig`
//! (enforced by `zig build lint`). Imports: `std` and `prim` only.

const std = @import("std");
const prim = @import("prim");

/// Which border piece a cell on a node or cluster outline represents.
/// Lets the painter (and validators) tell corners from edges without
/// reinspecting the geometry.
pub const BorderRole = enum {
    corner_nw,
    corner_ne,
    corner_se,
    corner_sw,
    edge_n,
    edge_e,
    edge_s,
    edge_w,
};

/// Cardinal direction. Shared via `prim` — lattice does not import sketch.
pub const Dir4 = prim.Dir4;

/// Per-cell connectivity bitmask used by the junction table.
///
/// Bit layout (matches `paint/junction_glyphs.zig` indexing):
///   bit 0 = north
///   bit 1 = east
///   bit 2 = south
///   bit 3 = west
///
/// `@bitCast` between `Neighbours` and `u4` is well-defined because
/// the struct is `packed` with backing integer `u4`.
pub const Neighbours = packed struct(u4) {
    n: bool = false,
    e: bool = false,
    s: bool = false,
    w: bool = false,

    /// Convert to the raw 4-bit mask. Bit ordering: N=0, E=1, S=2, W=3.
    pub fn toMask(self: Neighbours) u4 {
        return @bitCast(self);
    }

    /// Inverse of `toMask`.
    pub fn fromMask(m: u4) Neighbours {
        return @bitCast(m);
    }
};

pub const NodeId = prim.NodeId;
pub const EdgeId = prim.EdgeId;
pub const ClusterId = prim.ClusterId;

/// Stroke style of an edge segment. Shared with `sketch/` via `prim`.
pub const EdgeKind = prim.EdgeKind;

/// Routing-intent role of an edge-segment cell. Shared with `sketch/` via
/// `prim`.
pub const EdgeRole = prim.EdgeRole;

/// Visual shape of the node a border cell belongs to. Shared with
/// `sketch/` via `prim`.
pub const Shape = prim.Shape;

/// What a single cell holds. The `empty` variant is the default and
/// represents background space.
pub const Occupant = union(enum) {
    empty,
    node_interior: NodeId,
    node_border: struct {
        node: NodeId,
        role: BorderRole,
    },
    cluster_border: struct {
        cluster: ClusterId,
        role: BorderRole,
    },
    edge_segment: struct {
        edge: EdgeId,
        kind: EdgeKind,
        role: EdgeRole = .forward,
    },
    arrowhead: struct {
        dir: Dir4,
        edge: EdgeId,
    },
    label_char: u21,
};

/// One grid cell.
///
/// `stroke_kind` records the stroke style for the painter's glyph
/// pick. For `.edge_segment` cells it mirrors the segment's kind.
/// For `.node_border` cells it stays `.solid` unless a non-solid
/// edge merges connectivity into the border (e.g. a thick edge
/// departing south sets the border cell's `stroke_kind = .thick`
/// so the painter picks `╥` instead of `┬`).
pub const Cell = struct {
    occupant: Occupant,
    neighbours: Neighbours,
    stroke_kind: EdgeKind = .solid,
    /// Visual shape of the node this cell belongs to, when relevant
    /// (`.node_border` and `.node_interior` occupants). For all other
    /// occupants this field is meaningless and stays `.rect`. The
    /// painter uses it to pick shape-specific perimeter glyphs.
    shape: Shape = .rect,

    /// Default cell value: empty background, no neighbours.
    pub const empty: Cell = .{
        .occupant = .empty,
        .neighbours = .{},
        .stroke_kind = .solid,
        .shape = .rect,
    };
};

/// Width × height grid of cells, row-major.
///
/// `cells.len` must equal `width * height`. The lattice does not own
/// `cells` — the rasterizer (the producer) is responsible for the
/// allocation lifetime.
pub const Lattice = struct {
    width: u32,
    height: u32,
    cells: []Cell,

    /// Mutable cell access. Bounds are asserted in debug builds.
    pub fn at(self: Lattice, x: u32, y: u32) *Cell {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return &self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    /// Const cell access.
    pub fn atConst(self: Lattice, x: u32, y: u32) *const Cell {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return &self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }
};

test "Neighbours bitmask round-trip across all 16 values" {
    var m: u5 = 0;
    while (m < 16) : (m += 1) {
        const mask: u4 = @intCast(m);
        const n = Neighbours.fromMask(mask);
        try std.testing.expectEqual(mask, n.toMask());

        // Spot-check individual bits agree with the documented layout.
        try std.testing.expectEqual((mask & 0b0001) != 0, n.n);
        try std.testing.expectEqual((mask & 0b0010) != 0, n.e);
        try std.testing.expectEqual((mask & 0b0100) != 0, n.s);
        try std.testing.expectEqual((mask & 0b1000) != 0, n.w);
    }
}

test "Neighbours default is all-false / mask 0" {
    const n: Neighbours = .{};
    try std.testing.expectEqual(@as(u4, 0), n.toMask());
}

test "Neighbours single-bit constructors" {
    try std.testing.expectEqual(@as(u4, 0b0001), (Neighbours{ .n = true }).toMask());
    try std.testing.expectEqual(@as(u4, 0b0010), (Neighbours{ .e = true }).toMask());
    try std.testing.expectEqual(@as(u4, 0b0100), (Neighbours{ .s = true }).toMask());
    try std.testing.expectEqual(@as(u4, 0b1000), (Neighbours{ .w = true }).toMask());
}

test "Lattice index calculation: row-major, at() returns correct cell" {
    var buf: [12]Cell = undefined;
    for (&buf) |*c| c.* = Cell.empty;

    var lat = Lattice{ .width = 4, .height = 3, .cells = &buf };

    // Tag each cell with a distinct label_char so we can verify ordering.
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            lat.at(x, y).*.occupant = .{ .label_char = @intCast(y * lat.width + x) };
        }
    }

    // Verify row-major linearization: cells[y*w + x].
    for (buf, 0..) |c, i| {
        switch (c.occupant) {
            .label_char => |ch| try std.testing.expectEqual(@as(u21, @intCast(i)), ch),
            else => return error.UnexpectedOccupant,
        }
    }

    // Spot-check via at() / atConst().
    try std.testing.expectEqual(@as(u21, 0), switch (lat.atConst(0, 0).occupant) {
        .label_char => |ch| ch,
        else => unreachable,
    });
    try std.testing.expectEqual(@as(u21, 6), switch (lat.atConst(2, 1).occupant) {
        .label_char => |ch| ch,
        else => unreachable,
    });
    try std.testing.expectEqual(@as(u21, 11), switch (lat.atConst(3, 2).occupant) {
        .label_char => |ch| ch,
        else => unreachable,
    });
}

test "Cell.empty default matches struct literal" {
    const a = Cell.empty;
    try std.testing.expectEqual(@as(u4, 0), a.neighbours.toMask());
    switch (a.occupant) {
        .empty => {},
        else => return error.NotEmpty,
    }
}

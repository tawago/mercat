//! Lattice IR — the cell-grid intermediate representation between the
//! rasterizer and the painter. A `Lattice` is a width × height grid of
//! `Cell`s; each cell carries an `Occupant` tag (empty, node/cluster
//! border or interior, edge segment, arrowhead, or label codepoint)
//! and a `Neighbours` bitmask consumed by the painter's junction table.
//!
//! Beside the grid sits `aux`: a position-keyed side table of `Aux`
//! records (see below), the channel for facts that are plural or
//! positional rather than painted.
//!
//! Pure data: must not import `sketch.zig`, `parse.zig`, or `paint.zig`
//! (enforced by `zig build lint`). Imports: `std` and `prim` only.
//!
//! ANTI-DESYNC LAW (the side table's one rule): an `Aux` record may only
//! carry a fact the `Cell` CANNOT express. Never a restatement of an
//! occupant, a neighbour bit, a stroke kind or a shape. A Cell holds one
//! single-valued painted fact per position and is rewritten in place by
//! passes that run AFTER the producer walk (role stamping, neighbour
//! reconciliation, arrowhead-base receiving); a record that duplicated a
//! Cell field would become a second, stale source of truth the moment one
//! of those passes fired. Records are therefore append-only history of
//! what a producer did — which edge attached here, which runs share this
//! cell — and no pass rewrites them.
//! guarded-by: raster/aux_test.zig "aux records survive the three post-walk mutating passes"

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

/// Arrowhead style of an `arrowhead` cell. Shared with `sketch/` via
/// `prim`.
pub const ArrowKind = prim.ArrowKind;

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
        /// Head style the producing edge asked for. Carried so the head
        /// glyph can stop being a function of `dir` alone; the painter
        /// still ignores it, so every cell paints exactly as before.
        /// The default keeps synthetic/test cells at today's shape.
        /// guarded-by: lattice.zig "Cell stays 16 bytes: the arrowhead style rides in existing padding"
        arrow: ArrowKind = .filled,
    },
    label_char: u21,
    /// Second terminal column of the East-Asian-Wide `label_char`
    /// immediately WEST. Paints zero bytes and contributes zero display
    /// columns; it exists so collision detection and free-space probes see
    /// a wide glyph's true 2-cell footprint. Never written for a
    /// display-width-1 codepoint, so an all-ASCII lattice is bit-identical
    /// to the pre-continuation pipeline.
    /// guarded-by: labels_eaw_test.zig "wide node label writes char + continuation and paints two columns"
    label_cont,
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

/// What a side-table record is about. One variant per WRITER: a variant
/// is added in the same change as the pass that writes it, so the channel
/// never carries a tag nothing produces.
pub const AuxKind = enum(u8) {
    /// A port attachment: the edge named by `value` attached to the
    /// node-border cell named by `cell` (see `raster/edges_write.zig`'s
    /// `drawPortStroke`). The border cell records the node, the border
    /// role and the merged arm — never WHICH edge merged it, which is why
    /// this record is legal under the anti-desync law. `detail` is
    /// `portArmDetail(arm)` — WHICH arm the port stroke merged. The bit
    /// itself is in the mask, but ownership of the bit is not: a border
    /// cell can carry arms from several writers, and the audit must not
    /// let one recorded stroke excuse a different, unexplained arm.
    /// guarded-by: rings_test.zig "fusion: a port record excuses only the arm it merged"
    port,
    /// A carrier: the edge named by `value` has ink at `cell` that the
    /// Cell does not name. A Cell holds exactly ONE edge id, so every
    /// further edge reaching that position is anonymous the moment it
    /// arrives — either its bits merged in under the first writer's id, or
    /// the crossing rule suppressed them outright. `detail` is a
    /// `CarrierKind`. Filed by the edge writers in
    /// `raster/edges_write.zig` and, in `raster/edges.zig`, by the walk's
    /// corner merge onto a foreign run and by the crossing refusals.
    carrier,
    /// Label ownership: the label span occupying `cell` belongs to the
    /// entity named by `value`, of the kind in `detail` (`LabelOwnerKind`).
    /// A `label_char` Cell holds the codepoint and nothing else — which
    /// node, cluster or edge put it there is exactly the fact it cannot
    /// express. Filed by `raster/labels_write.zig` at each glyph head.
    label_owner,
    /// Fan-rail membership: the fan member edge named by `value` has ink at
    /// `cell` that the Cell attributes to someone else, with the member's
    /// fan polarity in `detail` (a `RailPolarity`). A shared fan run is one
    /// stroke several edges ride; the Cell holds ONE edge id and ONE role,
    /// so it can name at most one rider. Filed by `raster/busbars.zig` for
    /// a first-class rail — where the members have no `EdgePath` at all, so
    /// these records are their only trace on the grid — and by the fan
    /// polyline walk in `raster/edges.zig` for peer-drawn fans, where the
    /// position also carries a merged `.carrier`: that one says an identity
    /// was lost here, this one says which fan family lost it.
    rail_member,
    /// A branch point: the edge named by `value` leaves (fan-OUT) or joins
    /// (fan-IN) a shared fan run at `cell`, polarity in `detail`. Not the
    /// same fact as `.rail_member`, which says a member's ink passes
    /// THROUGH: the mask at a branch cell grows a dropper arm, but no Cell
    /// field says whose it is, nor which of the riders turns off here.
    /// Filed by `raster/busbars.zig` only — see its header for the peer-fan
    /// gap.
    tap,
    /// A frame intrusion: the edge named by `value` met a subgraph frame
    /// border at `cell` and the frame-solid ruling resolved it as `detail`
    /// (an `IntrusionKind`) — the edge bridged the border, or its corner
    /// arm was refused. Either way the cell stays a pristine
    /// `cluster_border`, so that an edge touched it at all is unrecoverable
    /// from the grid. Filed by the walk in `raster/edges.zig`; the report's
    /// `b_frame_bridge` / `b_border_fusion_refused` tallies count the same
    /// events in aggregate.
    /// guarded-by: tiling_records_test.zig "the frame-bridge tallies and the per-cell intrusion records count the same events"
    intrusion,
};

/// Encoding of a `.port` record's `detail`: WHICH border arm the port
/// stroke merged. Offset by 1 so 0 never names a direction — a record
/// built without a direction (a hand-rolled test fixture, a stale table)
/// matches no arm instead of silently matching north.
pub fn portArmDetail(arm: Dir4) u8 {
    return 1 + @as(u8, @intFromEnum(arm));
}

/// How an edge's ink came to be anonymous at a carrier cell. Not a Cell
/// fact either way: the Cell shows the surviving id, never the manner in
/// which the other one was lost.
pub const CarrierKind = enum(u8) {
    /// The carrier's bits are IN the cell's mask; only its identity was
    /// dropped, because the position already had an owner.
    merged = 0,
    /// The carrier contributed no bits at all — the crossing rule kept the
    /// first writer untouched (a transversal, a refused foreign junction,
    /// or a pristine arrowhead). The ink is on the grid, the cell is not.
    suppressed = 1,
};

/// Which kind of entity a `label_owner` record names.
pub const LabelOwnerKind = enum(u8) {
    node = 0,
    cluster = 1,
    edge = 2,
};

/// Which side of a fan a `rail_member` / `tap` record belongs to. One
/// position can sit on a fan-OUT run and a fan-IN run at once, and a Cell's
/// single `EdgeRole` can only name one of the two families.
pub const RailPolarity = enum(u8) {
    /// A fan-OUT member: one pivot, many targets; the member's ink runs
    /// from the shared stroke outwards to its own node.
    out = 0,
    /// A fan-IN member: many sources, one pivot; the member's ink joins the
    /// shared stroke and runs inwards.
    in = 1,
};

/// How an edge and a subgraph frame border resolved at an `.intrusion`.
pub const IntrusionKind = enum(u8) {
    /// A through-going segment bridged the border: the frame glyph stays
    /// continuous and the edge contributed no bits, resuming beyond it.
    bridge = 0,
    /// A corner arm onto the border was refused: fusing it would have
    /// welded a tee into the frame.
    fusion_refused = 1,
};

/// One position-keyed side-table record: 12 bytes, no pointers, freely
/// copyable. `cell` is the row-major linear index (`y * width + x`) of the
/// position the fact belongs to, so a record stays valid however the Cell
/// at that position is later rewritten.
///
/// A position may carry any number of records, including of the same kind
/// (that plurality is the whole point — a Cell cannot hold a set).
pub const Aux = struct {
    /// Row-major linear cell index: `y * width + x`.
    cell: u32,
    /// Kind-specific primary value: an edge id for every kind except
    /// `.label_owner`, whose value is the owning entity's id.
    value: u32,
    kind: AuxKind,
    /// Kind-specific secondary byte; 0 when the kind has no second
    /// dimension. Never a duplicate of a Cell field.
    detail: u8 = 0,

    /// Total order used to sort a finished table: (cell, kind, value).
    /// `detail` is deliberately not a key — the sort is stable, so records
    /// that tie on the key keep producer order.
    pub fn lessThan(_: void, a: Aux, b: Aux) bool {
        if (a.cell != b.cell) return a.cell < b.cell;
        const ak = @intFromEnum(a.kind);
        const bk = @intFromEnum(b.kind);
        if (ak != bk) return ak < bk;
        return a.value < b.value;
    }
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
    /// Position-keyed side table, sorted by (cell, kind, value). Empty
    /// unless the rasterizer was asked to collect it (`raster.Options`),
    /// so a consumer must treat "no records" as "not collected", never as
    /// "nothing happened". Same lifetime rule as `cells`.
    aux: []const Aux = &.{},

    /// Row-major linear index of (x, y) — the key `Aux.cell` uses.
    pub fn cellIndex(self: Lattice, x: u32, y: u32) u32 {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return y * self.width + x;
    }

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

test "Cell stays 16 bytes: the arrowhead style rides in existing padding" {
    // The grid is one Cell per terminal column, so Cell's footprint is the
    // pipeline's dominant allocation. Before the arrowhead payload carried
    // a style it was already 16 bytes: a 12-byte tagged Occupant plus
    // stroke_kind + shape + neighbours, with one byte of tail padding and
    // two spare bytes inside the 8-byte union payload. `arrow` lands in
    // that slack, so the widening is free. A future payload that pushes
    // this past 16 is a deliberate decision, not an accident — this pin
    // makes it visible in review.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Occupant));
}

test "Aux is 12 bytes and its order is (cell, kind, value)" {
    // The side table is event-proportional, not grid-proportional, but it
    // is still a hot array: keep the record pointer-free and small enough
    // that three of them fit where two Cells do. A future field that pushes
    // this past 12 is a deliberate decision, not an accident.
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Aux));

    const a: Aux = .{ .cell = 3, .value = 9, .kind = .port };
    const same_cell_smaller_value: Aux = .{ .cell = 3, .value = 4, .kind = .port };
    const later_cell: Aux = .{ .cell = 4, .value = 0, .kind = .port };

    try std.testing.expect(Aux.lessThan({}, same_cell_smaller_value, a));
    try std.testing.expect(!Aux.lessThan({}, a, same_cell_smaller_value));
    try std.testing.expect(Aux.lessThan({}, a, later_cell));
    // Irreflexive: a strict weak order, as std.mem.sort requires.
    try std.testing.expect(!Aux.lessThan({}, a, a));
}

test "cellIndex agrees with at()'s row-major linearization" {
    var buf: [12]Cell = undefined;
    for (&buf) |*c| c.* = Cell.empty;
    var lat = Lattice{ .width = 4, .height = 3, .cells = &buf };

    try std.testing.expectEqual(@as(u32, 0), lat.cellIndex(0, 0));
    try std.testing.expectEqual(@as(u32, 6), lat.cellIndex(2, 1));
    try std.testing.expectEqual(@as(u32, 11), lat.cellIndex(3, 2));

    // The index is a key INTO cells: at(x,y) must be that element.
    try std.testing.expectEqual(&buf[lat.cellIndex(2, 1)], lat.at(2, 1));
}

test "a fresh Lattice carries no aux records" {
    // "Empty" means "not collected" — consumers must not read absence as
    // evidence that no producer fired.
    var buf: [1]Cell = .{Cell.empty};
    const lat = Lattice{ .width = 1, .height = 1, .cells = &buf };
    try std.testing.expectEqual(@as(usize, 0), lat.aux.len);
}

test "Cell.empty default matches struct literal" {
    const a = Cell.empty;
    try std.testing.expectEqual(@as(u4, 0), a.neighbours.toMask());
    switch (a.occupant) {
        .empty => {},
        else => return error.NotEmpty,
    }
}

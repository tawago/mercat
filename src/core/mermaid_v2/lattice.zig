//! @guarded-by: raster/aux_test.zig "aux records survive the post-walk mutating passes"

const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");

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

pub const Dir4 = prim.Dir4;

pub const Neighbours = packed struct(u4) {
    n: bool = false,
    e: bool = false,
    s: bool = false,
    w: bool = false,

    pub fn toMask(self: Neighbours) u4 {
        return @bitCast(self);
    }

    pub fn fromMask(m: u4) Neighbours {
        return @bitCast(m);
    }
};

pub const NodeId = prim.NodeId;
pub const EdgeId = prim.EdgeId;
pub const ClusterId = prim.ClusterId;

pub const EdgeKind = prim.EdgeKind;

pub const EdgeRole = prim.EdgeRole;

pub const Shape = prim.Shape;

pub const ArrowKind = prim.ArrowKind;

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
        /// @guarded-by: lattice.zig "Cell stays 16 bytes: the arrowhead style rides in existing padding"
        arrow: ArrowKind = .filled,
    },
    /// @guarded-by: labels_eaw_test.zig "a decomposed accent occupies one cell per grapheme and interns base plus mark"
    label_char: u21,
    /// @guarded-by: labels_eaw_test.zig "wide node label writes char + continuation and paints two columns"
    label_cont,
};

pub const InkState = enum(u8) {
    none = 0,
    node,
    stroke,
    rail_interior,
    junction,
    crossing,
};

pub const Cell = struct {
    occupant: Occupant,
    neighbours: Neighbours,
    stroke_kind: EdgeKind = .solid,
    shape: Shape = .rect,
    state: InkState = .none,

    pub const empty: Cell = .{
        .occupant = .empty,
        .neighbours = .{},
        .stroke_kind = .solid,
        .shape = .rect,
        .state = .none,
    };

    pub fn upgradeState(self: *Cell, s: InkState) void {
        if (self.state == .junction) return;
        if (self.state == .crossing and s != .junction) return;
        self.state = s;
    }
};

pub const AuxKind = enum(u8) {
    port,
    carrier,
    label_owner,
    rail_member,
    tap,
    intrusion,
};

pub fn portArmDetail(arm: Dir4) u8 {
    return 1 + @as(u8, @intFromEnum(arm));
}

/// @guarded-by: junction_licence_test.zig "junction licence: a three-way port share the pairwise flood missed is licensed on the raster; the render ships one lateral arm, a bridge-routed head stamped over a departure bend"
pub const CarrierKind = enum(u8) {
    merged_untested = 0,
    suppressed = 1,
    merged_foreign = 2,
    merged_licensed = 3,
};

pub const LabelOwnerKind = enum(u8) {
    node = 0,
    cluster = 1,
    edge = 2,
};

pub const RailPolarity = enum(u8) {
    out = 0,
    in = 1,
};

pub const IntrusionKind = enum(u8) {
    bridge = 0,
    fusion_refused = 1,
};

pub const Aux = struct {
    cell: u32,
    value: u32,
    kind: AuxKind,
    detail: u8 = 0,

    pub fn lessThan(_: void, a: Aux, b: Aux) bool {
        if (a.cell != b.cell) return a.cell < b.cell;
        const ak = @intFromEnum(a.kind);
        const bk = @intFromEnum(b.kind);
        if (ak != bk) return ak < bk;
        return a.value < b.value;
    }
};

pub const AuxCollectionState = enum {
    not_collected,
    complete,
    out_of_memory,
};

pub const AuxCollectionReport = struct {
    state: AuxCollectionState = .not_collected,
    attempted_records: u64 = 0,
};

pub const Glyph = struct {
    bytes: []const u8,
    width: u8,
};

pub const GLYPH_REF_BASE: u21 = 0x110000;

pub const MAX_GLYPHS: usize = @as(usize, std.math.maxInt(u21)) - GLYPH_REF_BASE + 1;

pub fn isGlyphRef(cp: u21) bool {
    return cp >= GLYPH_REF_BASE;
}

pub fn glyphRef(index: usize) u21 {
    std.debug.assert(index < MAX_GLYPHS);
    return @intCast(GLYPH_REF_BASE + index);
}

pub const Lattice = struct {
    width: u32,
    height: u32,
    cells: []Cell,
    glyphs: []const Glyph = &.{},
    rail_claims: []const ledger.RailClaim = &.{},
    aux: []const Aux = &.{},
    aux_collection: AuxCollectionReport = .{},

    pub fn cellIndex(self: Lattice, x: u32, y: u32) u32 {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return y * self.width + x;
    }

    pub fn at(self: Lattice, x: u32, y: u32) *Cell {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return &self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn atConst(self: Lattice, x: u32, y: u32) *const Cell {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        return &self.cells[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn glyphOf(self: Lattice, cp: u21) ?Glyph {
        if (!isGlyphRef(cp)) return null;
        const index: usize = cp - GLYPH_REF_BASE;
        if (index >= self.glyphs.len) return null;
        return self.glyphs[index];
    }
};

test "Neighbours bitmask round-trip across all 16 values" {
    var m: u5 = 0;
    while (m < 16) : (m += 1) {
        const mask: u4 = @intCast(m);
        const n = Neighbours.fromMask(mask);
        try std.testing.expectEqual(mask, n.toMask());

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

    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            lat.at(x, y).*.occupant = .{ .label_char = @intCast(y * lat.width + x) };
        }
    }

    for (buf, 0..) |c, i| {
        switch (c.occupant) {
            .label_char => |ch| try std.testing.expectEqual(@as(u21, @intCast(i)), ch),
            else => return error.UnexpectedOccupant,
        }
    }

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
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(Occupant));
}

test "glyph references live above the scalar range and resolve through the table" {
    try std.testing.expect(!isGlyphRef('A'));
    try std.testing.expect(!isGlyphRef(0x10FFFF));
    try std.testing.expect(isGlyphRef(glyphRef(0)));
    try std.testing.expect(isGlyphRef(glyphRef(MAX_GLYPHS - 1)));
    try std.testing.expectEqual(@as(u21, 0x110000), glyphRef(0));
    try std.testing.expectEqual(@as(u21, std.math.maxInt(u21)), glyphRef(MAX_GLYPHS - 1));

    var cells: [1]Cell = .{Cell.empty};
    const table = [_]Glyph{ .{ .bytes = "e\u{0301}", .width = 1 }, .{ .bytes = "\u{1F468}\u{200D}\u{1F469}", .width = 2 } };
    const lat = Lattice{ .width = 1, .height = 1, .cells = &cells, .glyphs = &table };
    try std.testing.expectEqualStrings("e\u{0301}", lat.glyphOf(glyphRef(0)).?.bytes);
    try std.testing.expectEqual(@as(u8, 2), lat.glyphOf(glyphRef(1)).?.width);
    try std.testing.expectEqual(@as(?Glyph, null), lat.glyphOf('e'));
    try std.testing.expectEqual(@as(?Glyph, null), lat.glyphOf(glyphRef(2)));
}

test "cellIndex agrees with at()'s row-major linearization" {
    var buf: [12]Cell = undefined;
    for (&buf) |*c| c.* = Cell.empty;
    var lat = Lattice{ .width = 4, .height = 3, .cells = &buf };

    try std.testing.expectEqual(@as(u32, 0), lat.cellIndex(0, 0));
    try std.testing.expectEqual(@as(u32, 6), lat.cellIndex(2, 1));
    try std.testing.expectEqual(@as(u32, 11), lat.cellIndex(3, 2));
    try std.testing.expectEqual(&buf[lat.cellIndex(2, 1)], lat.at(2, 1));
}

test "upgradeState: junction is never demoted; crossing yields only to junction" {
    var c = Cell.empty;
    c.upgradeState(.stroke);
    try std.testing.expectEqual(InkState.stroke, c.state);
    c.upgradeState(.crossing);
    try std.testing.expectEqual(InkState.crossing, c.state);
    c.upgradeState(.rail_interior);
    try std.testing.expectEqual(InkState.crossing, c.state);
    c.upgradeState(.junction);
    try std.testing.expectEqual(InkState.junction, c.state);
    c.upgradeState(.crossing);
    try std.testing.expectEqual(InkState.junction, c.state);
}

test "Cell.empty default matches struct literal" {
    const a = Cell.empty;
    try std.testing.expectEqual(@as(u4, 0), a.neighbours.toMask());
    switch (a.occupant) {
        .empty => {},
        else => return error.NotEmpty,
    }
}

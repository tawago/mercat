//! Arrowhead-base painted validator (owner ruling, tawago 2026-07-18):
//!
//!   "make sure that the arrowhead is receiving the tip of the edge line on
//!    the triangle surface (eg: ▲ needs to receive a tip of the edge line │
//!    or ┘ from the bottom, ▶ needs to receive the tip from left ─ or └)".
//!
//! I.e. the cell on an arrowhead's BASE side (opposite the tip direction) must
//! carry that connecting stroke with an arm pointing INTO the arrowhead. A base
//! cell that is blank, or a stroke whose neighbour mask lacks the into-arrow
//! arm, is a violation.
//!
//! This is a PAINTED post-raster scan over the final `Lattice`: it reads the
//! neighbour bits already committed by the edge/rail/reconcile stages, so it
//! automatically excludes dotted-stroke feeds (they carry the correct axis bits
//! even though their glyph is `┊`/`╎`) — that removes the python corpus scan's
//! "class 4" artifact without any glyph table.
//!
//! EXEMPTION (structural, never seed-keyed): a base cell whose occupant is a
//! `.label_char` is an on-run label or a cluster-title glyph (frame-solid
//! interruption). The owner's convention leaves those interruptions in place,
//! so a label base is NOT a violation ("class 3").
//!
//! The count flows raster → entry → the MERCAT_INTEGRITY stderr line, and via
//! `audit.zig` into `score.RasterCounts`' violation tier of candidate
//! selection; it never mutates a cell. Allowed imports: `std`, `lattice.zig` (raster zone).

const std = @import("std");
const lattice = @import("../lattice.zig");

/// Report-only decoration-cell tallies surfaced through the raster report.
/// A decoration cell has three guarded sides (constitution, ink
/// attribution): its base, its tip and its two laterals. One field per side
/// class, each read off the painted lattice.
pub const ArrowBaseCounts = struct {
    /// Arrowheads whose base-side cell does not carry an arm pointing into
    /// the triangle (blank base, or a stroke missing the into-arrow bit).
    /// Label/title bases are exempt and never counted.
    violations: u32 = 0,
    /// Arrowheads whose TIP neighbour is not the port of the end they
    /// decorate: the cell one step along the tip is not a node-border cell
    /// (blank, another edge's ink, a node interior, or off the lattice).
    /// The head is drawn sideways or into space — the reader loses the
    /// orientation the graph states. Attributed to the head's own edge.
    tip_not_port: u32 = 0,
    /// Lateral arms that SHIPPED on arrowhead cells: every mask bit off the
    /// head's axis, one per arm. The painted half of `arm_into_head` (the
    /// refused half is `crossings.CrossingCounts.arm_into_head`); today's
    /// only producer is an edge turning inside its own terminal cell.
    lateral_arms: u32 = 0,
};

/// The neighbour bit a base cell must carry to feed an arrowhead pointing in
/// direction `tip`: the arm on the base points TOWARD the arrowhead, i.e. in
/// the tip direction itself (a `▼` (tip=south) base needs a south arm `.s`).
fn intoArrowBit(tip: lattice.Dir4) lattice.Neighbours {
    return switch (tip) {
        .north => .{ .n = true },
        .east => .{ .e = true },
        .south => .{ .s = true },
        .west => .{ .w = true },
    };
}

/// The base cell sits one step opposite the tip direction from the arrowhead.
/// Returns `null` when that cell would fall outside the lattice.
fn baseCoord(x: u32, y: u32, tip: lattice.Dir4, w: u32, h: u32) ?struct { x: u32, y: u32 } {
    return switch (tip) {
        .south => if (y >= 1) .{ .x = x, .y = y - 1 } else null,
        .north => if (y + 1 < h) .{ .x = x, .y = y + 1 } else null,
        .east => if (x >= 1) .{ .x = x - 1, .y = y } else null,
        .west => if (x + 1 < w) .{ .x = x + 1, .y = y } else null,
    };
}

/// The tip cell sits one step along the tip direction from the arrowhead.
/// Returns `null` when that cell would fall outside the lattice.
fn tipCoord(x: u32, y: u32, tip: lattice.Dir4, w: u32, h: u32) ?struct { x: u32, y: u32 } {
    return switch (tip) {
        .north => if (y >= 1) .{ .x = x, .y = y - 1 } else null,
        .south => if (y + 1 < h) .{ .x = x, .y = y + 1 } else null,
        .west => if (x >= 1) .{ .x = x - 1, .y = y } else null,
        .east => if (x + 1 < w) .{ .x = x + 1, .y = y } else null,
    };
}

/// The mask bits of an arrowhead cell that lie off its tip axis.
fn lateralBits(tip: lattice.Dir4, mask: lattice.Neighbours) u4 {
    const axis: lattice.Neighbours = switch (tip) {
        .north, .south => .{ .n = true, .s = true },
        .east, .west => .{ .e = true, .w = true },
    };
    return mask.toMask() & ~axis.toMask();
}

/// True when a base `cell` (in an already-painted lattice) legitimately feeds
/// an arrowhead whose tip points `tip`. A `.label_char` base is exempt (class
/// 3): the label/title interruption is a convention, not a break in the run.
pub fn baseFeedsArrow(cell: *const lattice.Cell, tip: lattice.Dir4) bool {
    switch (cell.occupant) {
        .label_char, .label_cont => return true,
        else => {
            const need = intoArrowBit(tip).toMask();
            return (cell.neighbours.toMask() & need) == need;
        },
    }
}

/// Scan the final lattice and tally, for every arrowhead: a base-side cell
/// that does not feed the triangle (owner ruling), a tip neighbour that is
/// not the port it decorates, and each lateral arm the cell ships. Pure
/// read; never mutates.
/// @guarded-by: arrow_base.zig "a tip into blank, into a run, or off the lattice is tip_not_port; a tip into the port is not"
/// @guarded-by: arrow_base.zig "a lateral arm on a head is counted per arm; an on-axis head counts none"
pub fn validate(lat: *const lattice.Lattice) ArrowBaseCounts {
    var counts: ArrowBaseCounts = .{};
    if (lat.width == 0 or lat.height == 0) return counts;

    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.atConst(x, y);
            const tip = switch (cell.occupant) {
                .arrowhead => |a| a.dir,
                else => continue,
            };
            counts.lateral_arms += @popCount(lateralBits(tip, cell.neighbours));
            if (tipCoord(x, y, tip, lat.width, lat.height)) |tc| {
                if (lat.atConst(tc.x, tc.y).occupant != .node_border) counts.tip_not_port += 1;
            } else counts.tip_not_port += 1;
            const bc = baseCoord(x, y, tip, lat.width, lat.height) orelse {
                counts.violations += 1;
                continue;
            };
            if (!baseFeedsArrow(lat.atConst(bc.x, bc.y), tip)) counts.violations += 1;
        }
    }
    return counts;
}

const testing = std.testing;

fn arrowCell(dir: lattice.Dir4) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = dir, .edge = 0 } }, .neighbours = .{} };
}
fn edgeCell(nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid } }, .neighbours = nb };
}

test "clean vertical feed: ▼ under a │ is legal" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCell(.{ .n = true, .s = true });
    lat.at(0, 1).* = arrowCell(.south);
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);
}

test "side-fed ▼ under a plain ─ is a violation (class 1)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCell(.{ .e = true, .w = true });
    lat.at(0, 1).* = arrowCell(.south);
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
}

test "corner feed: ┴ (no south arm) under a ▼ is a violation (class 1b)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCell(.{ .n = true, .e = true, .w = true });
    lat.at(0, 1).* = arrowCell(.south);
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
    lat.at(0, 0).*.neighbours.s = true;
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);
}

test "space-fed ▶ (blank base) is a violation (class 2)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &buf };
    lat.at(0, 0).* = lattice.Cell.empty;
    lat.at(1, 0).* = arrowCell(.east);
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
}

test "label base is exempt (class 3), even without an arm" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    lat.at(0, 1).* = arrowCell(.south);
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);
}

test "dotted stroke base is legal: bits carry, glyph does not matter (class 4)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = .{ .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .dotted } }, .neighbours = .{ .n = true, .s = true } };
    lat.at(0, 1).* = arrowCell(.south);
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);
}

test "▲/◀ orientations resolve the correct base cell" {
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };
    lat.at(1, 1).* = arrowCell(.north);
    lat.at(1, 2).* = edgeCell(.{ .n = true, .s = true });
    lat.at(0, 0).* = arrowCell(.west);
    lat.at(1, 0).* = edgeCell(.{ .e = true, .w = true });
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);
}

fn arrowCellE(dir: lattice.Dir4, edge: lattice.EdgeId, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge } }, .neighbours = nb };
}
fn edgeCellE(edge: lattice.EdgeId, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid } }, .neighbours = nb };
}

test "an unfed own-edge corner base is a counted defect, never welded (subtractive repair only)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCellE(7, .{ .n = true, .e = true });
    lat.at(0, 1).* = arrowCellE(.south, 7, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
    try testing.expect(!lat.atConst(0, 0).neighbours.s);
}

test "a foreign edge crossing the base stays a counted residual (no fabricated junction)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCellE(1, .{ .e = true, .w = true });
    lat.at(0, 1).* = arrowCellE(.south, 7, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
}

test "a blank base behind a real run is a counted gap, never bridged (subtractive repair only)" {
    var buf: [4]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 4, .cells = &buf };
    lat.at(0, 0).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
    lat.at(0, 2).* = arrowCellE(.south, 7, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
    try testing.expect(lat.atConst(0, 1).occupant == .empty);
}

fn portCell(node: lattice.NodeId) lattice.Cell {
    return .{ .occupant = .{ .node_border = .{ .node = node, .role = .edge_n } }, .neighbours = .{} };
}

test "a tip into blank, into a run, or off the lattice is tip_not_port; a tip into the port is not" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCellE(7, .{ .n = true, .s = true });
    lat.at(0, 1).* = arrowCellE(.south, 7, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 1), validate(&lat).tip_not_port);

    lat.at(0, 2).* = portCell(3);
    try testing.expectEqual(@as(u32, 0), validate(&lat).tip_not_port);
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);

    lat.at(0, 2).* = edgeCellE(9, .{ .e = true, .w = true });
    try testing.expectEqual(@as(u32, 1), validate(&lat).tip_not_port);

    lat.at(0, 2).* = lattice.Cell.empty;
    lat.at(0, 1).* = edgeCellE(7, .{ .n = true, .s = true });
    lat.at(0, 2).* = arrowCellE(.south, 7, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 1), validate(&lat).tip_not_port);
}

test "a lateral arm on a head is counted per arm; an on-axis head counts none" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &buf };
    lat.at(0, 0).* = edgeCellE(7, .{ .e = true, .w = true });
    lat.at(1, 0).* = arrowCellE(.east, 7, .{ .e = true, .w = true });
    lat.at(2, 0).* = portCell(3);
    try testing.expectEqual(@as(u32, 0), validate(&lat).lateral_arms);

    lat.at(1, 0).*.neighbours.n = true;
    try testing.expectEqual(@as(u32, 1), validate(&lat).lateral_arms);
    lat.at(1, 0).*.neighbours.s = true;
    try testing.expectEqual(@as(u32, 2), validate(&lat).lateral_arms);
    try testing.expectEqual(@as(u32, 0), validate(&lat).tip_not_port);
}

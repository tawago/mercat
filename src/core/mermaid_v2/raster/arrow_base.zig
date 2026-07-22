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
//! neighbour bits already committed by the edge/busbar/reconcile stages, so it
//! automatically excludes dotted-stroke feeds (they carry the correct axis bits
//! even though their glyph is `┊`/`╎`) — that removes the python corpus scan's
//! "class 4" artifact without any glyph table.
//!
//! EXEMPTION (structural, never seed-keyed): a base cell whose occupant is a
//! `.label_char` is an on-run label or a cluster-title glyph (frame-solid
//! interruption). The owner's convention leaves those interruptions in place,
//! so a label base is NOT a violation ("class 3").
//!
//! Report-only: the count flows raster → entry → the MERCAT_INTEGRITY stderr line,
//! never into `score.RasterCounts`, `audit.zig`, or candidate selection, and it
//! never mutates a cell. Allowed imports: `std`, `lattice.zig` (raster zone).

const std = @import("std");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");

/// Report-only arrowhead-base tally surfaced through the raster report.
pub const ArrowBaseCounts = struct {
    /// Arrowheads whose base-side cell does not carry an arm pointing into
    /// the triangle (blank base, or a stroke missing the into-arrow bit).
    /// Label/title bases are exempt and never counted.
    violations: u32 = 0,
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
        // tip=south → base is north (y-1); tip=north → base is south (y+1); etc.
        .south => if (y >= 1) .{ .x = x, .y = y - 1 } else null,
        .north => if (y + 1 < h) .{ .x = x, .y = y + 1 } else null,
        .east => if (x >= 1) .{ .x = x - 1, .y = y } else null,
        .west => if (x + 1 < w) .{ .x = x + 1, .y = y } else null,
    };
}

/// True when a base `cell` (in an already-painted lattice) legitimately feeds
/// an arrowhead whose tip points `tip`. A `.label_char` base is exempt (class
/// 3): the label/title interruption is a convention, not a break in the run.
fn baseFeedsArrow(cell: *const lattice.Cell, tip: lattice.Dir4) bool {
    switch (cell.occupant) {
        // Structural exemption (class 3): the base is a node/cluster label or
        // title glyph. The owner's frame-solid convention leaves such a run
        // interrupted by the label in place — INCLUDING the inter-word spaces
        // of a multi-word title, which are still that title's cells (welding a
        // stroke there would split the title, e.g. `Inventory│Management`). A
        // label base is therefore never a violation and never welded.
        .label_char => return true,
        // The base must carry the into-arrow arm. Any occupant whose glyph is
        // driven by the neighbour mask (edge segment, cluster/node border) is
        // judged purely on that mask, matching what the painter draws.
        else => {
            const need = intoArrowBit(tip).toMask();
            return (cell.neighbours.toMask() & need) == need;
        },
    }
}

/// True when a real stroke/structure a bridge bit may legitimately connect to
/// occupies `occ` (mirrors `reconcile.isRealConnection`; `.empty` is nothing).
fn isRealConnection(occ: lattice.Occupant) bool {
    return occ != .empty;
}

/// True when the arrowhead at `(x,y)` (tip `tip`) is fed by an EDGE stroke
/// coming in PERPENDICULAR to the tip axis — i.e. the edge turned the corner
/// AT the arrowhead (`─▼`, `───▲`). Those are routing/orientation artifacts,
/// not a missing base stub: the ink genuinely arrives from the side, so a base
/// weld would fabricate a connection the edge never made. A perpendicular
/// FRAME/BORDER cell coincident with the arrowhead is NOT a side-feed (the
/// frame just passes through), so this checks the neighbour's OCCUPANT, not the
/// arrowhead's own inherited mask.
fn sideFed(lat: *const lattice.Lattice, x: u32, y: u32, tip: lattice.Dir4) bool {
    const w = lat.width;
    const h = lat.height;
    // Perpendicular directions and the arm each neighbour needs to point back.
    const Probe = struct { nx: ?u32, ny: ?u32, need: lattice.Neighbours };
    var probes: [2]Probe = undefined;
    switch (tip) {
        .north, .south => {
            probes[0] = .{ .nx = if (x >= 1) x - 1 else null, .ny = y, .need = .{ .e = true } }; // west nbr → its east arm
            probes[1] = .{ .nx = if (x + 1 < w) x + 1 else null, .ny = y, .need = .{ .w = true } }; // east nbr → its west arm
        },
        .east, .west => {
            probes[0] = .{ .nx = x, .ny = if (y >= 1) y - 1 else null, .need = .{ .s = true } }; // north nbr → its south arm
            probes[1] = .{ .nx = x, .ny = if (y + 1 < h) y + 1 else null, .need = .{ .n = true } }; // south nbr → its north arm
        },
    }
    for (probes) |p| {
        const nx = p.nx orelse continue;
        const ny = p.ny orelse continue;
        const c = lat.atConst(nx, ny);
        const is_edgey = switch (c.occupant) {
            .edge_segment, .arrowhead => true,
            else => false,
        };
        if (is_edgey and (c.neighbours.toMask() & p.need.toMask()) != 0) return true;
    }
    return false;
}

/// Weld the connecting stroke onto arrowhead base cells so the tip is received
/// on its base side (owner ruling 2026-07-18). Runs on the FINAL lattice, after
/// reconcile and labels. Returns the number of base cells welded.
///
/// Only TRUTHFUL, non-foreign welds are applied — the rule is a truth rule, so
/// fabricating foreign junction ink or a dangling stub is forbidden:
///   * own-ink base (`edge_segment` of the SAME edge, incl. a fan trunk that
///     forgot its tap's drop arm, or a node border the edge emerges from):
///     OR the into-arrow arm in (`└`→`├`, `┴`→`┼`, node `─`→`┬`).
///   * a genuine 1-cell resume gap (blank / space-padding base) whose cell one
///     step further back is a real connection: bridge a straight stroke through.
/// Cases left UNTOUCHED (reported as residual, class 1a / routing):
///   * a FOREIGN edge crossing the base cell (a weld would fabricate a junction);
///   * a side-fed arrowhead (the edge turned the corner at the tip);
///   * a blank base with nothing behind it (a weld would dangle).
pub fn weld(lat: *lattice.Lattice) u32 {
    if (lat.width == 0 or lat.height == 0) return 0;
    var welded: u32 = 0;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const acell = lat.at(x, y);
            const info = switch (acell.occupant) {
                .arrowhead => |a| a,
                else => continue,
            };
            const tip = info.dir;
            const bc = baseCoord(x, y, tip, lat.width, lat.height) orelse continue;
            const bcell = lat.at(bc.x, bc.y);
            if (baseFeedsArrow(bcell, tip)) continue; // already fed / exempt label
            if (sideFed(lat, x, y, tip)) continue; // routing artifact, not a stub gap
            const need = intoArrowBit(tip);
            switch (bcell.occupant) {
                .edge_segment => |seg| {
                    // Only the arrowhead's OWN edge may gain the arm; a foreign
                    // crossing here must stay a transversal (no fabricated tee).
                    if (seg.edge != info.edge) continue;
                    bcell.neighbours = ew.orMask(bcell.neighbours, need);
                    welded += 1;
                },
                .node_border => {
                    // The edge emerges from / lands on this frame; the border
                    // gains the drop/enter arm (painter picks `┬`/`┤`…).
                    bcell.neighbours = ew.orMask(bcell.neighbours, need);
                    welded += 1;
                },
                .empty => {
                    // A blank base: bridge a straight stroke only when the cell
                    // one step further back is real ink — so the weld extends an
                    // existing run, never dangles. (Label bases are exempt above:
                    // a title's cells, incl. its spaces, are never overwritten.)
                    const behind = baseCoord(bc.x, bc.y, tip, lat.width, lat.height) orelse continue;
                    if (!isRealConnection(lat.atConst(behind.x, behind.y).occupant)) continue;
                    bcell.occupant = .{ .edge_segment = .{ .edge = info.edge, .kind = .solid, .role = .forward } };
                    // The base sits opposite the tip; bridge a straight stroke
                    // `behind → base → arrow` along that axis.
                    bcell.neighbours = ew.orMask(need, intoArrowBit(ew.reverse(tip)));
                    bcell.stroke_kind = .solid;
                    welded += 1;
                },
                else => {}, // cluster_border (frame-solid), node_interior: leave.
            }
        }
    }
    return welded;
}

/// Scan the final lattice and tally every arrowhead whose base-side cell does
/// not feed the triangle (owner ruling). Pure read; never mutates.
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
            const bc = baseCoord(x, y, tip, lat.width, lat.height) orelse {
                counts.violations += 1;
                continue;
            };
            if (!baseFeedsArrow(lat.atConst(bc.x, bc.y), tip)) counts.violations += 1;
        }
    }
    return counts;
}

// -- Tests -------------------------------------------------------------------

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
    lat.at(0, 0).* = edgeCell(.{ .n = true, .s = true }); // │ base
    lat.at(0, 1).* = arrowCell(.south);
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);
}

test "side-fed ▼ under a plain ─ is a violation (class 1)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCell(.{ .e = true, .w = true }); // ─ base: no south arm
    lat.at(0, 1).* = arrowCell(.south);
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
}

test "corner feed: ┴ (no south arm) under a ▼ is a violation (class 1b)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCell(.{ .n = true, .e = true, .w = true }); // ┴: N+E+W, no S
    lat.at(0, 1).* = arrowCell(.south);
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
    // Adding the south arm (┼) clears it.
    lat.at(0, 0).*.neighbours.s = true;
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);
}

test "space-fed ▶ (blank base) is a violation (class 2)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 1, .cells = &buf };
    lat.at(0, 0).* = lattice.Cell.empty; // blank base
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
    // ▲ (tip=north) base is SOUTH; ◀ (tip=west) base is EAST.
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };
    // ▲ at (1,1), base south (1,2) is a clean │.
    lat.at(1, 1).* = arrowCell(.north);
    lat.at(1, 2).* = edgeCell(.{ .n = true, .s = true });
    // ◀ at (0,0), base east (1,0) is a clean ─.
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

test "weld: own-edge corner base gains the drop arm (└→├), clearing the violation" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCellE(7, .{ .n = true, .e = true }); // └ own trunk (edge 7)
    lat.at(0, 1).* = arrowCellE(.south, 7, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations);
    try testing.expectEqual(@as(u32, 1), weld(&lat));
    try testing.expect(lat.atConst(0, 0).neighbours.s); // south arm added
    try testing.expectEqual(@as(u32, 0), validate(&lat).violations);
}

test "weld: a FOREIGN edge crossing the base is NEVER welded (no fabricated junction)" {
    var buf: [3]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 3, .cells = &buf };
    lat.at(0, 0).* = edgeCellE(1, .{ .e = true, .w = true }); // foreign ─ (edge 1)
    lat.at(0, 1).* = arrowCellE(.south, 7, .{ .n = true, .s = true }); // arrow is edge 7
    try testing.expectEqual(@as(u32, 0), weld(&lat)); // refused
    try testing.expectEqual(@as(u32, 1), validate(&lat).violations); // stays a residual
}

test "weld: blank base bridges a straight stroke only when the cell behind is real" {
    // Real behind (node_border) → bridge.
    var buf: [4]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 1, .height = 4, .cells = &buf };
    lat.at(0, 0).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
    // (0,1) blank base, (0,2) arrow south, behind of base is (0,0) node_border.
    lat.at(0, 2).* = arrowCellE(.south, 7, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 1), weld(&lat));
    try testing.expectEqual(@as(u4, 0b0101), lat.atConst(0, 1).neighbours.toMask()); // │ (n+s)

    // Dangling (nothing behind) → refused.
    for (&buf) |*c| c.* = lattice.Cell.empty;
    lat.at(0, 2).* = arrowCellE(.south, 7, .{ .n = true, .s = true });
    try testing.expectEqual(@as(u32, 0), weld(&lat));
}

test "weld: a side-fed arrowhead (edge turned the corner at the tip) is left alone" {
    // ▼ at (1,1) fed from the WEST by an edge_segment ─ (a routing corner, not
    // a base gap): the perpendicular west neighbour carries an east arm.
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };
    lat.at(1, 1).* = arrowCellE(.south, 7, .{ .n = true, .s = true, .w = true });
    lat.at(0, 1).* = edgeCellE(7, .{ .e = true, .w = true }); // west feed
    // base (1,0) blank, behind (1,... OOB up) — but side-fed guard fires first.
    try testing.expectEqual(@as(u32, 0), weld(&lat));
}

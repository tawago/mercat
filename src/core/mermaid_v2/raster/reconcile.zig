//! Neighbour-reconciliation post-pass for the lattice, run after
//! `rasterizeEdges` (fan roles and the fan-OUT strip included). Clears
//! junction-bearing cells'
//! neighbour bits pointing at an out-of-bounds or `.empty` adjacent
//! cell (a "phantom arm"); bits pointing at a real occupant are kept.
//! Only `.edge_segment`/`.cluster_border` are touched; `.arrowhead`/
//! `.node_border` glyphs are left alone. Order-independent: each bit's
//! decision depends only on the neighbour's occupant, never mutated
//! here. This module only ever CLEARS a bit: nothing in it may add one.
//! An arm the edge writer declined to paint stays unpainted — restoring it
//! from geometry alone would assert an adjacency the writer refused on
//! edge identity, a question no pass here is in a position to re-ask.
//! Imports: `std`, `lattice.zig`, and the raster-zone sibling
//! `edges_write.zig` (shared Dir4 mask helpers; any bare-name raster
//! sibling is legal, see `tools/lint_imports.zig`).

const std = @import("std");
const lattice = @import("../lattice.zig");
const ew = @import("edges_write.zig");

/// True if `occ` represents a real stroke/structure a neighbour bit may
/// legitimately point at. Only `.empty` is treated as "no connection".
/// `.cluster_border` counts as real WITHOUT requiring reciprocity, so a
/// frame-bridge approach arm survives reconciliation (frame-solid
/// convention). // @guarded-by: reconcile_test.zig "reconcileNeighbours: frame-bridge approach arm facing a non-reciprocating cluster_border is kept"
pub fn isRealConnection(occ: lattice.Occupant) bool {
    return switch (occ) {
        .empty => false,
        .node_interior,
        .node_border,
        .cluster_border,
        .edge_segment,
        .arrowhead,
        .label_char,
        .label_cont,
        => true,
    };
}

/// True if the cell's occupant is one whose junction glyph is picked
/// from the neighbour mask, i.e. a cell this pass may modify.
fn isJunctionBearing(occ: lattice.Occupant) bool {
    return switch (occ) {
        .edge_segment, .cluster_border => true,
        else => false,
    };
}

/// True if `nb`'s bit in direction `d` is set. Thin wrapper over the shared
/// raster Dir4 mask helper (`edges_write.bitMask`) so no Dir4 switch is
/// duplicated here.
fn bitSet(nb: lattice.Neighbours, d: lattice.Dir4) bool {
    return nb.toMask() & ew.bitMask(d).toMask() != 0;
}

/// True if the 1-cell-port reprieve target `cell` genuinely continues the
/// run arriving from direction `d` (the junction bit points toward `cell`).
/// A reprieve is only justified when the target reciprocates — it carries
/// the neighbour bit pointing BACK toward the junction (`reverse(d)`) — or
/// is an `.arrowhead` (a genuine terminal always faces its run). A cell
/// that merely happens to sit collinear (an incidental perpendicular border
/// running alongside the rail) does NOT reciprocate, so its reprieve is
/// denied and the phantom arm is cleared.
/// // @guarded-by: reconcile_test.zig "reconcileNeighbours: 1-cell port gap before a reciprocating node border keeps the bit (duplicate-point reprieve)"
fn reprieveReciprocates(cell: *const lattice.Cell, d: lattice.Dir4) bool {
    return switch (cell.occupant) {
        .empty => false,
        .arrowhead => true,
        else => bitSet(cell.neighbours, ew.reverse(d)),
    };
}

/// True if the neighbour bit in direction `d` from `(x,y)` is a phantom
/// arm — i.e. no stroke actually continues there. Grants a 1-cell
/// port-padding reprieve when the adjacent cell is empty but the cell
/// beyond it (same axis) genuinely continues the run (reciprocates or is a
/// terminal arrowhead). // @guarded-by: reconcile_test.zig "reconcileNeighbours: 1-cell port gap before a reciprocating node border keeps the bit (duplicate-point reprieve)"
pub fn bitIsPhantom(lat: *const lattice.Lattice, x: u32, y: u32, d: lattice.Dir4) bool {
    const Pair = struct { ax: ?u32, ay: ?u32, bx: ?u32, by: ?u32 };
    const p: Pair = switch (d) {
        .north => .{
            .ax = x,
            .ay = if (y >= 1) y - 1 else null,
            .bx = x,
            .by = if (y >= 2) y - 2 else null,
        },
        .east => .{
            .ax = if (x + 1 < lat.width) x + 1 else null,
            .ay = y,
            .bx = if (x + 2 < lat.width) x + 2 else null,
            .by = y,
        },
        .south => .{
            .ax = x,
            .ay = if (y + 1 < lat.height) y + 1 else null,
            .bx = x,
            .by = if (y + 2 < lat.height) y + 2 else null,
        },
        .west => .{
            .ax = if (x >= 1) x - 1 else null,
            .ay = y,
            .bx = if (x >= 2) x - 2 else null,
            .by = y,
        },
    };

    const ax = p.ax orelse return true;
    const ay = p.ay orelse return true;

    if (isRealConnection(lat.atConst(ax, ay).occupant)) return false;

    const bx = p.bx orelse return true;
    const by = p.by orelse return true;
    if (reprieveReciprocates(lat.atConst(bx, by), d)) return false;

    return true;
}

/// Final reconciliation pass: clear neighbour bits that point into empty
/// background (a "phantom arm") on junction-bearing cells. Returns the
/// number of bits cleared, for reporting only — a cleared arm is a
/// *repaired* upstream mask, not a shipped defect.
pub fn reconcileNeighbours(lat: *lattice.Lattice) u32 {
    if (lat.width == 0 or lat.height == 0) return 0;

    var cleared: u32 = 0;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.at(x, y);
            if (!isJunctionBearing(cell.occupant)) continue;

            var nb = cell.neighbours;
            if (nb.n and bitIsPhantom(lat, x, y, .north)) {
                nb.n = false;
                cleared += 1;
            }
            if (nb.e and bitIsPhantom(lat, x, y, .east)) {
                nb.e = false;
                cleared += 1;
            }
            if (nb.s and bitIsPhantom(lat, x, y, .south)) {
                nb.s = false;
                cleared += 1;
            }
            if (nb.w and bitIsPhantom(lat, x, y, .west)) {
                nb.w = false;
                cleared += 1;
            }
            cell.neighbours = nb;
        }
    }
    return cleared;
}

const testing = std.testing;

fn edgeCell(nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid } },
        .neighbours = nb,
    };
}

test "┼ with an empty east neighbour reconciles to ┤" {
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };

    lat.at(1, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    lat.at(1, 0).* = edgeCell(.{ .s = true });
    lat.at(1, 2).* = edgeCell(.{ .n = true });
    lat.at(0, 1).* = edgeCell(.{ .e = true });

    _ = reconcileNeighbours(&lat);

    const got = lat.atConst(1, 1).neighbours;
    try testing.expectEqual(@as(u4, 0b1101), got.toMask());
    try testing.expect(!got.e);
}

test "┼ with all four neighbours occupied stays ┼" {
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };

    lat.at(1, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    lat.at(1, 0).* = edgeCell(.{ .s = true });
    lat.at(1, 2).* = edgeCell(.{ .n = true });
    lat.at(0, 1).* = edgeCell(.{ .e = true });
    lat.at(2, 1).* = edgeCell(.{ .w = true });

    _ = reconcileNeighbours(&lat);

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 1).neighbours.toMask());
}

test "node_border and arrowhead neighbours keep the bit" {
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };

    lat.at(1, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    lat.at(1, 0).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
    lat.at(2, 1).* = .{ .occupant = .{ .arrowhead = .{ .dir = .west, .edge = 0 } }, .neighbours = .{} };
    lat.at(0, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_e } }, .neighbours = .{} };
    _ = reconcileNeighbours(&lat);

    const got = lat.atConst(1, 1).neighbours;
    try testing.expect(got.n);
    try testing.expect(got.e);
    try testing.expect(!got.s);
    try testing.expect(got.w);
}

test "non-junction occupants are left untouched" {
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };

    lat.at(1, 1).* = .{
        .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 0 } },
        .neighbours = .{ .n = true, .e = true, .s = true, .w = true },
    };

    _ = reconcileNeighbours(&lat);

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 1).neighbours.toMask());
}

test "trailing ┬ on a rail past the last child loses into-empty arms" {
    var buf: [12]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 4, .height = 3, .cells = &buf };

    lat.at(2, 1).* = edgeCell(.{ .e = true, .w = true });
    lat.at(3, 1).* = edgeCell(.{ .e = true, .s = true, .w = true });

    _ = reconcileNeighbours(&lat);

    const got = lat.atConst(3, 1).neighbours;
    try testing.expectEqual(@as(u4, 0b1000), got.toMask());
}

test "reconcile is NOT order-independent w.r.t. labels: swapping the pipeline position changes the result" {
    var buf_before: [9]lattice.Cell = undefined;
    for (&buf_before) |*c| c.* = lattice.Cell.empty;
    var lat_before = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf_before };
    lat_before.at(1, 1).* = edgeCell(.{ .s = true });
    _ = reconcileNeighbours(&lat_before);
    lat_before.at(1, 2).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    try testing.expect(!lat_before.atConst(1, 1).neighbours.s);

    var buf_after: [9]lattice.Cell = undefined;
    for (&buf_after) |*c| c.* = lattice.Cell.empty;
    var lat_after = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf_after };
    lat_after.at(1, 1).* = edgeCell(.{ .s = true });
    lat_after.at(1, 2).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    _ = reconcileNeighbours(&lat_after);
    try testing.expect(lat_after.atConst(1, 1).neighbours.s);
}

test {
    _ = @import("reconcile_test.zig");
}

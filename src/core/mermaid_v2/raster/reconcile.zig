//! Neighbour-reconciliation post-pass for the lattice, run after
//! `rasterizeEdges`/`stampFanTrunks`. Clears junction-bearing cells'
//! neighbour bits pointing at an out-of-bounds or `.empty` adjacent
//! cell (a "phantom arm"); bits pointing at a real occupant are kept.
//! Only `.edge_segment`/`.cluster_border` are touched; `.arrowhead`/
//! `.node_border` glyphs are left alone. Order-independent: each bit's
//! decision depends only on the neighbour's occupant, never mutated
//! here. Imports: `std`, `lattice.zig`, and the raster-zone siblings
//! `crossings.zig`/`edges_write.zig` (shared Dir4 + straight-run helpers;
//! any bare-name raster sibling is legal, see `tools/lint_imports.zig`).

const std = @import("std");
const lattice = @import("../lattice.zig");
const crossings = @import("crossings.zig");
const ew = @import("edges_write.zig");

/// True if `occ` represents a real stroke/structure a neighbour bit may
/// legitimately point at. Only `.empty` is treated as "no connection".
/// `.cluster_border` counts as real WITHOUT requiring reciprocity, so a
/// frame-bridge approach arm survives reconciliation (frame-solid
/// convention). // guarded-by: reconcile_test.zig "reconcileNeighbours: frame-bridge approach arm facing a non-reciprocating cluster_border is kept"
fn isRealConnection(occ: lattice.Occupant) bool {
    return switch (occ) {
        .empty => false,
        .node_interior,
        .node_border,
        .cluster_border,
        .edge_segment,
        .arrowhead,
        .label_char,
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
/// running alongside the trunk) does NOT reciprocate, so its reprieve is
/// denied and the phantom arm is cleared.
/// // guarded-by: reconcile_test.zig "reconcileNeighbours: 1-cell port gap before a reciprocating node border keeps the bit (duplicate-point reprieve)"
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
/// terminal arrowhead). // guarded-by: reconcile_test.zig "reconcileNeighbours: 1-cell port gap before a reciprocating node border keeps the bit (duplicate-point reprieve)"
fn bitIsPhantom(lat: *const lattice.Lattice, x: u32, y: u32, d: lattice.Dir4) bool {
    // Adjacent cell coordinates (ax,ay) and the cell one step beyond
    // (bx,by) along the same axis. `null` means out of bounds.
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

    // Adjacent cell is empty. Reprieve only if this is a 1-cell port
    // gap: the cell one step beyond (collinear) genuinely continues the
    // run — it reciprocates the arm (or is a terminal arrowhead).
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

/// Set the neighbour bit in direction `d`. Thin wrapper over the shared
/// raster Dir4 mask helpers so no Dir4 switch is duplicated here.
fn addBit(nb: *lattice.Neighbours, d: lattice.Dir4) void {
    nb.* = ew.orMask(nb.*, ew.bitMask(d));
}

/// Index into `lat.cells` of the cell one step in direction `d` from
/// `(x,y)`, or `null` when that step leaves the grid.
fn neighbourIndex(lat: *const lattice.Lattice, x: u32, y: u32, d: lattice.Dir4) ?usize {
    const nx: ?u32 = switch (d) {
        .east => if (x + 1 < lat.width) x + 1 else null,
        .west => if (x >= 1) x - 1 else null,
        .north, .south => x,
    };
    const ny: ?u32 = switch (d) {
        .south => if (y + 1 < lat.height) y + 1 else null,
        .north => if (y >= 1) y - 1 else null,
        .east, .west => y,
    };
    const rx = nx orelse return null;
    const ry = ny orelse return null;
    return @as(usize, ry) * @as(usize, lat.width) + rx;
}

/// Reciprocity-REPAIR post-pass: the additive dual of `reconcileNeighbours`'s
/// phantom-arm CLEAR. Heals a half-open junction where a neighbouring edge
/// stroke asserts a collinear connection that the junction cell fails to
/// reciprocate — e.g. a stacked split-junction where a second out-branch's
/// polyline begins at the shared stem cell, leaving the corner above it with
/// no arm back down into the branch below. Purely additive: it only SETS a
/// missing bit toward a genuinely-asserting `.edge_segment` neighbour. It
/// never clears; never touches a `.cluster_border` frame or any non-edge
/// occupant (Slice-1 frame safety); never upgrades a clean straight run (the
/// C1 transversal guard — a legal crossing's crossed cell is preserved); and
/// never resurrects a lone stub (the bend-junction popcount guard). Returns
/// the number of bits added, for reporting only.
///
/// Order-independent without a snapshot: repairs only ADD a bit toward a
/// neighbour that already asserts the reverse arm, and such a neighbour is
/// never itself an add candidate (its own bit-set check short-circuits first).
/// // guarded-by: reconcile_test.zig "repairReciprocalArms: stacked adds are order-independent"
pub fn repairReciprocalArms(lat: *lattice.Lattice) u32 {
    if (lat.width == 0 or lat.height == 0) return 0;

    var repaired: u32 = 0;
    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.at(x, y);
            // Only heal an edge-segment junction — never grow an arm into a
            // frame (Slice-1 safety) or any other occupant kind.
            if (cell.occupant != .edge_segment) continue;

            const here = cell.neighbours;
            // Must be an existing bend junction: at least two arms and not a
            // clean straight run (C1 guard) — a lone stub or a legal
            // transversal cell is left untouched.
            if (@popCount(here.toMask()) < 2) continue;
            if (crossings.isStraightPair(here)) continue;

            const dirs = [_]lattice.Dir4{ .north, .east, .south, .west };
            for (dirs) |d| {
                if (bitSet(here, d)) continue; // arm already present
                const m = neighbourIndex(lat, x, y, d) orelse continue;
                if (lat.cells[m].occupant != .edge_segment) continue;
                // The neighbour must ASSERT the reciprocal arm back at us.
                if (!bitSet(lat.cells[m].neighbours, ew.reverse(d))) continue;
                addBit(&cell.neighbours, d);
                repaired += 1;
            }
        }
    }
    return repaired;
}

const testing = std.testing;

fn edgeCell(nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid } },
        .neighbours = nb,
    };
}

test "┼ with an empty east neighbour reconciles to ┤" {
    // 3x3 grid. Center (1,1) is a 4-way edge junction. Its N, S, W
    // neighbours are real strokes; its E neighbour is empty background.
    var buf: [9]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };

    lat.at(1, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    lat.at(1, 0).* = edgeCell(.{ .s = true });
    lat.at(1, 2).* = edgeCell(.{ .n = true });
    lat.at(0, 1).* = edgeCell(.{ .e = true });

    _ = reconcileNeighbours(&lat);

    const got = lat.atConst(1, 1).neighbours;
    // Expect N+S+W = ┤ (mask 0b1101).
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

    // Center edge cell with N (node_border), E (arrowhead), S (empty),
    // W (cluster_border) bits set.
    lat.at(1, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    lat.at(1, 0).* = .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_s } }, .neighbours = .{} };
    lat.at(2, 1).* = .{ .occupant = .{ .arrowhead = .{ .dir = .west, .edge = 0 } }, .neighbours = .{} };
    lat.at(0, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_e } }, .neighbours = .{} };
    _ = reconcileNeighbours(&lat);

    const got = lat.atConst(1, 1).neighbours;
    try testing.expect(got.n); // node_border kept
    try testing.expect(got.e); // arrowhead kept
    try testing.expect(!got.s); // empty cleared
    try testing.expect(got.w); // cluster_border kept
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
    // Horizontal rail running along row 1; cell (3,1) is the last rail
    // cell stamped as ┬ (E+S+W) but nothing lies east or south of it.
    var buf: [12]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 4, .height = 3, .cells = &buf };

    lat.at(2, 1).* = edgeCell(.{ .e = true, .w = true });
    lat.at(3, 1).* = edgeCell(.{ .e = true, .s = true, .w = true });

    _ = reconcileNeighbours(&lat);

    const got = lat.atConst(3, 1).neighbours;
    // Only W survives -> ╴ stub (mask 0b1000).
    try testing.expectEqual(@as(u4, 0b1000), got.toMask());
}

test "reconcile is NOT order-independent w.r.t. labels: swapping the pipeline position changes the result" {
    // The module doc's "order-independent" claim only means this pass
    // never MUTATES an occupant, just reads it — but its *decision*
    // (phantom or not) depends on what already exists at the neighbour
    // cell, so WHEN it runs relative to `rasterizeLabels` (which can turn
    // a previously-`.empty` cell into a `.label_char` cell, e.g. an edge
    // label's fallback landing beside the line) changes the outcome.
    // This pins the required order: reconcile before labels.

    // Real pipeline order: reconcile runs first, while (1,2) is still
    // empty, so the south bit is judged a phantom arm and cleared; the
    // label write that follows doesn't get consulted retroactively.
    var buf_before: [9]lattice.Cell = undefined;
    for (&buf_before) |*c| c.* = lattice.Cell.empty;
    var lat_before = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf_before };
    lat_before.at(1, 1).* = edgeCell(.{ .s = true });
    _ = reconcileNeighbours(&lat_before);
    lat_before.at(1, 2).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    try testing.expect(!lat_before.atConst(1, 1).neighbours.s);

    // Hypothetical reordering: labels write BEFORE reconcile runs. Now
    // the same south bit survives, because the neighbour already looks
    // like a "real connection" (a label_char, not a stroke).
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

//! Tests for `reconcile.zig`'s `bitIsPhantom` port-gap reprieve. Split out
//! of the former misc grab-bag test file (since dissolved) into
//! reconcile.zig's own sibling, per the mermaid_v2/ test-file convention.
//! Discovered via reconcile.zig's top-level
//! `test { _ = @import("reconcile_test.zig"); }` block. (reconcile.zig's
//! own junction/order tests stay inline in reconcile.zig itself.)

const std = @import("std");
const lattice = @import("../lattice.zig");
const reconcile = @import("reconcile.zig");

const testing = std.testing;

fn edgeCell(nb: lattice.Neighbours) lattice.Cell {
    return .{
        .occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid } },
        .neighbours = nb,
    };
}

/// Fill `buf` with empty cells and wrap it in a `w`×`h` lattice.
fn emptyLattice(buf: []lattice.Cell, w: u32, h: u32) lattice.Lattice {
    for (buf) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = buf };
}

// ---------------------------------------------------------------------
// reconcile.zig: bitIsPhantom's 1-cell port-padding reprieve (near line 37)
// ---------------------------------------------------------------------
// A routed edge that touches its endpoint node across a blank buffer cell
// leaves a duplicate-point-style gap: the immediately adjacent cell is
// `.empty`, but the cell one step further along the SAME axis is the real
// node border THAT RECIPROCATES (its `.n` bit points back at the junction,
// as a genuine perpendicular arrival merges). `bitIsPhantom` must grant a
// reprieve here (keep the bit) rather than clearing it as a phantom arm.
test "reconcileNeighbours: 1-cell port gap before a reciprocating node border keeps the bit (duplicate-point reprieve)" {
    var buf: [12]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 4);

    // (1,1) is an edge cell whose south bit points at (1,2), left `.empty`
    // (the port gap); (1,3) is a node_border two cells south whose north
    // bit reciprocates the arm.
    lat.at(1, 1).* = edgeCell(.{ .s = true });
    lat.at(1, 3).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_n } }, .neighbours = .{ .n = true } };

    _ = reconcile.reconcileNeighbours(&lat);

    try testing.expect(lat.atConst(1, 1).neighbours.s);
}

test "reconcileNeighbours: 1-cell port gap before an arrowhead keeps the bit (terminal reprieve)" {
    var buf: [12]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 4);

    // Same port gap, but the cell 2-out is a terminal arrowhead (always
    // faces its run — reprieve granted regardless of its neighbour bits).
    lat.at(1, 1).* = edgeCell(.{ .s = true });
    lat.at(1, 3).* = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0 } }, .neighbours = .{} };

    _ = reconcile.reconcileNeighbours(&lat);

    try testing.expect(lat.atConst(1, 1).neighbours.s);
}

// ---------------------------------------------------------------------
// Slice 2(2a): reprieve requires reciprocity — a non-reciprocating cell
// collinear with the arm (an incidental perpendicular border running
// alongside the rail) does NOT justify the 1-cell reprieve.
// ---------------------------------------------------------------------
// Fan-in rail shape (adv_b01): a 4-way junction whose S bit faces a blank
// gutter, with an incidental horizontal node_border two cells south. The
// border's run is {e,w} (it does NOT reciprocate with a .n), so the S arm
// must be cleared: ┼ → ┴.
test "reconcileNeighbours: reprieve denied for a perpendicular horizontal node_border (fan-in rail ┼→┴)" {
    var buf: [12]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 4);

    lat.at(1, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    // Real reciprocating strokes on N/E/W so only the S arm is at issue.
    lat.at(1, 0).* = edgeCell(.{ .s = true });
    lat.at(2, 1).* = edgeCell(.{ .w = true });
    lat.at(0, 1).* = edgeCell(.{ .e = true });
    // (1,2) empty; (1,3) is a horizontal border run {e,w} — no reciprocal .n.
    lat.at(1, 3).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_n } }, .neighbours = .{ .e = true, .w = true } };

    _ = reconcile.reconcileNeighbours(&lat);

    const got = lat.atConst(1, 1).neighbours;
    try testing.expect(!got.s); // phantom S cleared
    try testing.expectEqual(@as(u4, 0b1011), got.toMask()); // ┴ = N+E+W
}

// Fan rail beside an outer frame wall (docling): a 4-way junction whose W
// bit faces a blank gutter, with the outer frame wall two cells west. The
// wall's run is {n,s} (no reciprocal .e), so the W arm must be cleared:
// ┼ → ├.
test "reconcileNeighbours: reprieve denied for a perpendicular vertical cluster_border wall (fan rail ┼→├)" {
    var buf: [15]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 5, 3);

    lat.at(3, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    // Real reciprocating strokes on N/E/S so only the W arm is at issue.
    lat.at(3, 0).* = edgeCell(.{ .s = true });
    lat.at(4, 1).* = edgeCell(.{ .w = true });
    lat.at(3, 2).* = edgeCell(.{ .n = true });
    // (2,1) empty; (1,1) is a vertical frame wall {n,s} — no reciprocal .e.
    lat.at(1, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_w } }, .neighbours = .{ .n = true, .s = true } };

    _ = reconcile.reconcileNeighbours(&lat);

    const got = lat.atConst(3, 1).neighbours;
    try testing.expect(!got.w); // phantom W cleared
    try testing.expectEqual(@as(u4, 0b0111), got.toMask()); // ├ = N+E+S
}

// ---------------------------------------------------------------------
// Slice 1(d) pin: frame-bridge approach arm survives reconciliation
// ---------------------------------------------------------------------
// The frame-solid convention bridges an edge across a subgraph frame: the
// border cell holds ONLY the frame glyph (a horizontal `─` run here, bits
// {e,w}) and does NOT reciprocate the crossing edge with a perpendicular
// bit. The through-edge's approach arm therefore faces a `.cluster_border`
// cell that points the other way. Because `isRealConnection` treats
// `.cluster_border` as a real connection, `reconcileNeighbours` must KEEP
// that arm — the arms print on both sides of the continuous frame. This
// pin exists so Slice 2's reciprocity-based phantom-arm tightening cannot
// silently clip the bridge back to a gap.
test "reconcileNeighbours: frame-bridge approach arm facing a non-reciprocating cluster_border is kept" {
    var buf: [9]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 3);

    // Row 1 is a horizontal frame border (`─` run, bits {e,w} only — no
    // vertical bit welding the crossing edge into the frame).
    lat.at(0, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } }, .neighbours = .{ .e = true } };
    lat.at(1, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } }, .neighbours = .{ .e = true, .w = true } };
    lat.at(2, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } }, .neighbours = .{ .w = true } };

    // Edge approaching from the north at (1,0): its south arm faces the
    // frame cell (1,1), which does NOT carry a reciprocating north bit.
    lat.at(1, 0).* = edgeCell(.{ .s = true });

    _ = reconcile.reconcileNeighbours(&lat);

    // The approach arm must survive: `.cluster_border` is a real
    // connection, reciprocity notwithstanding.
    try testing.expect(lat.atConst(1, 0).neighbours.s);
    // And the frame line is untouched by this pass (still `─`, {e,w}).
    try testing.expect(lat.atConst(1, 1).neighbours.e and lat.atConst(1, 1).neighbours.w);
    try testing.expect(!lat.atConst(1, 1).neighbours.n and !lat.atConst(1, 1).neighbours.s);
}

test "reconcileNeighbours: a genuinely empty cell 2 steps out still clears (no reprieve)" {
    // Contrast case: same shape, but (1,3) is ALSO empty (no real
    // connection beyond the gap) — this is a genuine phantom arm and must
    // be cleared, distinguishing the reprieve from an unconditional grant.
    var buf: [12]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 4);

    lat.at(1, 1).* = edgeCell(.{ .s = true });
    // (1,2) and (1,3) both stay `.empty`.

    _ = reconcile.reconcileNeighbours(&lat);

    try testing.expect(!lat.atConst(1, 1).neighbours.s);
}

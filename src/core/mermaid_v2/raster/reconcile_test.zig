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

test "reconcileNeighbours: 1-cell port gap before a reciprocating node border keeps the bit (duplicate-point reprieve)" {
    var buf: [12]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 4);

    lat.at(1, 1).* = edgeCell(.{ .s = true });
    lat.at(1, 3).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_n } }, .neighbours = .{ .n = true } };

    _ = reconcile.reconcileNeighbours(&lat);

    try testing.expect(lat.atConst(1, 1).neighbours.s);
}

test "reconcileNeighbours: 1-cell port gap before an arrowhead keeps the bit (terminal reprieve)" {
    var buf: [12]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 4);

    lat.at(1, 1).* = edgeCell(.{ .s = true });
    lat.at(1, 3).* = .{ .occupant = .{ .arrowhead = .{ .dir = .south, .edge = 0 } }, .neighbours = .{} };

    _ = reconcile.reconcileNeighbours(&lat);

    try testing.expect(lat.atConst(1, 1).neighbours.s);
}

test "reconcileNeighbours: reprieve denied for a perpendicular horizontal node_border (fan-in rail ┼→┴)" {
    var buf: [12]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 4);

    lat.at(1, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    lat.at(1, 0).* = edgeCell(.{ .s = true });
    lat.at(2, 1).* = edgeCell(.{ .w = true });
    lat.at(0, 1).* = edgeCell(.{ .e = true });
    lat.at(1, 3).* = .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_n } }, .neighbours = .{ .e = true, .w = true } };

    _ = reconcile.reconcileNeighbours(&lat);

    const got = lat.atConst(1, 1).neighbours;
    try testing.expect(!got.s);
    try testing.expectEqual(@as(u4, 0b1011), got.toMask());
}

test "reconcileNeighbours: reprieve denied for a perpendicular vertical cluster_border wall (fan rail ┼→├)" {
    var buf: [15]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 5, 3);

    lat.at(3, 1).* = edgeCell(.{ .n = true, .e = true, .s = true, .w = true });
    lat.at(3, 0).* = edgeCell(.{ .s = true });
    lat.at(4, 1).* = edgeCell(.{ .w = true });
    lat.at(3, 2).* = edgeCell(.{ .n = true });
    lat.at(1, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_w } }, .neighbours = .{ .n = true, .s = true } };

    _ = reconcile.reconcileNeighbours(&lat);

    const got = lat.atConst(3, 1).neighbours;
    try testing.expect(!got.w);
    try testing.expectEqual(@as(u4, 0b0111), got.toMask());
}

test "reconcileNeighbours: frame-bridge approach arm facing a non-reciprocating cluster_border is kept" {
    var buf: [9]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 3);

    lat.at(0, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } }, .neighbours = .{ .e = true } };
    lat.at(1, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } }, .neighbours = .{ .e = true, .w = true } };
    lat.at(2, 1).* = .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_s } }, .neighbours = .{ .w = true } };

    lat.at(1, 0).* = edgeCell(.{ .s = true });

    _ = reconcile.reconcileNeighbours(&lat);

    try testing.expect(lat.atConst(1, 0).neighbours.s);
    try testing.expect(lat.atConst(1, 1).neighbours.e and lat.atConst(1, 1).neighbours.w);
    try testing.expect(!lat.atConst(1, 1).neighbours.n and !lat.atConst(1, 1).neighbours.s);
}

test "reconcileNeighbours: a genuinely empty cell 2 steps out still clears (no reprieve)" {
    var buf: [12]lattice.Cell = undefined;
    var lat = emptyLattice(&buf, 3, 4);

    lat.at(1, 1).* = edgeCell(.{ .s = true });

    _ = reconcile.reconcileNeighbours(&lat);

    try testing.expect(!lat.atConst(1, 1).neighbours.s);
}

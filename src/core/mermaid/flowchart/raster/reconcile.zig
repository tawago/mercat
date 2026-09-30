const std = @import("std");
const lattice = @import("../lattice.zig");
const geo = @import("geometry.zig");

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

fn isJunctionBearing(occ: lattice.Occupant) bool {
    return switch (occ) {
        .edge_segment, .cluster_border => true,
        else => false,
    };
}

fn bitSet(nb: lattice.Neighbours, d: lattice.Dir4) bool {
    return nb.toMask() & geo.bitMask(d).toMask() != 0;
}

fn reprieveReciprocates(cell: *const lattice.Cell, d: lattice.Dir4) bool {
    return switch (cell.occupant) {
        .empty => false,
        .arrowhead => true,
        else => bitSet(cell.neighbours, geo.reverse(d)),
    };
}

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

pub fn reconcileNeighbours(lat: *lattice.Lattice) void {
    if (lat.width == 0 or lat.height == 0) return;

    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.at(x, y);
            if (!isJunctionBearing(cell.occupant)) continue;

            var nb = cell.neighbours;
            if (nb.n and bitIsPhantom(lat, x, y, .north)) {
                nb.n = false;
            }
            if (nb.e and bitIsPhantom(lat, x, y, .east)) {
                nb.e = false;
            }
            if (nb.s and bitIsPhantom(lat, x, y, .south)) {
                nb.s = false;
            }
            if (nb.w and bitIsPhantom(lat, x, y, .west)) {
                nb.w = false;
            }
            cell.neighbours = nb;
        }
    }
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

    reconcileNeighbours(&lat);

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

    reconcileNeighbours(&lat);

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
    reconcileNeighbours(&lat);

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

    reconcileNeighbours(&lat);

    try testing.expectEqual(@as(u4, 0b1111), lat.atConst(1, 1).neighbours.toMask());
}

test "trailing ┬ on a rail past the last child loses into-empty arms" {
    var buf: [12]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    var lat = lattice.Lattice{ .width = 4, .height = 3, .cells = &buf };

    lat.at(2, 1).* = edgeCell(.{ .e = true, .w = true });
    lat.at(3, 1).* = edgeCell(.{ .e = true, .s = true, .w = true });

    reconcileNeighbours(&lat);

    const got = lat.atConst(3, 1).neighbours;
    try testing.expectEqual(@as(u4, 0b1000), got.toMask());
}

test "reconcile is NOT order-independent w.r.t. labels: swapping the pipeline position changes the result" {
    var buf_before: [9]lattice.Cell = undefined;
    for (&buf_before) |*c| c.* = lattice.Cell.empty;
    var lat_before = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf_before };
    lat_before.at(1, 1).* = edgeCell(.{ .s = true });
    reconcileNeighbours(&lat_before);
    lat_before.at(1, 2).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    try testing.expect(!lat_before.atConst(1, 1).neighbours.s);

    var buf_after: [9]lattice.Cell = undefined;
    for (&buf_after) |*c| c.* = lattice.Cell.empty;
    var lat_after = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf_after };
    lat_after.at(1, 1).* = edgeCell(.{ .s = true });
    lat_after.at(1, 2).* = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    reconcileNeighbours(&lat_after);
    try testing.expect(lat_after.atConst(1, 1).neighbours.s);
}

test {
    _ = @import("reconcile_test.zig");
}

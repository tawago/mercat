const std = @import("std");
const lattice = @import("../lattice.zig");
const geo = @import("geometry.zig");

fn isRealConnection(occ: lattice.Occupant) bool {
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

fn bitIsPhantom(lat: *const lattice.Lattice, x: u32, y: u32, d: lattice.Dir4) bool {
    const near = geo.step(.{ .x = @intCast(x), .y = @intCast(y) }, d);
    const near_cell = geo.cellAt(lat, near.x, near.y) orelse return true;
    if (isRealConnection(near_cell.occupant)) return false;
    const far = geo.step(near, d);
    const far_cell = geo.cellAt(lat, far.x, far.y) orelse return true;
    return !reprieveReciprocates(far_cell, d);
}

const directions = [_]lattice.Dir4{ .north, .east, .south, .west };

pub fn reconcileNeighbours(lat: *lattice.Lattice) void {
    if (lat.width == 0 or lat.height == 0) return;

    var y: u32 = 0;
    while (y < lat.height) : (y += 1) {
        var x: u32 = 0;
        while (x < lat.width) : (x += 1) {
            const cell = lat.at(x, y);
            if (!isJunctionBearing(cell.occupant)) continue;

            var keep = cell.neighbours.toMask();
            for (directions) |d| {
                const bit = geo.bitMask(d).toMask();
                if (keep & bit != 0 and bitIsPhantom(lat, x, y, d)) keep &= ~bit;
            }
            cell.neighbours = lattice.Neighbours.fromMask(keep);
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

const Put = struct { x: u32, y: u32, cell: lattice.Cell };
const Case = struct { w: u32, h: u32, puts: []const Put, at: [2]u32 = .{ 1, 1 }, want: u4 };

fn runCases(cases: []const Case) !void {
    for (cases) |c| {
        var buf: [20]lattice.Cell = undefined;
        for (&buf) |*cell| cell.* = lattice.Cell.empty;
        var lat = lattice.Lattice{ .width = c.w, .height = c.h, .cells = buf[0 .. c.w * c.h] };
        for (c.puts) |p| lat.at(p.x, p.y).* = p.cell;
        reconcileNeighbours(&lat);
        try testing.expectEqual(c.want, lat.atConst(c.at[0], c.at[1]).neighbours.toMask());
    }
}

const all4: lattice.Neighbours = .{ .n = true, .e = true, .s = true, .w = true };
fn nodeBorder(nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .node_border = .{ .node = 5, .role = .edge_n } }, .neighbours = nb };
}
fn frame(role: lattice.BorderRole, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = role } }, .neighbours = nb };
}
fn head(dir: lattice.Dir4) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = dir, .edge = 0 } }, .neighbours = .{} };
}

test "reconcileNeighbours clears arms into nothing and keeps arms into real connections" {
    try runCases(&.{
        // ┼ with an empty east neighbour reconciles to ┤.
        .{ .w = 3, .h = 3, .puts = &.{ .{ .x = 1, .y = 1, .cell = edgeCell(all4) }, .{ .x = 1, .y = 0, .cell = edgeCell(.{ .s = true }) }, .{ .x = 1, .y = 2, .cell = edgeCell(.{ .n = true }) }, .{ .x = 0, .y = 1, .cell = edgeCell(.{ .e = true }) } }, .want = 0b1101 },
        // ┼ with all four neighbours occupied stays ┼.
        .{ .w = 3, .h = 3, .puts = &.{ .{ .x = 1, .y = 1, .cell = edgeCell(all4) }, .{ .x = 1, .y = 0, .cell = edgeCell(.{ .s = true }) }, .{ .x = 1, .y = 2, .cell = edgeCell(.{ .n = true }) }, .{ .x = 0, .y = 1, .cell = edgeCell(.{ .e = true }) }, .{ .x = 2, .y = 1, .cell = edgeCell(.{ .w = true }) } }, .want = 0b1111 },
        // Node border, arrowhead and cluster border neighbours keep the bit; the empty south clears.
        .{ .w = 3, .h = 3, .puts = &.{ .{ .x = 1, .y = 1, .cell = edgeCell(all4) }, .{ .x = 1, .y = 0, .cell = nodeBorder(.{}) }, .{ .x = 2, .y = 1, .cell = head(.west) }, .{ .x = 0, .y = 1, .cell = frame(.edge_e, .{}) } }, .want = 0b1011 },
        // Non-junction occupants are left untouched.
        .{ .w = 3, .h = 3, .puts = &.{.{ .x = 1, .y = 1, .cell = .{ .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 0 } }, .neighbours = all4 } }}, .want = 0b1111 },
        // A trailing ┬ on a rail past the last child loses its into-empty arms.
        .{ .w = 4, .h = 3, .puts = &.{ .{ .x = 2, .y = 1, .cell = edgeCell(.{ .e = true, .w = true }) }, .{ .x = 3, .y = 1, .cell = edgeCell(.{ .e = true, .s = true, .w = true }) } }, .at = .{ 3, 1 }, .want = 0b1000 },
        // A label neighbour keeps the bit (so reconcile must run before labels are painted).
        .{ .w = 3, .h = 3, .puts = &.{ .{ .x = 1, .y = 1, .cell = edgeCell(.{ .s = true }) }, .{ .x = 1, .y = 2, .cell = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} } } }, .want = 0b0100 },
        // A genuinely empty cell 2 steps out still clears (no reprieve).
        .{ .w = 3, .h = 4, .puts = &.{.{ .x = 1, .y = 1, .cell = edgeCell(.{ .s = true }) }}, .want = 0 },
    });
}

test "reconcileNeighbours reprieves a 1-cell port gap only before a reciprocating border, a head, or a frame bridge" {
    try runCases(&.{
        // Duplicate-point reprieve: a reciprocating node border.
        .{ .w = 3, .h = 4, .puts = &.{ .{ .x = 1, .y = 1, .cell = edgeCell(.{ .s = true }) }, .{ .x = 1, .y = 3, .cell = nodeBorder(.{ .n = true }) } }, .want = 0b0100 },
        // Terminal reprieve: an arrowhead.
        .{ .w = 3, .h = 4, .puts = &.{ .{ .x = 1, .y = 1, .cell = edgeCell(.{ .s = true }) }, .{ .x = 1, .y = 3, .cell = head(.south) } }, .want = 0b0100 },
        // Denied for a perpendicular horizontal node border (fan-in rail ┼→┴).
        .{ .w = 3, .h = 4, .puts = &.{ .{ .x = 1, .y = 1, .cell = edgeCell(all4) }, .{ .x = 1, .y = 0, .cell = edgeCell(.{ .s = true }) }, .{ .x = 2, .y = 1, .cell = edgeCell(.{ .w = true }) }, .{ .x = 0, .y = 1, .cell = edgeCell(.{ .e = true }) }, .{ .x = 1, .y = 3, .cell = nodeBorder(.{ .e = true, .w = true }) } }, .want = 0b1011 },
        // Denied for a perpendicular vertical cluster wall (fan rail ┼→├).
        .{ .w = 5, .h = 3, .puts = &.{ .{ .x = 3, .y = 1, .cell = edgeCell(all4) }, .{ .x = 3, .y = 0, .cell = edgeCell(.{ .s = true }) }, .{ .x = 4, .y = 1, .cell = edgeCell(.{ .w = true }) }, .{ .x = 3, .y = 2, .cell = edgeCell(.{ .n = true }) }, .{ .x = 1, .y = 1, .cell = frame(.edge_w, .{ .n = true, .s = true }) } }, .at = .{ 3, 1 }, .want = 0b0111 },
        // A frame-bridge approach arm facing a non-reciprocating cluster border is kept, and the border stays ─.
        .{ .w = 3, .h = 3, .puts = &frame_bridge, .at = .{ 1, 0 }, .want = 0b0100 },
        .{ .w = 3, .h = 3, .puts = &frame_bridge, .want = 0b1010 },
    });
}

const frame_bridge = [_]Put{
    .{ .x = 0, .y = 1, .cell = frame(.edge_s, .{ .e = true }) },
    .{ .x = 1, .y = 1, .cell = frame(.edge_s, .{ .e = true, .w = true }) },
    .{ .x = 2, .y = 1, .cell = frame(.edge_s, .{ .w = true }) },
    .{ .x = 1, .y = 0, .cell = edgeCell(.{ .s = true }) },
};

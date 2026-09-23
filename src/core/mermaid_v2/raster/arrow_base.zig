const std = @import("std");
const lattice = @import("../lattice.zig");

pub const ArrowBaseCounts = struct {
    violations: u32 = 0,
    tip_not_port: u32 = 0,
    lateral_arms: u32 = 0,
};

fn intoArrowBit(tip: lattice.Dir4) lattice.Neighbours {
    return switch (tip) {
        .north => .{ .n = true },
        .east => .{ .e = true },
        .south => .{ .s = true },
        .west => .{ .w = true },
    };
}

fn baseCoord(x: u32, y: u32, tip: lattice.Dir4, w: u32, h: u32) ?struct { x: u32, y: u32 } {
    return switch (tip) {
        .south => if (y >= 1) .{ .x = x, .y = y - 1 } else null,
        .north => if (y + 1 < h) .{ .x = x, .y = y + 1 } else null,
        .east => if (x >= 1) .{ .x = x - 1, .y = y } else null,
        .west => if (x + 1 < w) .{ .x = x + 1, .y = y } else null,
    };
}

fn tipCoord(x: u32, y: u32, tip: lattice.Dir4, w: u32, h: u32) ?struct { x: u32, y: u32 } {
    return switch (tip) {
        .north => if (y >= 1) .{ .x = x, .y = y - 1 } else null,
        .south => if (y + 1 < h) .{ .x = x, .y = y + 1 } else null,
        .west => if (x >= 1) .{ .x = x - 1, .y = y } else null,
        .east => if (x + 1 < w) .{ .x = x + 1, .y = y } else null,
    };
}

fn lateralBits(tip: lattice.Dir4, mask: lattice.Neighbours) u4 {
    const axis: lattice.Neighbours = switch (tip) {
        .north, .south => .{ .n = true, .s = true },
        .east, .west => .{ .e = true, .w = true },
    };
    return mask.toMask() & ~axis.toMask();
}

pub fn baseFeedsArrow(cell: *const lattice.Cell, tip: lattice.Dir4) bool {
    switch (cell.occupant) {
        .label_char, .label_cont => return true,
        else => {
            const need = intoArrowBit(tip).toMask();
            return (cell.neighbours.toMask() & need) == need;
        },
    }
}

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

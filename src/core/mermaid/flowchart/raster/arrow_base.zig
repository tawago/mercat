const std = @import("std");
const lattice = @import("../lattice.zig");
const geo = @import("geometry.zig");

pub const ArrowBaseCounts = struct {
    violations: u32 = 0,
    lateral_arms: u32 = 0,
};

fn baseCoord(x: u32, y: u32, tip: lattice.Dir4, w: u32, h: u32) ?struct { x: u32, y: u32 } {
    return switch (tip) {
        .south => if (y >= 1) .{ .x = x, .y = y - 1 } else null,
        .north => if (y + 1 < h) .{ .x = x, .y = y + 1 } else null,
        .east => if (x >= 1) .{ .x = x - 1, .y = y } else null,
        .west => if (x + 1 < w) .{ .x = x + 1, .y = y } else null,
    };
}

pub fn baseFeedsArrow(cell: *const lattice.Cell, tip: lattice.Dir4) bool {
    switch (cell.occupant) {
        .label_char, .label_cont => return true,
        else => {
            const need = geo.bitMask(tip).toMask();
            return (cell.neighbours.toMask() & need) == need;
        },
    }
}

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
            counts.lateral_arms += @popCount(geo.lateralArms(tip, cell.neighbours).toMask());
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

fn edgeCellE(edge: lattice.EdgeId, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid } }, .neighbours = nb };
}
fn arrowCellE(dir: lattice.Dir4, edge: lattice.EdgeId, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = dir, .edge = edge } }, .neighbours = nb };
}

test "arrow base classification: clean, side-fed, corner-fed, space-fed, label; every tip direction" {
    const Row = struct { base: lattice.Cell, tip: lattice.Dir4, want: u32 };
    const label: lattice.Cell = .{ .occupant = .{ .label_char = 'x' }, .neighbours = .{} };
    const rows = [_]Row{
        .{ .base = edgeCellE(0, .{ .n = true, .s = true }), .tip = .south, .want = 0 }, // clean │ feed
        .{ .base = edgeCellE(0, .{ .e = true, .w = true }), .tip = .south, .want = 1 }, // class 1: side-fed ─
        .{ .base = edgeCellE(0, .{ .n = true, .e = true, .w = true }), .tip = .south, .want = 1 }, // class 1b: ┴
        .{ .base = edgeCellE(0, .{ .n = true, .e = true, .w = true, .s = true }), .tip = .south, .want = 0 }, // ┼ feeds
        .{ .base = lattice.Cell.empty, .tip = .east, .want = 1 }, // class 2: blank base
        .{ .base = label, .tip = .south, .want = 0 }, // class 3: label base exempt without an arm
        .{ .base = edgeCellE(0, .{ .n = true, .s = true }), .tip = .north, .want = 0 }, // ▲ base is below
        .{ .base = edgeCellE(0, .{ .e = true, .w = true }), .tip = .west, .want = 0 }, // ◀ base is right
    };
    for (rows) |r| {
        var buf: [9]lattice.Cell = undefined;
        for (&buf) |*c| c.* = lattice.Cell.empty;
        var lat = lattice.Lattice{ .width = 3, .height = 3, .cells = &buf };
        lat.at(1, 1).* = arrowCellE(r.tip, 0, .{});
        const bx: u32, const by: u32 = switch (r.tip) {
            .south => .{ 1, 0 },
            .north => .{ 1, 2 },
            .east => .{ 0, 1 },
            .west => .{ 2, 1 },
        };
        lat.at(bx, by).* = r.base;
        try testing.expectEqual(r.want, validate(&lat).violations);
    }
}

fn portCell(node: lattice.NodeId) lattice.Cell {
    return .{ .occupant = .{ .node_border = .{ .node = node, .role = .edge_n } }, .neighbours = .{} };
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
}

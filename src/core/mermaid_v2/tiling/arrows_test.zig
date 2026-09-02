//! Unit tests for `tiling/arrows.zig`. Every bucket of the lateral
//! ladder gets a firing fixture and the ladder as a whole gets a
//! non-firing one, so a bucket can never quietly absorb its neighbour.

const std = @import("std");
const lattice = @import("../lattice.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const arrows = @import("arrows.zig");

const testing = std.testing;

/// 3x3 scratch grid with the arrowhead at the centre.
const Grid = struct {
    buf: [9]lattice.Cell = undefined,

    fn init(self: *Grid) void {
        for (&self.buf) |*c| c.* = lattice.Cell.empty;
    }

    fn lat(self: *Grid) lattice.Lattice {
        return .{ .width = 3, .height = 3, .cells = &self.buf };
    }

    fn set(self: *Grid, x: usize, y: usize, c: lattice.Cell) void {
        self.buf[y * 3 + x] = c;
    }
};

fn arrowCell(dir: lattice.Dir4, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .arrowhead = .{ .dir = dir, .edge = 7 } }, .neighbours = nb };
}

fn edgeCell(nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = 7, .kind = .solid } }, .neighbours = nb };
}

/// Run the lateral check on the single cell at `(x,y)`.
fn check(lat: *const lattice.Lattice, x: u32, y: u32) counts.Counts {
    const v = cell.View.init(lat);
    var c: counts.Counts = .{};
    arrows.checkLateral(v, x, y, v.at(x, y).?, &c);
    return c;
}

test "lateral: a pure along-axis arrowhead mask fires nothing" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .s = true }));
    g.set(1, 0, edgeCell(.{ .n = true, .s = true }));
    const lat = g.lat();
    const c = check(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try testing.expectEqual(@as(u32, 0), c.c_arrow_lat_explained);
    try testing.expectEqual(@as(u32, 0), c.c_arrow_lat_frame);
    try testing.expectEqual(@as(u32, 0), c.c_arrow_lat_opaque);
}

test "lateral: a reciprocating stroke explains the bit" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .w = true }));
    g.set(0, 1, edgeCell(.{ .e = true, .w = true }));
    const lat = g.lat();
    const c = check(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.c_arrow_lat_explained);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "lateral: a silent stroke neighbour leaves the bit an orphan" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .w = true }));
    g.set(0, 1, edgeCell(.{ .n = true, .s = true }));
    const lat = g.lat();
    const c = check(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.d_arrow_lat_orphan);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
}

test "lateral: a foreign crossing that reciprocates on both sides is explained" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .e = true, .w = true }));
    g.set(0, 1, edgeCell(.{ .e = true, .w = true }));
    g.set(2, 1, edgeCell(.{ .e = true, .w = true }));
    const lat = g.lat();
    const c = check(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 2), c.c_arrow_lat_explained);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "lateral: a ring neighbour is a frame convention, never a defect" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .e = true, .w = true }));
    g.set(0, 1, .{ .occupant = .{ .node_border = .{ .node = 1, .role = .edge_e } }, .neighbours = .{} });
    g.set(2, 1, .{ .occupant = .{ .cluster_border = .{ .cluster = 0, .role = .edge_w } }, .neighbours = .{} });
    const lat = g.lat();
    const c = check(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 2), c.c_arrow_lat_frame);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "lateral: an opaque neighbour (label glyph or node fill) explains itself" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.east, .{ .n = true, .s = true }));
    g.set(1, 0, .{ .occupant = .{ .label_char = 'A' }, .neighbours = .{} });
    g.set(1, 2, .{ .occupant = .{ .node_interior = 5 }, .neighbours = .{} });
    const lat = g.lat();
    const c = check(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 2), c.c_arrow_lat_opaque);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "lateral: a blank neighbour with a resuming run beyond is reprieved" {
    var buf: [5]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 5, .height = 1, .cells = &buf };
    buf[2] = arrowCell(.north, .{ .w = true });
    buf[0] = edgeCell(.{ .e = true });
    var c = check(&lat, 2, 0);
    try testing.expectEqual(@as(u32, 1), c.c_arrow_lat_explained);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    buf[0] = edgeCell(.{ .n = true, .s = true });
    c = check(&lat, 2, 0);
    try testing.expectEqual(@as(u32, 1), c.d_arrow_lat_orphan);

    buf[0] = lattice.Cell.empty;
    c = check(&lat, 2, 0);
    try testing.expectEqual(@as(u32, 1), c.d_arrow_lat_orphan);
}

test "lateral: a ghost neighbour is background, and can still be reprieved" {
    var buf: [5]lattice.Cell = undefined;
    for (&buf) |*c| c.* = lattice.Cell.empty;
    const lat = lattice.Lattice{ .width = 5, .height = 1, .cells = &buf };
    buf[2] = arrowCell(.north, .{ .w = true });
    buf[1] = .{ .occupant = .{ .edge_segment = .{ .edge = 1, .kind = .invisible } }, .neighbours = .{ .e = true, .w = true } };
    buf[0] = edgeCell(.{ .e = true });
    const c = check(&lat, 2, 0);
    try testing.expectEqual(@as(u32, 1), c.c_arrow_lat_explained);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "lateral: an off-grid perpendicular bit is an orphan" {
    var g: Grid = .{};
    g.init();
    g.set(0, 0, arrowCell(.south, .{ .w = true }));
    const lat = g.lat();
    const c = check(&lat, 0, 0);
    try testing.expectEqual(@as(u32, 1), c.d_arrow_lat_orphan);
}

test "lateral: tip-axis bits are never laterals, whatever sits on them" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.east, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = check(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try testing.expectEqual(@as(u32, 0), c.c_arrow_lat_explained);
}

/// Run the base-support check on the single cell at `(x,y)`.
fn base(lat: *const lattice.Lattice, x: u32, y: u32) counts.Counts {
    const v = cell.View.init(lat);
    var c: counts.Counts = .{};
    arrows.checkBase(v, x, y, v.at(x, y).?, &c);
    return c;
}

fn baseCell(occ: lattice.Occupant, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = occ, .neighbours = nb };
}

test "base: a clean vertical feed fires nothing at all" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .s = true }));
    g.set(1, 0, edgeCell(.{ .n = true, .s = true }));
    const lat = g.lat();
    const c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try testing.expectEqual(@as(u32, 0), c.c_base_label);
    try testing.expectEqual(@as(u32, 0), c.c_base_side_fed);
}

test "base: a dotted feed is legal — the bits carry, the glyph does not matter" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .s = true }));
    g.set(1, 0, baseCell(.{ .edge_segment = .{ .edge = 7, .kind = .dotted } }, .{ .n = true, .s = true }));
    const lat = g.lat();
    try testing.expectEqual(@as(u32, 0), base(&lat, 1, 1).defectTotal());
}

test "base: an invisible base carrying the bit reads as fed, exactly as the renderer sees it" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .s = true }));
    g.set(1, 0, baseCell(.{ .edge_segment = .{ .edge = 7, .kind = .invisible } }, .{ .n = true, .s = true }));
    const lat = g.lat();
    const c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
    try testing.expectEqual(@as(u32, 0), c.c_base_fan_rail);
}

test "base: a label base is the validator's exemption, never a violation" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .s = true }));
    g.set(1, 0, baseCell(.{ .label_char = 'x' }, .{}));
    const lat = g.lat();
    const c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.c_base_label);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "base: a blank base with nothing behind it floats" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .s = true }));
    const lat = g.lat();
    const c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.d_base_blank);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
}

test "base: a side feed is checked before the occupant buckets" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .s = true }));
    g.set(0, 1, edgeCell(.{ .e = true, .w = true }));
    const lat = g.lat();
    const c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.c_base_side_fed);
    try testing.expectEqual(@as(u32, 0), c.d_base_blank);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "base: a coincident frame beside the tip is NOT a side feed" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .s = true }));
    g.set(0, 1, baseCell(.{ .cluster_border = .{ .cluster = 0, .role = .edge_n } }, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 0), c.c_base_side_fed);
    try testing.expectEqual(@as(u32, 1), c.d_base_blank);
}

test "base: a fan-strip rail legally lacks the into-arrow arm" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .s = true }));
    g.set(1, 0, baseCell(
        .{ .edge_segment = .{ .edge = 7, .kind = .solid, .role = .fan_out_rail } },
        .{ .e = true, .w = true },
    ));
    const lat = g.lat();
    const c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.c_base_fan_rail);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "base: a foreign run under the tip is refused by the weld, not a defect" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .s = true }));
    g.set(1, 0, baseCell(.{ .edge_segment = .{ .edge = 3, .kind = .solid } }, .{ .e = true, .w = true }));
    var lat = g.lat();
    var c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.c_base_foreign);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    g.set(1, 0, edgeCell(.{ .e = true, .w = true }));
    lat = g.lat();
    c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.d_base_unfed);
    try testing.expectEqual(@as(u32, 0), c.c_base_foreign);
}

test "base: a cluster frame base is frame-solid, a node border base is not" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.south, .{ .n = true, .s = true }));
    g.set(1, 0, baseCell(.{ .cluster_border = .{ .cluster = 0, .role = .edge_s } }, .{ .e = true, .w = true }));
    var lat = g.lat();
    var c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.c_base_frame);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    g.set(1, 0, baseCell(.{ .node_border = .{ .node = 2, .role = .edge_s } }, .{ .e = true, .w = true }));
    lat = g.lat();
    c = base(&lat, 1, 1);
    try testing.expectEqual(@as(u32, 1), c.d_base_unfed);
}

test "base: an off-grid base is an audit limitation, not a renderer defect" {
    var g: Grid = .{};
    g.init();
    g.set(1, 0, arrowCell(.south, .{ .s = true }));
    const lat = g.lat();
    const c = base(&lat, 1, 0);
    try testing.expectEqual(@as(u32, 1), c.u_base_oob);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "base: all four tips resolve the cell opposite the tip" {
    var g: Grid = .{};
    g.init();
    g.set(1, 1, arrowCell(.north, .{ .n = true, .s = true }));
    g.set(1, 2, edgeCell(.{ .n = true, .s = true }));
    var lat = g.lat();
    try testing.expectEqual(@as(u32, 0), base(&lat, 1, 1).defectTotal());

    g.set(1, 1, arrowCell(.west, .{ .e = true, .w = true }));
    g.set(2, 1, edgeCell(.{ .e = true, .w = true }));
    lat = g.lat();
    try testing.expectEqual(@as(u32, 0), base(&lat, 1, 1).defectTotal());

    g.set(1, 1, arrowCell(.east, .{ .e = true, .w = true }));
    g.set(0, 1, edgeCell(.{ .e = true, .w = true }));
    lat = g.lat();
    try testing.expectEqual(@as(u32, 0), base(&lat, 1, 1).defectTotal());
}

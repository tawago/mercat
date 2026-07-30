//! Unit tests for `tiling/strokes.zig`. Every bucket gets a firing and a
//! non-firing fixture, and the pairs that could shadow each other
//! (into-fill vs the interior verdict, dangling vs reprieved, fusion vs
//! crossing) are pinned against each other rather than in isolation.

const std = @import("std");
const lattice = @import("../lattice.zig");
const cell = @import("cell.zig");
const counts = @import("counts.zig");
const strokes = @import("strokes.zig");

const testing = std.testing;

const Grid = struct {
    buf: [25]lattice.Cell = undefined,

    fn init(self: *Grid) void {
        for (&self.buf) |*c| c.* = lattice.Cell.empty;
    }

    fn lat(self: *Grid) lattice.Lattice {
        return .{ .width = 5, .height = 5, .cells = &self.buf };
    }

    fn set(self: *Grid, x: usize, y: usize, c: lattice.Cell) void {
        self.buf[y * 5 + x] = c;
    }
};

fn edgeCell(id: u32, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = id, .kind = .solid } }, .neighbours = nb };
}

fn roledCell(id: u32, role: lattice.EdgeRole, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = id, .kind = .solid, .role = role } }, .neighbours = nb };
}

fn ghostCell(id: u32, nb: lattice.Neighbours) lattice.Cell {
    return .{ .occupant = .{ .edge_segment = .{ .edge = id, .kind = .invisible } }, .neighbours = nb };
}

fn fillCell(node: u32) lattice.Cell {
    return .{ .occupant = .{ .node_interior = node }, .neighbours = .{} };
}

fn check(lat: *const lattice.Lattice, x: u32, y: u32) counts.Counts {
    const v = cell.View.init(lat);
    var c: counts.Counts = .{};
    strokes.check(v, x, y, v.at(x, y).?, &c);
    return c;
}

test "arity: an armless stroke has nothing for the painter to join" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{}));
    const lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_stroke_armless);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
}

test "arity: a one-armed stroke beside a terminal is a convention, alone it is a stub" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{ .w = true }));
    g.set(1, 2, edgeCell(1, .{ .e = true }));
    var lat = g.lat();
    // Nothing terminal beside it.
    var c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_stroke_stub);
    try testing.expectEqual(@as(u32, 0), c.c_stub_terminal);

    // An arrowhead to the east makes it the end of a run.
    g.set(3, 2, .{ .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 1 } }, .neighbours = .{} });
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_stub_terminal);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    // So does a node ring.
    g.set(3, 2, .{ .occupant = .{ .node_border = .{ .node = 4, .role = .edge_w } }, .neighbours = .{} });
    lat = g.lat();
    try testing.expectEqual(@as(u32, 1), check(&lat, 2, 2).c_stub_terminal);
}

test "arity: the census partitions two-, three- and four-armed cells" {
    var g: Grid = .{};
    g.init();
    // Surround the centre with reciprocating strokes so the arm pass is
    // silent and only the census speaks.
    g.set(2, 1, edgeCell(1, .{ .s = true }));
    g.set(2, 3, edgeCell(1, .{ .n = true }));
    g.set(1, 2, edgeCell(1, .{ .e = true }));
    g.set(3, 2, edgeCell(1, .{ .w = true }));

    g.set(2, 2, edgeCell(1, .{ .n = true, .s = true }));
    var lat = g.lat();
    var c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.m_straight_cells);
    try testing.expectEqual(@as(u32, 0), c.m_corner_cells);

    g.set(2, 2, edgeCell(1, .{ .n = true, .e = true }));
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.m_corner_cells);

    g.set(2, 2, edgeCell(1, .{ .n = true, .e = true, .w = true }));
    lat = g.lat();
    try testing.expectEqual(@as(u32, 1), check(&lat, 2, 2).m_tee_cells);

    g.set(2, 2, edgeCell(1, .{ .n = true, .e = true, .s = true, .w = true }));
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.m_cross_cells);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "arms: dangling, reprieved and into-ghost are three different answers" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{ .n = true, .w = true }));
    g.set(2, 1, edgeCell(1, .{ .s = true }));
    var lat = g.lat();
    // (1,2) blank, (0,2) blank: nothing resumes.
    var c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_arm_dangling);

    // (0,2) reciprocates east across the one-cell gap.
    g.set(0, 2, edgeCell(1, .{ .e = true }));
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_arm_gap_reprieved);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    // An invisible edge occupies the adjacent cell: it paints nothing, so
    // the arm terminates on a blank by convention.
    g.set(1, 2, ghostCell(9, .{ .e = true, .w = true }));
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_arm_into_ghost);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "arms: an off-grid arm is dangling, not silently dropped" {
    var g: Grid = .{};
    g.init();
    g.set(0, 0, edgeCell(1, .{ .n = true, .s = true }));
    g.set(0, 1, edgeCell(1, .{ .n = true }));
    const lat = g.lat();
    try testing.expectEqual(@as(u32, 1), check(&lat, 0, 0).d_arm_dangling);
}

test "interior: opposite-side fill of the same node fires, one side or two ids do not" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(1, 2, edgeCell(1, .{ .e = true }));
    g.set(3, 2, edgeCell(1, .{ .w = true }));

    // Fill on one side only: a run alongside a box.
    g.set(2, 1, fillCell(4));
    var lat = g.lat();
    try testing.expectEqual(@as(u32, 0), check(&lat, 2, 2).d_ink_in_interior);

    // Fill on both sides but two DIFFERENT nodes: a gutter.
    g.set(2, 3, fillCell(5));
    lat = g.lat();
    try testing.expectEqual(@as(u32, 0), check(&lat, 2, 2).d_ink_in_interior);

    // Same node on both sides: ink is crossing that box.
    g.set(2, 3, fillCell(4));
    lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_ink_in_interior);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
}

test "interior: the cell verdict suppresses that cell's into-fill increments" {
    var g: Grid = .{};
    g.init();
    // A four-armed cell inside a box: two arms point into the same node's
    // fill. Without suppression this would count three times.
    g.set(2, 2, edgeCell(1, .{ .n = true, .e = true, .s = true, .w = true }));
    g.set(2, 1, fillCell(4));
    g.set(2, 3, fillCell(4));
    g.set(1, 2, edgeCell(1, .{ .e = true }));
    g.set(3, 2, edgeCell(1, .{ .w = true }));
    const lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_ink_in_interior);
    try testing.expectEqual(@as(u32, 0), c.d_arm_into_fill);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
}

test "arms: an arm into a foreign node's fill is counted on its own" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{ .n = true, .s = true }));
    g.set(2, 1, edgeCell(1, .{ .s = true }));
    g.set(2, 3, fillCell(4));
    const lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_arm_into_fill);
    try testing.expectEqual(@as(u32, 0), c.d_ink_in_interior);
}

test "arms: asymmetry is measured, never accused" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{ .n = true, .s = true }));
    g.set(2, 1, edgeCell(1, .{ .s = true }));
    // The south neighbour is a stroke that never points back north.
    g.set(2, 3, edgeCell(1, .{ .e = true, .w = true }));
    const lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.m_arm_asym);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "fusion: two straight runs of different edges fuse; the same edge does not" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(3, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(1, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(4, 2, edgeCell(1, .{ .w = true }));
    var lat = g.lat();
    try testing.expectEqual(@as(u32, 0), check(&lat, 2, 2).d_run_fused_collinear);

    // Same geometry, different owner east of it.
    g.set(3, 2, edgeCell(2, .{ .e = true, .w = true }));
    lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_run_fused_collinear);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
}

test "fusion: a junction beside a foreign run is a crossing, not a fusion" {
    // Where two runs MEET, the cell's id is whichever arrived first — the
    // id difference there says nothing. Both the four-armed cross and the
    // three-armed tee are junctions.
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(1, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(3, 2, edgeCell(2, .{ .n = true, .e = true, .s = true, .w = true }));
    g.set(3, 1, edgeCell(2, .{ .s = true }));
    g.set(3, 3, edgeCell(2, .{ .n = true }));
    g.set(4, 2, edgeCell(2, .{ .w = true }));
    var lat = g.lat();
    var c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_run_fused_crossing);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    // Drop the south arm: a tee is still a meeting point.
    g.set(3, 2, edgeCell(2, .{ .n = true, .e = true, .w = true }));
    g.set(3, 3, lattice.Cell.empty);
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_run_fused_crossing);
    try testing.expectEqual(@as(u32, 0), c.d_run_fused_collinear);
}

test "fusion: a bus-bar rail above its tap's dropper is not a fusion" {
    // The rail cell carries only the drop arm on the shared axis, so the
    // "both cells run straight through" gate excludes the pair — which is
    // what keeps the trunk's shared id from reading as a defect.
    var g: Grid = .{};
    g.init();
    g.set(2, 2, roledCell(1, .fan_out_trunk, .{ .e = true, .s = true, .w = true }));
    g.set(1, 2, roledCell(1, .fan_out_rail, .{ .e = true, .w = true }));
    g.set(3, 2, roledCell(1, .fan_out_rail, .{ .e = true, .w = true }));
    g.set(2, 3, roledCell(7, .fan_out_rail, .{ .n = true, .s = true }));
    g.set(2, 4, roledCell(7, .fan_out_rail, .{ .n = true }));
    const lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 0), c.d_run_fused_collinear);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "fusion: each ordered pair is visited once (east/south scan only)" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(1, 2, edgeCell(2, .{ .e = true, .w = true }));
    g.set(3, 2, edgeCell(2, .{ .e = true, .w = true }));
    g.set(0, 2, edgeCell(2, .{ .e = true, .w = true }));
    g.set(4, 2, edgeCell(2, .{ .w = true }));
    const lat = g.lat();
    // The centre owns only its EAST pair; the west one belongs to (1,2).
    try testing.expectEqual(@as(u32, 1), check(&lat, 2, 2).d_run_fused_collinear);
}

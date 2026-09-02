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
    var c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_stroke_stub);
    try testing.expectEqual(@as(u32, 0), c.c_stub_terminal);

    g.set(3, 2, .{ .occupant = .{ .arrowhead = .{ .dir = .east, .edge = 1 } }, .neighbours = .{} });
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_stub_terminal);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

    g.set(3, 2, .{ .occupant = .{ .node_border = .{ .node = 4, .role = .edge_w } }, .neighbours = .{} });
    lat = g.lat();
    try testing.expectEqual(@as(u32, 1), check(&lat, 2, 2).c_stub_terminal);
}

test "arity: the census partitions two-, three- and four-armed cells" {
    var g: Grid = .{};
    g.init();
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
    var c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_arm_dangling);

    g.set(0, 2, edgeCell(1, .{ .e = true }));
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_arm_gap_reprieved);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());

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

    g.set(2, 1, fillCell(4));
    var lat = g.lat();
    try testing.expectEqual(@as(u32, 0), check(&lat, 2, 2).d_ink_in_interior);

    g.set(2, 3, fillCell(5));
    lat = g.lat();
    try testing.expectEqual(@as(u32, 0), check(&lat, 2, 2).d_ink_in_interior);

    g.set(2, 3, fillCell(4));
    lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_ink_in_interior);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
}

test "interior: the cell verdict suppresses that cell's into-fill increments" {
    var g: Grid = .{};
    g.init();
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

    g.set(3, 2, edgeCell(2, .{ .e = true, .w = true }));
    lat = g.lat();
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.d_run_fused_collinear);
    try testing.expectEqual(@as(u32, 1), c.defectTotal());
}

test "fusion: a junction beside a foreign run is a crossing, not a fusion" {
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

    g.set(3, 2, edgeCell(2, .{ .n = true, .e = true, .w = true }));
    g.set(3, 3, lattice.Cell.empty);
    lat = g.lat();
    c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_run_fused_crossing);
    try testing.expectEqual(@as(u32, 0), c.d_run_fused_collinear);
}

test "fusion: a rail's crossbar above its tap's dropper is not a fusion" {
    var g: Grid = .{};
    g.init();
    g.set(2, 2, roledCell(1, .fan_out_rail, .{ .e = true, .s = true, .w = true }));
    g.set(1, 2, roledCell(1, .fan_out_dropper, .{ .e = true, .w = true }));
    g.set(3, 2, roledCell(1, .fan_out_dropper, .{ .e = true, .w = true }));
    g.set(2, 3, roledCell(7, .fan_out_dropper, .{ .n = true, .s = true }));
    g.set(2, 4, roledCell(7, .fan_out_dropper, .{ .n = true }));
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
    try testing.expectEqual(@as(u32, 1), check(&lat, 2, 2).d_run_fused_collinear);
}

const JUNCTION = 3 * 1 + 2 * 5;

fn carrier(index: u32, edge: u32, how: lattice.CarrierKind) lattice.Aux {
    return .{ .cell = index, .value = edge, .kind = .carrier, .detail = @intFromEnum(how) };
}

/// The shared fixture, with `table` as the side table. Records must be
/// given in the table's own (cell, kind, value) order.
fn junctionPair(g: *Grid, table: []const lattice.Aux) lattice.Lattice {
    g.init();
    g.set(1, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(2, 2, edgeCell(1, .{ .e = true, .w = true }));
    g.set(3, 2, edgeCell(2, .{ .n = true, .e = true, .s = true, .w = true }));
    g.set(3, 1, edgeCell(2, .{ .s = true }));
    g.set(3, 3, edgeCell(2, .{ .n = true }));
    g.set(4, 2, edgeCell(2, .{ .w = true }));
    return .{ .width = 5, .height = 5, .cells = &g.buf, .aux = table };
}

test "fusion: a foreign record on the junction cell files the defect" {
    for ([2]lattice.CarrierKind{ .suppressed, .merged_foreign }) |how| {
        var g: Grid = .{};
        const table = [_]lattice.Aux{carrier(JUNCTION, 1, how)};
        const lat = junctionPair(&g, &table);
        const c = check(&lat, 2, 2);
        try testing.expectEqual(@as(u32, 1), c.c_run_fused_crossing);
        try testing.expectEqual(@as(u32, 1), c.d_run_fused_foreign);
        try testing.expectEqual(@as(u32, 0), c.c_run_fused_licensed);
        try testing.expectEqual(@as(u32, 0), c.u_run_fused_unevidenced);
        try testing.expectEqual(@as(u32, 1), c.defectTotal());
    }
}

test "fusion: a licensed record on the junction cell keeps the convention" {
    var g: Grid = .{};
    const table = [_]lattice.Aux{carrier(JUNCTION, 1, .merged_licensed)};
    const lat = junctionPair(&g, &table);
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 1), c.c_run_fused_crossing);
    try testing.expectEqual(@as(u32, 1), c.c_run_fused_licensed);
    try testing.expectEqual(@as(u32, 0), c.d_run_fused_foreign);
    try testing.expectEqual(@as(u32, 0), c.defectTotal());
}

test "fusion: a junction with no usable record is unevidenced, never licensed" {
    var g: Grid = .{};
    const tables = [3][]const lattice.Aux{
        &.{},
        &.{carrier(JUNCTION, 4, .merged_foreign)},
        &.{carrier(JUNCTION, 1, .merged_untested)},
    };
    for (tables) |table| {
        const lat = junctionPair(&g, table);
        const c = check(&lat, 2, 2);
        try testing.expectEqual(@as(u32, 1), c.c_run_fused_crossing);
        try testing.expectEqual(@as(u32, 1), c.u_run_fused_unevidenced);
        try testing.expectEqual(@as(u32, 0), c.c_run_fused_licensed);
        try testing.expectEqual(@as(u32, 0), c.defectTotal());
    }
}

test "fusion: precedence — any foreign record outranks a licensed one, in either order" {
    var g: Grid = .{};
    const licensed = carrier(JUNCTION, 1, .merged_licensed);
    const foreign = carrier(JUNCTION, 1, .suppressed);
    const tables = [2][2]lattice.Aux{ .{ licensed, foreign }, .{ foreign, licensed } };
    for (tables) |table| {
        const lat = junctionPair(&g, &table);
        const c = check(&lat, 2, 2);
        try testing.expectEqual(@as(u32, 1), c.d_run_fused_foreign);
        try testing.expectEqual(@as(u32, 0), c.c_run_fused_licensed);
    }
}

test "fusion: only a JUNCTION cell's records answer, and either junction may" {
    {
        var g: Grid = .{};
        const table = [_]lattice.Aux{carrier(2 + 2 * 5, 2, .suppressed)};
        const lat = junctionPair(&g, &table);
        const c = check(&lat, 2, 2);
        try testing.expectEqual(@as(u32, 1), c.u_run_fused_unevidenced);
        try testing.expectEqual(@as(u32, 0), c.d_run_fused_foreign);
    }
    {
        var g: Grid = .{};
        const table = [_]lattice.Aux{carrier(2 + 2 * 5, 2, .suppressed)};
        var lat = junctionPair(&g, &table);
        g.set(2, 2, edgeCell(1, .{ .n = true, .e = true, .w = true }));
        g.set(2, 1, edgeCell(1, .{ .s = true }));
        lat = .{ .width = 5, .height = 5, .cells = &g.buf, .aux = &table };
        const c = check(&lat, 2, 2);
        try testing.expectEqual(@as(u32, 1), c.d_run_fused_foreign);
    }
}

test "fusion: the three junction verdicts partition the crossing population" {
    var g: Grid = .{};
    const table = [_]lattice.Aux{carrier(JUNCTION, 1, .merged_licensed)};
    var lat = junctionPair(&g, &table);
    g.set(2, 2, edgeCell(1, .{ .e = true, .w = true, .n = true, .s = true }));
    g.set(2, 1, edgeCell(1, .{ .s = true }));
    g.set(2, 3, edgeCell(5, .{ .n = true, .s = true }));
    g.set(2, 4, edgeCell(5, .{ .n = true }));
    lat = .{ .width = 5, .height = 5, .cells = &g.buf, .aux = &table };
    const c = check(&lat, 2, 2);
    try testing.expectEqual(@as(u32, 2), c.c_run_fused_crossing);
    try testing.expectEqual(
        c.c_run_fused_crossing,
        c.c_run_fused_licensed + c.d_run_fused_foreign + c.u_run_fused_unevidenced,
    );
    try testing.expectEqual(@as(u32, 1), c.c_run_fused_licensed);
    try testing.expectEqual(@as(u32, 1), c.u_run_fused_unevidenced);
}

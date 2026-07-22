//! Integration tests for the crossing/transversal rule (Amendment C, C1/C2)
//! driven through `raster/edges.zig`'s `rasterizeEdges`. Sketches are built by
//! hand; the realized-join plan (`Sketch.joins`) is set to activate the rule
//! and to exercise the co-member exemption.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ledger = @import("../base/ledger.zig");
const edges = @import("edges.zig");
const crossings = @import("crossings.zig");

const testing = std.testing;

fn makeLattice(a: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try a.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn edge(id: u32, pts: []const sketch.Point, arrow_to: sketch.ArrowKind) sketch.EdgePath {
    return .{
        .id = id,
        .from = id,
        .to = id + 100,
        .polyline = pts,
        .port_from = .{ .node = id, .side = .south, .offset = 0 },
        .port_to = .{ .node = id + 100, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = arrow_to,
        .label = null,
        .kind = .solid,
    };
}

fn sketchWith(es: []const sketch.EdgePath, joins: ledger.RealizedJoins) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 12, .h = 12 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = es,
        .joins = joins,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

/// A plan that makes the rule active but places every listed edge in DISTINCT
/// (independent) memberships, so no two are co-members: every foreign crossing
/// is subject to the transversal rule.
fn independentPlan(mems: []const ledger.RealizedEdgeMembership) ledger.RealizedJoins {
    return .{ .memberships = mems };
}

const mask_hw = (lattice.Neighbours{ .e = true, .w = true }).toMask();
const mask_ns = (lattice.Neighbours{ .n = true, .s = true }).toMask();
const mask_cross = (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask();

test "V-D-CROSS-01: two independent perpendicular edges cross as a transversal" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 11, 11);
    defer a.free(lat.cells);

    // Edge 0 horizontal along row 5; edge 1 vertical along column 5.
    const h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const v = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 } };
    const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &v, .none) };
    var mems = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = null },
        .{ .edge = 1, .source = null, .target = null },
    };
    const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge);

    // First writer (edge 0, horizontal) keeps its straight stroke: NOT a ┼.
    const cross = lat.atConst(5, 5).*;
    try testing.expectEqual(mask_hw, cross.neighbours.toMask());
    switch (cross.occupant) {
        .edge_segment => |seg| try testing.expectEqual(@as(u32, 0), seg.edge),
        else => return error.NotEdgeSegment,
    }
    // Exactly one legal crossing, no violations.
    try testing.expectEqual(@as(u32, 1), r.crossings.legal_crossing);
    try testing.expectEqual(@as(u32, 0), r.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), r.crossings.arrowhead_transit_violation);

    // Edge 1's ink resumes on BOTH sides of the crossing (opposite sides).
    try testing.expectEqual(mask_ns, lat.atConst(5, 4).neighbours.toMask());
    try testing.expectEqual(mask_ns, lat.atConst(5, 6).neighbours.toMask());
}

test "V-D-CROSS-01 companion: same-group perpendicular crossing keeps the ┼ (no event)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 11, 11);
    defer a.free(lat.cells);

    const h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const v = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 } };
    const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &v, .none) };
    // Both edges are co-members of ONE realized join → legal shared ink.
    var members = [_]ledger.EdgeId{ 0, 1 };
    var sel = [_]ledger.SelectedJoin{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &members }};
    const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, .{ .selected_joins = &sel }), .bridge);

    // Co-members keep the pre-C OR-merge: the crossing fuses to ┼.
    try testing.expectEqual(mask_cross, lat.atConst(5, 5).neighbours.toMask());
    try testing.expectEqual(@as(u32, 0), r.crossings.legal_crossing);
    try testing.expectEqual(@as(u32, 0), r.crossings.foreign_junction_violation);
}

test "V-D-CROSS-02: a foreign run through an arrowhead cell is refused (C2)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 11, 11);
    defer a.free(lat.cells);

    // Edge 0 descends column 5 and lands its arrowhead at (5,5); edge 1 runs
    // horizontally through that same cell. Edge 0 is written FIRST.
    const v = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 6 } };
    const hrun = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const es = [_]sketch.EdgePath{ edge(0, &v, .filled), edge(1, &hrun, .none) };
    var mems = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = null },
        .{ .edge = 1, .source = null, .target = null },
    };
    const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge);

    // The arrowhead cell stays an arrowhead owned by edge 0 — no foreign bits.
    const cell = lat.atConst(5, 5).*;
    switch (cell.occupant) {
        .arrowhead => |ah| try testing.expectEqual(@as(u32, 0), ah.edge),
        else => return error.NotArrowhead,
    }
    try testing.expectEqual(@as(u32, 1), r.crossings.arrowhead_transit_violation);
    // Edge 0's own terminal arrowhead is NOT counted as a transit violation
    // (only edge 1's crossing is), so the count is exactly one.
}

test "C1 violation shape: a foreign collinear/corner overlap keeps first-writer bits (no tee)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // Edge 0 runs horizontally along row 5. Edge 1 runs west ALONG row 5
    // (collinear overlap), then corners south at (7,5). It never crosses edge 0
    // perpendicularly, so there is no legal transversal — only foreign overlap.
    const h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const l = [_]sketch.Point{ .{ .x = 11, .y = 5 }, .{ .x = 7, .y = 5 }, .{ .x = 7, .y = 9 } };
    const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &l, .none) };
    var mems = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = null },
        .{ .edge = 1, .source = null, .target = null },
    };
    const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge);

    // The corner cell (7,5) keeps edge 0's straight horizontal stroke — no ┬.
    const corner = lat.atConst(7, 5).*;
    try testing.expectEqual(mask_hw, corner.neighbours.toMask());
    switch (corner.occupant) {
        .edge_segment => |seg| try testing.expectEqual(@as(u32, 0), seg.edge),
        else => return error.NotEdgeSegment,
    }
    // At least one foreign-junction violation (corner + collinear run cells);
    // NO legal crossing (nothing here is a clean perpendicular transversal).
    try testing.expect(r.crossings.foreign_junction_violation >= 1);
    try testing.expectEqual(@as(u32, 0), r.crossings.legal_crossing);
}

test "determinism: crossing outcome is deterministic under edge-array permutation (first-writer)" {
    const a = testing.allocator;

    const h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const v = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 } };
    var mems = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = null },
        .{ .edge = 1, .source = null, .target = null },
    };

    // Raster order == Sketch.edges array order, so first-writer is the first
    // edge in the array. Order [H, V] → the horizontal stroke survives.
    {
        var lat = try makeLattice(a, 11, 11);
        defer a.free(lat.cells);
        const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &v, .none) };
        const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge);
        try testing.expectEqual(mask_hw, lat.atConst(5, 5).neighbours.toMask());
        try testing.expectEqual(@as(u32, 1), r.crossings.legal_crossing);
    }
    // Order [V, H] → the vertical stroke survives; still exactly one legal
    // crossing and never a fused ┼.
    {
        var lat = try makeLattice(a, 11, 11);
        defer a.free(lat.cells);
        const es = [_]sketch.EdgePath{ edge(1, &v, .none), edge(0, &h, .none) };
        const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge);
        try testing.expectEqual(mask_ns, lat.atConst(5, 5).neighbours.toMask());
        try testing.expectEqual(@as(u32, 1), r.crossings.legal_crossing);
    }
}

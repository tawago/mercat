const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const ledger = @import("../base/ledger.zig");
const edges = @import("edges.zig");

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

fn sketchWith(es: []const sketch.EdgePath, bundles: ledger.RealizedBundles) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 12, .h = 12 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = es,
        .bundles = bundles,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn independentPlan(mems: []const ledger.RealizedEdgeMembership) ledger.RealizedBundles {
    return .{ .memberships = mems };
}

const mask_hw = (lattice.Neighbours{ .e = true, .w = true }).toMask();
const mask_ns = (lattice.Neighbours{ .n = true, .s = true }).toMask();
const mask_cross = (lattice.Neighbours{ .n = true, .e = true, .s = true, .w = true }).toMask();

test "V-D-CROSS-01: two independent perpendicular edges cross as a transversal" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 11, 11);
    defer a.free(lat.cells);

    const h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const v = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 } };
    const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &v, .none) };
    var mems = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = null },
        .{ .edge = 1, .source = null, .target = null },
    };
    const r = try edges.rasterizeEdges(&lat, sketchWith(&es, independentPlan(&mems)), .bridge);

    const cross = lat.atConst(5, 5).*;
    try testing.expectEqual(mask_hw, cross.neighbours.toMask());
    switch (cross.occupant) {
        .edge_segment => |seg| try testing.expectEqual(@as(u32, 0), seg.edge),
        else => return error.NotEdgeSegment,
    }
    try testing.expectEqual(@as(u32, 0), r.crossings.foreign_junction_violation);
    try testing.expectEqual(@as(u32, 0), r.crossings.arrowhead_transit_violation);

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
    var members = [_]ledger.EdgeId{ 0, 1 };
    var sel = [_]ledger.SelectedBundle{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &members }};
    const r = try edges.rasterizeEdges(&lat, sketchWith(&es, .{ .selected_bundles = &sel }), .bridge);

    try testing.expectEqual(mask_cross, lat.atConst(5, 5).neighbours.toMask());
    try testing.expectEqual(@as(u32, 0), r.crossings.foreign_junction_violation);
}

test "V-D-CROSS-02: a foreign run through an arrowhead cell is refused (arrowhead sanctity)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 11, 11);
    defer a.free(lat.cells);

    const v = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 6 } };
    const hrun = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const es = [_]sketch.EdgePath{ edge(0, &v, .filled), edge(1, &hrun, .none) };
    var mems = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = null },
        .{ .edge = 1, .source = null, .target = null },
    };
    const r = try edges.rasterizeEdges(&lat, sketchWith(&es, independentPlan(&mems)), .bridge);

    const cell = lat.atConst(5, 5).*;
    switch (cell.occupant) {
        .arrowhead => |ah| try testing.expectEqual(@as(u32, 0), ah.edge),
        else => return error.NotArrowhead,
    }
    try testing.expectEqual(@as(u32, 1), r.crossings.arrowhead_transit_violation);
}

test "transversal-violation shape: a foreign collinear/corner overlap keeps first-writer bits (no tee)" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    const h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const l = [_]sketch.Point{ .{ .x = 11, .y = 5 }, .{ .x = 7, .y = 5 }, .{ .x = 7, .y = 9 } };
    const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &l, .none) };
    var mems = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = null },
        .{ .edge = 1, .source = null, .target = null },
    };
    const r = try edges.rasterizeEdges(&lat, sketchWith(&es, independentPlan(&mems)), .bridge);

    const corner = lat.atConst(7, 5).*;
    try testing.expectEqual(mask_hw, corner.neighbours.toMask());
    switch (corner.occupant) {
        .edge_segment => |seg| try testing.expectEqual(@as(u32, 0), seg.edge),
        else => return error.NotEdgeSegment,
    }
    try testing.expect(r.crossings.foreign_junction_violation >= 1);
}

test "determinism: crossing outcome is deterministic under edge-array permutation (first-writer)" {
    const a = testing.allocator;

    const h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const v = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 } };
    var mems = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = null },
        .{ .edge = 1, .source = null, .target = null },
    };

    {
        var lat = try makeLattice(a, 11, 11);
        defer a.free(lat.cells);
        const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &v, .none) };
        _ = try edges.rasterizeEdges(&lat, sketchWith(&es, independentPlan(&mems)), .bridge);
        try testing.expectEqual(mask_hw, lat.atConst(5, 5).neighbours.toMask());
    }
    {
        var lat = try makeLattice(a, 11, 11);
        defer a.free(lat.cells);
        const es = [_]sketch.EdgePath{ edge(1, &v, .none), edge(0, &h, .none) };
        _ = try edges.rasterizeEdges(&lat, sketchWith(&es, independentPlan(&mems)), .bridge);
        try testing.expectEqual(mask_ns, lat.atConst(5, 5).neighbours.toMask());
    }
}

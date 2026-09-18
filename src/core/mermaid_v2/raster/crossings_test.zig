//! Integration tests for the crossing/transversal rule (Amendment C: the transversal and arrowhead-sanctity rulings)
//! driven through `raster/edges.zig`'s `rasterizeEdges`. Sketches are built by
//! hand; the realized-bundle plan (`Sketch.bundles`) is set to activate the rule
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

/// A plan that places every listed edge in DISTINCT
/// (independent) memberships, so no two are co-members: every foreign crossing
/// is subject to the transversal rule.
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
    const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge, null);

    const cross = lat.atConst(5, 5).*;
    try testing.expectEqual(mask_hw, cross.neighbours.toMask());
    switch (cross.occupant) {
        .edge_segment => |seg| try testing.expectEqual(@as(u32, 0), seg.edge),
        else => return error.NotEdgeSegment,
    }
    try testing.expectEqual(@as(u32, 1), r.crossings.legal_crossing);
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
    const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, .{ .selected_bundles = &sel }), .bridge, null);

    try testing.expectEqual(mask_cross, lat.atConst(5, 5).neighbours.toMask());
    try testing.expectEqual(@as(u32, 0), r.crossings.legal_crossing);
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
    const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge, null);

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
    const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge, null);

    const corner = lat.atConst(7, 5).*;
    try testing.expectEqual(mask_hw, corner.neighbours.toMask());
    switch (corner.occupant) {
        .edge_segment => |seg| try testing.expectEqual(@as(u32, 0), seg.edge),
        else => return error.NotEdgeSegment,
    }
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

    {
        var lat = try makeLattice(a, 11, 11);
        defer a.free(lat.cells);
        const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &v, .none) };
        const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge, null);
        try testing.expectEqual(mask_hw, lat.atConst(5, 5).neighbours.toMask());
        try testing.expectEqual(@as(u32, 1), r.crossings.legal_crossing);
    }
    {
        var lat = try makeLattice(a, 11, 11);
        defer a.free(lat.cells);
        const es = [_]sketch.EdgePath{ edge(1, &v, .none), edge(0, &h, .none) };
        const r = try edges.rasterizeEdges(a, &lat, sketchWith(&es, independentPlan(&mems)), .bridge, null);
        try testing.expectEqual(mask_ns, lat.atConst(5, 5).neighbours.toMask());
        try testing.expectEqual(@as(u32, 1), r.crossings.legal_crossing);
    }
}

test "carrierKindFor trusts identity only after a complete consistent stamp" {
    var members = [_]u32{ 0, 1 };
    const unstamped = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &members }};
    const at: ledger.BundleCell = .{ .x = 0, .y = 0 };
    const stamped = try ledger.numberBundles(testing.allocator, &unstamped);
    defer testing.allocator.free(stamped);

    for ([_]sketch.BundleStampState{ .unattempted, .out_of_memory, .rail_invariant }) |state| {
        try testing.expectEqual(
            lattice.CarrierKind.merged_untested,
            crossings.carrierKindFor(0, 1, stamped, state, at),
        );
    }

    try testing.expectEqual(
        lattice.CarrierKind.merged_untested,
        crossings.carrierKindFor(0, 1, &unstamped, .complete, at),
    );

    try testing.expectEqual(
        lattice.CarrierKind.merged_licensed,
        crossings.carrierKindFor(0, 1, stamped, .complete, at),
    );
    try testing.expectEqual(
        lattice.CarrierKind.merged_foreign,
        crossings.carrierKindFor(0, 2, stamped, .complete, at),
    );
}

test "carrierKind asks a rail's bundle by name, so a member of two bundles is licensed on both rails" {
    // Edge 1 fans out with 0 (set 1) and fans in with 2 (set 2): rail
    // membership at both ends. Both sets license everywhere.
    var fan_out = [_]u32{ 0, 1 };
    var fan_in = [_]u32{ 1, 2 };
    const raw = [_]ledger.Bundle{
        .{ .origin = .fan_rail, .members = &fan_out },
        .{ .origin = .fan_rail, .members = &fan_in },
    };
    const sets = try ledger.numberBundles(testing.allocator, &raw);
    defer testing.allocator.free(sets);
    const at: ledger.BundleCell = .{ .x = 4, .y = 4 };

    // The fan-in rail (2) welds onto 1's ink, and 1's ink welds onto 2's,
    // on rail 2's cells: licensed both ways, by rail 2's own name.
    try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKind(sets, .complete, 1, 2, 2, at));
    try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKind(sets, .complete, 2, 1, 2, at));
    // The fan-out rail (1) likewise on its own cells.
    try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKind(sets, .complete, 1, 0, 1, at));
    // Rail 1 meeting an edge only rail 2 names is foreign, and a rail no set
    // names (the producer numbered it past the sets) holds nobody.
    try testing.expectEqual(lattice.CarrierKind.merged_foreign, crossings.carrierKind(sets, .complete, 2, 0, 1, at));
    try testing.expectEqual(lattice.CarrierKind.merged_foreign, crossings.carrierKind(sets, .complete, 1, 2, 3, at));
    // Two edges with no rail ask the pair: 1 and 2 share set 2, 0 and 2 nothing.
    try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKind(sets, .complete, 1, 2, null, at));
    try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKindFor(2, 1, sets, .complete, at));
    try testing.expectEqual(lattice.CarrierKind.merged_foreign, crossings.carrierKind(sets, .complete, 0, 2, null, at));
    // Same edge on both sides is its own ink, whatever the rail.
    try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKind(sets, .complete, 1, 1, 3, at));

    // `carrierKindOnto` reads the occupant and abstains on a cell naming nobody.
    var run = lattice.Cell.empty;
    run.occupant = .{ .edge_segment = .{ .edge = 1, .kind = .solid, .role = .forward } };
    try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKindOnto(&run, sets, .complete, 2, 2, at));
    var stranger = lattice.Cell.empty;
    stranger.occupant = .{ .edge_segment = .{ .edge = 0, .kind = .solid, .role = .forward } };
    try testing.expectEqual(lattice.CarrierKind.merged_foreign, crossings.carrierKindOnto(&stranger, sets, .complete, 1, 2, at));
    var head = lattice.Cell.empty;
    head.occupant = .{ .arrowhead = .{ .dir = .south, .edge = 2, .arrow = .filled } };
    try testing.expectEqual(lattice.CarrierKind.merged_licensed, crossings.carrierKindOnto(&head, sets, .complete, 1, null, at));
    const nobody = lattice.Cell.empty;
    try testing.expectEqual(lattice.CarrierKind.merged_untested, crossings.carrierKindOnto(&nobody, sets, .complete, 1, 2, at));
}

test "stamp state and BundleId never change derived crossing ink" {
    const a = testing.allocator;
    const h = [_]sketch.Point{ .{ .x = 0, .y = 5 }, .{ .x = 10, .y = 5 } };
    const v = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 10 } };
    const es = [_]sketch.EdgePath{ edge(0, &h, .none), edge(1, &v, .none) };
    var baseline: [121]lattice.Cell = undefined;
    var have_baseline = false;

    for ([_]ledger.BundleId{ 1, 97 }) |bundle| {
        const bundle_sets = [_]ledger.Bundle{.{
            .origin = .fan_rail,
            .bundle = bundle,
            .members = &.{ 0, 1 },
        }};
        for ([_]sketch.BundleStampState{ .unattempted, .complete, .out_of_memory, .rail_invariant }) |state| {
            var lat = try makeLattice(a, 11, 11);
            defer a.free(lat.cells);
            var s = sketchWith(&es, .{});
            s.bundle_sets = &bundle_sets;
            s.bundle_stamp_state = state;

            const r = try edges.rasterizeEdges(a, &lat, s, .bridge, null);
            try testing.expectEqual(mask_cross, lat.atConst(5, 5).neighbours.toMask());
            try testing.expectEqual(crossings.CrossingCounts{}, r.crossings);

            if (have_baseline) {
                try testing.expectEqualSlices(lattice.Cell, &baseline, lat.cells);
            } else {
                @memcpy(&baseline, lat.cells);
                have_baseline = true;
            }
        }
    }
}

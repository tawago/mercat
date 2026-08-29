//! Unit tests for THE CORNER-CELL WRITER in `edges.zig`: the mask a turn
//! deposits at the point where the polyline bends, and what that mask does
//! to whatever the cell already carries.
//!
//! The walk skips `b` on every segment, so the corner cell is written once
//! per turn and never as a straight cell — which is what lets a turn onto a
//! SHARED rail stay `┴` instead of welding a phantom fourth arm. The same
//! rule is why ink already on the cell can only have come from somebody
//! else's run, or from an EARLIER visit of this edge's own route, and both
//! survive the turn.
//!
//! Split from `edges_test.zig`, at the 500-line cap. Imports: `std`,
//! `sketch.zig`, `lattice.zig`, `edges.zig`, `base/ledger.zig`.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const edges = @import("edges.zig");
const ledger = @import("../base/ledger.zig");

const testing = std.testing;

fn makeLattice(allocator: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try allocator.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn makeSketch(es: []const sketch.EdgePath) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 16, .h = 16 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = es,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn makeEdge(id: u32, pts: []const sketch.Point) sketch.EdgePath {
    return .{
        .id = id,
        .from = 0,
        .to = 1,
        .polyline = pts,
        .port_from = .{ .node = 0, .side = .east, .offset = 0 },
        .port_to = .{ .node = 1, .side = .west, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .solid,
    };
}

test "L-shaped corner has reverse-incoming + outgoing bits" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 10, 10);
    defer a.free(lat.cells);

    const pts = [_]sketch.Point{
        .{ .x = 2, .y = 2 },
        .{ .x = 2, .y = 6 },
        .{ .x = 6, .y = 6 },
    };
    const es = [_]sketch.EdgePath{makeEdge(7, &pts)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    const corner = lat.atConst(2, 6);
    try testing.expect(switch (corner.occupant) {
        .edge_segment => |seg| seg.edge == 7,
        else => false,
    });
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true }).toMask(),
        corner.neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .s = true }).toMask(),
        lat.atConst(2, 3).neighbours.toMask(),
    );
    try testing.expectEqual(
        (lattice.Neighbours{ .e = true, .w = true }).toMask(),
        lat.atConst(4, 6).neighbours.toMask(),
    );
}

test "a route that doubles back keeps both visits' arms at the cell it re-enters" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // The shape a back edge routed around its own source really takes: the
    // polyline turns north at (2,5), runs east, then RETURNS along that row
    // and turns north again at the very same cell. The second turn is a
    // corner onto this edge's OWN earlier ink — its {e,n} arms join the first
    // visit's {s,e} rather than displacing them, so the cell is ├ and the
    // riser coming up from the south still has an arm to meet.
    const pts = [_]sketch.Point{
        .{ .x = 1, .y = 7 }, .{ .x = 2, .y = 7 }, .{ .x = 2, .y = 5 },
        .{ .x = 8, .y = 5 }, .{ .x = 2, .y = 5 }, .{ .x = 2, .y = 3 },
    };
    const es = [_]sketch.EdgePath{makeEdge(2, &pts)};
    _ = try edges.rasterizeEdges(a, &lat, makeSketch(&es), .bridge, null);

    try testing.expectEqual(
        (lattice.Neighbours{ .n = true, .e = true, .s = true }).toMask(),
        lat.atConst(2, 5).neighbours.toMask(),
    );
    // The south arm is the one a replacing write drops, and it is exactly the
    // one the riser below reciprocates: without it the edge is cut from
    // itself and the run below the turn hangs off nothing.
    try testing.expect(lat.atConst(2, 6).neighbours.n);
    // The far turn of the doubling-back leg keeps its single arm: the return
    // trip is the same ink, not a second stroke.
    try testing.expectEqual(
        (lattice.Neighbours{ .w = true }).toMask(),
        lat.atConst(8, 5).neighbours.toMask(),
    );
}

test "shared rail corner: sibling drops bending at one cell yield ┴, not a phantom ┼" {
    const a = testing.allocator;
    var lat = try makeLattice(a, 12, 12);
    defer a.free(lat.cells);

    // Three `.forward` edges (an UNDETECTED fan: no fan role, so no rail
    // is ever named here and the fan-OUT strip never runs) descend a shared
    // source column to a common rail row (5), then bend to their own
    // columns. None continues SOUTH past the rail cell (5,5): the left
    // two bend west, the right one bends east. The rail cell must render
    // ┴ ({n,e,w}) — a phantom {s} here (drawn by a sibling's straight
    // endpoint before the corner rewrite) would falsely assert a fourth
    // arm and paint ┼.
    const a_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 2, .y = 5 }, .{ .x = 2, .y = 8 } };
    const b_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 4, .y = 5 }, .{ .x = 4, .y = 8 } };
    const c_pts = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 8, .y = 5 }, .{ .x = 8, .y = 8 } };
    const es = [_]sketch.EdgePath{
        makeEdge(1, &a_pts),
        makeEdge(2, &b_pts),
        makeEdge(3, &c_pts),
    };
    // They share the rail legally (one bundle), so the crossing rule
    // exempts them and the phantom-arm question is the one under test.
    const members = [_]ledger.EdgeId{ 1, 2, 3 };
    const bundle_sets = [_]ledger.Bundle{.{ .origin = .fan_rail, .members = &members }};
    var s = makeSketch(&es);
    s.bundle_sets = &bundle_sets;
    _ = try edges.rasterizeEdges(a, &lat, s, .bridge, null);

    // Rail cell: north riser + east/west rail, NO south arm.
    const rail = lat.atConst(5, 5).neighbours;
    try testing.expect(rail.n and rail.e and rail.w);
    try testing.expect(!rail.s);

    // Contrast: a real sibling drop keeps its south arm (┬ at the bending
    // column), proving the fix suppresses only the phantom, not real drops.
    const drop = lat.atConst(4, 5).neighbours;
    try testing.expect(drop.s);
}

//! Unit tests for raster/labels_onrun.zig — RULE A (edge-only interrupt),
//! RULE B (flanked resumption), lateral isolation, and determinism of the
//! on-run fan-dropper label candidate.

const std = @import("std");
const sketch = @import("../sketch.zig");
const lattice = @import("../lattice.zig");
const onrun = @import("labels_onrun.zig");

const testing = std.testing;

fn makeLattice(alloc: std.mem.Allocator, w: u32, h: u32) !lattice.Lattice {
    const cells = try alloc.alloc(lattice.Cell, @as(usize, w) * @as(usize, h));
    for (cells) |*c| c.* = lattice.Cell.empty;
    return .{ .width = w, .height = h, .cells = cells };
}

fn emptySketch(bw: u32, bh: u32) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = bw, .h = bh },
        .direction = .TD,
        .nodes = &[_]sketch.NodePlacement{},
        .clusters = &[_]sketch.ClusterFrame{},
        .edges = &[_]sketch.EdgePath{},
        .diagnostics = &[_]sketch.Diagnostic{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn dropCell(lat: *lattice.Lattice, x: u32, y: u32, edge: u32, role: lattice.EdgeRole) void {
    lat.at(x, y).* = .{
        .occupant = .{ .edge_segment = .{ .edge = edge, .kind = .solid, .role = role } },
        .neighbours = .{ .n = true, .s = true },
    };
}

fn arrowCell(lat: *lattice.Lattice, x: u32, y: u32, edge: u32) void {
    lat.at(x, y).* = .{
        .occupant = .{ .arrowhead = .{ .dir = .south, .edge = edge } },
        .neighbours = .{ .n = true },
    };
}

fn labelCharAt(lat: lattice.Lattice, x: u32, y: u32) u21 {
    return switch (lat.atConst(x, y).occupant) {
        .label_char => |c| c,
        else => 0,
    };
}

/// A DECORATED (4-cell) fan-OUT tap dropper on column 5: crossbar row 1
/// (shared), dropper cells rows 2..4, arrowhead row 5, landing (node
/// border) row 6. Four private cells is the minimum the decorated
/// sandwich needs: flank, label, flank, head.
fn paintTapDropper(lat: *lattice.Lattice, edge: u32) void {
    dropCell(lat, 5, 1, edge, .fan_out_rail); // crossbar branch cell (shared)
    dropCell(lat, 5, 2, edge, .fan_out_dropper);
    dropCell(lat, 5, 3, edge, .fan_out_dropper);
    dropCell(lat, 5, 4, edge, .fan_out_dropper);
    arrowCell(lat, 5, 5, edge);
}

fn theTap(edge: u32) sketch.Tap {
    return .{ .edge = edge, .node = 1, .at = .{ .x = 5, .y = 1 }, .landing = .{ .x = 5, .y = 6 }, .label = "ok" };
}

fn theRail(taps: []const sketch.Tap, stem: []const sketch.Point) sketch.Rail {
    return .{
        .pivot = 0,
        .stem = stem,
        .crossbar = .{ .{ .x = 2, .y = 1 }, .{ .x = 8, .y = 1 } },
        .taps = taps,
        .kind = .solid,
        .role = .fan_out_dropper,
    };
}

const stem_pts = [_]sketch.Point{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 1 } };

test "happy path: the label interrupts its own dropper for one row, sandwiched by run flanks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 12, 9);
    paintTapDropper(&lat, 7);
    const taps = [_]sketch.Tap{theTap(7)};
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    try testing.expect(onrun.tryOnRunTap(&lat, s, taps[0], "ok", null));

    // Label centered on the dropper column: interruption row is the middle
    // of the private stretch (rows 2..5 -> row 3).
    try testing.expectEqual(@as(u21, 'o'), labelCharAt(lat, 5, 3));
    try testing.expectEqual(@as(u21, 'k'), labelCharAt(lat, 6, 3));

    // Both flanks are LINE cells of the run — never the arrowhead, which
    // stays below the lower flank.
    const above = lat.atConst(5, 2);
    try testing.expect(above.occupant == .edge_segment);
    const below = lat.atConst(5, 4);
    try testing.expect(below.occupant == .edge_segment);
    try testing.expect(lat.atConst(5, 5).occupant == .arrowhead);
}

test "the flanks stay ORDINARY full-stroke run cells in the edge's own kind" {
    // Reverted experiment (blind decoder veto): the label-adjacent cells
    // once tapered to `╵`/`╷` half strokes, and the decoder read the taper
    // as a dashed line STYLE, reconstructing solid edges as dotted. The
    // flanks must therefore keep BOTH vertical bits and their own stroke
    // kind, so the run around a label reads exactly as it did without one.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 12, 9);
    paintTapDropper(&lat, 7);
    for ([_]u32{ 1, 2, 3, 4 }) |y| {
        lat.at(5, y).stroke_kind = .dotted;
        lat.at(5, y).occupant.edge_segment.kind = .dotted;
    }
    const taps = [_]sketch.Tap{theTap(7)};
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    try testing.expect(onrun.tryOnRunTap(&lat, s, taps[0], "ok", null));

    for ([_]u32{ 2, 4 }) |y| {
        const c = lat.atConst(5, y);
        // Both vertical bits survive: the painter emits the full glyph.
        try testing.expect(c.neighbours.n);
        try testing.expect(c.neighbours.s);
        // And the edge's own stroke kind is untouched.
        try testing.expectEqual(lattice.EdgeKind.dotted, c.stroke_kind);
        try testing.expectEqual(lattice.EdgeKind.dotted, c.occupant.edge_segment.kind);
    }
}

test "RULE B: an arrowhead is not a flank, so the head-adjacent row is refused" {
    // The UNDECORATED 3-cell shape (flank, label, head) used to pass under
    // the old rule where an arrowhead counted as a flank. It must now be
    // refused outright and fall to the ordinary labels_edge ladder.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 12, 9);
    dropCell(&lat, 5, 1, 7, .fan_out_rail); // shared crossbar
    dropCell(&lat, 5, 2, 7, .fan_out_dropper);
    dropCell(&lat, 5, 3, 7, .fan_out_dropper);
    arrowCell(&lat, 5, 4, 7);
    const taps = [_]sketch.Tap{
        .{ .edge = 7, .node = 1, .at = .{ .x = 5, .y = 1 }, .landing = .{ .x = 5, .y = 5 }, .label = "ok" },
    };
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    // Row 3: below-flank is the arrowhead -> refused. Row 2: above-flank is
    // the shared crossbar -> refused. No legal row.
    try testing.expect(!onrun.tryOnRunTap(&lat, s, taps[0], "ok", null));
    try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 5, 3));
}

test "RULE A: a rail/crossbar cell is never interrupted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 12, 9);
    paintTapDropper(&lat, 7);
    // Poison the would-be interruption row with a SHARED role: everything
    // else stays legal, the role alone must refuse the candidate.
    dropCell(&lat, 5, 3, 7, .fan_out_rail);
    const taps = [_]sketch.Tap{theTap(7)};
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    // Row 3 refused (rail role); rows 2 and 4 have the poisoned rail cell
    // as a flank (also refused), and row 5 is the arrowhead. No legal row.
    try testing.expect(!onrun.tryOnRunTap(&lat, s, taps[0], "ok", null));
    try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 5, 3));
}

test "RULE A: a cell another tap's drop covers is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 12, 9);
    paintTapDropper(&lat, 7);
    const taps = [_]sketch.Tap{
        theTap(7),
        // A sibling tap whose declared drop covers the same column cells —
        // geometry-level sharing the lattice roles cannot see.
        .{ .edge = 9, .node = 2, .at = .{ .x = 5, .y = 1 }, .landing = .{ .x = 5, .y = 5 } },
    };
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    try testing.expect(!onrun.tryOnRunTap(&lat, s, taps[0], "ok", null));
    try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 5, 3));
}

test "RULE B: a 1-cell private dropper has no legal interruption row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 12, 9);
    // Crossbar at row 1, single dropper cell row 2, arrowhead row 3.
    dropCell(&lat, 5, 1, 7, .fan_out_rail);
    dropCell(&lat, 5, 2, 7, .fan_out_dropper);
    arrowCell(&lat, 5, 3, 7);
    const taps = [_]sketch.Tap{
        .{ .edge = 7, .node = 1, .at = .{ .x = 5, .y = 1 }, .landing = .{ .x = 5, .y = 4 }, .label = "ok" },
    };
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    // Row 2: above-flank is the shared crossbar cell (refused as flank).
    // Row 3: an arrowhead, not an interruptible segment. No legal row.
    try testing.expect(!onrun.tryOnRunTap(&lat, s, taps[0], "ok", null));
    try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 5, 2));
}

test "foreign ink beside the span still refuses the on-run candidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 12, 9);
    paintTapDropper(&lat, 7);
    // Foreign edge ink adjacent to where the span's last cell (col 6, row 3)
    // would sit: the lateral margin must hold.
    dropCell(&lat, 7, 3, 99, .forward);
    const taps = [_]sketch.Tap{theTap(7)};
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    // Row 3 refused by isolation; rows 2 and 4 have the foreign ink in their
    // span neighbourhood too; row 5 is the arrowhead. Refused.
    try testing.expect(!onrun.tryOnRunTap(&lat, s, taps[0], "ok", null));
    try testing.expectEqual(@as(u21, 0), labelCharAt(lat, 5, 3));
}

test "on-run placement over a routed polyline dropper (fan-IN member)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat = try makeLattice(a, 14, 8);
    // Private fan-IN descent on column 5, rows 1..3; corner bundles a rail
    // at row 4 (not painted here — flanks come from the descent itself).
    dropCell(&lat, 5, 1, 3, .fan_in_dropper);
    dropCell(&lat, 5, 2, 3, .fan_in_dropper);
    dropCell(&lat, 5, 3, 3, .fan_in_dropper);

    const poly = [_]sketch.Point{ .{ .x = 5, .y = 0 }, .{ .x = 5, .y = 4 }, .{ .x = 9, .y = 4 } };
    const ep: sketch.EdgePath = .{
        .id = 3,
        .from = 0,
        .to = 1,
        .polyline = &poly,
        .port_from = .{ .node = 0, .side = .south, .offset = 0 },
        .port_to = .{ .node = 1, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = "grpc",
        .kind = .solid,
        .role = .fan_in_dropper,
    };
    var s = emptySketch(14, 8);
    const edges = [_]sketch.EdgePath{ep};
    s.edges = &edges;

    try testing.expect(onrun.tryOnRunEdge(&lat, s, ep, "grpc", null));
    // Interruption at the middle of rows 1..3 -> row 2, span centered on
    // column 5: start = 5 - (4-1)/2 = 4.
    try testing.expectEqual(@as(u21, 'g'), labelCharAt(lat, 4, 2));
    try testing.expectEqual(@as(u21, 'r'), labelCharAt(lat, 5, 2));
    try testing.expectEqual(@as(u21, 'p'), labelCharAt(lat, 6, 2));
    try testing.expectEqual(@as(u21, 'c'), labelCharAt(lat, 7, 2));
    // Flanks intact: full strokes, both vertical bits.
    try testing.expect(lat.atConst(5, 1).neighbours.s);
    try testing.expect(lat.atConst(5, 3).neighbours.n);
}

test "determinism: identical inputs place identically" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lat1 = try makeLattice(a, 12, 9);
    var lat2 = try makeLattice(a, 12, 9);
    paintTapDropper(&lat1, 7);
    paintTapDropper(&lat2, 7);
    const taps = [_]sketch.Tap{theTap(7)};
    var s = emptySketch(12, 9);
    const rails = [_]sketch.Rail{theRail(&taps, &stem_pts)};
    s.rails = &rails;

    try testing.expect(onrun.tryOnRunTap(&lat1, s, taps[0], "ok", null));
    try testing.expect(onrun.tryOnRunTap(&lat2, s, taps[0], "ok", null));
    for (lat1.cells, lat2.cells) |c1, c2| {
        try testing.expect(std.meta.eql(c1, c2));
    }
}

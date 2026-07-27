//! Tests for routing_terminal.zig's base-approach LENGTHEN pass.
//!
//! `ensureBaseApproachLengthen` promotes a "corner-fed" terminal (a
//! perpendicular run turning at a corner that sits directly on the
//! arrowhead's base cell — a final leg of length exactly 2) into a formal
//! `[corner][straight][arrow]` approach by pulling the corner back one cell,
//! but ONLY when a clear collinear cell exists to grow into (zero-height,
//! accept-fallback otherwise). The lookup helpers re-exported here are
//! exercised end-to-end through `buildEdges` in routing_test.zig.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const rt = @import("routing_terminal.zig");
const testing = std.testing;

fn mkPlacement(id: sketch.NodeId, rect: sketch.Rect) sketch.NodePlacement {
    return .{ .id = id, .rect = rect, .shape = .rect, .lines = &.{}, .cluster_id = null };
}

// Minimal geom view: terminalApproachExtraRows only reads .x and .w.
const G = struct { x: i32, w: u32 };

fn mkGraph(edges: []const sg.Edge) sg.SemGraph {
    return .{
        .direction = .TD,
        .nodes = &.{},
        .edges = edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
}

test "terminalApproachExtraRows flags a bare gap with an offset adjacent forward terminal but not a column-aligned one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two real nodes, one adjacent forward edge 0→1 (S at layer 0, T at layer 1).
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 } };
    var l0 = [_]u32{0};
    var l1 = [_]u32{1};
    var layers = [_][]u32{ l0[0..], l1[0..] };
    var edges = [_]sugiyama.LayerEdge{.{ .from = 0, .to = 1, .edge = 0, .reversed = false }};
    const lg: sugiyama.LayeredGraph = .{
        .nodes = nodes[0..],
        .layers = layers[0..],
        .edges = edges[0..],
        .reversed_edges = &.{},
        .real_index = .empty,
        .arena = null,
    };
    const graph_edges = [_]sg.Edge{.{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null }};
    const graph = mkGraph(graph_edges[0..]);

    // Offset: centers 5 vs 25 differ ⇒ the terminal approach turns ⇒ +1 row.
    const offset_geom = [_]G{ .{ .x = 0, .w = 10 }, .{ .x = 20, .w = 10 } };
    const offset = try rt.terminalApproachExtraRows(G, a, graph, lg, offset_geom[0..]);
    try testing.expectEqual(@as(usize, 1), offset.len);
    try testing.expectEqual(@as(u32, 1), offset[0]);

    // Column-aligned: centers 5 vs 5 match ⇒ straight descent ⇒ no extra row.
    const aligned_geom = [_]G{ .{ .x = 0, .w = 10 }, .{ .x = 0, .w = 10 } };
    const aligned = try rt.terminalApproachExtraRows(G, a, graph, lg, aligned_geom[0..]);
    try testing.expectEqual(@as(u32, 0), aligned[0]);

    // Reversed (back-edge) and arrowhead-free segments never reserve, even offset.
    var rev_edges = [_]sugiyama.LayerEdge{.{ .from = 0, .to = 1, .edge = 0, .reversed = true }};
    const rev_lg: sugiyama.LayeredGraph = .{ .nodes = nodes[0..], .layers = layers[0..], .edges = rev_edges[0..], .reversed_edges = &.{}, .real_index = .empty, .arena = null };
    const rev = try rt.terminalApproachExtraRows(G, a, graph, rev_lg, offset_geom[0..]);
    try testing.expectEqual(@as(u32, 0), rev[0]);

    const no_arrow = [_]sg.Edge{.{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null }};
    const na = try rt.terminalApproachExtraRows(G, a, mkGraph(no_arrow[0..]), lg, offset_geom[0..]);
    try testing.expectEqual(@as(u32, 0), na[0]);
}

test "ensureBaseApproachLengthen grows a corner-fed len-2 final into a straight base approach" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Target box (id=1) has a north port at x=10; the terminal is (10,10).
    // The route descends (id-0 source region), turns horizontal at y=8, then
    // drops the final 2 cells into the port — a corner directly on the base.
    const target = mkPlacement(1, .{ .x = 3, .y = 10, .w = 20, .h = 3 });
    const placements = [_]sketch.NodePlacement{target};
    var poly = [_]sketch.Point{
        .{ .x = 4, .y = 5 }, // q: interior vertex above p (along the base axis)
        .{ .x = 4, .y = 8 }, // p: start of the perpendicular (horizontal) run
        .{ .x = 10, .y = 8 }, // b: the corner (turn from horizontal into the final descent)
        .{ .x = 10, .y = 10 }, // c: terminal port border (final leg length 2)
    };
    const grown = try rt.ensureBaseApproachLengthen(a, &poly, &placements, false);
    // A fresh slice (the input is retained for revert), corner pulled up one
    // row so the final leg is now length 3: [corner (10,7)][straight][arrow].
    try testing.expect(grown.ptr != (&poly).ptr);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 7 }, grown[1]);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 7 }, grown[2]);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 10 }, grown[3]);
    // Final leg is a clean 3-cell vertical descent (base cell behind the tip
    // is now a straight stroke, not the corner).
    try testing.expectEqual(@as(i32, 3), grown[3].y - grown[2].y);
    try testing.expectEqual(grown[2].x, grown[3].x);
}

test "ensureBaseApproachLengthen accept-fallback: no clear cell leaves the polyline untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A foreign box (id=2) occupies the row the pulled-back run would use
    // (y=7 across x=4..10), so the grow is refused and the residual is left
    // for the report-only validator.
    const target = mkPlacement(1, .{ .x = 3, .y = 10, .w = 20, .h = 3 });
    const blocker = mkPlacement(2, .{ .x = 4, .y = 6, .w = 10, .h = 3 }); // covers y=6..8
    const placements = [_]sketch.NodePlacement{ target, blocker };
    var poly = [_]sketch.Point{
        .{ .x = 4, .y = 5 },
        .{ .x = 4, .y = 8 },
        .{ .x = 10, .y = 8 },
        .{ .x = 10, .y = 10 },
    };
    const result = try rt.ensureBaseApproachLengthen(a, &poly, &placements, false);
    try testing.expectEqual((&poly).ptr, result.ptr);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 8 }, poly[1]);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 8 }, poly[2]);
}

test "ensureBaseApproachLengthen is a no-op for a formal (length-3) or turn-at-tip (length-1) final" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sketch.NodePlacement{mkPlacement(1, .{ .x = 3, .y = 10, .w = 20, .h = 3 })};

    // Already-formal: final leg length 3, base cell is straight -> untouched.
    var formal = [_]sketch.Point{ .{ .x = 4, .y = 5 }, .{ .x = 4, .y = 7 }, .{ .x = 10, .y = 7 }, .{ .x = 10, .y = 10 } };
    const r1 = try rt.ensureBaseApproachLengthen(a, &formal, &placements, false);
    try testing.expectEqual((&formal).ptr, r1.ptr);

    // Length-1 turn-at-tip is ensureBaseStub's job, not this pass -> untouched.
    var tip = [_]sketch.Point{ .{ .x = 4, .y = 8 }, .{ .x = 10, .y = 8 }, .{ .x = 10, .y = 9 } };
    const r2 = try rt.ensureBaseApproachLengthen(a, &tip, &placements, false);
    try testing.expectEqual((&tip).ptr, r2.ptr);
}

test "ensureSourceBaseApproach mirrors the base-approach passes onto the source end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The exact mirror of the LENGTHEN fixture above, written source-first:
    // source box (id=1) has a south port at (10,10)... reflected, the route
    // leaves the source at (10,13), rises 2 cells to a corner at (10,11) and
    // turns horizontal — a corner directly on the SOURCE head's base cell.
    const source = mkPlacement(1, .{ .x = 3, .y = 10, .w = 20, .h = 3 });
    const placements = [_]sketch.NodePlacement{source};
    var poly = [_]sketch.Point{
        .{ .x = 10, .y = 13 }, // source port border cell (raster skips it)
        .{ .x = 10, .y = 15 }, // corner sitting ON the head's base cell
        .{ .x = 4, .y = 15 }, // perpendicular run away from the source
        .{ .x = 4, .y = 18 }, // interior vertex (the target attachment side)
    };
    const grown = try rt.ensureSourceBaseApproach(a, &poly, &placements, 1, 9, true);
    try testing.expect(grown.ptr != (&poly).ptr);
    // Corner pushed one cell further from the source: the first leg is now a
    // length-3 straight run, so the head at (10,14) has a straight base.
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 13 }, grown[0]);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 16 }, grown[1]);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 16 }, grown[2]);
    // The TARGET attachment (last point) never moves — the mirror of the
    // forward pass's "index 0 is untouchable" rule.
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 18 }, grown[3]);
    // Input retained intact for a clearance-driven revert.
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 15 }, poly[1]);
}

test "ensureSourceBaseApproach shifts a source turn-at-tip and no-ops on a formal source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sketch.NodePlacement{mkPlacement(1, .{ .x = 3, .y = 0, .w = 5, .h = 3 })};

    // Turn-at-tip at the SOURCE: the first leg is a single cell, so the head
    // would sit ON the corner. The stub pass shifts the run one cell away.
    // Four points, so the shifted run (indices 1..2 counting from the source)
    // stays clear of the target attachment at index 3.
    var tip = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 3 }, .{ .x = 12, .y = 3 }, .{ .x = 12, .y = 9 } };
    const shifted = try rt.ensureSourceBaseApproach(a, &tip, &placements, 1, 9, true);
    try testing.expect(shifted.ptr != (&tip).ptr);
    try testing.expectEqual(sketch.Point{ .x = 5, .y = 2 }, shifted[0]);
    try testing.expectEqual(sketch.Point{ .x = 5, .y = 4 }, shifted[1]);
    try testing.expectEqual(sketch.Point{ .x = 12, .y = 4 }, shifted[2]);
    try testing.expectEqual(sketch.Point{ .x = 12, .y = 9 }, shifted[3]);

    // Already formal (first leg length 3): neither pass fires, same pointer.
    var formal = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 5 }, .{ .x = 12, .y = 5 }, .{ .x = 12, .y = 9 } };
    const r = try rt.ensureSourceBaseApproach(a, &formal, &placements, 1, 9, true);
    try testing.expectEqual((&formal).ptr, r.ptr);
}

test "ensureSourceBaseApproach never moves the target attachment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sketch.NodePlacement{mkPlacement(1, .{ .x = 3, .y = 0, .w = 5, .h = 3 })};

    // THREE-point turn-at-tip. Reversed, the stub's own floor (bi >= 1) would
    // happily write rev[0] — i.e. drag the TARGET port (12,3) to (12,4) and
    // detach the arrival. The shared bi >= 2 pre-gate refuses the whole pass.
    var tip3 = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 3 }, .{ .x = 12, .y = 3 } };
    const r3 = try rt.ensureSourceBaseApproach(a, &tip3, &placements, 1, 9, true);
    try testing.expectEqual((&tip3).ptr, r3.ptr);
    try testing.expectEqual(sketch.Point{ .x = 12, .y = 3 }, tip3[2]);

    // FOUR-point lengthen whose pulled-back run would land one cell from the
    // target port — on the far head's own cell. `far_head` reserves it.
    // (Same fixture with far_head = false still grows, so the refusal is the
    //  reserve talking, not an unrelated gate.)
    var crowd = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 4 }, .{ .x = 12, .y = 4 }, .{ .x = 12, .y = 6 } };
    const r4 = try rt.ensureSourceBaseApproach(a, &crowd, &placements, 1, 9, true);
    try testing.expectEqual((&crowd).ptr, r4.ptr);
    const r5 = try rt.ensureSourceBaseApproach(a, &crowd, &placements, 1, 9, false);
    try testing.expect(r5.ptr != (&crowd).ptr);
    try testing.expectEqual(sketch.Point{ .x = 5, .y = 5 }, r5[1]);
    try testing.expectEqual(sketch.Point{ .x = 12, .y = 5 }, r5[2]);
    try testing.expectEqual(sketch.Point{ .x = 12, .y = 6 }, r5[3]);
}

test "ensureBaseApproachLengthen keeps a far-end head's base cell clear when far_head is set" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const target = mkPlacement(1, .{ .x = 3, .y = 10, .w = 20, .h = 3 });
    const placements = [_]sketch.NodePlacement{target};
    // q is poly[0] (bi == 2): the source port of a source-decorated edge. Its
    // own head sits at y=6 and that head's base at y=7, so pulling the run to
    // y=6 would erase it. Grows freely when the far end carries no head.
    var poly = [_]sketch.Point{
        .{ .x = 4, .y = 5 }, // q == poly[0]: far attachment (carries a head)
        .{ .x = 4, .y = 7 },
        .{ .x = 10, .y = 7 },
        .{ .x = 10, .y = 9 }, // final leg length 2 -> corner-fed terminal
    };
    const kept = try rt.ensureBaseApproachLengthen(a, &poly, &placements, true);
    try testing.expectEqual((&poly).ptr, kept.ptr);
    const grown = try rt.ensureBaseApproachLengthen(a, &poly, &placements, false);
    try testing.expect(grown.ptr != (&poly).ptr);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 6 }, grown[1]);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 6 }, grown[2]);
}

test "ensureSourceBaseApproach refuses a stub shift that would collapse the target's approach leg" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sketch.NodePlacement{
        mkPlacement(1, .{ .x = 8, .y = 3, .w = 5, .h = 3 }), // source, port (10,5)
        mkPlacement(9, .{ .x = 2, .y = 7, .w = 5, .h = 3 }), // target, port (4,7)
    };

    // Source-end turn-at-tip: reversed, the stub's shift moves rev[1] from
    // (4,6) onto (4,7) — rev[0], the TARGET port. The far leg collapses to zero
    // length and the target's arrival flips from vertical to horizontal, so the
    // terminal arrowhead would point along an axis the route never travelled.
    var poly = [_]sketch.Point{
        .{ .x = 10, .y = 5 }, // source port (the end being formalized)
        .{ .x = 10, .y = 6 }, // length-1 final leg on the reversed buffer
        .{ .x = 4, .y = 6 },
        .{ .x = 4, .y = 7 }, // target port
    };
    const kept = try rt.ensureSourceBaseApproach(a, &poly, &placements, 1, 9, true);
    try testing.expectEqual((&poly).ptr, kept.ptr);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 6 }, poly[1]);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 6 }, poly[2]);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 7 }, poly[3]);

    // Control: give the target's approach leg two cells of room instead of one
    // and the very same pass fires — the refusal above is the collapse guard,
    // not an unrelated gate.
    var roomy = [_]sketch.Point{
        .{ .x = 10, .y = 5 },
        .{ .x = 10, .y = 6 },
        .{ .x = 4, .y = 6 },
        .{ .x = 4, .y = 8 },
    };
    const grown = try rt.ensureSourceBaseApproach(a, &roomy, &placements, 1, 9, true);
    try testing.expect(grown.ptr != (&roomy).ptr);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 8 }, grown[grown.len - 1]);
}

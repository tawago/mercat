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
    const grown = try rt.ensureBaseApproachLengthen(a, &poly, &placements);
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
    const result = try rt.ensureBaseApproachLengthen(a, &poly, &placements);
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
    const r1 = try rt.ensureBaseApproachLengthen(a, &formal, &placements);
    try testing.expectEqual((&formal).ptr, r1.ptr);

    // Length-1 turn-at-tip is ensureBaseStub's job, not this pass -> untouched.
    var tip = [_]sketch.Point{ .{ .x = 4, .y = 8 }, .{ .x = 10, .y = 8 }, .{ .x = 10, .y = 9 } };
    const r2 = try rt.ensureBaseApproachLengthen(a, &tip, &placements);
    try testing.expectEqual((&tip).ptr, r2.ptr);
}

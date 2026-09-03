//! Tests for routing_terminal.zig's base-approach LENGTHEN pass.
//!
//! `satisfyApproach` promotes a "corner-fed" terminal (a
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

    const offset_geom = [_]G{ .{ .x = 0, .w = 10 }, .{ .x = 20, .w = 10 } };
    const offset = try rt.terminalApproachExtraRows(G, a, graph, lg, offset_geom[0..]);
    try testing.expectEqual(@as(usize, 1), offset.len);
    try testing.expectEqual(@as(u32, 1), offset[0]);

    const aligned_geom = [_]G{ .{ .x = 0, .w = 10 }, .{ .x = 0, .w = 10 } };
    const aligned = try rt.terminalApproachExtraRows(G, a, graph, lg, aligned_geom[0..]);
    try testing.expectEqual(@as(u32, 0), aligned[0]);

    var rev_edges = [_]sugiyama.LayerEdge{.{ .from = 0, .to = 1, .edge = 0, .reversed = true }};
    const rev_lg: sugiyama.LayeredGraph = .{ .nodes = nodes[0..], .layers = layers[0..], .edges = rev_edges[0..], .reversed_edges = &.{}, .real_index = .empty, .arena = null };
    const rev = try rt.terminalApproachExtraRows(G, a, graph, rev_lg, offset_geom[0..]);
    try testing.expectEqual(@as(u32, 0), rev[0]);

    const no_arrow = [_]sg.Edge{.{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null }};
    const na = try rt.terminalApproachExtraRows(G, a, mkGraph(no_arrow[0..]), lg, offset_geom[0..]);
    try testing.expectEqual(@as(u32, 0), na[0]);

    // A decorated end on either side needs the row: a bidirectional edge and
    // a source-only decoration both keep a terminal cell straight.
    const both = [_]sg.Edge{.{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .filled, .arrow_to = .filled, .label = null }};
    const bi = try rt.terminalApproachExtraRows(G, a, mkGraph(both[0..]), lg, offset_geom[0..]);
    try testing.expectEqual(@as(u32, 1), bi[0]);
    const source_only = [_]sg.Edge{.{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .filled, .arrow_to = .none, .label = null }};
    const so = try rt.terminalApproachExtraRows(G, a, mkGraph(source_only[0..]), lg, offset_geom[0..]);
    try testing.expectEqual(@as(u32, 1), so[0]);
}

test "terminalsStraight refuses a turn inside a decorated terminal cell at either end and admits one two cells out" {
    const turn_in_departure = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 3 }, .{ .x = 9, .y = 3 }, .{ .x = 9, .y = 8 } };
    try testing.expect(!rt.terminalsStraight(&turn_in_departure, .{ .from = true }));
    try testing.expect(rt.terminalsStraight(&turn_in_departure, .{ .to = true }));
    try testing.expect(rt.terminalsStraight(&turn_in_departure, .{}));

    const turn_in_arrival = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 7 }, .{ .x = 9, .y = 7 }, .{ .x = 9, .y = 8 } };
    try testing.expect(!rt.terminalsStraight(&turn_in_arrival, .{ .to = true }));
    try testing.expect(rt.terminalsStraight(&turn_in_arrival, .{ .from = true }));

    const two_out = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 4 }, .{ .x = 9, .y = 4 }, .{ .x = 9, .y = 8 } };
    try testing.expect(rt.terminalsStraight(&two_out, .{ .from = true, .to = true }));

    // Collinear consecutive legs are one run: the turn is two cells out.
    const collinear = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 3 }, .{ .x = 5, .y = 4 }, .{ .x = 9, .y = 4 }, .{ .x = 9, .y = 8 } };
    try testing.expect(rt.terminalsStraight(&collinear, .{ .from = true, .to = true }));

    // A straight two-point route has no turn at all.
    const straight = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 8 } };
    try testing.expect(rt.terminalsStraight(&straight, .{ .from = true, .to = true }));
}

test "satisfyApproach grows a corner-fed len-2 final into a straight base approach" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const target = mkPlacement(1, .{ .x = 3, .y = 10, .w = 20, .h = 3 });
    const placements = [_]sketch.NodePlacement{target};
    var poly = [_]sketch.Point{
        .{ .x = 4, .y = 5 },
        .{ .x = 4, .y = 8 },
        .{ .x = 10, .y = 8 },
        .{ .x = 10, .y = 10 },
    };
    const grown = try rt.satisfyApproach(a, &poly, &placements);
    try testing.expect(grown.ptr != (&poly).ptr);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 7 }, grown[1]);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 7 }, grown[2]);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 10 }, grown[3]);
    try testing.expectEqual(@as(i32, 3), grown[3].y - grown[2].y);
    try testing.expectEqual(grown[2].x, grown[3].x);
}

test "satisfyApproach accept-fallback: no clear cell leaves the polyline untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const target = mkPlacement(1, .{ .x = 3, .y = 10, .w = 20, .h = 3 });
    const blocker = mkPlacement(2, .{ .x = 4, .y = 6, .w = 10, .h = 3 });
    const placements = [_]sketch.NodePlacement{ target, blocker };
    var poly = [_]sketch.Point{
        .{ .x = 4, .y = 5 },
        .{ .x = 4, .y = 8 },
        .{ .x = 10, .y = 8 },
        .{ .x = 10, .y = 10 },
    };
    const result = try rt.satisfyApproach(a, &poly, &placements);
    try testing.expectEqual((&poly).ptr, result.ptr);
    try testing.expectEqual(sketch.Point{ .x = 4, .y = 8 }, poly[1]);
    try testing.expectEqual(sketch.Point{ .x = 10, .y = 8 }, poly[2]);
}

test "satisfyApproach is a no-op for a formal (length-3) or turn-at-tip (length-1) final" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sketch.NodePlacement{mkPlacement(1, .{ .x = 3, .y = 10, .w = 20, .h = 3 })};

    var formal = [_]sketch.Point{ .{ .x = 4, .y = 5 }, .{ .x = 4, .y = 7 }, .{ .x = 10, .y = 7 }, .{ .x = 10, .y = 10 } };
    const r1 = try rt.satisfyApproach(a, &formal, &placements);
    try testing.expectEqual((&formal).ptr, r1.ptr);

    var tip = [_]sketch.Point{ .{ .x = 4, .y = 8 }, .{ .x = 10, .y = 8 }, .{ .x = 10, .y = 9 } };
    const r2 = try rt.satisfyApproach(a, &tip, &placements);
    try testing.expectEqual((&tip).ptr, r2.ptr);
}

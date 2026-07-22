//! Tests for `back_edges.zig`. Split out of the former misc grab-bag test
//! file (since dissolved) into back_edges.zig's own sibling, per the
//! mermaid_v2/ test-file convention. Discovered via back_edges.zig's
//! top-level `test { _ = @import("back_edges_test.zig"); }` block.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const back_edges = @import("back_edges.zig");
const routing = @import("routing.zig");

const testing = std.testing;
const NodeGeom = routing.NodeGeom;

// ---------------------------------------------------------------------
// back_edges.zig: span-ascending sort biases nested loops onto the shared
// innermost rail (near line 108)
// ---------------------------------------------------------------------
// Chain A0->A1->...->A7 (layers 0..7, TD) plus three back edges:
//   E_big: A7->A0   (span 7, encloses both of the below)
//   E1:    A2->A1   (span 1)
//   E2:    A6->A5   (span 1, disjoint from E1)
// Declared in DESCENDING span order (E_big before E1/E2) so the observed
// lane split can only come from the explicit span-ascending sort inside
// `allocateBackEdgeRails`, not from declaration order.
test "allocateBackEdgeRails: span-ascending sort shares the innermost rail between disjoint short loops" {
    const a = testing.allocator;
    const N = 8;
    var nodes_buf: [N]sg.Node = undefined;
    for (0..N) |i| {
        nodes_buf[i] = .{
            .id = @intCast(i),
            .raw_id = "n",
            .label = "n",
            .shape = .rect,
            .classes = &.{},
            .cluster = null,
        };
    }
    var edges_buf: [7 + 3]sg.Edge = undefined;
    for (0..N - 1) |i| {
        edges_buf[i] = .{ .id = @intCast(i), .from = @intCast(i), .to = @intCast(i + 1), .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    }
    // Back edges, declared span-descending: E_big (7), E1 (1), E2 (1).
    const e_big_id: sg.EdgeId = 100;
    const e1_id: sg.EdgeId = 101;
    const e2_id: sg.EdgeId = 102;
    edges_buf[7] = .{ .id = e_big_id, .from = 7, .to = 0, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[8] = .{ .id = e1_id, .from = 2, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[9] = .{ .id = e2_id, .from = 6, .to = 5, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };

    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes_buf,
        .edges = &edges_buf,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(a, graph);
    defer lg.deinit(a);
    try testing.expectEqual(@as(usize, N), lg.layerCount());

    var geom: [N]NodeGeom = undefined;
    var placements: [N]sketch.NodePlacement = undefined;
    for (0..N) |i| {
        const y: i32 = @intCast(i * 4);
        geom[i] = .{ .x = 0, .y = y, .w = 3, .h = 3, .layer = @intCast(i) };
        placements[i] = .{ .id = @intCast(i), .rect = .{ .x = 0, .y = y, .w = 3, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    }

    const rails = try back_edges.allocateBackEdgeRails(a, graph, lg, &geom, &placements);
    defer a.free(rails);

    const r_big = back_edges.findRail(rails, e_big_id);
    const r1 = back_edges.findRail(rails, e1_id);
    const r2 = back_edges.findRail(rails, e2_id);

    // The two mutually-disjoint short (span-1) loops share ONE innermost
    // rail; the big enclosing loop is pushed to a strictly farther rail.
    try testing.expectEqual(r1, r2);
    try testing.expect(r_big > r1);
}

//! Tests for `spacing.zig`. Split out of the former misc grab-bag test
//! file (since dissolved) into spacing.zig's own sibling, per the
//! mermaid_v2/ test-file convention. Discovered via spacing.zig's
//! top-level `test { _ = @import("spacing_test.zig"); }` block.

const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const spacing = @import("spacing.zig");

const testing = std.testing;

// ---------------------------------------------------------------------
// spacing.zig: clusterHPad <-> prim.framePadX lockstep (near line 39)
// ---------------------------------------------------------------------
// `clusterHPad` is a one-line forward to `prim.framePadX`; `cluster/stitch`
// zone rules forbid layout/ from importing cluster/, so the OTHER half of
// the lockstep (`cluster/stitch.superSize` using the SAME `framePadX`) is
// covered separately by `recurse_test.zig`'s
// "nested cluster: outer super-node pad tracks framePadX(scale) across two
// recursion levels" test. This test locks the layout/ side to the shared
// primitive so the two halves can't silently drift apart.
test "clusterHPad forwards prim.framePadX exactly, at every scale" {
    for ([_]u8{ 0, 1, 2, 3 }) |scale| {
        try testing.expectEqual(prim.framePadX(scale), spacing.clusterHPad(scale));
    }
}

// ---------------------------------------------------------------------
// spacing.zig: interLayerSpacing's absolute floor (near line 286)
// ---------------------------------------------------------------------
test "interLayerSpacing: interior intra-cluster edge floors a base=2 gap to 3" {
    const nodes = [_]sg.Node{
        .{ .id = 1, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 10 },
        .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 10 },
    };
    const edges = [_]sg.Edge{
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const clusters = [_]sg.Cluster{
        .{ .id = 10, .raw_id = "S", .label = "S", .parent = null, .members = &.{ 1, 2 }, .sub_clusters = &.{} },
    };
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, graph);
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), lg.layerCount());
    // base=2: both the TD/BT direct path and the small transposed-subgraph
    // path use this base; the interior floor (3) must still win.
    try testing.expectEqual(@as(u32, 3), spacing.interLayerSpacing(graph, lg, 0, 1, 2));
    // Sanity: a non-interior (no same-cluster edge crossing the gap) base
    // is returned unchanged, so the floor only fires for the claimed case.
    try testing.expectEqual(@as(u32, 2), spacing.interLayerSpacing(graph, lg, 1, 5, 2));
}

// ---------------------------------------------------------------------
// spacing.zig: cluster-boundary vertical banding avoids a frame/feeder
// collision at cluster entry (near line 316)
// ---------------------------------------------------------------------
test "addClusterBandReservations: cluster entry band clears a non-member feeder row" {
    const a = testing.allocator;
    const nodes = [_]sg.Node{
        .{ .id = 1, .raw_id = "F", .label = "F", .shape = .rect, .classes = &.{}, .cluster = null }, // feeder, layer 0
        .{ .id = 2, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 10 }, // cluster entry, layer 1
    };
    const edges = [_]sg.Edge{
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const clusters = [_]sg.Cluster{
        .{ .id = 10, .raw_id = "S", .label = "S", .parent = null, .members = &.{2}, .sub_clusters = &.{} },
    };
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(a, graph);
    defer lg.deinit(a);
    try testing.expectEqual(@as(usize, 2), lg.layerCount());

    // One gap (layer 0 -> layer 1), starting at a small connector-only base.
    var gaps = try a.alloc(u32, 1);
    defer a.free(gaps);
    const base: u32 = 1;
    gaps[0] = base;
    try spacing.addClusterBandReservations(a, graph, lg, gaps);

    // The reservation must add exactly one frame band (border+inset) on
    // top of the base connector gap, not replace it.
    const band = 2; // frameBandThickness(.TD) = 1 border + 1 V_INSET
    try testing.expectEqual(base + band, gaps[0]);

    // Concrete geometry check: lay out both rows using the reserved gap and
    // confirm the cluster's leading border row (member_top - band) never
    // rises above the feeder row's bottom edge (no collision), and in fact
    // lands exactly on the base connector gap past it (tight, no waste).
    const feeder_h: i32 = 3;
    const feeder_bottom: i32 = 0 + feeder_h;
    const member_top: i32 = feeder_bottom + @as(i32, @intCast(gaps[0]));
    const frame_border_row: i32 = member_top - band;
    try testing.expect(frame_border_row >= feeder_bottom);
    try testing.expectEqual(feeder_bottom + @as(i32, @intCast(base)), frame_border_row);
}

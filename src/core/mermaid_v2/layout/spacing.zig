//! Cluster-aware spacing helpers for `layout.zig`.
//!
//! `intraLayerExtra` returns EXTRA horizontal cells (beyond the per-pair
//! `h_spacing` already added by `assignInitialX`) needed between two
//! adjacent same-layer nodes so any cluster borders they belong to keep
//! minimum whitespace: 0 if both ungrouped or sharing/nesting a cluster;
//! a sibling-gap reservation if in distinct clusters; a smaller
//! reservation if only one side is grouped.
//!
//! `interLayerSpacing` returns the gap between layer L and L+1, widened
//! to a small floor only for interior intra-cluster edges;
//! cluster-boundary bands are reserved separately by
//! `addClusterBandReservations`.
//!
//! Allowed imports (tools/lint_imports.zig): the layout zone — `std`,
//! `prim`, the `base/` no-deps tier, `../sem_graph.zig`, `sketch.zig`, and
//! layout-internal siblings. Actually imports `std`, `prim`,
//! `../sem_graph.zig`, `sugiyama.zig`.

const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");

/// Horizontal inflation each cluster rect grows beyond its members on
/// each side (1 cell border + 3 inset at scale 0). Mirrors `layout/clusters.H_INSET`
/// + 1 for the border itself. Scaled by `spacing_scale`, in lockstep with
/// super-node sizing (`cluster/stitch.superSize`) via the shared `prim.framePadX(scale)`. // @guarded-by: spacing_test.zig "clusterHPad forwards prim.framePadX exactly, at every scale"
pub fn clusterHPad(scale: u8) u32 {
    return prim.framePadX(scale);
}
/// Minimum whitespace cells between two adjacent sibling clusters'
/// inflated rects (matches `└──┘     ┌──` in `subgraph_level_edges`).
/// Scaled by `spacing_scale` under width pressure.
const SIBLING_GAP_BASE: u32 = 5;
/// Minimum whitespace cells between a cluster's inflated rect and an
/// adjacent ungrouped node rect. Scaled by `spacing_scale` under pressure.
const CLUSTER_NODE_GAP: u32 = 5;
/// Floor for a scaled gap so adjacent boxes/frames never collide.
const MIN_SCALED_GAP: u32 = 2;

/// Shrink a pure inter-node/inter-cluster gap by `scale` halvings, floored at
/// `MIN_SCALED_GAP`. `scale == 0` returns `gap` unchanged (natural rung).
/// Only the pure GAPS pass through here — frame insets (`CLUSTER_H_PAD`) do not.
fn scaledGap(gap: u32, scale: u8) u32 {
    if (scale == 0) return gap;
    var g = gap;
    var s = scale;
    while (s > 0) : (s -= 1) g /= 2;
    return @max(g, MIN_SCALED_GAP);
}
/// Default per-pair `h_spacing` consumed by `assignInitialX` between
/// any two same-layer nodes. We subtract this so `intraLayerExtra`
/// returns only the EXTRA cells beyond the baseline.
const BASE_H_SPACING: u32 = 4;

fn realNodeCluster(graph: sg.SemGraph, nid: sg.NodeId) ?sg.ClusterId {
    for (graph.nodes) |n| {
        if (n.id == nid) return nonSyntheticAncestor(graph, n.cluster);
    }
    return null;
}

/// A synthetic packing cluster (motif/pack.zig) has ZERO frame chrome, so
/// for spacing purposes a node inside one belongs to its nearest REAL
/// (non-synthetic) ancestor cluster — lockstep with the zero pad at the
/// stitch/superSize/sub-budget sites.
fn nonSyntheticAncestor(graph: sg.SemGraph, start: ?sg.ClusterId) ?sg.ClusterId {
    var cur = start;
    while (cur) |id| {
        const c = findCluster(graph, id) orelse return id;
        if (!c.synthetic) return id;
        cur = c.parent;
    }
    return null;
}

fn layerNodeCluster(graph: sg.SemGraph, n: sugiyama.LayerNode) ?sg.ClusterId {
    return switch (n) {
        .real => |nid| realNodeCluster(graph, nid),
        .virtual => null,
    };
}

fn findCluster(graph: sg.SemGraph, id: sg.ClusterId) ?sg.Cluster {
    for (graph.clusters) |c| {
        if (c.id == id) return c;
    }
    return null;
}

/// True if `anc` is an ancestor of `desc` (or equal). Walks up the
/// cluster parent chain.
fn clusterAncestorOrSelf(graph: sg.SemGraph, anc: sg.ClusterId, desc: sg.ClusterId) bool {
    var cur: ?sg.ClusterId = desc;
    while (cur) |id| {
        if (id == anc) return true;
        const c = findCluster(graph, id) orelse return false;
        cur = c.parent;
    }
    return false;
}

/// True if `a` and `b` share innermost cluster, or one contains the
/// other (nested). In any of these cases no sibling-gap padding is
/// required between adjacent nodes belonging to them.
fn clustersEnclosed(graph: sg.SemGraph, a: sg.ClusterId, b: sg.ClusterId) bool {
    if (a == b) return true;
    return clusterAncestorOrSelf(graph, a, b) or clusterAncestorOrSelf(graph, b, a);
}

pub fn intraLayerExtra(
    graph: sg.SemGraph,
    prev: sugiyama.LayerNode,
    this: sugiyama.LayerNode,
    /// Gap-shrink halvings under width pressure (LayoutOptions.spacing_scale).
    /// 0 = natural full-size gaps; >0 shrinks ONLY the pure inter-cluster GAPS
    /// (SIBLING_GAP_BASE / CLUSTER_NODE_GAP), never the frame insets.
    scale: u8,
) u32 {
    const ca = layerNodeCluster(graph, prev);
    const cb = layerNodeCluster(graph, this);

    if (ca == null and cb == null) return 0;
    if (ca != null and cb != null and clustersEnclosed(graph, ca.?, cb.?)) return 0;

    // Distinct innermost clusters: 2 cluster pads + SIBLING_GAP_BASE; only the gap shrinks under pressure. // @guarded-by: spacing.zig "intraLayerExtra: sibling clusters → 2*pad + base - h_spacing"
    if (ca != null and cb != null) {
        const need: u32 = 2 * clusterHPad(scale) + scaledGap(SIBLING_GAP_BASE, scale);
        if (need > BASE_H_SPACING) return need - BASE_H_SPACING;
        return 0;
    }

    // One clustered, one ungrouped: one inflated side + CLUSTER_NODE_GAP. // @guarded-by: spacing.zig "intraLayerExtra: cluster vs ungrouped → pad + node_gap - h_spacing"
    const need: u32 = clusterHPad(scale) + scaledGap(CLUSTER_NODE_GAP, scale);
    if (need > BASE_H_SPACING) return need - BASE_H_SPACING;
    return 0;
}

test "intraLayerExtra: both ungrouped → 0" {
    const t = std.testing;
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &.{
            .{ .id = 1, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = null },
            .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = null },
        },
        .edges = &.{},
        .classes = &.{},
        .arena = null,
        .clusters = &.{},
    };
    const lhs: sugiyama.LayerNode = .{ .real = 1 };
    const rhs: sugiyama.LayerNode = .{ .real = 2 };
    try t.expectEqual(@as(u32, 0), intraLayerExtra(graph, lhs, rhs, 0));
}

test "intraLayerExtra: same cluster → 0" {
    const t = std.testing;
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &.{
            .{ .id = 1, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 10 },
            .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 10 },
        },
        .edges = &.{},
        .classes = &.{},
        .arena = null,
        .clusters = &.{
            .{ .id = 10, .raw_id = "S", .label = "S", .parent = null, .members = &.{ 1, 2 }, .sub_clusters = &.{} },
        },
    };
    const lhs: sugiyama.LayerNode = .{ .real = 1 };
    const rhs: sugiyama.LayerNode = .{ .real = 2 };
    try t.expectEqual(@as(u32, 0), intraLayerExtra(graph, lhs, rhs, 0));
}

test "intraLayerExtra: sibling clusters → 2*pad + base - h_spacing" {
    const t = std.testing;
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &.{
            .{ .id = 1, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 10 },
            .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 11 },
        },
        .edges = &.{},
        .classes = &.{},
        .arena = null,
        .clusters = &.{
            .{ .id = 10, .raw_id = "S1", .label = "S1", .parent = null, .members = &.{1}, .sub_clusters = &.{} },
            .{ .id = 11, .raw_id = "S2", .label = "S2", .parent = null, .members = &.{2}, .sub_clusters = &.{} },
        },
    };
    const lhs: sugiyama.LayerNode = .{ .real = 1 };
    const rhs: sugiyama.LayerNode = .{ .real = 2 };
    try t.expectEqual(@as(u32, 9), intraLayerExtra(graph, lhs, rhs, 0));
}

test "intraLayerExtra: cluster vs ungrouped → pad + node_gap - h_spacing" {
    const t = std.testing;
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &.{
            .{ .id = 1, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 10 },
            .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = null },
        },
        .edges = &.{},
        .classes = &.{},
        .arena = null,
        .clusters = &.{
            .{ .id = 10, .raw_id = "S1", .label = "S1", .parent = null, .members = &.{1}, .sub_clusters = &.{} },
        },
    };
    const lhs: sugiyama.LayerNode = .{ .real = 1 };
    const rhs: sugiyama.LayerNode = .{ .real = 2 };
    try t.expectEqual(@as(u32, 5), intraLayerExtra(graph, lhs, rhs, 0));
}

test "intraLayerExtra: nested clusters (ancestor) → 0" {
    const t = std.testing;
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &.{
            .{ .id = 1, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 10 },
            .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 11 },
        },
        .edges = &.{},
        .classes = &.{},
        .arena = null,
        .clusters = &.{
            .{ .id = 10, .raw_id = "S1", .label = "S1", .parent = null, .members = &.{1}, .sub_clusters = &.{11} },
            .{ .id = 11, .raw_id = "S1a", .label = "S1a", .parent = 10, .members = &.{2}, .sub_clusters = &.{} },
        },
    };
    const lhs: sugiyama.LayerNode = .{ .real = 1 };
    const rhs: sugiyama.LayerNode = .{ .real = 2 };
    try t.expectEqual(@as(u32, 0), intraLayerExtra(graph, lhs, rhs, 0));
}

pub fn interLayerSpacing(
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    from_layer: u32,
    to_layer: u32,
    base: u32,
) u32 {
    // `addClusterBandReservations` already reserves the frame border+inset
    // rows at every cluster entry/exit boundary, so an interior
    // intra-cluster edge only needs a small ABSOLUTE floor for its jog row;
    // the floor is absolute (not `base + k`) since TD/BT base=2 and the
    // transposed-subgraph base both want the same ~3-row interior gap. // @guarded-by: spacing_test.zig "interLayerSpacing: interior intra-cluster edge floors a base=2 gap to 3"
    const INTRA_INTERIOR_MIN: u32 = 3;
    var spacing: u32 = base;
    const interior = @max(base, INTRA_INTERIOR_MIN);
    if (interior <= spacing) return spacing;
    for (lg.edges) |e| {
        const fl = nodeLayerOf(lg, e.from) orelse continue;
        const tl = nodeLayerOf(lg, e.to) orelse continue;
        if (!((fl == from_layer and tl == to_layer) or
            (fl == to_layer and tl == from_layer))) continue;
        const ca = layerNodeCluster(graph, lg.nodes[e.from]);
        const cb = layerNodeCluster(graph, lg.nodes[e.to]);
        if (ca != null and cb != null and ca.? == cb.?) {
            spacing = interior;
            break;
        }
    }
    return spacing;
}

fn nodeLayerOf(lg: sugiyama.LayeredGraph, idx: u32) ?u32 {
    for (lg.layers, 0..) |row, li| {
        for (row) |n| {
            if (n == idx) return @intCast(li);
        }
    }
    return null;
}

test {
    _ = @import("spacing_test.zig");
}

//! Tests for routing.zig's cluster-aware fan-rail lift: `fanRailLift` /
//! `crossesIntoCluster` decide whether a fan member's rail needs to clear a
//! cluster's leading frame-border row. Exercised through the public
//! `coords.layout` entry (same convention as `layout_test.zig`) with
//! hand-built `.cluster` fields on nodes, so the invariant is checked
//! end-to-end through `buildEdges` rather than by re-deriving it.
//!
//! `fan_rail.blocked`'s integrity gate (tested directly against the
//! rail artifact it reads) lives in `fan_rail_test.zig`, next to the
//! module it exercises.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const coords = @import("../layout.zig");
const routing = @import("routing.zig");
const sugiyama = @import("sugiyama.zig");
const port_plan = @import("port_plan.zig");
const ledger = @import("../base/ledger.zig");

const testing = std.testing;

fn mkNode(id: sg.NodeId, raw: []const u8, cluster: ?sg.ClusterId) sg.Node {
    return .{
        .id = id,
        .raw_id = raw,
        .label = raw,
        .shape = .rect,
        .classes = &.{},
        .cluster = cluster,
    };
}

/// Fan-OUT edge with `arrow_from = .filled` (and nothing at the target, so
/// the member still blocks and the star keeps its licence): fails
/// `fan_rail.resolve`'s eligibility check (`e.arrow_from != .none`), forcing
/// every peer of the fan onto the per-peer polyline path this file exercises.
fn mkForcedPeerEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .kind = .solid,
        .arrow_from = .filled,
        .arrow_to = .none,
        .label = null,
    };
}

/// Fully arrow-free edge (`A --- B`): the shape the closure law judges.
fn mkBareEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null };
}

/// Plain fan-OUT edge (arrow_from = .none): stays rail eligible.
fn mkPlainEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
    };
}

fn findEdge(edges: []const sketch.EdgePath, from: sketch.NodeId, to: sketch.NodeId) sketch.EdgePath {
    for (edges) |e| {
        if (e.from == from and e.to == to) return e;
    }
    @panic("missing edge");
}

fn findNode(nodes: []const sketch.NodePlacement, id: sketch.NodeId) sketch.NodePlacement {
    for (nodes) |n| if (n.id == id) return n;
    @panic("missing node");
}

/// The rail row a fan-OUT peer's polyline bends through. For an
/// undodged leftmost/rightmost/middle peer (no obstruction — true for
/// every fixture below), `fan_polyline.buildPolyline` unconditionally
/// appends `(sx, rail_y)` as its second point before any column-vs-tx
/// branch, so `poly[1].y` is exactly `rail_y` regardless of whether the
/// peer's column happens to coincide with the pivot's.
fn railRow(poly: []const sketch.Point) i32 {
    return poly[1].y;
}

/// Builds A -[fan-out]-> {B, C}, both on A's next layer. `c_cluster` is C's
/// (and only C's) cluster membership; B always stays top-level (cluster
/// null), so B is the non-crossing control peer in every fixture.
fn layoutForkIntoCluster(
    arena: std.mem.Allocator,
    clusters: []const sg.Cluster,
    c_cluster: ?sg.ClusterId,
    forced_per_peer: bool,
) !sketch.Sketch {
    const nodes = [_]sg.Node{
        mkNode(0, "A", null),
        mkNode(1, "B", null),
        mkNode(2, "C", c_cluster),
    };
    const edges = [_]sg.Edge{
        if (forced_per_peer) mkForcedPeerEdge(0, 0, 1) else mkPlainEdge(0, 0, 1),
        if (forced_per_peer) mkForcedPeerEdge(1, 0, 2) else mkPlainEdge(1, 0, 2),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = clusters,
        .classes = &.{},
        .arena = null,
    };
    return coords.layout(arena, g, .{});
}

// -- claim: crossesIntoCluster / fanRailLift (routing.zig ~305-327) ---------

test "fan-OUT per-peer rail lifts exactly one row for the peer crossing into a cluster its source is not part of" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const clusters = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "X", .label = "X", .parent = null, .members = &.{2}, .sub_clusters = &.{} },
    };
    const s = try layoutForkIntoCluster(arena.allocator(), &clusters, 0, true);

    const b = findNode(s.nodes, 1);
    const c = findNode(s.nodes, 2);
    // B and C share a layer (both fed directly by A), so their perimeter
    // top rows match — an exact baseline to diff the lift against.
    try testing.expectEqual(b.rect.y, c.rect.y);

    const eb = findEdge(s.edges, 0, 1); // non-crossing control peer
    const ec = findEdge(s.edges, 0, 2); // crosses into cluster X

    const b_rail = railRow(eb.polyline);
    const c_rail = railRow(ec.polyline);
    // The crossing peer's rail sits exactly one row further from the
    // target than the non-crossing control's — the fanRailLift(1) that
    // clears the cluster's leading frame-border row instead of fusing
    // with it.
    try testing.expectEqual(b_rail - 1, c_rail);
}

test "fan-OUT per-peer rail does not lift when the source is a member of (or ancestor of) the target's cluster" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // A is a member of cluster X too, so A -> C never crosses INTO X (same
    // frame interior); crossesIntoCluster's ancestor-walk must treat this as
    // a non-crossing edge exactly like the top-level-source case.
    const nodes = [_]sg.Node{
        mkNode(0, "A", 0),
        mkNode(1, "B", null),
        mkNode(2, "C", 0),
    };
    const edges = [_]sg.Edge{
        mkForcedPeerEdge(0, 0, 1),
        mkForcedPeerEdge(1, 0, 2),
    };
    const clusters = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "X", .label = "X", .parent = null, .members = &.{ 0, 2 }, .sub_clusters = &.{} },
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };
    const s = try coords.layout(arena.allocator(), g, .{});

    const b = findNode(s.nodes, 1);
    const c = findNode(s.nodes, 2);
    try testing.expectEqual(b.rect.y, c.rect.y);

    const eb = findEdge(s.edges, 0, 1);
    const ec = findEdge(s.edges, 0, 2);
    // Neither peer crosses into a cluster its source is outside of, so
    // both rails land on the same (unlifted) row.
    try testing.expectEqual(railRow(eb.polyline), railRow(ec.polyline));
}

test "rail pre-pass and forced per-peer path lift the same fan-OUT geometry to the same rail row" {
    // fanRailLift is documented as THE single shared lift rule used by both
    // the rail pre-pass and the per-peer polyline path. Same fixture
    // (fan-out peer crossing into cluster X), routed once eligible for the
    // rail and once forced onto the per-peer path (arrow_from set): the
    // resulting rail row must match exactly.
    const clusters = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "X", .label = "X", .parent = null, .members = &.{2}, .sub_clusters = &.{} },
    };

    var arena_bar = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_bar.deinit();
    const s_bar = try layoutForkIntoCluster(arena_bar.allocator(), &clusters, 0, false);
    try testing.expectEqual(@as(usize, 1), s_bar.rails.len);
    const bar_rail_y = s_bar.rails[0].crossbar[0].y;

    var arena_peer = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_peer.deinit();
    const s_peer = try layoutForkIntoCluster(arena_peer.allocator(), &clusters, 0, true);
    try testing.expectEqual(@as(usize, 0), s_peer.rails.len);
    const ec = findEdge(s_peer.edges, 0, 2);

    try testing.expectEqual(bar_rail_y, railRow(ec.polyline));
}

// -- claim: discharged withholding (routing.zig `routing_edges` loop) ------

test "a discharged edge is withheld from routing entirely" {
    // A---Z and B---Z fuse on one arrival, and the crossbar between their two
    // taps IS the rendering of the declared A---B. Routing must therefore emit
    // NO EdgePath for A---B: a private polyline would draw that relation twice.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ mkNode(0, "A", null), mkNode(1, "B", null), mkNode(2, "Z", null) };
    const edges = [_]sg.Edge{ mkBareEdge(0, 0, 2), mkBareEdge(1, 1, 2), mkBareEdge(2, 0, 1) };
    const g = sg.SemGraph{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };

    var lg_nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 } };
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{2};
    var layers = [_][]u32{ &row0, &row1 };
    var lg_edges = [_]sugiyama.LayerEdge{
        .{ .edge = 0, .from = 0, .to = 2, .reversed = false },
        .{ .edge = 1, .from = 1, .to = 2, .reversed = false },
        .{ .edge = 2, .from = 0, .to = 1, .reversed = false },
    };
    const lg: sugiyama.LayeredGraph = .{ .nodes = &lg_nodes, .layers = &layers, .edges = &lg_edges, .reversed_edges = &.{}, .real_index = .empty, .arena = null };
    const geom = [_]routing.NodeGeom{
        .{ .x = 0, .y = 0, .w = 5, .h = 3, .layer = 0 },
        .{ .x = 10, .y = 0, .w = 5, .h = 3, .layer = 0 },
        .{ .x = 5, .y = 7, .w = 5, .h = 3, .layer = 1 },
    };
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 10, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 5, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const ind: ledger.MembershipDisposition = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } };
    const memberships = [_]ledger.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = ind },
        .{ .edge = 1, .source = null, .target = ind },
        .{ .edge = 2, .source = null, .target = null },
    };
    const ports = try port_plan.midpoint(a, g, &placements);

    const routed = try routing.buildEdgesWithPlan(a, g, lg, &geom, &placements, &.{}, .{ .memberships = &memberships }, ports);
    try testing.expectEqual(@as(usize, 3), routed.edges.len);

    const withheld = try routing.buildEdgesWithPlan(a, g, lg, &geom, &placements, &.{}, .{ .memberships = &memberships, .discharged = &.{2} }, ports);
    try testing.expectEqual(@as(usize, 2), withheld.edges.len);
    for (withheld.edges) |e| try testing.expect(e.id != 2);
}

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
const back_edges = @import("back_edges.zig");
const route_clearance = @import("route_clearance.zig");
const route_search = @import("route_search.zig");

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
/// The decorated source holds its departure cell straight (the head sits
/// there — routing_terminal.zig's straight-through rule), so a per-peer
/// turn lands no nearer than two rows below the source wall.
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

/// Fully arrow-free edge (`A --- B`): the shape the closure licence judges.
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
    v_spacing: u32,
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
    return coords.layout(arena, g, .{ .v_spacing = v_spacing });
}

test "fan-OUT per-peer rail lifts exactly one row for the peer crossing into a cluster its source is not part of" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const clusters = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "X", .label = "X", .parent = null, .members = &.{2}, .sub_clusters = &.{} },
    };
    // One extra gap row: the forced peers' decorated source keeps its
    // departure cell for the head, and the lift needs a row of its own.
    const s = try layoutForkIntoCluster(arena.allocator(), &clusters, 0, true, 3);

    const b = findNode(s.nodes, 1);
    const c = findNode(s.nodes, 2);
    try testing.expectEqual(b.rect.y, c.rect.y);

    const eb = findEdge(s.edges, 0, 1);
    const ec = findEdge(s.edges, 0, 2);

    const b_rail = railRow(eb.polyline);
    const c_rail = railRow(ec.polyline);
    try testing.expectEqual(b_rail - 1, c_rail);
}

test "fan-OUT per-peer rail does not lift when the source is a member of (or ancestor of) the target's cluster" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

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
    try testing.expectEqual(railRow(eb.polyline), railRow(ec.polyline));
}

test "rail pre-pass and forced per-peer path lift the same fan-OUT geometry to the same rail row" {
    const clusters = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "X", .label = "X", .parent = null, .members = &.{2}, .sub_clusters = &.{} },
    };

    var arena_bar = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_bar.deinit();
    const s_bar = try layoutForkIntoCluster(arena_bar.allocator(), &clusters, 0, false, 2);
    try testing.expectEqual(@as(usize, 1), s_bar.rails.len);
    const bar_rail_y = s_bar.rails[0].crossbar[0].y;

    var arena_peer = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_peer.deinit();
    const s_peer = try layoutForkIntoCluster(arena_peer.allocator(), &clusters, 0, true, 2);
    try testing.expectEqual(@as(usize, 0), s_peer.rails.len);
    const ec = findEdge(s_peer.edges, 0, 2);

    // The same lifted row — except that the forced peers' decorated source
    // holds its departure cell (the head) straight, so where the rail's row
    // IS that cell the per-peer turn sits one row further out.
    const a_bottom = findNode(s_peer.nodes, 0).rect.bottom() - 1;
    try testing.expectEqual(@max(bar_rail_y, a_bottom + 2), railRow(ec.polyline));
    try testing.expectEqual(bar_rail_y, a_bottom + 1);
}

test "a discharged edge is withheld from routing entirely" {
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

test "the lane ladder climbs from the planned lane, then descends to lane 0, then ends" {
    var ladder = routing.LaneLadder{ .planned = 2, .lane = 2 };
    var seen: std.ArrayListUnmanaged(u32) = .empty;
    defer seen.deinit(testing.allocator);
    try seen.append(testing.allocator, ladder.lane);
    while (ladder.next()) try seen.append(testing.allocator, ladder.lane);
    try testing.expectEqual(@as(usize, 17), seen.items.len);
    try testing.expectEqual(@as(u32, 2), seen.items[0]);
    try testing.expectEqual(@as(u32, 16), seen.items[14]);
    try testing.expectEqual(@as(u32, 1), seen.items[15]);
    try testing.expectEqual(@as(u32, 0), seen.items[16]);

    var from_zero = routing.LaneLadder{ .planned = 0, .lane = 0 };
    var count: u32 = 0;
    while (from_zero.next()) count += 1;
    try testing.expectEqual(@as(u32, 16), count);
}

test "the base-approach grow is reverted when it would bend a decorated departure cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 3, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 7, .y = 6, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const points = [_]sketch.Point{ .{ .x = 5, .y = 2 }, .{ .x = 5, .y = 4 }, .{ .x = 9, .y = 4 }, .{ .x = 9, .y = 6 } };
    const ports = [_]port_plan.EdgePorts{};

    const plain_poly = try a.dupe(sketch.Point, &points);
    const plain = sg.Edge{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    const grown = try routing.growBaseApproach(a, plain_poly, &placements, plain, &.{}, &.{}, &ports, .{});
    try testing.expect(grown.ptr != plain_poly.ptr);
    try testing.expectEqual(@as(i32, 3), grown[1].y);

    const decorated_poly = try a.dupe(sketch.Point, &points);
    const decorated = sg.Edge{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .filled, .arrow_to = .filled, .label = null };
    const kept = try routing.growBaseApproach(a, decorated_poly, &placements, decorated, &.{}, &.{}, &ports, .{});
    try testing.expect(kept.ptr == decorated_poly.ptr);
    try testing.expectEqual(@as(i32, 4), kept[1].y);
}

test "a back edge's stub hop keeps off a foreign decorated arrival cell" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Source A below target B; box C blocks A's east stub row, so the stub
    // hops up to the nearest clear row toward B.
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 10, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 7, .y = 9, .w = 5, .h = 5 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const from: sketch.Port = .{ .node = 0, .side = .east, .offset = 1 };
    const to: sketch.Port = .{ .node = 1, .side = .east, .offset = 1 };
    const bare = try back_edges.backEdgePolylineAt(a, .TD, placements[0], placements[1], from, to, 14, &placements);
    try testing.expectEqual(@as(i32, 8), bare[2].y);

    // A foreign edge arrives at C's north port (8,9): its decorated arrival
    // cell (8,8) sits on that hop row, so the hop climbs one more row.
    const ports = [_]port_plan.EdgePorts{.{ .edge = 9, .source = .{ .node = 1, .side = .south, .offset = 3 }, .target = .{ .node = 2, .side = .north, .offset = 1 }, .source_ordinal = 0, .target_ordinal = 0, .target_decorated = true }};
    const guarded = try route_clearance.withDecoratedTerminalBoxes(a, 3, &placements, &ports, .{});
    // The clear-line search keeps its distance order: at the same distance
    // the far side (row 14) is clear where row 8 now reads as a box.
    const kept_off = try back_edges.backEdgePolylineAt(a, .TD, placements[0], placements[1], from, to, 14, guarded);
    try testing.expect(kept_off[2].y != 8);
    try testing.expectEqual(@as(i32, 14), kept_off[2].y);
}

fn inkRun(id: sg.EdgeId, from: sketch.Point, to: sketch.Point, points: []sketch.Point) sketch.EdgePath {
    points[0] = from;
    points[1] = to;
    return .{ .id = id, .from = 50, .to = 51, .polyline = points, .port_from = .{ .node = 50, .side = .south, .offset = 0 }, .port_to = .{ .node = 51, .side = .north, .offset = 0 }, .arrow_from = .none, .arrow_to = .none, .label = null, .kind = .solid, .role = .forward };
}

test "the detour ladder pushes a port run past a foreign jog row, and is null when every row is taken" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Source box rows 0..2, target rows 20..22; a foreign run lies along
    // row 3, the detour's nearest source row, so the pushed run on row 4 is
    // the first accepted candidate. With rows 3, 4 and 5 all taken, no
    // push clears and the ladder is null: nothing lying collinear ships.
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 10, .y = 20, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const edge = sg.Edge{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    const ep = port_plan.EdgePorts{ .edge = 0, .source = .{ .node = 0, .side = .south, .offset = 2 }, .target = .{ .node = 1, .side = .north, .offset = 2 }, .source_ordinal = 0, .target_ordinal = 0, .target_decorated = true };
    const ports = [_]port_plan.EdgePorts{ep};
    // The cross-bundle gate reads ink only under a realized plan.
    const memberships = [_]ledger.RealizedEdgeMembership{.{ .edge = 9, .source = null, .target = null }};
    const bundles: ledger.RealizedBundles = .{ .memberships = &memberships };
    var r3: [2]sketch.Point = undefined;
    var r4: [2]sketch.Point = undefined;
    var r5: [2]sketch.Point = undefined;
    const one = [_]sketch.EdgePath{inkRun(7, .{ .x = -40, .y = 3 }, .{ .x = 60, .y = 3 }, &r3)};
    const pushed = (try routing.detour(a, .TD, edge, placements[0], placements[1], ep, .{ .to = true }, &one, &.{}, &placements, &ports, bundles)).?;
    try testing.expectEqual(@as(i32, 4), pushed[1].y);
    try testing.expectEqual(@as(i32, 4), pushed[2].y);
    try testing.expectEqual(@as(i32, 12), pushed[0].x);
    const three = [_]sketch.EdgePath{
        inkRun(7, .{ .x = -40, .y = 3 }, .{ .x = 60, .y = 3 }, &r3),
        inkRun(8, .{ .x = -40, .y = 4 }, .{ .x = 60, .y = 4 }, &r4),
        inkRun(9, .{ .x = -40, .y = 5 }, .{ .x = 60, .y = 5 }, &r5),
    };
    try testing.expect((try routing.detour(a, .TD, edge, placements[0], placements[1], ep, .{ .to = true }, &three, &.{}, &placements, &ports, bundles)) == null);
}

test "a self loop lifts past foreign ink instead of lying along it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Node rows 10..12. The classic loop rises three rows above the box to
    // row 7; a foreign run lies along that row, so every candidate on it is
    // refused and the first accepted one runs one row higher.
    const node_p = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 10, .y = 10, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{node_p};
    const edge = sg.Edge{ .id = 0, .from = 0, .to = 0, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    const ep = port_plan.EdgePorts{ .edge = 0, .source = .{ .node = 0, .side = .east, .offset = 1 }, .target = .{ .node = 0, .side = .north, .offset = 2 }, .source_ordinal = 0, .target_ordinal = 0, .target_decorated = true };
    const ports = [_]port_plan.EdgePorts{ep};
    const memberships = [_]ledger.RealizedEdgeMembership{.{ .edge = 9, .source = null, .target = null }};
    const bundles: ledger.RealizedBundles = .{ .memberships = &memberships };
    const clear = try route_search.selfLoop(a, .TD, edge, node_p, ep, &.{}, &.{}, &placements, &ports, bundles);
    try testing.expectEqual(@as(i32, 7), clear.polyline[2].y);
    var r7: [2]sketch.Point = undefined;
    const along = [_]sketch.EdgePath{inkRun(7, .{ .x = 0, .y = 7 }, .{ .x = 40, .y = 7 }, &r7)};
    const lifted = try route_search.selfLoop(a, .TD, edge, node_p, ep, &along, &.{}, &placements, &ports, bundles);
    try testing.expectEqual(@as(usize, 5), lifted.polyline.len);
    try testing.expectEqual(@as(i32, 6), lifted.polyline[2].y);
    try testing.expectEqual(@as(i32, 6), lifted.polyline[3].y);
    // The re-entry still runs straight into the decorated north port.
    try testing.expectEqual(@as(i32, 12), lifted.polyline[4].x);
    try testing.expectEqual(@as(i32, 10), lifted.polyline[4].y);
}

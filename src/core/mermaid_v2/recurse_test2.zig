//! recurse_test2.zig — continuation of recurse_test.zig, split at the
//! mermaid_v2 500-line cap. Same zone privileges (cluster/ + layout/); the
//! shared merged-Sketch helpers are imported from recurse_test.zig.

const std = @import("std");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const ledger = @import("base/ledger.zig");
const lattice = @import("lattice.zig");
const recurse = @import("recurse.zig");
const raster = @import("raster.zig");
const rt = @import("recurse_test.zig");
const assertUniqueEdgeIds = rt.assertUniqueEdgeIds;
const clusterOf = rt.clusterOf;

test "a nested clustered fan-in loses no RailClaim during either stitch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 200 },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 200 },
        .{ .id = 2, .raw_id = "P", .label = "P", .shape = .rect, .classes = &.{}, .cluster = 200 },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{ 0, 1, 2 };
    const subs = [_]sem_graph.ClusterId{200};
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "outer", .label = "outer", .parent = null, .members = &.{}, .sub_clusters = &subs },
        .{ .id = 200, .raw_id = "inner", .label = "inner", .parent = 100, .members = &members, .sub_clusters = &.{} },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });
    try std.testing.expectEqual(@as(usize, 1), s.rail_claims.len);
    const claim = s.rail_claims[0];
    try std.testing.expectEqual(@as(ledger.RailClaimId, 1), claim.id);
    try std.testing.expectEqual(ledger.RailPolarity.in, claim.polarity);
    try std.testing.expectEqual(@as(usize, 2), claim.members.len);
    try std.testing.expect(ledger.checkRailClaim(claim).isValid());
    for (claim.members) |member| {
        var carrier = false;
        for (s.edges) |edge| carrier = carrier or edge.id == member.edge;
        for (s.busbars) |rail| for (rail.taps) |tap| {
            carrier = carrier or tap.edge == member.edge;
        };
        try std.testing.expect(carrier);
    }
}

/// The merged placement whose label reads `name`, or null.
fn placementNamed(s: sketch.Sketch, name: []const u8) ?sketch.NodePlacement {
    for (s.nodes) |p| {
        if (p.lines.len != 0 and std.mem.eql(u8, p.lines[0], name)) return p;
    }
    return null;
}

// An outer fan whose targets are SUBGRAPHS: the outer piece's fan co-set
// names the outer PLACEMENT edges, and stitch drops exactly those (they
// touch a super-node) in favour of bridge EdgePaths keyed by crossing id.
// Unless the set is rewritten through that swap, its members resolve to
// nothing in the merged Sketch and the ink those edges legally share loses
// its permission record.
// Fan-into-subgraphs fixture: Top fans out into two sibling subgraphs
// (Top -> a1 in S, Top -> b1 in R), each subgraph a two-node chain. In the
// OUTER piece both targets are super-nodes one layer below Top, so the outer
// layout sees a two-peer fan whose members are placement edges — the exact
// edges stitch drops in favour of bridges.
/// `labeled` stamps a label on each of Top's two CROSS-BORDER members, the
/// only difference between the two variants the row-reservation pin compares.
fn fanIntoTwoSubgraphsGraph(
    nodes_buf: []sem_graph.Node,
    edges_buf: []sem_graph.Edge,
    members_s: []sem_graph.NodeId,
    members_r: []sem_graph.NodeId,
    clusters_buf: []sem_graph.Cluster,
    labeled: bool,
) sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    const names = [_][]const u8{ "Top", "a1", "a2", "b1", "b2" };
    const owners = [_]?sem_graph.ClusterId{ null, 100, 100, 200, 200 };
    for (names, 0..) |nm, i| {
        nodes_buf[i] = .{ .id = @intCast(i), .raw_id = nm, .label = nm, .shape = NS.rect, .classes = &.{}, .cluster = owners[i] };
    }
    const pairs = [_][2]sem_graph.NodeId{ .{ 0, 1 }, .{ 1, 2 }, .{ 0, 3 }, .{ 3, 4 } };
    for (pairs, 0..) |p, i| {
        edges_buf[i] = .{ .id = @intCast(i), .from = p[0], .to = p[1], .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    }
    if (labeled) {
        edges_buf[0].label = "yes"; // Top -> a1, crosses into S
        edges_buf[2].label = "no"; // Top -> b1, crosses into R
    }
    members_s[0] = 1;
    members_s[1] = 2;
    members_r[0] = 3;
    members_r[1] = 4;
    clusters_buf[0] = .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = members_s, .sub_clusters = &.{}, .direction = null };
    clusters_buf[1] = .{ .id = 200, .raw_id = "R", .label = "R", .parent = null, .members = members_r, .sub_clusters = &.{}, .direction = null };
    return .{
        .direction = .TD,
        .nodes = nodes_buf,
        .edges = edges_buf,
        .clusters = clusters_buf,
        .classes = &.{},
        .arena = null,
    };
}

// An outer fan whose targets are SUBGRAPHS: the outer piece's fan co-set
// names the outer PLACEMENT edges, and stitch drops exactly those (they
// touch a super-node) in favour of bridge EdgePaths keyed by crossing id.
// Unless the set is rewritten through that swap, its members resolve to
// nothing in the merged Sketch and the ink those edges legally share loses
// its permission record.
test "an outer fan into sibling subgraphs names its bridges, not the dropped placement edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_s: [2]sem_graph.NodeId = undefined;
    var members_r: [2]sem_graph.NodeId = undefined;
    var clusters_buf: [2]sem_graph.Cluster = undefined;
    const graph = fanIntoTwoSubgraphsGraph(&nodes_buf, &edges_buf, &members_s, &members_r, &clusters_buf, false);

    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });
    const top = placementNamed(s, "Top") orelse return error.TopNotPlaced;

    var owners = try assertUniqueEdgeIds(a, s);
    defer owners.deinit();

    // A qualifying set: at least two members that still carry geometry, all
    // leaving Top, at least two of them landing INSIDE a cluster — i.e. the
    // bridges that replaced Top's dropped placement edges.
    var found = false;
    for (s.co_sets) |set| {
        var live: usize = 0;
        var into_clusters: usize = 0;
        for (set.members) |m| {
            const owner = owners.get(m) orelse continue;
            if (owner != top.id) break;
            live += 1;
            for (s.edges) |e| {
                if (e.id != m) continue;
                if (try clusterOf(s, e.to) != null) into_clusters += 1;
            }
        } else if (live >= 2 and into_clusters >= 2) found = true;
        if (found) break;
    }
    try std.testing.expect(found);

    // The same exact final pivot/site evidence rebuilds the semantic claim;
    // no super-node endpoint or placement edge may survive in it.
    var claimed = false;
    for (s.rail_claims) |claim| {
        if (claim.polarity != .out or claim.pivot != top.id or claim.members.len < 2) continue;
        if (!ledger.checkRailClaim(claim).isValid()) continue;
        for (claim.members) |member| {
            if (member.node(.source) != top.id) break;
            if (edgeById(s, member.edge) == null) break;
        } else claimed = true;
    }
    try std.testing.expect(claimed);
}

/// The merged frame of cluster `id`, or null.
fn frameOf(s: sketch.Sketch, id: sem_graph.ClusterId) ?sketch.ClusterFrame {
    for (s.clusters) |c| {
        if (c.id == id) return c;
    }
    return null;
}

/// Rows between Top's bottom edge and the top of subgraph S's frame — the
/// inter-layer gap the labeled-fan reservation would inflate.
fn topToFrameGap(s: sketch.Sketch) !u32 {
    const top = placementNamed(s, "Top") orelse return error.TopNotPlaced;
    const frame = frameOf(s, 100) orelse return error.FrameNotPlaced;
    const bottom: i32 = top.rect.y + @as(i32, @intCast(top.rect.h));
    if (frame.rect.y < bottom) return error.FrameAboveTop;
    return @intCast(frame.rect.y - bottom);
}

// A fan whose members all CROSS a subgraph border pays no on-run label rows.
//
// The reservation (fan.LABEL_RUN_EXTRA_ROWS, driven by `Fan.labeled`) buys a
// 4-cell private dropper for the decorated on-run sandwich. The on-run writer
// only ever sees edges that SURVIVE the stitch, and stitch drops every outer
// edge touching a super-node in favour of a bridge EdgePath — so rows bought
// for a bridge-routed member could never be spent. They are not bought:
// `split.buildOuter` rewrites each cross-border edge as a LABEL-FREE placement
// edge, so `fan.detect`, which reads the outer piece's semantic edges, never
// sees a label on a bridge-routed member and leaves `labeled` clear.
//
// This pins that end to end: labelling both members of the outer fan must not
// move a single row. It is the standing guard on the coupling — a future
// change that carried crossing labels onto the placement edges (for bridge
// label placement, say) would start buying rows the raster can never spend,
// and this test is what would catch it.
test "a labeled fan into sibling subgraphs reserves no on-run rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var plain_nodes: [5]sem_graph.Node = undefined;
    var plain_edges: [4]sem_graph.Edge = undefined;
    var plain_ms: [2]sem_graph.NodeId = undefined;
    var plain_mr: [2]sem_graph.NodeId = undefined;
    var plain_clusters: [2]sem_graph.Cluster = undefined;
    const plain = fanIntoTwoSubgraphsGraph(&plain_nodes, &plain_edges, &plain_ms, &plain_mr, &plain_clusters, false);

    var lbl_nodes: [5]sem_graph.Node = undefined;
    var lbl_edges: [4]sem_graph.Edge = undefined;
    var lbl_ms: [2]sem_graph.NodeId = undefined;
    var lbl_mr: [2]sem_graph.NodeId = undefined;
    var lbl_clusters: [2]sem_graph.Cluster = undefined;
    const labeled = fanIntoTwoSubgraphsGraph(&lbl_nodes, &lbl_edges, &lbl_ms, &lbl_mr, &lbl_clusters, true);

    const sp = try recurse.layoutPieces(a, plain, .{ .max_width = 120 });
    const sl = try recurse.layoutPieces(a, labeled, .{ .max_width = 120 });

    // The gap the reservation would inflate, and the whole canvas height.
    try std.testing.expectEqual(try topToFrameGap(sp), try topToFrameGap(sl));
    try std.testing.expectEqual(sp.bbox.h, sl.bbox.h);

    // Guard the guard: both members really are bridge-routed, i.e. Top's
    // outgoing ink lands INSIDE a cluster rather than on a top-level box.
    const top = placementNamed(sl, "Top") orelse return error.TopNotPlaced;
    var crossings: usize = 0;
    for (sl.edges) |e| {
        if (e.from != top.id) continue;
        if (try clusterOf(sl, e.to) != null) crossings += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), crossings);
}

// Two OUTER nodes both edge into the SAME node inside a subgraph. Each
// crossing becomes its own bridge, minted independently by cluster/bridges,
// and both elbows land on the target placement's one perimeter port. Neither
// bridge knows about the other, so only the merged geometry can declare that
// their approach ink is one channel — which is exactly what stitch reads back
// off the final edge slice.
fn twoBridgesIntoOnePortGraph(
    nodes_buf: []sem_graph.Node,
    edges_buf: []sem_graph.Edge,
    members: []sem_graph.NodeId,
    clusters_buf: []sem_graph.Cluster,
) sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    const names = [_][]const u8{ "A", "B", "C", "D" };
    const owners = [_]?sem_graph.ClusterId{ null, null, 100, 100 };
    for (names, 0..) |nm, i| {
        nodes_buf[i] = .{ .id = @intCast(i), .raw_id = nm, .label = nm, .shape = NS.rect, .classes = &.{}, .cluster = owners[i] };
    }
    const pairs = [_][2]sem_graph.NodeId{ .{ 0, 2 }, .{ 1, 2 }, .{ 2, 3 } };
    for (pairs, 0..) |pr, i| {
        edges_buf[i] = .{ .id = @intCast(i), .from = pr[0], .to = pr[1], .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    }
    members[0] = 2;
    members[1] = 3;
    clusters_buf[0] = .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = members, .sub_clusters = &.{}, .direction = null };
    return .{
        .direction = .TD,
        .nodes = nodes_buf,
        .edges = edges_buf,
        .clusters = clusters_buf,
        .classes = &.{},
        .arena = null,
    };
}

test "two bridges into one port declare a port-share co-set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [4]sem_graph.Node = undefined;
    var edges_buf: [3]sem_graph.Edge = undefined;
    var members: [2]sem_graph.NodeId = undefined;
    var clusters_buf: [1]sem_graph.Cluster = undefined;
    const graph = twoBridgesIntoOnePortGraph(&nodes_buf, &edges_buf, &members, &clusters_buf);

    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });

    // The two bridges: the merged edges that end on C's placement, arriving
    // from outside the cluster. Named by geometry, never by id arithmetic.
    const c = placementNamed(s, "C") orelse return error.TargetNotPlaced;
    var arrivals: [8]sketch.EdgeId = undefined;
    var n: usize = 0;
    for (s.edges) |e| {
        if (e.to != c.id) continue;
        if (n < arrivals.len) {
            arrivals[n] = e.id;
            n += 1;
        }
    }
    try std.testing.expect(n >= 2);

    // Every pair of arrivals that lands on the SAME point must be co-members
    // of a `.port_share` set — the whole point of the stitch-side wire-in.
    var checked = false;
    for (0..n) |i| for (i + 1..n) |j| {
        const first = edgeById(s, arrivals[i]) orelse continue;
        const second = edgeById(s, arrivals[j]) orelse continue;
        const fe = first.polyline[first.polyline.len - 1];
        const se = second.polyline[second.polyline.len - 1];
        if (fe.x != se.x or fe.y != se.y) continue;
        checked = true;
        var named = false;
        for (s.co_sets) |set| {
            if (set.origin != .port_share) continue;
            var saw_first = false;
            var saw_second = false;
            for (set.members) |m| {
                if (m == first.id) saw_first = true;
                if (m == second.id) saw_second = true;
            }
            if (saw_first and saw_second) named = true;
        }
        try std.testing.expect(named);
    };
    try std.testing.expect(checked);
}

test "a child rail and cross-border bridge sharing A's final port are licensed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 3, .raw_id = "D", .label = "D", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 0, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{ 0, 1, 2 };
    const clusters = [_]sem_graph.Cluster{.{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{} }};
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });
    const pivot = placementNamed(s, "A") orelse return error.PivotNotPlaced;
    var bridge: ?sketch.EdgePath = null;
    for (s.edges) |edge| {
        if (edge.from == pivot.id) bridge = edge;
    }
    const final_bridge = bridge orelse return error.BridgeNotRouted;
    try std.testing.expectEqual(@as(usize, 1), s.busbars.len);

    var licensed = false;
    for (s.busbars[0].taps) |tap| {
        if (ledger.coMembersAt(s.co_sets, tap.edge, final_bridge.id, .{
            .x = final_bridge.polyline[0].x,
            .y = final_bridge.polyline[0].y + 1,
        })) licensed = true;
    }
    try std.testing.expect(licensed);

    const report = try raster.rasterize(a, s, .bridge, .{ .collect_aux = true });
    try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
    var licensed_carriers: usize = 0;
    for (report.lattice.aux) |record| {
        if (record.kind != .carrier) continue;
        try std.testing.expect(record.detail != @intFromEnum(lattice.CarrierKind.merged_foreign));
        if (record.value == final_bridge.id and record.detail == @intFromEnum(lattice.CarrierKind.merged_licensed)) licensed_carriers += 1;
    }
    try std.testing.expect(licensed_carriers > 0);
}

fn edgeById(s: sketch.Sketch, id: sketch.EdgeId) ?sketch.EdgePath {
    for (s.edges) |e| {
        if (e.id == id) return e;
    }
    return null;
}

test "the merged sketch sums its pieces' closure counts" {
    // The refusal happens INSIDE the child piece: `subgraph S { Z---A; Z---B;
    // Z---C }`. Report-only counts are per-piece facts about one merged
    // picture, so keeping only the outer piece's would report a clean render
    // for a diagram whose fan the law refused.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "Z", .label = "Z", .shape = .rect, .classes = &.{}, .cluster = 0 },
        .{ .id = 1, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 0 },
        .{ .id = 2, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 0 },
        .{ .id = 3, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = 0 },
    };
    var edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null },
        .{ .id = 2, .from = 0, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null },
    };
    var members = [_]sem_graph.NodeId{ 0, 1, 2, 3 };
    var clusters = [_]sem_graph.Cluster{
        .{ .id = 0, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{}, .direction = null },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };
    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });
    try std.testing.expectEqual(@as(u32, 1), s.closure.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 3), s.closure.co_undeclared);
}

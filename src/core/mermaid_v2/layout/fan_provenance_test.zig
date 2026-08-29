//! Production tests for semantic fan RailClaims.

const std = @import("std");
const ledger = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const coords = @import("../layout.zig");
const raster = @import("../raster.zig");
const painter = @import("../paint.zig");
const select = @import("../select.zig");
const fan = @import("fan.zig");
const provenance = @import("fan_provenance.zig");

const testing = std.testing;

fn node(id: u32, name: []const u8, cluster: ?u32) sg.Node {
    return .{ .id = id, .raw_id = name, .label = name, .shape = .rect, .classes = &.{}, .cluster = cluster };
}

fn edge(id: u32, from: u32, to: u32) sg.Edge {
    return styledEdge(id, from, to, .solid, .none, .filled, null);
}

fn styledEdge(id: u32, from: u32, to: u32, kind: sg.EdgeKind, from_arrow: sg.ArrowEnd, to_arrow: sg.ArrowEnd, label: ?[]const u8) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = kind, .arrow_from = from_arrow, .arrow_to = to_arrow, .label = label };
}

fn graph(direction: sg.Direction, nodes: []const sg.Node, edges: []const sg.Edge, clusters: []const sg.Cluster) sg.SemGraph {
    return .{ .direction = direction, .nodes = nodes, .edges = edges, .clusters = clusters, .classes = &.{}, .arena = null };
}

fn expectAllValid(claims: []const ledger.RailClaim) !void {
    for (claims) |claim| try testing.expect(ledger.checkRailClaim(claim).isValid());
}

fn hasMember(claim: ledger.RailClaim, id: ledger.EdgeId) bool {
    for (claim.members) |member| if (member.edge == id) return true;
    return false;
}

test "fan provenance: first-class fan-out claim is valid metadata and changes no painted byte" {
    const nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null), node(3, "C", null) };
    const edges = [_]sg.Edge{ edge(10, 0, 1), edge(11, 0, 2), edge(12, 0, 3) };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try coords.layout(a, graph(.TD, &nodes, &edges, &.{}), .{});

    try testing.expectEqual(@as(usize, 1), s.rails.len);
    try testing.expectEqual(@as(usize, 1), s.rail_claims.len);
    const claim = s.rail_claims[0];
    try testing.expectEqual(@as(ledger.RailClaimId, 1), claim.id);
    try testing.expectEqual(ledger.RailPolarity.out, claim.polarity);
    try testing.expectEqual(@as(?ledger.NodeId, 0), ledger.checkRailClaim(claim).derived_pivot);
    try testing.expectEqual(@as(usize, 3), claim.members.len);
    try testing.expect(ledger.checkRailClaim(claim).isValid());

    const with_report = try raster.rasterize(a, s, .bridge);
    const with_bytes = try painter.paint(a, with_report.lattice, s.budget.max_width);
    var without = s;
    without.rail_claims = &.{};
    const without_report = try raster.rasterize(a, without, .bridge);
    const without_bytes = try painter.paint(a, without_report.lattice, without.budget.max_width);
    try testing.expectEqualStrings(with_bytes, without_bytes);
}

test "fan provenance: realized fan-in Rail claims the pivot while labeled fan-in stays private" {
    const nodes = [_]sg.Node{ node(0, "A", null), node(1, "B", null), node(2, "T", null) };
    const edges = [_]sg.Edge{ edge(20, 0, 2), edge(21, 1, 2) };
    const groups = [_]ledger.JoinGroup{.{ .id = 0, .direction = .in, .pivot = 2, .members = &.{ 20, 21 } }};
    const memberships = [_]ledger.JoinMembership{
        .{ .edge = 20, .source_group = null, .target_group = 0 },
        .{ .edge = 21, .source_group = null, .target_group = 0 },
    };
    const permits: ledger.JoinPermits = .{ .policy = .joined, .groups = &groups, .memberships = &memberships };

    var rail_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer rail_arena.deinit();
    const rail = try coords.layout(rail_arena.allocator(), graph(.TD, &nodes, &edges, &.{}), .{
        .join_permits = &permits,
    });
    try testing.expectEqual(@as(usize, 1), rail.rails.len);
    try testing.expectEqual(sketch.EdgeRole.fan_in_dropper, rail.rails[0].role);
    try testing.expectEqual(@as(usize, 1), rail.rail_claims.len);
    try testing.expectEqual(ledger.RailPolarity.in, rail.rail_claims[0].polarity);
    try testing.expectEqual(@as(?ledger.NodeId, 2), ledger.checkRailClaim(rail.rail_claims[0]).derived_pivot);
    try expectAllValid(rail.rail_claims);

    const clustered_nodes = [_]sg.Node{ node(0, "A", null), node(1, "B", null), node(2, "T", 7) };
    const clustered_edges = [_]sg.Edge{
        styledEdge(20, 0, 2, .solid, .none, .filled, "left"),
        styledEdge(21, 1, 2, .solid, .none, .filled, "right"),
    };
    const clusters = [_]sg.Cluster{.{ .id = 7, .raw_id = "G", .label = "G", .parent = null, .members = &.{2}, .sub_clusters = &.{} }};
    var peer_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer peer_arena.deinit();
    const peer = try coords.layout(peer_arena.allocator(), graph(.TD, &clustered_nodes, &clustered_edges, &clusters), .{});
    try testing.expectEqual(@as(usize, 0), peer.rails.len);
    try testing.expectEqual(@as(usize, 2), peer.edges.len);
    try testing.expectEqual(@as(usize, 0), peer.rail_claims.len);
    const report = try raster.rasterize(peer_arena.allocator(), peer, .bridge);
    try testing.expectEqual(@as(u32, 0), report.labels_dropped);
}

test "fan provenance: forced peer drawing, wrapping, and arrow-style partition" {
    const forced_nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null) };
    const forced_edges = [_]sg.Edge{
        // Head at the SOURCE only: forces per-peer drawing (a pivot-side
        // head fails fan_rail.resolve eligibility) while every member still
        // blocks, so the star keeps its licence.
        styledEdge(0, 0, 1, .solid, .filled, .none, null),
        styledEdge(1, 0, 2, .solid, .filled, .none, null),
    };
    var forced_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer forced_arena.deinit();
    const forced = try coords.layout(forced_arena.allocator(), graph(.TD, &forced_nodes, &forced_edges, &.{}), .{});
    try testing.expectEqual(@as(usize, 0), forced.rails.len);
    try testing.expectEqual(@as(usize, 1), forced.rail_claims.len);
    try testing.expectEqual(sketch.ArrowKind.filled, forced.rail_claims[0].members[0].arrows[0]);
    try expectAllValid(forced.rail_claims);

    const wide_nodes = [_]sg.Node{
        node(0, "Pivot", null),  node(1, "Peer-A", null), node(2, "Peer-B", null), node(3, "Peer-C", null),
        node(4, "Peer-D", null), node(5, "Peer-E", null), node(6, "Peer-F", null),
    };
    const wide_edges = [_]sg.Edge{ edge(30, 0, 1), edge(31, 0, 2), edge(32, 0, 3), edge(33, 0, 4), edge(34, 0, 5), edge(35, 0, 6) };
    var wide_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer wide_arena.deinit();
    const wide = try coords.layout(wide_arena.allocator(), graph(.TD, &wide_nodes, &wide_edges, &.{}), .{ .max_width = 18 });
    try testing.expectEqual(@as(usize, 0), wide.rails.len);
    try testing.expectEqual(@as(usize, 6), wide.edges.len);
    try testing.expectEqual(@as(usize, 1), wide.rail_claims.len);
    try testing.expectEqual(@as(usize, 6), wide.rail_claims[0].members.len);
    try expectAllValid(wide.rail_claims);

    const mixed_nodes = [_]sg.Node{
        node(0, "P", null), node(1, "A", null), node(2, "B", null),
        node(3, "C", null), node(4, "D", null), node(5, "E", null),
    };
    const mixed_edges = [_]sg.Edge{
        edge(40, 0, 1),
        edge(41, 0, 2),
        styledEdge(42, 0, 3, .solid, .filled, .filled, null),
        styledEdge(43, 0, 4, .solid, .filled, .filled, null),
        styledEdge(44, 0, 5, .dotted, .none, .filled, null),
    };
    var mixed_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer mixed_arena.deinit();
    const mixed = try coords.layout(mixed_arena.allocator(), graph(.TD, &mixed_nodes, &mixed_edges, &.{}), .{});
    try testing.expectEqual(@as(usize, 0), mixed.rails.len);
    // Construction keeps the stable largest decoration/style class. The other
    // valid-looking class is not lane-proven independent here, so it stays
    // private rather than creating a second same-row shared channel.
    try testing.expectEqual(@as(usize, 1), mixed.rail_claims.len);
    try testing.expectEqual(@as(usize, 2), mixed.rail_claims[0].members.len);
    try testing.expect(hasMember(mixed.rail_claims[0], 40));
    try testing.expect(hasMember(mixed.rail_claims[0], 41));
    for (mixed.rail_claims) |claim| {
        try testing.expect(!hasMember(claim, 42));
        try testing.expect(!hasMember(claim, 43));
        try testing.expect(!hasMember(claim, 44));
    }
    for ([3]ledger.EdgeId{ 42, 43, 44 }) |id| {
        var private = false;
        for (mixed.edges) |path| {
            if (path.id == id) private = true;
        }
        try testing.expect(private);
    }
    try expectAllValid(mixed.rail_claims);
}

test "fan provenance: stable sequential local ids and BT mirrored sites" {
    const nodes = [_]sg.Node{
        node(0, "P", null), node(1, "A", null), node(2, "B", null), node(3, "C", null), node(4, "T", null),
    };
    const edges = [_]sg.Edge{
        edge(0, 0, 1), edge(1, 0, 2), edge(2, 0, 3),
        edge(3, 1, 4), edge(4, 2, 4), edge(5, 3, 4),
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try coords.layout(arena.allocator(), graph(.TD, &nodes, &edges, &.{}), .{});
    try testing.expectEqual(@as(usize, 2), s.rail_claims.len);
    try testing.expectEqual(@as(ledger.RailClaimId, 1), s.rail_claims[0].id);
    try testing.expectEqual(@as(ledger.RailClaimId, 2), s.rail_claims[1].id);
    try expectAllValid(s.rail_claims);

    const bt_nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null) };
    const bt_edges = [_]sg.Edge{ edge(10, 0, 1), edge(11, 0, 2) };
    var bt_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer bt_arena.deinit();
    const bt = try coords.layout(bt_arena.allocator(), graph(.BT, &bt_nodes, &bt_edges, &.{}), .{});
    try testing.expectEqual(@as(usize, 1), bt.rail_claims.len);
    try testing.expectEqual(ledger.RailPolarity.out, bt.rail_claims[0].polarity);
    try testing.expectEqual(sketch.Dir4.north, ledger.checkRailClaim(bt.rail_claims[0]).derived_pi.?.side);
    for (bt.rail_claims[0].members) |member| try testing.expectEqual(sketch.Dir4.south, member.sites[1].?.side);
    try expectAllValid(bt.rail_claims);
}

test "fan provenance: plan selection preserves the winning claims" {
    const nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2) };
    const groups = [_]ledger.JoinGroup{.{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 0, 1 } }};
    const memberships = [_]ledger.JoinMembership{
        .{ .edge = 0, .source_group = 0, .target_group = null },
        .{ .edge = 1, .source_group = 0, .target_group = null },
    };
    const permits: ledger.JoinPermits = .{ .policy = .joined, .groups = &groups, .memberships = &memberships };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const winner = try select.choose(arena.allocator(), graph(.TD, &nodes, &edges, &.{}), &permits, 120, false, false, .bridge);

    try testing.expectEqual(@as(usize, 1), winner.sketch.rail_claims.len);
    try testing.expectEqual(@as(ledger.RailClaimId, 1), winner.sketch.rail_claims[0].id);
    try testing.expect(ledger.checkRailClaim(winner.sketch.rail_claims[0]).isValid());
}

test "fan provenance: missing artifact stays unresolved and a private singleton is omitted" {
    const nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null), node(3, "C", null) };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 0, 3) };
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 4, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 0, .y = 6, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 8, .y = 6, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 16, .y = 6, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const line = [_]sketch.Point{ .{ .x = 6, .y = 2 }, .{ .x = 2, .y = 6 } };
    const paths = [_]sketch.EdgePath{.{
        .id = 0,
        .from = 0,
        .to = 1,
        .polyline = &line,
        .port_from = .{ .node = 0, .side = .south, .offset = 2 },
        .port_to = .{ .node = 1, .side = .north, .offset = 2 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    }};
    var peers = [_]fan.FanEdge{
        .{ .edge_id = 0, .peer_idx = 1, .role = .leftmost },
        .{ .edge_id = 1, .peer_idx = 2, .role = .rightmost },
        .{ .edge_id = 2, .peer_idx = 3, .role = .rightmost, .lane = 1 },
    };
    const fans = [_]fan.Fan{.{ .direction = .out, .pivot = 0, .pivot_idx = 0, .source_layer = 0, .peers = &peers }};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const claims = try provenance.build(arena.allocator(), graph(.TD, &nodes, &edges, &.{}), &placements, &fans, .{}, &paths, &.{});
    try testing.expectEqual(@as(usize, 1), claims.len);
    try testing.expectEqual(@as(usize, 2), claims[0].members.len);
    try testing.expect(!hasMember(claims[0], 2));
    const checked = ledger.checkRailClaim(claims[0]);
    try testing.expectEqual(@as(u32, 1), checked.derived_unresolved_members);
    try testing.expect(checked.record.unresolved);
}

test "fan provenance: duplicate leaf is private on flat and clustered peer paths" {
    const plain_nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", null) };
    const edges = [_]sg.Edge{
        styledEdge(10, 0, 1, .solid, .none, .filled, null),
        styledEdge(11, 0, 1, .solid, .none, .circle, "private"),
        styledEdge(12, 0, 2, .solid, .none, .filled, null),
    };
    const cluster = [_]sg.Cluster{.{ .id = 7, .raw_id = "G", .label = "G", .parent = null, .members = &.{2}, .sub_clusters = &.{} }};
    const clustered_nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", 7) };

    inline for (.{ graph(.TD, &plain_nodes, &edges, &.{}), graph(.TD, &clustered_nodes, &edges, &cluster) }) |g| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const s = try coords.layout(arena.allocator(), g, .{});

        try testing.expectEqual(@as(usize, 0), s.rails.len);
        try testing.expectEqual(@as(usize, 3), s.edges.len);
        try testing.expectEqual(@as(usize, 1), s.rail_claims.len);
        try testing.expectEqual(@as(usize, 2), s.rail_claims[0].members.len);
        try testing.expect(hasMember(s.rail_claims[0], 10));
        try testing.expect(hasMember(s.rail_claims[0], 12));
        try testing.expect(!hasMember(s.rail_claims[0], 11));
        try testing.expect(ledger.checkRailClaim(s.rail_claims[0]).isValid());

        var private: ?sketch.EdgePath = null;
        for (s.edges) |path| if (path.id == 11) {
            private = path;
        };
        try testing.expectEqualStrings("private", private.?.label.?);
        try testing.expectEqual(sketch.ArrowKind.circle, private.?.arrow_to);
        var retained: ?sketch.EdgePath = null;
        for (s.edges) |path| if (path.id == 10) {
            retained = path;
        };
        try testing.expect(private.?.port_from.offset != retained.?.port_from.offset);
        try testing.expect(private.?.port_to.offset != retained.?.port_to.offset);
        try testing.expectEqual(sketch.EdgeRole.fan_out_dropper, private.?.role);
        const report = try raster.rasterize(arena.allocator(), s, .bridge);
        try testing.expect(report.labels_placed > 0);
        try testing.expectEqual(@as(u32, 0), report.labels_dropped);
    }
}

test "fan provenance: several clustered private members receive unique ports" {
    const nodes = [_]sg.Node{ node(0, "P", null), node(1, "A", null), node(2, "B", 7) };
    const edges = [_]sg.Edge{
        styledEdge(10, 0, 1, .solid, .none, .filled, null),
        styledEdge(11, 0, 1, .solid, .none, .filled, "x"),
        styledEdge(12, 0, 1, .solid, .none, .filled, "y"),
        styledEdge(13, 0, 2, .solid, .none, .filled, null),
    };
    const clusters = [_]sg.Cluster{.{ .id = 7, .raw_id = "G", .label = "G", .parent = null, .members = &.{2}, .sub_clusters = &.{} }};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try coords.layout(a, graph(.TD, &nodes, &edges, &clusters), .{});

    var source_offsets: [4]u32 = undefined;
    var target_offsets: [3]u32 = undefined;
    for (s.edges) |path| {
        source_offsets[path.id - 10] = path.port_from.offset;
        if (path.id <= 12) target_offsets[path.id - 10] = path.port_to.offset;
    }
    // Retained members 10 and 13 share the one legal pivot attachment. The two
    // excluded members each own a different source attachment instead.
    try testing.expectEqual(source_offsets[0], source_offsets[3]);
    try testing.expect(source_offsets[1] != source_offsets[0]);
    try testing.expect(source_offsets[2] != source_offsets[0]);
    try testing.expect(source_offsets[1] != source_offsets[2]);
    for (target_offsets, 0..) |offset, i| for (target_offsets[0..i]) |prior| try testing.expect(offset != prior);
}

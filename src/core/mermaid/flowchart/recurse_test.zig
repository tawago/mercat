const std = @import("std");
const prim = @import("prim");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const coords = @import("layout.zig");
const cluster_split = @import("cluster/split.zig");
const cluster_stitch = @import("cluster/stitch.zig");
const validate = @import("layout/validate.zig");
const recurse = @import("recurse.zig");
const raster = @import("raster.zig");
const ledger = @import("base/ledger.zig");
const bundle_mod = @import("base/bundle.zig");
const rail_star = @import("base/rail_star.zig");

fn nestedTwoLevelGraph(nodes_buf: []sem_graph.Node, edges_buf: []sem_graph.Edge, members_buf: []sem_graph.NodeId, sub_buf: []sem_graph.ClusterId, clusters_buf: []sem_graph.Cluster) sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    nodes_buf[0] = .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null };
    nodes_buf[1] = .{ .id = 1, .raw_id = "a", .label = "alphaalpha", .shape = NS.rect, .classes = &.{}, .cluster = 200 };
    nodes_buf[2] = .{ .id = 2, .raw_id = "b", .label = "bravobravo", .shape = NS.rect, .classes = &.{}, .cluster = 200 };
    nodes_buf[3] = .{ .id = 3, .raw_id = "c", .label = "charliecharlie", .shape = NS.rect, .classes = &.{}, .cluster = 200 };
    nodes_buf[4] = .{ .id = 4, .raw_id = "d", .label = "deltadelta", .shape = NS.rect, .classes = &.{}, .cluster = 200 };
    edges_buf[0] = .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[1] = .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[2] = .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[3] = .{ .id = 3, .from = 3, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    members_buf[0] = 1;
    members_buf[1] = 2;
    members_buf[2] = 3;
    members_buf[3] = 4;
    sub_buf[0] = 200;
    clusters_buf[0] = .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &.{}, .sub_clusters = sub_buf, .direction = null };
    clusters_buf[1] = .{ .id = 200, .raw_id = "T", .label = "T", .parent = 100, .members = members_buf, .sub_clusters = &.{}, .direction = .LR };
    return .{
        .direction = .TD,
        .nodes = nodes_buf,
        .edges = edges_buf,
        .clusters = clusters_buf,
        .classes = &.{},
        .arena = null,
    };
}

fn singleClusterChainGraph(nodes_buf: []sem_graph.Node, edges_buf: []sem_graph.Edge, members_buf: []sem_graph.NodeId, clusters_buf: []sem_graph.Cluster) sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    nodes_buf[0] = .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null };
    nodes_buf[1] = .{ .id = 1, .raw_id = "a", .label = "alphaalpha", .shape = NS.rect, .classes = &.{}, .cluster = 100 };
    nodes_buf[2] = .{ .id = 2, .raw_id = "b", .label = "bravobravo", .shape = NS.rect, .classes = &.{}, .cluster = 100 };
    nodes_buf[3] = .{ .id = 3, .raw_id = "c", .label = "charliecharlie", .shape = NS.rect, .classes = &.{}, .cluster = 100 };
    nodes_buf[4] = .{ .id = 4, .raw_id = "d", .label = "deltadelta", .shape = NS.rect, .classes = &.{}, .cluster = 100 };
    edges_buf[0] = .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[1] = .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[2] = .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    edges_buf[3] = .{ .id = 3, .from = 3, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    members_buf[0] = 1;
    members_buf[1] = 2;
    members_buf[2] = 3;
    members_buf[3] = 4;
    clusters_buf[0] = .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = members_buf, .sub_clusters = &.{}, .direction = .LR };
    return .{
        .direction = .TD,
        .nodes = nodes_buf,
        .edges = edges_buf,
        .clusters = clusters_buf,
        .classes = &.{},
        .arena = null,
    };
}

test "nested cluster: outer super-node pad tracks framePadX(scale) across two recursion levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var sub_buf: [1]sem_graph.ClusterId = undefined;
    var clusters_buf: [2]sem_graph.Cluster = undefined;
    const graph = nestedTwoLevelGraph(&nodes_buf, &edges_buf, &members_buf, &sub_buf, &clusters_buf);

    for ([_]u8{ 0, 1 }) |scale| {
        const s = try recurse.layoutPieces(a, graph, .{ .max_width = 400, .spacing_scale = scale });
        var t_rect: ?sketch.Rect = null;
        var s_rect: ?sketch.Rect = null;
        for (s.clusters) |cf| {
            if (cf.id == 200) t_rect = cf.rect;
            if (cf.id == 100) s_rect = cf.rect;
        }
        const expected_pad = 2 * prim.framePadX(scale);
        try std.testing.expectEqual(t_rect.?.w + expected_pad, s_rect.?.w);
        try std.testing.expectEqual(sem_graph.Direction.LR, innerLeafDirection(s, 200).?);
    }
}

fn innerLeafDirection(s: sketch.Sketch, cluster_id: sem_graph.ClusterId) ?sem_graph.Direction {
    for (s.clusters) |cf| {
        if (cf.id == cluster_id) return cf.direction;
    }
    return null;
}

fn nestedArrivalGraph(a: std.mem.Allocator, depth: usize) !sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    const innermost: sem_graph.ClusterId = @intCast(depth * 100);
    const nodes = try a.alloc(sem_graph.Node, 2);
    nodes[0] = .{ .id = 0, .raw_id = "X", .label = "X", .shape = NS.rect, .classes = &.{}, .cluster = null };
    nodes[1] = .{ .id = 1, .raw_id = "A", .label = "A", .shape = NS.rect, .classes = &.{}, .cluster = innermost };
    const edges = try a.alloc(sem_graph.Edge, 1);
    edges[0] = .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    const members = try a.alloc(sem_graph.NodeId, 1);
    members[0] = 1;
    const clusters = try a.alloc(sem_graph.Cluster, depth);
    for (clusters, 1..) |*c, level| {
        const id: sem_graph.ClusterId = @intCast(level * 100);
        const subs = try a.alloc(sem_graph.ClusterId, if (level < depth) 1 else 0);
        if (level < depth) subs[0] = id + 100;
        c.* = .{
            .id = id,
            .raw_id = "C",
            .label = "C",
            .parent = if (level == 1) null else id - 100,
            .members = if (level == depth) members else &.{},
            .sub_clusters = subs,
        };
    }
    return .{ .direction = .TD, .nodes = nodes, .edges = edges, .clusters = clusters, .classes = &.{}, .arena = null };
}

fn clusterRect(s: sketch.Sketch, cluster_id: sem_graph.ClusterId) sketch.Rect {
    for (s.clusters) |cf| {
        if (cf.id == cluster_id) return cf.rect;
    }
    unreachable;
}

test "an arrival inherited through every nesting level clears the innermost frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pad: i32 = @intCast(prim.framePadY(0));
    for ([_]usize{ 1, 2, 3 }) |depth| {
        const graph = try nestedArrivalGraph(a, depth);
        const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });
        const innermost = clusterRect(s, @intCast(depth * 100));
        try std.testing.expectEqual(pad + 1, s.nodes[1].rect.y - innermost.y);
        var level: usize = 1;
        while (level < depth) : (level += 1) {
            const outer = clusterRect(s, @intCast(level * 100));
            const inner = clusterRect(s, @intCast((level + 1) * 100));
            try std.testing.expectEqual(pad, inner.y - outer.y);
        }
    }
}

test "nested cluster: width sub-budget shrinks once per nesting level (saturating)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var sub_buf: [1]sem_graph.ClusterId = undefined;
    var clusters_buf: [2]sem_graph.Cluster = undefined;
    const graph = nestedTwoLevelGraph(&nodes_buf, &edges_buf, &members_buf, &sub_buf, &clusters_buf);

    const Case = struct { mw: u32, scale: u8, want: sem_graph.Direction };
    const cases = [_]Case{
        .{ .mw = 84, .scale = 0, .want = .TD },
        .{ .mw = 87, .scale = 0, .want = .TD },
        .{ .mw = 88, .scale = 0, .want = .LR },
        .{ .mw = 78, .scale = 1, .want = .TD },
        .{ .mw = 79, .scale = 1, .want = .TD },
        .{ .mw = 80, .scale = 1, .want = .LR },
    };
    for (cases) |c| {
        const s = try recurse.layoutPieces(a, graph, .{ .max_width = c.mw, .spacing_scale = c.scale });
        try std.testing.expectEqual(c.want, innerLeafDirection(s, 200).?);
    }

    _ = try recurse.layoutPieces(a, graph, .{ .max_width = 1, .spacing_scale = 1 });
}

test "declared baseline is always computed and never exceeded when a child flips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var clusters_buf: [1]sem_graph.Cluster = undefined;
    const graph = singleClusterChainGraph(&nodes_buf, &edges_buf, &members_buf, &clusters_buf);

    const opts: coords.LayoutOptions = .{ .max_width = 40 };
    const sr = try cluster_split.split(a, graph, .{});
    try std.testing.expect(!sr.isFlat());

    var child_opts = opts;
    child_opts.max_width = opts.max_width -| recurse.pieceFrameOverheadX(sr, 1, opts.spacing_scale);
    const cc = try recurse.layoutChild(a, sr.pieces[1].graph, child_opts, .{});
    try std.testing.expect(cc.flipped != null);

    const declared_children = try a.alloc(cluster_stitch.Clustered, sr.pieces.len);
    declared_children[1] = cc.declared;
    const declared_out = try recurse.stitchOuter(a, sr, opts, declared_children);

    const result = try recurse.layoutPieces(a, graph, opts);
    try std.testing.expect(result.bbox.w <= declared_out.sketch.bbox.w);
}

test "rotation that reduces but does not eliminate overflow is rejected (validator cross-check)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var clusters_buf: [1]sem_graph.Cluster = undefined;
    const graph = singleClusterChainGraph(&nodes_buf, &edges_buf, &members_buf, &clusters_buf);

    const sr = try cluster_split.split(a, graph, .{});
    const child_opts: coords.LayoutOptions = .{ .max_width = 14 };
    const cc = try recurse.layoutChild(a, sr.pieces[1].graph, child_opts, .{});

    try std.testing.expect(cc.declared.sketch.bbox.w > child_opts.max_width);
    try std.testing.expect(cc.flipped == null);

    var rotated_graph = sr.pieces[1].graph;
    rotated_graph.direction = prim.rotatedDirection(sr.pieces[1].graph.direction);
    const rotated = try recurse.layoutClustered(a, rotated_graph, child_opts, .{});
    try std.testing.expect(rotated.sketch.bbox.w < cc.declared.sketch.bbox.w);
    try std.testing.expect(rotated.sketch.bbox.w > child_opts.max_width);

    var budgeted = rotated.sketch;
    budgeted.budget = .{ .max_width = child_opts.max_width, .rung = 0 };
    const vr = try validate.validate(a, budgeted);
    const c = validate.counts(vr, budgeted);
    try std.testing.expect(c.bbox_overflow >= 1);
}

test "stitch re-clamps a surviving rail's crossbar past a dropped super-node tap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NS = sem_graph.NodeShape;
    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "P", .label = "P", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "A", .label = "A", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 2, .raw_id = "B", .label = "B", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 3, .raw_id = "D", .label = "D", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 0, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{3};
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{} },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const opts: coords.LayoutOptions = .{ .max_width = 400 };
    const sr = try cluster_split.split(a, graph, .{});
    try std.testing.expect(!sr.isFlat());
    try std.testing.expectEqual(@as(usize, 1), sr.supers.len);

    const child = try recurse.layoutChild(a, sr.pieces[1].graph, opts, .{});
    const children = try a.alloc(cluster_stitch.Clustered, sr.pieces.len);
    children[1] = child.declared;

    const fixed = try a.alloc(coords.FixedSize, sr.supers.len);
    for (sr.supers, 0..) |super, i| {
        const sz = cluster_stitch.superSize(children[super.child_piece].sketch.bbox, opts.spacing_scale, super.synthetic);
        fixed[i] = .{ .node = super.outer_node, .w = sz.w, .h = sz.h };
    }
    var outer_opts = opts;
    outer_opts.fixed_sizes = fixed;
    const outer = try coords.layout(a, sr.pieces[0].graph, outer_opts);
    children[0] = .{ .sketch = outer, .input_of = &.{} };

    try std.testing.expectEqual(@as(usize, 1), outer.rails.len);
    try std.testing.expectEqual(@as(usize, 3), outer.rails[0].taps.len);
    var dropped_x: ?i32 = null;
    for (outer.rails[0].taps) |tap| {
        if (tap.node == sr.supers[0].outer_node) dropped_x = tap.at.x;
    }
    try std.testing.expect(dropped_x != null);

    const merged = try cluster_stitch.stitch(a, sr, outer, children, opts.spacing_scale, false, .plain);

    try std.testing.expectEqual(@as(usize, 1), merged.sketch.rails.len);
    try std.testing.expectEqual(@as(usize, 2), merged.sketch.rails[0].taps.len);
    const crossbar = merged.sketch.rails[0].crossbar;
    try std.testing.expect(crossbar[0].x <= crossbar[1].x);
    try std.testing.expect(dropped_x.? > crossbar[1].x or dropped_x.? < crossbar[0].x);
}

fn twoSiblingFanGraph(
    nodes_buf: []sem_graph.Node,
    edges_buf: []sem_graph.Edge,
    members_s: []sem_graph.NodeId,
    members_r: []sem_graph.NodeId,
    clusters_buf: []sem_graph.Cluster,
) sem_graph.SemGraph {
    const NS = sem_graph.NodeShape;
    const names = [_][]const u8{ "Top", "a1", "a2", "a3", "b1", "b2", "b3", "End" };
    const owners = [_]?sem_graph.ClusterId{ null, 100, 100, 100, 200, 200, 200, null };
    for (names, 0..) |nm, i| {
        nodes_buf[i] = .{ .id = @intCast(i), .raw_id = nm, .label = nm, .shape = NS.rect, .classes = &.{}, .cluster = owners[i] };
    }
    const pairs = [_][2]sem_graph.NodeId{
        .{ 0, 1 }, .{ 1, 2 }, .{ 1, 3 }, .{ 0, 4 },
        .{ 4, 5 }, .{ 4, 6 }, .{ 2, 7 }, .{ 5, 7 },
        .{ 0, 7 },
    };
    for (pairs, 0..) |p, i| {
        edges_buf[i] = .{ .id = @intCast(i), .from = p[0], .to = p[1], .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    }
    members_s[0] = 1;
    members_s[1] = 2;
    members_s[2] = 3;
    members_r[0] = 4;
    members_r[1] = 5;
    members_r[2] = 6;
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

pub fn assertUniqueEdgeIds(a: std.mem.Allocator, s: sketch.Sketch) !std.AutoHashMap(sketch.EdgeId, sketch.NodeId) {
    var owners = std.AutoHashMap(sketch.EdgeId, sketch.NodeId).init(a);
    for (s.edges) |e| {
        if (e.role != .member_stroke) try std.testing.expect(!owners.contains(e.id));
        if (!owners.contains(e.id)) try owners.put(e.id, e.from);
    }
    for (s.rails) |b| {
        for (b.taps) |t| {
            if (!t.continues) try std.testing.expect(!owners.contains(t.edge));
            if (!owners.contains(t.edge)) try owners.put(t.edge, b.pivot);
        }
    }
    return owners;
}

pub fn clusterOf(s: sketch.Sketch, node: sketch.NodeId) !?sem_graph.ClusterId {
    for (s.nodes) |p| {
        if (p.id == node) return p.cluster_id;
    }
    return error.NodeNotPlaced;
}

test "stitched sibling clusters share one edge-id space" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [8]sem_graph.Node = undefined;
    var edges_buf: [9]sem_graph.Edge = undefined;
    var members_s: [3]sem_graph.NodeId = undefined;
    var members_r: [3]sem_graph.NodeId = undefined;
    var clusters_buf: [2]sem_graph.Cluster = undefined;
    const graph = twoSiblingFanGraph(&nodes_buf, &edges_buf, &members_s, &members_r, &clusters_buf);

    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });
    try std.testing.expect(s.clusters.len >= 2);

    var owners = try assertUniqueEdgeIds(a, s);
    defer owners.deinit();

    for (s.bundle_sets) |set| {
        if (set.origin == .port_share) {
            for (set.members) |m| {
                const owner = owners.get(m) orelse continue;
                _ = try clusterOf(s, owner);
            }
            continue;
        }
        var seen: ??sem_graph.ClusterId = null;
        for (set.members) |m| {
            const owner = owners.get(m) orelse continue;
            const cid = try clusterOf(s, owner);
            if (seen) |want| try std.testing.expectEqual(want, cid) else seen = cid;
        }
    }
}

test "edge-id uniqueness survives two stitch levels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [5]sem_graph.Node = undefined;
    var edges_buf: [4]sem_graph.Edge = undefined;
    var members_buf: [4]sem_graph.NodeId = undefined;
    var sub_buf: [1]sem_graph.ClusterId = undefined;
    var clusters_buf: [2]sem_graph.Cluster = undefined;
    const graph = nestedTwoLevelGraph(&nodes_buf, &edges_buf, &members_buf, &sub_buf, &clusters_buf);

    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 400 });
    var owners = try assertUniqueEdgeIds(a, s);
    defer owners.deinit();
    try std.testing.expect(owners.count() >= graph.edges.len);
}

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
    try std.testing.expectEqual(@as(rail_star.RailClaimId, 1), claim.id);
    try std.testing.expectEqual(rail_star.RailPolarity.in, claim.polarity);
    try std.testing.expectEqual(@as(usize, 2), claim.members.len);
    try std.testing.expect(rail_star.check(claim).isValid());
    for (claim.members) |member| {
        var carrier = false;
        for (s.edges) |edge| carrier = carrier or edge.id == member.edge;
        for (s.rails) |rail| for (rail.taps) |tap| {
            carrier = carrier or tap.edge == member.edge;
        };
        try std.testing.expect(carrier);
    }
}

fn placementNamed(s: sketch.Sketch, name: []const u8) ?sketch.NodePlacement {
    for (s.nodes) |p| {
        if (p.lines.len != 0 and std.mem.eql(u8, p.lines[0], name)) return p;
    }
    return null;
}

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
        edges_buf[0].label = "yes";
        edges_buf[2].label = "no";
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

    var found = false;
    for (s.bundle_sets) |set| {
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

    var claimed = false;
    for (s.rail_claims) |claim| {
        if (claim.polarity != .out or claim.members.len < 2) continue;
        const checked = rail_star.check(claim);
        if (checked.derived_pivot != top.id or !checked.isValid()) continue;
        for (claim.members) |member| {
            if (member.node(.source) != top.id) break;
            if (edgeById(s, member.edge) == null) break;
        } else claimed = true;
    }
    try std.testing.expect(claimed);
}

fn frameOf(s: sketch.Sketch, id: sem_graph.ClusterId) ?sketch.ClusterFrame {
    for (s.clusters) |c| {
        if (c.id == id) return c;
    }
    return null;
}

fn topToFrameGap(s: sketch.Sketch) !u32 {
    const top = placementNamed(s, "Top") orelse return error.TopNotPlaced;
    const frame = frameOf(s, 100) orelse return error.FrameNotPlaced;
    const bottom: i32 = top.rect.y + @as(i32, @intCast(top.rect.h));
    if (frame.rect.y < bottom) return error.FrameAboveTop;
    return @intCast(frame.rect.y - bottom);
}

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

    try std.testing.expectEqual(try topToFrameGap(sp), try topToFrameGap(sl));
    try std.testing.expectEqual(sp.bbox.h, sl.bbox.h);

    const top = placementNamed(sl, "Top") orelse return error.TopNotPlaced;
    var crossings: usize = 0;
    for (sl.edges) |e| {
        if (e.from != top.id) continue;
        if (try clusterOf(sl, e.to) != null) crossings += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), crossings);
}

test "two bridges into one port are one selected bundle at the target end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [4]sem_graph.Node = undefined;
    var edges_buf: [3]sem_graph.Edge = undefined;
    var members: [2]sem_graph.NodeId = undefined;
    var clusters_buf: [1]sem_graph.Cluster = undefined;
    const graph = twoBridgesIntoOnePortGraph(&nodes_buf, &edges_buf, &members, &clusters_buf);

    const permits = ledger.BundlePermits{ .policy = .joined, .scope = .skipped_clustered };
    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120, .bundle_permits = &permits });
    const c = placementNamed(s, "C") orelse return error.TargetNotPlaced;

    var bundle: ?ledger.SelectedBundleId = null;
    var arrivals: usize = 0;
    for (s.bundles.memberships) |m| {
        const e = edgeById(s, m.edge) orelse continue;
        if (e.to != c.id) continue;
        arrivals += 1;
        const disp = m.target orelse return error.ArrivalUndecided;
        try std.testing.expect(disp == .selected);
        if (bundle) |b| try std.testing.expectEqual(b, disp.selected) else bundle = disp.selected;
    }
    try std.testing.expectEqual(@as(usize, 2), arrivals);
    try std.testing.expectEqual(@as(usize, 2), s.bundles.selected_bundles[bundle.?].members.len);
}

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

test "two bridges into one port declare a port-share bundle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var nodes_buf: [4]sem_graph.Node = undefined;
    var edges_buf: [3]sem_graph.Edge = undefined;
    var members: [2]sem_graph.NodeId = undefined;
    var clusters_buf: [1]sem_graph.Cluster = undefined;
    const graph = twoBridgesIntoOnePortGraph(&nodes_buf, &edges_buf, &members, &clusters_buf);

    const s = try recurse.layoutPieces(a, graph, .{ .max_width = 120 });

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

    var checked = false;
    for (0..n) |i| for (i + 1..n) |j| {
        const first = edgeById(s, arrivals[i]) orelse continue;
        const second = edgeById(s, arrivals[j]) orelse continue;
        const fe = first.polyline[first.polyline.len - 1];
        const se = second.polyline[second.polyline.len - 1];
        if (fe.x != se.x or fe.y != se.y) continue;
        checked = true;
        var named = false;
        for (s.bundle_sets) |set| {
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
    try std.testing.expectEqual(@as(usize, 1), s.rails.len);

    var licensed = false;
    for (s.rails[0].taps) |tap| {
        if (bundle_mod.bundleMembersAt(s.bundle_sets, tap.edge, final_bridge.id, .{
            .x = final_bridge.polyline[0].x,
            .y = final_bridge.polyline[0].y + 1,
        })) licensed = true;
    }
    try std.testing.expect(licensed);

    const report = try raster.rasterize(a, s, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.foreign_junction_violation);
    try std.testing.expectEqual(@as(u32, 0), report.crossings.arrowhead_transit_violation);
}

fn edgeById(s: sketch.Sketch, id: sketch.EdgeId) ?sketch.EdgePath {
    for (s.edges) |e| {
        if (e.id == id) return e;
    }
    return null;
}

//! Integration tests for `recurse.zig` that need both `cluster/`- and
//! `layout/`-zone privileges (split out to keep `recurse.zig` under the
//! mermaid_v2 500-line cap). Discovered by `recurse.zig`'s own top-level
//! `test { ... }` block, the established `x.zig` -> `x_test.zig` pattern.

const std = @import("std");
const prim = @import("prim");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const coords = @import("layout.zig");
const cluster_split = @import("cluster/split.zig");
const cluster_stitch = @import("cluster/stitch.zig");
const validate = @import("layout/validate.zig");
const recurse = @import("recurse.zig");

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

/// Find a specific cluster's recorded direction (by id) in a stitched
/// Sketch, regardless of nesting depth.
fn innerLeafDirection(s: sketch.Sketch, cluster_id: sem_graph.ClusterId) ?sem_graph.Direction {
    for (s.clusters) |cf| {
        if (cf.id == cluster_id) return cf.direction;
    }
    return null;
}

/// `X --> A`, X top-level, A the sole member of the innermost of `depth`
/// nested clusters (ids 100, 200, ...; each the only child of the previous).
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

    // The arrowhead sits in the arrival cell right above A; the cell above it must be a plain run, never the frame's title row — so the frame A sits in grows one row past its pad, at every depth, and no enclosing frame (which the edge only passes through) grows at all.
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

/// Every edge id the merged Sketch names geometrically (`EdgePath.id` plus
/// each rail `Tap.edge`), asserted pairwise distinct, and returned so a
/// caller can resolve bundle members against it.
/// Every edge id has one owner. A member whose tap `continues` is the one
/// sanctioned repeat: its rail tap (one per rail end) plus its own
/// `.member_stroke` are one edge's ink, and the first sighting owns it.
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

/// The cluster owning `node` in a merged Sketch. A node the Sketch does not
/// place is a FAILURE, never a skip: silently treating "no such node" as
/// "top-level" would let a comparison pass by finding nothing to compare.
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

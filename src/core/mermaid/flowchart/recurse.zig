const std = @import("std");
const prim = @import("prim");
const sketch = @import("sketch.zig");
const sem_graph = @import("sem_graph.zig");
const coords = @import("layout.zig");
const cluster_split = @import("cluster/split.zig");
const cluster_stitch = @import("cluster/stitch.zig");

pub const RecurseError = coords.CoordsError || cluster_stitch.StitchError;

/// @guarded-by: entry.zig "V-D-IR-07: a clustered graph's bundles ride piece plans; the root plan stays skipped"
pub fn layoutPieces(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    opts: coords.LayoutOptions,
) RecurseError!sketch.Sketch {
    return (try layoutClustered(arena, graph, opts, .{})).sketch;
}

/// @guarded-by: recurse_test.zig "an arrival inherited through every nesting level clears the innermost frame"
pub fn layoutClustered(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    opts: coords.LayoutOptions,
    inherited: cluster_split.Inherited,
) RecurseError!cluster_stitch.Clustered {
    const sr = try cluster_split.split(arena, graph, inherited);

    if (sr.isFlat()) {
        var flat_opts = opts;
        flat_opts.departures = try departingNodes(arena, inherited.departures, null);
        const s = try coords.layout(arena, sr.pieces[0].graph, flat_opts);
        return .{ .sketch = s, .input_of = try identityMap(arena, s.nodes) };
    }
    var outer_opts = opts;
    outer_opts.departures = try departingNodes(arena, inherited.departures, sr.pieces[0].orig_ids);

    // @guarded-by: recurse_test.zig "nested cluster: width sub-budget shrinks once per nesting level (saturating)"
    const choices = try arena.alloc(ChildChoice, sr.pieces.len);
    var any_flip = false;
    for (sr.pieces[1..], 1..) |piece, i| {
        var child_opts = opts;
        child_opts.max_width = opts.max_width -| pieceFrameOverheadX(sr, i, opts.spacing_scale);
        choices[i] = try layoutChild(arena, piece.graph, child_opts, try sr.childInherited(arena, i));
        if (choices[i].flipped != null) any_flip = true;
    }

    // @guarded-by: recurse_test.zig "declared baseline is always computed and never exceeded when a child flips"
    const declared_children = try arena.alloc(cluster_stitch.Clustered, sr.pieces.len);
    for (choices[1..], 1..) |c, i| declared_children[i] = c.declared;
    const declared_out = try stitchOuter(arena, sr, outer_opts, declared_children);

    if (!any_flip) return declared_out;

    const greedy_children = try arena.alloc(cluster_stitch.Clustered, sr.pieces.len);
    for (choices[1..], 1..) |c, i| greedy_children[i] = c.flipped orelse c.declared;
    const greedy_out = try stitchOuter(arena, sr, outer_opts, greedy_children);

    if (greedy_out.sketch.bbox.w < declared_out.sketch.bbox.w) return greedy_out;
    return declared_out;
}

pub fn stitchOuter(
    arena: std.mem.Allocator,
    sr: cluster_split.SplitResult,
    opts: coords.LayoutOptions,
    children: []cluster_stitch.Clustered,
) RecurseError!cluster_stitch.Clustered {
    const fixed = try arena.alloc(coords.FixedSize, sr.supers.len);
    for (sr.supers, 0..) |super, i| {
        const sz = cluster_stitch.superSize(children[super.child_piece].sketch.bbox, opts.spacing_scale, super.synthetic);
        const ei = cluster_stitch.entryInsetFor(sr, children, super);
        fixed[i] = .{ .node = super.outer_node, .w = sz.w + ei.wExtra(), .h = sz.h + ei.hExtra(), .synthetic = super.synthetic };
    }
    var outer_opts = opts;
    outer_opts.fixed_sizes = fixed;
    const outer = try coords.layout(arena, sr.pieces[0].graph, outer_opts);
    children[0] = .{ .sketch = outer, .input_of = &.{} };
    const authored_cluster_run = if (opts.bundle_permits) |p| !p.isFlat() else false;
    return cluster_stitch.stitch(arena, sr, outer, children, opts.spacing_scale, authored_cluster_run, opts.bridge_build);
}

pub fn pieceFrameOverheadX(sr: cluster_split.SplitResult, piece_idx: usize, scale: u32) u32 {
    for (sr.supers) |s| {
        if (s.child_piece == piece_idx) {
            return if (s.synthetic) 0 else prim.frameOverheadX(scale);
        }
    }
    return prim.frameOverheadX(scale);
}

const ChildChoice = struct {
    declared: cluster_stitch.Clustered,
    flipped: ?cluster_stitch.Clustered,
};

pub fn layoutChild(
    arena: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    child_opts: coords.LayoutOptions,
    inherited: cluster_split.Inherited,
) RecurseError!ChildChoice {
    const declared = try layoutClustered(arena, graph, child_opts, inherited);
    if (declared.sketch.bbox.w <= child_opts.max_width) {
        return .{ .declared = declared, .flipped = null };
    }

    var rotated_graph = graph;
    rotated_graph.direction = prim.rotatedDirection(graph.direction);
    const rotated = try layoutClustered(arena, rotated_graph, child_opts, inherited);

    // @guarded-by: recurse_test.zig "rotation that reduces but does not eliminate overflow is rejected (validator cross-check)"
    if (rotated.sketch.bbox.w < declared.sketch.bbox.w and
        rotated.sketch.bbox.w <= child_opts.max_width)
    {
        return .{ .declared = declared, .flipped = rotated };
    }
    return .{ .declared = declared, .flipped = null };
}

fn departingNodes(arena: std.mem.Allocator, departures: []const cluster_split.Departure, orig_ids: ?[]const sem_graph.NodeId) RecurseError![]const sem_graph.NodeId {
    var out: std.ArrayListUnmanaged(sem_graph.NodeId) = .empty;
    for (departures) |d| {
        if (orig_ids) |ids| {
            for (ids, 0..) |o, i| if (o == d.from) try out.append(arena, @intCast(i));
        } else try out.append(arena, d.from);
    }
    return out.toOwnedSlice(arena);
}

fn identityMap(arena: std.mem.Allocator, nodes: []const sketch.NodePlacement) RecurseError![]sketch.NodeId {
    var max: sketch.NodeId = 0;
    for (nodes) |n| {
        if (n.id > max) max = n.id;
    }
    const len: usize = if (nodes.len == 0) 0 else @as(usize, max) + 1;
    const m = try arena.alloc(sketch.NodeId, len);
    for (m, 0..) |*slot, i| slot.* = @intCast(i);
    return m;
}

fn innerClusterDirection(s: sketch.Sketch) ?sem_graph.Direction {
    for (s.clusters) |cf| {
        if (cf.parent_id == null) return cf.direction;
    }
    return null;
}

test "inner-flip scenario: inner LR-in-TD subgraph flips to TD at narrow width, stays LR at wide; outer stays TD" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NS = sem_graph.NodeShape;
    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "a", .label = "alphaalpha", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 2, .raw_id = "b", .label = "bravobravo", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 3, .raw_id = "c", .label = "charliecharlie", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 4, .raw_id = "d", .label = "deltadelta", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 3, .from = 3, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{ 1, 2, 3, 4 };
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{}, .direction = .LR },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const narrow = try layoutPieces(a, graph, .{ .max_width = 40 });
    try std.testing.expectEqual(sem_graph.Direction.TD, narrow.direction);
    try std.testing.expectEqual(sem_graph.Direction.TD, innerClusterDirection(narrow).?);

    const wide = try layoutPieces(a, graph, .{ .max_width = 400 });
    try std.testing.expectEqual(sem_graph.Direction.TD, wide.direction);
    try std.testing.expectEqual(sem_graph.Direction.LR, innerClusterDirection(wide).?);
}

test "layoutChild never widens: rotation rejected when it does not reduce width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NS = sem_graph.NodeShape;
    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "x", .label = "wwwwwwwwwwwwwwww", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{1};
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{}, .direction = .LR },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const s = try layoutPieces(a, graph, .{ .max_width = 8 });
    try std.testing.expectEqual(sem_graph.Direction.LR, innerClusterDirection(s).?);
}

test "fitting child keeps declared direction (overall never widened by a needless flip)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const NS = sem_graph.NodeShape;
    const nodes = [_]sem_graph.Node{
        .{ .id = 0, .raw_id = "Top", .label = "Top", .shape = NS.rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "a", .label = "A", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 2, .raw_id = "b", .label = "B", .shape = NS.rect, .classes = &.{}, .cluster = 100 },
        .{ .id = 3, .raw_id = "Bot", .label = "Bot", .shape = NS.rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sem_graph.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const members = [_]sem_graph.NodeId{ 1, 2 };
    const clusters = [_]sem_graph.Cluster{
        .{ .id = 100, .raw_id = "S", .label = "S", .parent = null, .members = &members, .sub_clusters = &.{}, .direction = .LR },
    };
    const graph: sem_graph.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };

    const budget: u32 = 200;
    const s = try layoutPieces(a, graph, .{ .max_width = budget });
    try std.testing.expectEqual(sem_graph.Direction.LR, innerClusterDirection(s).?);
    try std.testing.expect(s.bbox.w <= budget);
}

test {
    _ = @import("recurse_test.zig");
    _ = @import("recurse_test2.zig");
}

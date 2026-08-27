//! Post-routing bridge authority reconstruction tests.

const std = @import("std");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const bridge_cosets = @import("bridge_cosets.zig");
const bridge_claims = @import("bridge_claims.zig");
const split_mod = @import("split.zig");

const testing = std.testing;

fn emptyGraph() sg.SemGraph {
    return .{
        .direction = .TD,
        .nodes = &.{},
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
}

fn twoTargetSplit(crossings: []const split_mod.Crossing) split_mod.SplitResult {
    const S = struct {
        const outer_ids = [_]sg.NodeId{ 0, sg.SENTINEL, sg.SENTINEL };
        const left_ids = [_]sg.NodeId{1};
        const right_ids = [_]sg.NodeId{2};
        const pieces = [_]split_mod.Piece{
            .{ .graph = emptyGraph(), .cluster_id = null, .orig_ids = &outer_ids },
            .{ .graph = emptyGraph(), .cluster_id = 10, .orig_ids = &left_ids },
            .{ .graph = emptyGraph(), .cluster_id = 20, .orig_ids = &right_ids },
        };
        const supers = [_]split_mod.SuperNode{
            .{ .outer_node = 1, .cluster_id = 10, .child_piece = 1 },
            .{ .outer_node = 2, .cluster_id = 20, .child_piece = 2 },
        };
    };
    return .{ .pieces = &S.pieces, .supers = &S.supers, .crossings = crossings, .orig_node_count = 3 };
}

fn outerPath(id: sketch.EdgeId, from: sketch.NodeId, to: sketch.NodeId) sketch.EdgePath {
    return path(id, from, to, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 });
}

fn path(id: sketch.EdgeId, from: sketch.NodeId, to: sketch.NodeId, first: sketch.Point, last: sketch.Point) sketch.EdgePath {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .polyline = &.{},
        .port_from = .{ .node = from, .side = .south, .offset = @intCast(first.x) },
        .port_to = .{ .node = to, .side = .north, .offset = @intCast(last.x) },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    };
}

fn routedPath(id: sketch.EdgeId, from: sketch.NodeId, to: sketch.NodeId, points: []const sketch.Point) sketch.EdgePath {
    var out = path(id, from, to, points[0], points[points.len - 1]);
    out.polyline = points;
    return out;
}

fn outerSketch(edges: []const sketch.EdgePath, sets: []const ledger.CoSet) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = edges,
        .co_sets = sets,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

fn pending(edge: sketch.EdgeId, from: ?sketch.NodeId, to: ?sketch.NodeId) ledger.RailClaimMember {
    return .{
        .edge = edge,
        .endpoints = .{ from, to },
        .sites = .{
            if (from) |node| .{ .node = node, .side = .south, .offset = 1 } else null,
            if (to) |node| .{ .node = node, .side = .north, .offset = 1 } else null,
        },
        .arrows = .{ .none, .filled },
        .kind = .solid,
        .pivot_end = .source,
    };
}

test "many routed crossings behind one placement do not make a structural fan" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]split_mod.Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const sr = twoTargetSplit(&crossings);
    const outer_edges = [_]sketch.EdgePath{outerPath(5, 0, 1)};
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &.{5} }};
    const outer = outerSketch(&outer_edges, &sets);
    const bridges = [_]sketch.EdgePath{
        path(100, 10, 20, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 8 }),
        path(101, 10, 21, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 8 }),
    };

    const images = try bridge_cosets.finalImages(a, sr, outer, 5, 50, 100, &bridges, &bridges, &.{});
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101 }, &.{ images[0].edge, images[1].edge });
    try testing.expectEqual(@as(usize, 0), (try bridge_cosets.rebuildOuterSets(a, sr, outer, 50, 100, &bridges, &bridges, &.{})).len);
}

test "two distinct contributors with one real pivot form structural authority" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]split_mod.Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const sr = twoTargetSplit(&crossings);
    const outer_edges = [_]sketch.EdgePath{ outerPath(5, 0, 1), outerPath(6, 0, 2) };
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .channel = 42, .members = &.{ 5, 6 } }};
    const outer = outerSketch(&outer_edges, &sets);
    const bridges = [_]sketch.EdgePath{
        path(100, 10, 20, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 8 }),
        path(101, 10, 21, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 8 }),
    };

    const got = try bridge_cosets.rebuildOuterSets(a, sr, outer, 50, 100, &bridges, &bridges, &.{});
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(ledger.no_channel, got[0].channel);
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101 }, got[0].members);
    try testing.expect(got[0].cells == null and got[0].pairwise == null);

    const members = [_]ledger.RailClaimMember{ pending(55, 10, null), pending(56, 10, null) };
    const claims = [_]ledger.RailClaim{.{ .id = 8, .polarity = .out, .members = &members, .pivot = 10, .unresolved_members = 2 }};
    const rebuilt_claims = try bridge_claims.rebuild(a, sr, outer, &claims, 50, 100, &bridges, &bridges, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), rebuilt_claims.len);
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101 }, &.{ rebuilt_claims[0].members[0].edge, rebuilt_claims[0].members[1].edge });
    try testing.expect(ledger.checkRailClaim(rebuilt_claims[0]).isValid());
}

test "contributors expanding behind one super split on different real pivots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const S = struct {
        const outer_ids = [_]sg.NodeId{ sg.SENTINEL, 4, 5 };
        const child_ids = [_]sg.NodeId{ 0, 1 };
        const pieces = [_]split_mod.Piece{
            .{ .graph = emptyGraph(), .cluster_id = null, .orig_ids = &outer_ids },
            .{ .graph = emptyGraph(), .cluster_id = 10, .orig_ids = &child_ids },
        };
        const supers = [_]split_mod.SuperNode{.{ .outer_node = 0, .cluster_id = 10, .child_piece = 1 }};
        const crossings = [_]split_mod.Crossing{
            .{ .id = 0, .from = 0, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
            .{ .id = 1, .from = 1, .to = 4, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
            .{ .id = 2, .from = 0, .to = 5, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
            .{ .id = 3, .from = 1, .to = 5, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        };
    };
    const sr: split_mod.SplitResult = .{ .pieces = &S.pieces, .supers = &S.supers, .crossings = &S.crossings, .orig_node_count = 6 };
    const outer_edges = [_]sketch.EdgePath{ outerPath(5, 0, 1), outerPath(6, 0, 2) };
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &.{ 5, 6 } }};
    const outer = outerSketch(&outer_edges, &sets);
    const routed = [_]sketch.EdgePath{
        path(100, 10, 20, .{ .x = 3, .y = 1 }, .{ .x = 1, .y = 8 }),
        path(101, 11, 20, .{ .x = 4, .y = 1 }, .{ .x = 1, .y = 8 }),
        path(102, 10, 21, .{ .x = 3, .y = 1 }, .{ .x = 2, .y = 8 }),
        path(103, 11, 21, .{ .x = 4, .y = 1 }, .{ .x = 2, .y = 8 }),
    };

    const rebuilt_sets = try bridge_cosets.rebuildOuterSets(a, sr, outer, 50, 100, &routed, &routed, &.{});
    try testing.expectEqual(@as(usize, 2), rebuilt_sets.len);
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 102 }, rebuilt_sets[0].members);
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 101, 103 }, rebuilt_sets[1].members);

    const members = [_]ledger.RailClaimMember{ pending(55, null, 20), pending(56, null, 21) };
    const claims = [_]ledger.RailClaim{.{ .id = 7, .polarity = .out, .members = &members, .unresolved_members = 2 }};
    const rebuilt_claims = try bridge_claims.rebuild(a, sr, outer, &claims, 50, 100, &routed, &routed, &.{}, &.{});
    var out_claims: usize = 0;
    for (rebuilt_claims) |claim| {
        try testing.expect(ledger.checkRailClaim(claim).isValid());
        if (claim.polarity != .out) continue;
        try testing.expectEqual(@as(?sketch.NodeId, @intCast(10 + out_claims)), claim.pivot);
        out_claims += 1;
    }
    try testing.expectEqual(@as(usize, 2), out_claims);
}

test "a proven mixed survivor and bridge structural set is retained" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const S = struct {
        const outer_ids = [_]sg.NodeId{ 0, 2, sg.SENTINEL };
        const child_ids = [_]sg.NodeId{1};
        const pieces = [_]split_mod.Piece{
            .{ .graph = emptyGraph(), .cluster_id = null, .orig_ids = &outer_ids },
            .{ .graph = emptyGraph(), .cluster_id = 10, .orig_ids = &child_ids },
        };
        const supers = [_]split_mod.SuperNode{.{ .outer_node = 2, .cluster_id = 10, .child_piece = 1 }};
        const crossings = [_]split_mod.Crossing{.{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null }};
    };
    const sr: split_mod.SplitResult = .{ .pieces = &S.pieces, .supers = &S.supers, .crossings = &S.crossings, .orig_node_count = 3 };
    const outer_edges = [_]sketch.EdgePath{ outerPath(5, 0, 1), outerPath(6, 0, 2) };
    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &.{ 5, 6 } }};
    const outer = outerSketch(&outer_edges, &sets);
    const final = [_]sketch.EdgePath{
        path(55, 10, 11, .{ .x = 3, .y = 1 }, .{ .x = 1, .y = 8 }),
        path(100, 10, 20, .{ .x = 3, .y = 1 }, .{ .x = 2, .y = 8 }),
    };

    const got = try bridge_cosets.rebuildOuterSets(a, sr, outer, 50, 100, &final, final[1..], &.{});
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 55, 100 }, got[0].members);
}

test "missing routed bridge leaves the proven claim member unresolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]split_mod.Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const sr = twoTargetSplit(&crossings);
    const outer_edges = [_]sketch.EdgePath{ outerPath(5, 0, 1), outerPath(6, 0, 2) };
    const outer = outerSketch(&outer_edges, &.{});
    const routed = [_]sketch.EdgePath{path(100, 10, 20, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 8 })};
    const members = [_]ledger.RailClaimMember{ pending(55, 10, null), pending(56, 10, null) };
    const claims = [_]ledger.RailClaim{.{ .id = 9, .polarity = .out, .members = &members, .pivot = 10, .unresolved_members = 2 }};

    const got = try bridge_claims.rebuild(a, sr, outer, &claims, 50, 100, &routed, &routed, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(ledger.RailClaimId, 1), got[0].id);
    try testing.expectEqual(@as(usize, 2), got[0].members.len);
    try testing.expectEqual(@as(u32, 1), got[0].unresolved_members);
    try testing.expectEqual(@as(?sketch.NodeId, 10), got[0].pivot);
    try testing.expectEqual(@as(?ledger.AttachmentSite, null), got[0].pi);
    try testing.expect(!ledger.checkRailClaim(got[0]).isValid());
    try testing.expect(!ledger.checkRailClaim(got[0]).record.stale_caches);

    const sets = [_]ledger.CoSet{.{ .origin = .fan_rail, .members = &.{ 5, 6 } }};
    var structural_outer = outer;
    structural_outer.co_sets = &sets;
    try testing.expectEqual(
        @as(usize, 0),
        (try bridge_cosets.rebuildOuterSets(a, sr, structural_outer, 50, 100, &routed, &routed, &.{})).len,
    );
}

test "bridge-native claim uses exact final endpoint and site" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]split_mod.Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const sr = twoTargetSplit(&crossings);
    const outer_edges = [_]sketch.EdgePath{outerPath(5, 0, 1)};
    const outer = outerSketch(&outer_edges, &.{});
    const first = [_]sketch.Point{ .{ .x = 3, .y = 1 }, .{ .x = 3, .y = 5 }, .{ .x = 1, .y = 8 } };
    const second = [_]sketch.Point{ .{ .x = 3, .y = 1 }, .{ .x = 3, .y = 5 }, .{ .x = 2, .y = 8 } };
    const routed = [_]sketch.EdgePath{ routedPath(100, 10, 20, &first), routedPath(101, 10, 21, &second) };

    const got = try bridge_claims.rebuild(a, sr, outer, &.{}, 50, 100, &routed, &routed, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(@as(ledger.RailClaimId, 1), got[0].id);
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101 }, &.{ got[0].members[0].edge, got[0].members[1].edge });
    try testing.expectEqual(@as(?sketch.NodeId, 10), got[0].pivot);
    try testing.expectEqual(@as(sketch.NodeId, 10), got[0].pi.?.node);
    try testing.expectEqual(sketch.Dir4.south, got[0].pi.?.side);
    try testing.expectEqual(@as(u32, 3), got[0].pi.?.offset);
    try testing.expect(ledger.checkRailClaim(got[0]).isValid());
}

test "bridge-native claims reject empty paths and immediate divergence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]split_mod.Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const sr = twoTargetSplit(&crossings);
    const outer_edges = [_]sketch.EdgePath{outerPath(5, 0, 1)};
    const outer = outerSketch(&outer_edges, &.{});
    const empty = [_]sketch.EdgePath{
        path(100, 10, 20, .{ .x = 3, .y = 1 }, .{ .x = 1, .y = 8 }),
        path(101, 10, 21, .{ .x = 3, .y = 1 }, .{ .x = 2, .y = 8 }),
    };
    try testing.expectEqual(@as(usize, 0), (try bridge_claims.rebuild(a, sr, outer, &.{}, 50, 100, &empty, &empty, &.{}, &.{})).len);

    const left = [_]sketch.Point{ .{ .x = 3, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 1, .y = 8 } };
    const right = [_]sketch.Point{ .{ .x = 3, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 5, .y = 8 } };
    const divergent = [_]sketch.EdgePath{ routedPath(100, 10, 20, &left), routedPath(101, 10, 21, &right) };
    try testing.expectEqual(@as(usize, 0), (try bridge_claims.rebuild(a, sr, outer, &.{}, 50, 100, &divergent, &divergent, &.{}, &.{})).len);
}

test "bridge-native fan-in requires a genuine shared suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const crossings = [_]split_mod.Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const sr = twoTargetSplit(&crossings);
    const outer_edges = [_]sketch.EdgePath{outerPath(5, 0, 1)};
    const outer = outerSketch(&outer_edges, &.{});
    const first = [_]sketch.Point{ .{ .x = 1, .y = 1 }, .{ .x = 3, .y = 5 }, .{ .x = 3, .y = 8 } };
    const second = [_]sketch.Point{ .{ .x = 5, .y = 1 }, .{ .x = 3, .y = 5 }, .{ .x = 3, .y = 8 } };
    const routed = [_]sketch.EdgePath{ routedPath(100, 20, 10, &first), routedPath(101, 21, 10, &second) };
    const got = try bridge_claims.rebuild(a, sr, outer, &.{}, 50, 100, &routed, &routed, &.{}, &.{});
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqual(ledger.RailPolarity.in, got[0].polarity);
    try testing.expect(ledger.checkRailClaim(got[0]).isValid());
}

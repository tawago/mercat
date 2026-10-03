const std = @import("std");
const crossing = @import("crossing.zig");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");

const testing = std.testing;
const Key = crossing.Key;

fn key(v: u32, sum: u64, count: u64, prev: u32) Key {
    return .{ .v = v, .sum = sum, .count = count, .back = false, .prev = prev };
}

fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{
        .id = id,
        .raw_id = raw,
        .label = raw,
        .shape = .rect,
        .classes = &.{},
        .cluster = null,
    };
}

fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
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

fn graphOf(nodes: []const sg.Node, edges: []const sg.Edge) sg.SemGraph {
    return .{
        .direction = .TD,
        .nodes = nodes,
        .edges = edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
}

fn crossingsOf(lg: sugiyama.LayeredGraph) !u64 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const order = try crossing.Order.init(arena.allocator(), lg);
    return order.crossings(lg.layers);
}

test "Key.less breaks barycenter ties by original position, independent of input order" {
    var order_a = [_]Key{
        key(10, 0, 1, 5),
        key(11, 1, 1, 0),
        key(12, 1, 1, 1),
        key(13, 1, 1, 2),
        key(14, 2, 1, 6),
    };
    var order_b = [_]Key{
        key(13, 1, 1, 2),
        key(14, 2, 1, 6),
        key(12, 1, 1, 1),
        key(10, 0, 1, 5),
        key(11, 1, 1, 0),
    };

    std.mem.sort(Key, &order_a, {}, Key.less);
    std.mem.sort(Key, &order_b, {}, Key.less);

    const expect_v = [_]u32{ 10, 11, 12, 13, 14 };
    for (order_a, 0..) |k, i| try testing.expectEqual(expect_v[i], k.v);
    for (order_b, 0..) |k, i| try testing.expectEqual(expect_v[i], k.v);

    try testing.expectEqualSlices(Key, &order_a, &order_b);
}

test "Key.less compares sum over count as an exact fraction" {
    var keys = [_]Key{ key(1, 3, 2, 7), key(2, 6, 4, 3), key(3, 4, 3, 0) };
    std.mem.sort(Key, &keys, {}, Key.less);
    try testing.expectEqual(@as(u32, 3), keys[0].v);
    try testing.expectEqual(@as(u32, 2), keys[1].v);
    try testing.expectEqual(@as(u32, 1), keys[2].v);
}

test "Key.less places back-edge endpoint after equal-barycenter sibling" {
    var order_a = [_]Key{
        .{ .v = 20, .sum = 1, .count = 1, .back = true, .prev = 0 },
        .{ .v = 21, .sum = 1, .count = 1, .back = false, .prev = 1 },
    };
    var order_b = [_]Key{
        .{ .v = 21, .sum = 1, .count = 1, .back = false, .prev = 1 },
        .{ .v = 20, .sum = 1, .count = 1, .back = true, .prev = 0 },
    };
    std.mem.sort(Key, &order_a, {}, Key.less);
    std.mem.sort(Key, &order_b, {}, Key.less);
    try testing.expectEqual(@as(u32, 21), order_a[0].v);
    try testing.expectEqual(@as(u32, 20), order_a[1].v);
    try testing.expectEqualSlices(Key, &order_a, &order_b);
}

test "Key.less back-edge bias never overrides a real barycenter difference" {
    var order = [_]Key{
        .{ .v = 30, .sum = 2, .count = 1, .back = false, .prev = 0 },
        .{ .v = 31, .sum = 1, .count = 1, .back = true, .prev = 1 },
    };
    std.mem.sort(Key, &order, {}, Key.less);
    try testing.expectEqual(@as(u32, 31), order[0].v);
    try testing.expectEqual(@as(u32, 30), order[1].v);
}

test "reduceCrossings parks a back-edge endpoint at the last within-layer index even when crossings are minimal" {
    const nodes = [_]sg.Node{ mkNode(0, "P"), mkNode(1, "A"), mkNode(2, "B") };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1),
        mkEdge(1, 0, 2),
        mkEdge(2, 1, 0),
    };
    var lg = try sugiyama.assignLayers(testing.allocator, graphOf(&nodes, &edges));
    defer lg.deinit(testing.allocator);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const order = try crossing.Order.init(arena.allocator(), lg);
    try testing.expect(order.back[1]);
    try testing.expect(!order.back[2]);

    const before = order.crossings(lg.layers);
    try crossing.reduceCrossings(testing.allocator, &lg);
    const after = order.crossings(lg.layers);
    try testing.expect(after <= before);

    var found = false;
    for (lg.layers) |row| {
        if (row.len == 2 and
            ((row[0] == 1 and row[1] == 2) or (row[0] == 2 and row[1] == 1)))
        {
            found = true;
            try testing.expectEqual(@as(u32, 1), row[row.len - 1]);
            try testing.expectEqual(@as(u64, 0), order.railCost(lg.layers));
        }
    }
    try testing.expect(found);
}

test "railCost is zero on a graph with no back-edges" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 0, 2) };
    var lg = try sugiyama.assignLayers(testing.allocator, graphOf(&nodes, &edges));
    defer lg.deinit(testing.allocator);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const order = try crossing.Order.init(arena.allocator(), lg);
    try testing.expectEqual(@as(u64, 0), order.railCost(lg.layers));
}

test "linear chain has zero crossings before and after" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2) };
    var lg = try sugiyama.assignLayers(testing.allocator, graphOf(&nodes, &edges));
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 0), try crossingsOf(lg));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const snap = try arena.allocator().alloc([]u32, lg.layers.len);
    for (lg.layers, snap) |row, *kept| kept.* = try arena.allocator().dupe(u32, row);

    try crossing.reduceCrossings(testing.allocator, &lg);

    try testing.expectEqual(@as(u64, 0), try crossingsOf(lg));
    try testing.expectEqual(snap.len, lg.layers.len);
    for (snap, lg.layers) |s, r| try testing.expectEqualSlices(u32, s, r);
}

test "two-layer X pattern reduces from 1 to 0" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C"), mkNode(3, "D") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 3), mkEdge(1, 1, 2) };
    var lg = try sugiyama.assignLayers(testing.allocator, graphOf(&nodes, &edges));
    defer lg.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), lg.layers.len);
    try testing.expectEqual(@as(usize, 2), lg.layers[0].len);
    try testing.expectEqual(@as(usize, 2), lg.layers[1].len);
    try testing.expectEqual(@as(u64, 1), try crossingsOf(lg));

    const orig_lower = try testing.allocator.dupe(u32, lg.layers[1]);
    defer testing.allocator.free(orig_lower);

    try crossing.reduceCrossings(testing.allocator, &lg);

    try testing.expectEqual(@as(u64, 0), try crossingsOf(lg));
    const upper_swapped = lg.layers[0][0] != 0 or lg.layers[0][1] != 1;
    const lower_swapped = lg.layers[1][0] != orig_lower[0] or lg.layers[1][1] != orig_lower[1];
    try testing.expect(upper_swapped or lower_swapped);
}

test "best-of rollback never increases crossings" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "B"),
        mkNode(2, "C"),
        mkNode(3, "D"),
        mkNode(4, "E"),
        mkNode(5, "F"),
    };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 4),
        mkEdge(1, 0, 5),
        mkEdge(2, 1, 3),
        mkEdge(3, 1, 5),
        mkEdge(4, 2, 3),
        mkEdge(5, 2, 4),
    };
    var lg = try sugiyama.assignLayers(testing.allocator, graphOf(&nodes, &edges));
    defer lg.deinit(testing.allocator);

    const before = try crossingsOf(lg);
    try crossing.reduceCrossings(testing.allocator, &lg);
    try testing.expect(try crossingsOf(lg) <= before);
}

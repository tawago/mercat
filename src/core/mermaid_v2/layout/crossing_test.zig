//! Unit tests for `crossing.zig`'s `cmpScored` tie-break contract.
//!
//! `std.mem.sort` is not guaranteed stable in Zig 0.15, so `cmpScored`
//! encodes the tie-break explicitly via `.cur` (original row position)
//! rather than relying on sort stability. These tests exercise the
//! comparator directly (not through `reduceCrossings`, whose best-of-
//! iteration rollback can mask a reorder that doesn't change the crossing
//! count) to confirm ties resolve deterministically by `.cur` regardless
//! of the input array's order.

const std = @import("std");
const crossing = @import("crossing.zig");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");

const testing = std.testing;
const ScoredNode = crossing.ScoredNode;

fn sn(idx: u32, bary: f64, cur: u32) ScoredNode {
    return .{ .idx = idx, .bary = bary, .cur = cur };
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

test "cmpScored breaks barycenter ties by original position, independent of input order" {
    var order_a = [_]ScoredNode{
        sn(10, 0.0, 5),
        sn(11, 1.0, 0),
        sn(12, 1.0, 1),
        sn(13, 1.0, 2),
        sn(14, 2.0, 6),
    };
    var order_b = [_]ScoredNode{
        sn(13, 1.0, 2),
        sn(14, 2.0, 6),
        sn(12, 1.0, 1),
        sn(10, 0.0, 5),
        sn(11, 1.0, 0),
    };

    std.mem.sort(ScoredNode, &order_a, {}, crossing.cmpScored);
    std.mem.sort(ScoredNode, &order_b, {}, crossing.cmpScored);

    const expect_idx = [_]u32{ 10, 11, 12, 13, 14 };
    for (order_a, 0..) |s, i| try testing.expectEqual(expect_idx[i], s.idx);
    for (order_b, 0..) |s, i| try testing.expectEqual(expect_idx[i], s.idx);

    try testing.expectEqualSlices(ScoredNode, &order_a, &order_b);
}

test "cmpScored places back-edge endpoint after equal-barycenter sibling" {
    var order_a = [_]ScoredNode{
        .{ .idx = 20, .bary = 1.0, .cur = 0, .back = 1 },
        .{ .idx = 21, .bary = 1.0, .cur = 1, .back = 0 },
    };
    var order_b = [_]ScoredNode{
        .{ .idx = 21, .bary = 1.0, .cur = 1, .back = 0 },
        .{ .idx = 20, .bary = 1.0, .cur = 0, .back = 1 },
    };
    std.mem.sort(ScoredNode, &order_a, {}, crossing.cmpScored);
    std.mem.sort(ScoredNode, &order_b, {}, crossing.cmpScored);
    try testing.expectEqual(@as(u32, 21), order_a[0].idx);
    try testing.expectEqual(@as(u32, 20), order_a[1].idx);
    try testing.expectEqualSlices(ScoredNode, &order_a, &order_b);
}

test "cmpScored back-edge bias never overrides a real barycenter difference" {
    var order = [_]ScoredNode{
        .{ .idx = 30, .bary = 2.0, .cur = 0, .back = 0 },
        .{ .idx = 31, .bary = 1.0, .cur = 1, .back = 1 },
    };
    std.mem.sort(ScoredNode, &order, {}, crossing.cmpScored);
    try testing.expectEqual(@as(u32, 31), order[0].idx);
    try testing.expectEqual(@as(u32, 30), order[1].idx);
}

test "reduceCrossings parks a back-edge endpoint at the last within-layer index even when crossings are minimal" {
    const nodes = [_]sg.Node{ mkNode(0, "P"), mkNode(1, "A"), mkNode(2, "B") };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1),
        mkEdge(1, 0, 2),
        mkEdge(2, 1, 0),
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    try testing.expect(crossing.isBackEndpoint(&lg, 1));
    try testing.expect(!crossing.isBackEndpoint(&lg, 2));

    const before = try crossing.countCrossings(testing.allocator, lg);
    try crossing.reduceCrossings(testing.allocator, &lg, .{});
    const after = try crossing.countCrossings(testing.allocator, lg);
    try testing.expect(after <= before);

    var found = false;
    for (lg.layers) |row| {
        if (row.len == 2 and
            ((row[0] == 1 and row[1] == 2) or (row[0] == 2 and row[1] == 1)))
        {
            found = true;
            try testing.expectEqual(@as(u32, 1), row[row.len - 1]);
            try testing.expectEqual(@as(u64, 0), crossing.railCost(lg));
        }
    }
    try testing.expect(found);
}

test "railCost is zero on a graph with no back-edges" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 0, 2) };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), crossing.railCost(lg));
}

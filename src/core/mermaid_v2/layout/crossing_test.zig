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
    // Three nodes tie at bary=1.0 (cur 0,1,2), interleaved with two
    // distinct-bary nodes. Regardless of the order these are handed to
    // `std.mem.sort`, the tied trio must come out in ascending `.cur`
    // order (0, 1, 2) — a plain `bary <` comparator (no tie-break) would
    // leave them in whatever order the sort algorithm's internal swaps
    // happen to produce, which is not guaranteed to match `.cur`.
    var order_a = [_]ScoredNode{
        sn(10, 0.0, 5), // distinct low
        sn(11, 1.0, 0), // tied trio, in-order
        sn(12, 1.0, 1),
        sn(13, 1.0, 2),
        sn(14, 2.0, 6), // distinct high
    };
    // Same multiset, handed in a different input arrangement.
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

    // The two independently-sorted, differently-ordered inputs converge on
    // byte-identical output — the tie-break is a deterministic function of
    // (bary, cur), not of input arrangement.
    try testing.expectEqualSlices(ScoredNode, &order_a, &order_b);
}

test "cmpScored places back-edge endpoint after equal-barycenter sibling" {
    // Two nodes tie at bary=1.0. Node 20 is a reversed-edge (back-)edge
    // endpoint (back=1) currently leftmost (cur=0); node 21 is not (back=0)
    // currently rightmost (cur=1). The back-edge rail parks at the max
    // cross-axis extent (last index), so the back-edge endpoint must move
    // to the HIGHER index (adjacent to its rail); the plain sibling takes
    // the lower slot — regardless of input order.
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
    // Plain sibling first, back-edge endpoint last, in both arrangements.
    try testing.expectEqual(@as(u32, 21), order_a[0].idx);
    try testing.expectEqual(@as(u32, 20), order_a[1].idx);
    try testing.expectEqualSlices(ScoredNode, &order_a, &order_b);
}

test "cmpScored back-edge bias never overrides a real barycenter difference" {
    // A back-edge endpoint (back=1) with a strictly SMALLER barycenter must
    // still sort before a plain node with a larger barycenter — the bias is
    // a tie-break only, subordinate to crossing-minimising barycenter order.
    var order = [_]ScoredNode{
        .{ .idx = 30, .bary = 2.0, .cur = 0, .back = 0 },
        .{ .idx = 31, .bary = 1.0, .cur = 1, .back = 1 },
    };
    std.mem.sort(ScoredNode, &order, {}, crossing.cmpScored);
    try testing.expectEqual(@as(u32, 31), order[0].idx);
    try testing.expectEqual(@as(u32, 30), order[1].idx);
}

test "reduceCrossings parks a back-edge endpoint at the last within-layer index even when crossings are minimal" {
    // Mirrors the oauth defect: a decision P fans to two children A and B
    // (pure barycenter tie), and A carries a back-edge A->P (reversed during
    // cycle removal). Its rail parks at the last within-layer index, so A
    // must land there. Declaration order puts A first; the swap is crossing-
    // NEUTRAL (single shared parent → 0 crossings either way), so it survives
    // only via the railCost secondary objective, not the strict rollback.
    const nodes = [_]sg.Node{ mkNode(0, "P"), mkNode(1, "A"), mkNode(2, "B") };
    const edges = [_]sg.Edge{
        mkEdge(0, 0, 1), // P -> A
        mkEdge(1, 0, 2), // P -> B
        mkEdge(2, 1, 0), // A -> P (back-edge; reversed during cycle removal)
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

    // Sanity: A is a back-endpoint, B is not.
    try testing.expect(crossing.isBackEndpoint(&lg, 1));
    try testing.expect(!crossing.isBackEndpoint(&lg, 2));

    const before = try crossing.countCrossings(testing.allocator, lg);
    try crossing.reduceCrossings(testing.allocator, &lg, .{});
    const after = try crossing.countCrossings(testing.allocator, lg);
    // Never trades a crossing for the tie-break.
    try testing.expect(after <= before);

    // Locate the two children's layer and assert A sits at the LAST index.
    var found = false;
    for (lg.layers) |row| {
        if (row.len == 2 and
            ((row[0] == 1 and row[1] == 2) or (row[0] == 2 and row[1] == 1)))
        {
            found = true;
            try testing.expectEqual(@as(u32, 1), row[row.len - 1]); // A last
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

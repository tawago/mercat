//! Tests for decascade.zig. Discovered by decascade.zig via `test { _ = @import }`.
//!
//! Builds `sugiyama.LayeredGraph` + `NodeGeom` slices by hand (rather than
//! running the full `assignLayers` pipeline) so each test can pin exact
//! drift/collision/fork geometry and exercise `deCascade` in isolation. The
//! `graph: sg.SemGraph` parameter is unused by `deCascade` (`_ = graph;`),
//! so every test passes the same empty dummy graph.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const decascade = @import("decascade.zig");

const testing = std.testing;
const NodeGeom = routing.NodeGeom;

const dummy_graph = sg.SemGraph{
    .direction = .TD,
    .nodes = &.{},
    .edges = &.{},
    .clusters = &.{},
    .classes = &.{},
    .arena = null,
};

fn geomAt(x: i32, y: i32, w: u32, h: u32, layer: u32) NodeGeom {
    return .{ .x = x, .y = y, .w = w, .h = h, .layer = layer };
}

fn lgOf(nodes: []sugiyama.LayerNode, layers: [][]u32, edges: []sugiyama.LayerEdge) sugiyama.LayeredGraph {
    return .{
        .nodes = nodes,
        .layers = layers,
        .edges = edges,
        .reversed_edges = &.{},
        .real_index = .empty,
        .arena = null,
    };
}

fn edge(from: u32, to: u32) sugiyama.LayerEdge {
    return .{ .from = from, .to = to, .edge = from, .reversed = false };
}

// -- claim: anchor on the MOST-drifted trunk node, not the first-drifted ---

test "deCascade anchors on the most-drifted trunk, not the first-drifted one" {
    // Two disjoint single-node-layer trunks, each hanging off its own
    // 2-real-node fork layer. Trunk A (layers 1-2) drifts only 6 cells and
    // is encountered FIRST by the layer scan; trunk B (layers 4-5) drifts
    // 30 cells and is encountered LATER. Only the most-drifted trunk (B)
    // may be picked as the slide anchor, so only B's nodes should move.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // ForkA
        .{ .real = 1 }, // SiblingA
        .{ .real = 2 }, // HeadA
        .{ .real = 3 }, // TailA
        .{ .real = 4 }, // ForkB
        .{ .real = 5 }, // SiblingB
        .{ .real = 6 }, // HeadB
        .{ .real = 7 }, // TailB
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var l3 = [_]u32{ 4, 5 };
    var l4 = [_]u32{6};
    var l5 = [_]u32{7};
    var layers = [_][]u32{ &l0, &l1, &l2, &l3, &l4, &l5 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2), // ForkA -> HeadA
        edge(2, 3), // HeadA -> TailA
        edge(4, 6), // ForkB -> HeadB
        edge(6, 7), // HeadB -> TailB
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0), // ForkA (margin = 0)
        geomAt(6, 0, 2, 1, 0), // SiblingA
        geomAt(6, 2, 2, 1, 1), // HeadA: drift 6
        geomAt(6, 4, 2, 1, 2), // TailA
        geomAt(0, 6, 2, 1, 3), // ForkB
        geomAt(30, 6, 2, 1, 3), // SiblingB
        geomAt(30, 8, 2, 1, 4), // HeadB: drift 30 (the true max)
        geomAt(30, 10, 2, 1, 5), // TailB
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    // Trunk B (the most-drifted) slid all the way to the margin.
    try testing.expectEqual(@as(i32, 0), geom[6].x);
    try testing.expectEqual(@as(i32, 0), geom[7].x);
    // Trunk A (drifted less, encountered earlier in the scan) is untouched.
    try testing.expectEqual(@as(i32, 6), geom[2].x);
    try testing.expectEqual(@as(i32, 6), geom[3].x);
}

// -- claim: head climb stops at a multi-node fork layer -----------------

test "deCascade head climb stops exactly at a multi-node fork layer" {
    // RootAbove (layer 0, sole) -> Fork/Sibling (layer 1, 2 real nodes) ->
    // Head (layer 2, sole, drifted) -> Tail (layer 3, sole). Climbing from
    // Head must stop AT Fork (its parent) because Fork's own layer forks
    // (2 real nodes) -- it must not continue up through Fork to RootAbove.
    // If it wrongly climbed to RootAbove (already at the margin), the
    // computed slide delta would be 0 and the whole call would no-op,
    // leaving Head/Tail undrifted -- so "did the slide even happen" is the
    // observable signal for where the climb actually stopped.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // RootAbove
        .{ .real = 1 }, // Fork
        .{ .real = 2 }, // Sibling
        .{ .real = 3 }, // Head
        .{ .real = 4 }, // Tail
    };
    var l0 = [_]u32{0};
    var l1 = [_]u32{ 1, 2 };
    var l2 = [_]u32{3};
    var l3 = [_]u32{4};
    var layers = [_][]u32{ &l0, &l1, &l2, &l3 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 1), // RootAbove -> Fork
        edge(1, 3), // Fork -> Head
        edge(3, 4), // Head -> Tail
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0), // RootAbove (margin = 0)
        geomAt(6, 2, 2, 1, 1), // Fork
        geomAt(20, 2, 2, 1, 1), // Sibling
        geomAt(6, 4, 2, 1, 2), // Head: drift 6
        geomAt(6, 6, 2, 1, 3), // Tail
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    // The slide fired and moved Head/Tail to the margin -- proving climb
    // stopped at Fork's (multi-node) layer rather than passing through it
    // to RootAbove (which was already at the margin and would have made
    // the whole call a no-op).
    try testing.expectEqual(@as(i32, 0), geom[3].x); // Head
    try testing.expectEqual(@as(i32, 0), geom[4].x); // Tail
    // Fork/Sibling/RootAbove never move: they sit above the slid unit.
    try testing.expectEqual(@as(i32, 6), geom[1].x);
    try testing.expectEqual(@as(i32, 20), geom[2].x);
    try testing.expectEqual(@as(i32, 0), geom[0].x);
}

// -- claim: head always has a forward parent (precondition for the slide) --

test "deCascade no-ops when the drifted trunk head is a true source (no forward parent)" {
    // Head is a source (no incoming edges at all) that still qualifies by
    // drift and has a valid 2-layer child chain below it (Tail). Without
    // the "head must have a forward parent" guard, this would look like a
    // perfectly good cascade and slide Head/Tail to the margin.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // Anchor (sets margin, unconnected)
        .{ .real = 1 }, // Head (source, no parent)
        .{ .real = 2 }, // Tail
    };
    var l0 = [_]u32{0};
    var l1 = [_]u32{1};
    var l2 = [_]u32{2};
    var layers = [_][]u32{ &l0, &l1, &l2 };
    var edges = [_]sugiyama.LayerEdge{
        edge(1, 2), // Head -> Tail (Head itself has no incoming edge)
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0), // Anchor (margin = 0)
        geomAt(6, 2, 2, 1, 1), // Head: drift 6, but sourceless
        geomAt(6, 4, 2, 1, 2), // Tail
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    // Nothing moves: the sourceless head is a true left edge already, not
    // a slidable cascade.
    try testing.expectEqual(@as(i32, 0), geom[0].x);
    try testing.expectEqual(@as(i32, 6), geom[1].x);
    try testing.expectEqual(@as(i32, 6), geom[2].x);
}

// -- claim: `next` must be the sole real node of its layer (trunk-straight) -

test "deCascade trunk walk stops at a branch instead of treating it as trunk-straight" {
    // Head (layer 1, sole, drifted) -> BranchNode (layer 2, which ALSO
    // holds BranchSibling: 2 real nodes) -> FarNode (layer 3, sole). Even
    // though a further sole-real-node layer (FarNode) exists past the
    // branch, the trunk must stop at Head because its immediate child's
    // layer is not sole -- so hi<=lo and the whole call must no-op.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // Parent
        .{ .real = 1 }, // Sibling0 (fork layer partner)
        .{ .real = 2 }, // Head
        .{ .real = 3 }, // BranchNode
        .{ .real = 4 }, // BranchSibling
        .{ .real = 5 }, // FarNode
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{ 3, 4 };
    var l3 = [_]u32{5};
    var layers = [_][]u32{ &l0, &l1, &l2, &l3 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2), // Parent -> Head
        edge(2, 3), // Head -> BranchNode
        edge(3, 5), // BranchNode -> FarNode
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0), // Parent (margin = 0)
        geomAt(20, 0, 2, 1, 0), // Sibling0
        geomAt(6, 2, 2, 1, 1), // Head: drift 6
        geomAt(6, 4, 2, 1, 2), // BranchNode
        geomAt(15, 4, 2, 1, 2), // BranchSibling
        geomAt(6, 6, 2, 1, 3), // FarNode
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    // hi never advances past lo (1), so hi<=lo fires and nothing moves --
    // in particular Head must NOT slide to the margin even though a
    // (branch-interrupted) sole-node layer exists further down.
    try testing.expectEqual(@as(i32, 6), geom[2].x); // Head
    try testing.expectEqual(@as(i32, 6), geom[3].x); // BranchNode
    try testing.expectEqual(@as(i32, 6), geom[5].x); // FarNode
}

// -- claim: a lone drifted single-node layer is NOT a cascade (need >=2) ---

test "deCascade does not fire for a lone drifted single-node layer (hi==lo)" {
    // Head hangs off a 2-node fork layer and drifts well past MIN_DRIFT,
    // but is a leaf (no children at all) -- hi never advances past lo, so
    // this must NOT be treated as a cascade.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // Parent
        .{ .real = 1 }, // Sibling
        .{ .real = 2 }, // Head (leaf)
        .{ .real = 3 }, // Other (unconnected filler so nl >= 3)
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var layers = [_][]u32{ &l0, &l1, &l2 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2), // Parent -> Head
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0), // Parent (margin = 0)
        geomAt(20, 0, 2, 1, 0), // Sibling
        geomAt(6, 2, 2, 1, 1), // Head: drift 6, but a leaf
        geomAt(0, 4, 2, 1, 2), // Other (drift 0, doesn't qualify)
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    // No cascade of length >= 2 exists, so nothing moves.
    try testing.expectEqual(@as(i32, 6), geom[2].x);
}

// -- claim: flood-forward stays in layers >= lo (never pulls a node above) -

test "deCascade flood-forward never pulls a node above the run into the unit" {
    // Tail (part of the unit) has a forward edge to Sibling, a real node
    // that sits in the FORK layer (layer 0), i.e. strictly above lo (1).
    // The flood must skip it even though it is a valid forward edge target.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // Parent
        .{ .real = 1 }, // Sibling (layer 0, above the run)
        .{ .real = 2 }, // Head
        .{ .real = 3 }, // Tail
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var layers = [_][]u32{ &l0, &l1, &l2 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2), // Parent -> Head
        edge(2, 3), // Head -> Tail
        edge(3, 1), // Tail -> Sibling (points back up above lo)
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0), // Parent (margin = 0)
        geomAt(20, 0, 2, 1, 0), // Sibling
        geomAt(6, 2, 2, 1, 1), // Head: drift 6
        geomAt(6, 4, 2, 1, 2), // Tail
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    try testing.expectEqual(@as(i32, 0), geom[2].x); // Head slid to margin
    try testing.expectEqual(@as(i32, 0), geom[3].x); // Tail slid to margin
    // Sibling sits above lo and must never be swept into the unit.
    try testing.expectEqual(@as(i32, 20), geom[1].x);
}

// -- claim: collision floor prevents crossing into the left neighbor's edge -

test "deCascade collision floor clamps the slide short of a fixed sibling's right edge" {
    // ForkChild (part of the unit, pulled in via flood beyond hi) shares
    // its layer with FixedSibling, a fixed non-unit node. An unclamped
    // slide would move the whole unit to the margin (delta -30), but the
    // collision floor must clamp it to just barely clear FixedSibling's
    // right edge plus the collision gap (2).
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // Parent
        .{ .real = 1 }, // Sibling0 (fork layer partner)
        .{ .real = 2 }, // Head
        .{ .real = 3 }, // Tail
        .{ .real = 4 }, // ForkChild (flooded, shares layer 3 with FixedSibling)
        .{ .real = 5 }, // FixedSibling (not in the unit)
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var l3 = [_]u32{ 4, 5 };
    var layers = [_][]u32{ &l0, &l1, &l2, &l3 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2), // Parent -> Head
        edge(2, 3), // Head -> Tail
        edge(3, 4), // Tail -> ForkChild
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 2, 1, 0), // Parent (margin = 0)
        geomAt(50, 0, 2, 1, 0), // Sibling0
        geomAt(30, 2, 2, 1, 1), // Head: drift 30
        geomAt(30, 4, 2, 1, 2), // Tail
        geomAt(30, 6, 2, 1, 3), // ForkChild
        geomAt(20, 6, 4, 1, 3), // FixedSibling: right edge at 24
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    // Unclamped, the unit would slide by -30 straight to the margin (0).
    // The collision floor must instead clamp the slide to -4, so ForkChild
    // lands exactly at FixedSibling's right edge (24) + the 2-cell gap.
    try testing.expectEqual(@as(i32, 26), geom[2].x); // Head
    try testing.expectEqual(@as(i32, 26), geom[3].x); // Tail
    try testing.expectEqual(@as(i32, 26), geom[4].x); // ForkChild
    // FixedSibling never moves (not in the unit).
    try testing.expectEqual(@as(i32, 20), geom[5].x);
}

// -- claim: drop distance couples to the MAX sibling depth in the fork layer

test "deCascade entry-corridor drop uses the tallest fork-layer sibling, not just the overlapping one" {
    // The fork layer (0) holds two non-unit siblings: Parent (shallow,
    // h=3, directly under the head's post-slide port) and Sibling (deep,
    // h=10, positioned away from the port so it never triggers the overlap
    // check on its own). The drop distance must equal the layer's TALLEST
    // sibling (10), not just the overlapping one's height (3) -- otherwise
    // the corridor would fail to clear Sibling's deeper bottom border.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // Parent (shallow, overlaps head's post-slide port)
        .{ .real = 1 }, // Sibling (deep, does not overlap)
        .{ .real = 2 }, // Head
        .{ .real = 3 }, // Tail
        .{ .real = 4 }, // AnchorLow (sets margin, unconnected)
    };
    var l0 = [_]u32{ 0, 1 };
    var l1 = [_]u32{2};
    var l2 = [_]u32{3};
    var l3 = [_]u32{4};
    var layers = [_][]u32{ &l0, &l1, &l2, &l3 };
    var edges = [_]sugiyama.LayerEdge{
        edge(0, 2), // Parent -> Head
        edge(2, 3), // Head -> Tail
    };
    const lg = lgOf(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        geomAt(0, 0, 4, 3, 0), // Parent: span [0,4], h=3
        geomAt(60, 0, 4, 10, 0), // Sibling: span [60,64], h=10, far away
        geomAt(20, 10, 2, 2, 1), // Head: drift 20
        geomAt(20, 20, 2, 2, 2), // Tail
        geomAt(0, 30, 2, 2, 3), // AnchorLow (margin = 0)
    };

    try decascade.deCascade(testing.allocator, dummy_graph, &geom, lg);

    // Head slides all the way to the margin (x=0); its post-slide port
    // (x=0 + w/2=1) falls under Parent's span [0,4], triggering the
    // corridor. The drop applied to every layer >= lo must be 10 (the
    // layer's max sibling height), not 3 (Parent's own height).
    try testing.expectEqual(@as(i32, 0), geom[2].x);
    try testing.expectEqual(@as(i32, 20), geom[2].y); // 10 + 10
    try testing.expectEqual(@as(i32, 30), geom[3].y); // 20 + 10
    try testing.expectEqual(@as(i32, 40), geom[4].y); // 30 + 10 (layer 3 >= lo too)
    // The fork layer itself (layer 0, above lo) never moves.
    try testing.expectEqual(@as(i32, 0), geom[0].y);
    try testing.expectEqual(@as(i32, 0), geom[1].y);
}

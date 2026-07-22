//! Tests for `rank_grid.zig`'s invariants — split out to keep the file
//! under the 500-line cap. Builds synthetic `LayeredGraph`s by hand and
//! drives only the public `reflowWideRanks` entry point, observing effects
//! on `geom` (private helpers like `layerWrappedByFan` are file-private to
//! rank_grid.zig and not reachable from here).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const components = @import("components.zig");
const rank_grid = @import("rank_grid.zig");

const testing = std.testing;
const NodeGeom = components.NodeGeom;

fn mkGraph(nodes: []sugiyama.LayerNode, layers: [][]u32, edges: []sugiyama.LayerEdge) sugiyama.LayeredGraph {
    return .{
        .nodes = nodes,
        .layers = layers,
        .edges = edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
}

// -- base_y compounds correctly across sequential top-to-bottom layers -------

test "reflowWideRanks: a second wide layer's base_y reflects the first wide layer's shift, and a leaf further down cascades through both" {
    // layer0: 4 producers, each with a DISTINCT child in layer1 (no shared
    // pivot) — genuinely wide, must grid. layer1: those 4 children, each fed
    // by exactly one distinct producer (not roots) and all converging on the
    // single layer2 leaf — also genuinely wide (allRoots is false), must
    // grid too. layer2: one leaf, used only to observe the cascade.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 10 }, .{ .real = 11 }, .{ .real = 12 }, .{ .real = 13 }, // 0-3: layer0
        .{ .real = 20 }, .{ .real = 21 }, .{ .real = 22 }, .{ .real = 23 }, // 4-7: layer1
        .{ .real = 30 }, // 8: layer2 leaf
    };
    var layer0 = [_]u32{ 0, 1, 2, 3 };
    var layer1 = [_]u32{ 4, 5, 6, 7 };
    var layer2 = [_]u32{8};
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 4, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 5, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 6, .edge = 102, .reversed = false },
        .{ .from = 3, .to = 7, .edge = 103, .reversed = false },
        .{ .from = 4, .to = 8, .edge = 200, .reversed = false },
        .{ .from = 5, .to = 8, .edge = 201, .reversed = false },
        .{ .from = 6, .to = 8, .edge = 202, .reversed = false },
        .{ .from = 7, .to = 8, .edge = 203, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 20, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 40, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 60, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 40, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 60, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 200, .w = 6, .h = 3, .layer = 2 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    // layer0 grids into 2 rows of 2 (cols=2, row_step=5) → added_h0 = 5.
    // If layer1's base_y were computed BEFORE layer0's shift landed (the
    // bug this claim guards against), layer1's first row would sit at its
    // stale y=100 instead of the post-shift 105.
    try testing.expectEqual(@as(i32, 105), geom[4].y);

    // layer1 also grids (added_h1 = 5, same shape). The layer2 leaf must
    // cascade through BOTH shifts: 200 + 5 (layer0) + 5 (layer1) = 210.
    try testing.expectEqual(@as(i32, 210), geom[8].y);
}

// -- virtual nodes never contribute to packing, only ride the push ----------

test "reflowWideRanks: a same-layer virtual node's (oversized) width never enters the column/packing math and its position is untouched" {
    // 4 real nodes with a distinct child each (genuinely wide, non-exempt),
    // plus one same-layer virtual carrying a deliberately huge w/h that
    // would corrupt max_w/cols if it ever leaked into the real-node scan.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 }, .{ .real = 4 }, // 0-3: reals
        .{ .virtual = .{ .edge = 99, .index = 0 } }, // 4: same-layer virtual
        .{ .real = 5 }, .{ .real = 6 }, .{ .real = 7 }, .{ .real = 8 }, // 5-8: layer1 leaves
    };
    var layer0 = [_]u32{ 0, 1, 2, 3, 4 };
    var layer1 = [_]u32{ 5, 6, 7, 8 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 5, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 6, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 7, .edge = 102, .reversed = false },
        .{ .from = 3, .to = 8, .edge = 103, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 20, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 40, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 60, .y = 0, .w = 8, .h = 3, .layer = 0 },
        .{ .x = 999, .y = 0, .w = 100, .h = 50, .layer = 0 }, // virtual: huge box
        .{ .x = 0, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 10, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 30, .y = 100, .w = 6, .h = 3, .layer = 1 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    // If the virtual's w=100 had leaked into max_w, slot_w would be 102 and
    // cols would clamp to 1, producing 4 distinct sub-rows. Excluding it
    // correctly gives max_w=8, slot_w=10, cols=2 → only 2 distinct rows.
    var rows = std.AutoHashMapUnmanaged(i32, void).empty;
    defer rows.deinit(testing.allocator);
    for (0..4) |i| try rows.put(testing.allocator, geom[i].y, {});
    try testing.expectEqual(@as(usize, 2), rows.count());

    // The virtual itself is never packed into a column slot: same-layer
    // virtuals sit exactly at base_y (not > base_y), so the downward-push
    // pass leaves it untouched, and it is never visited by the packing loop
    // (which only walks `reals`).
    try testing.expectEqual(@as(i32, 999), geom[4].x);
    try testing.expectEqual(@as(i32, 0), geom[4].y);
}

// -- overflow is driven by rendered span, not tight packed width ------------

test "reflowWideRanks: nodes drifted far apart by centering are compacted even though their tight packed width already fits the budget" {
    // 3 narrow nodes (tight width 16, comfortably under budget 20) spread
    // far apart (x=0,50,100) as barycenter centering might drift them —
    // rendered span is 104, way over budget. If span (not tight width) did
    // not drive the overflow check, this layer would be skipped entirely
    // and the drift would survive uncorrected.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 },
        .{ .real = 4 }, .{ .real = 5 }, .{ .real = 6 },
    };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 4, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 5, .edge = 102, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 4, .h = 3, .layer = 0 },
        .{ .x = 50, .y = 0, .w = 4, .h = 3, .layer = 0 },
        .{ .x = 100, .y = 0, .w = 4, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 4, .h = 3, .layer = 1 },
        .{ .x = 6, .y = 100, .w = 4, .h = 3, .layer = 1 },
        .{ .x = 12, .y = 100, .w = 4, .h = 3, .layer = 1 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    // Compacted back into one tight row: sorted x's now touch with exactly
    // h_spacing (2) between them instead of the original 46-wide gaps.
    var xs = [_]i32{ geom[0].x, geom[1].x, geom[2].x };
    std.mem.sort(i32, &xs, {}, std.sort.asc(i32));
    try testing.expectEqual(xs[0] + 4 + 2, xs[1]); // node width 4 + h_spacing 2
    try testing.expectEqual(xs[1] + 4 + 2, xs[2]);
}

// -- compact_floor = budget - budget/8 boundary ------------------------------

test "reflowWideRanks: a row exactly at the compact_floor boundary compacts to one row; one unit past it stacks into a grid" {
    // budget=80, budget/8=10, compact_floor=70.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 },
        .{ .real = 4 }, .{ .real = 5 }, .{ .real = 6 },
    };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 4, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 5, .edge = 102, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    // Case A: widths 22,22,22 → single_row_w = 66 + 2*2 = 70 == compact_floor.
    {
        var geom = [_]NodeGeom{
            .{ .x = 0, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 300, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 600, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 0, .y = 100, .w = 6, .h = 3, .layer = 1 },
            .{ .x = 30, .y = 100, .w = 6, .h = 3, .layer = 1 },
            .{ .x = 60, .y = 100, .w = 6, .h = 3, .layer = 1 },
        };
        rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 80, 2, 1);
        // Compacted: all three share one row (same y).
        try testing.expectEqual(geom[0].y, geom[1].y);
        try testing.expectEqual(geom[0].y, geom[2].y);
    }

    // Case B: widths 22,22,23 → single_row_w = 67 + 4 = 71 == compact_floor+1.
    {
        var geom = [_]NodeGeom{
            .{ .x = 0, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 300, .y = 0, .w = 22, .h = 3, .layer = 0 },
            .{ .x = 600, .y = 0, .w = 23, .h = 3, .layer = 0 },
            .{ .x = 0, .y = 100, .w = 6, .h = 3, .layer = 1 },
            .{ .x = 30, .y = 100, .w = 6, .h = 3, .layer = 1 },
            .{ .x = 60, .y = 100, .w = 6, .h = 3, .layer = 1 },
        };
        rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 80, 2, 1);
        // Stacked: NOT all on the same row — must span at least 2 rows.
        var rows = std.AutoHashMapUnmanaged(i32, void).empty;
        defer rows.deinit(testing.allocator);
        for (0..3) |i| try rows.put(testing.allocator, geom[i].y, {});
        try testing.expect(rows.count() >= 2);
    }
}

// -- conservative widest-node column count forces >=2 rows -------------------

test "reflowWideRanks: the widest-node column formula still forces >=2 rows even when the naive per-node-count formula would leave one" {
    // budget=100, 3 nodes of width 30 each: single_row_w = 90+4 = 94, over
    // compact_floor (88) so this is on the grid path. The naive column
    // formula (budget+h_spacing)/(max_w+h_spacing) = 102/32 = 3, exactly
    // n — without the `cols >= n => cols = n-1` clamp this would produce a
    // single "row" of 3 (indistinguishable from not gridding at all).
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 },
        .{ .real = 4 }, .{ .real = 5 }, .{ .real = 6 },
    };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{ 3, 4, 5 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 4, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 5, .edge = 102, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 30, .h = 3, .layer = 0 },
        .{ .x = 400, .y = 0, .w = 30, .h = 3, .layer = 0 },
        .{ .x = 800, .y = 0, .w = 30, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 200, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 40, .y = 200, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 80, .y = 200, .w = 6, .h = 3, .layer = 1 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 100, 2, 1);

    var rows = std.AutoHashMapUnmanaged(i32, void).empty;
    defer rows.deinit(testing.allocator);
    for (0..3) |i| try rows.put(testing.allocator, geom[i].y, {});
    try testing.expectEqual(@as(usize, 2), rows.count());

    // No re-overflow: every packed row's width stays within budget.
    var row_w = std.AutoHashMapUnmanaged(i32, u32).empty;
    defer row_w.deinit(testing.allocator);
    for (0..3) |i| {
        const gp = row_w.getPtr(geom[i].y);
        if (gp) |p| p.* += geom[i].w else try row_w.put(testing.allocator, geom[i].y, geom[i].w);
    }
    var it = row_w.valueIterator();
    while (it.next()) |w| try testing.expect(w.* <= 100);
}

// -- row_step keeps overlapping-height sub-rows from touching ---------------

test "reflowWideRanks: row_step (max_h + v_spacing + 1) keeps a tall sub-row from touching the row below it" {
    // 4 nodes, cols=2 → 2 rows of 2. Row 0 holds the tallest node (h=9);
    // row_step must be derived from the layer's GLOBAL max_h (9), not any
    // individual row's own height, so row 0's tall box never reaches row 1.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 }, .{ .real = 4 },
        .{ .real = 5 }, .{ .real = 6 }, .{ .real = 7 }, .{ .real = 8 },
    };
    var layer0 = [_]u32{ 0, 1, 2, 3 };
    var layer1 = [_]u32{ 4, 5, 6, 7 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 4, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 5, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 6, .edge = 102, .reversed = false },
        .{ .from = 3, .to = 7, .edge = 103, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 8, .h = 9, .layer = 0 }, // tallest, row 0
        .{ .x = 20, .y = 0, .w = 8, .h = 3, .layer = 0 }, // row 0
        .{ .x = 40, .y = 0, .w = 8, .h = 3, .layer = 0 }, // row 1
        .{ .x = 60, .y = 0, .w = 8, .h = 3, .layer = 0 }, // row 1
        .{ .x = 0, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 30, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 60, .y = 100, .w = 6, .h = 3, .layer = 1 },
        .{ .x = 90, .y = 100, .w = 6, .h = 3, .layer = 1 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    const row0_y = geom[0].y;
    const row1_y = geom[2].y;
    try testing.expect(row1_y > row0_y);
    try testing.expectEqual(@as(i32, 11), row1_y - row0_y); // max_h(9) + v_spacing(1) + 1
    // The tall row's actual bottom edge must sit strictly above row 1.
    try testing.expect(row0_y + 9 < row1_y);
}

// -- disconnected isolates are a no-op, left to Lever A ----------------------

test "reflowWideRanks: two edge-free sibling nodes (all-roots AND all-leaves) are left untouched" {
    var nodes = [_]sugiyama.LayerNode{ .{ .real = 1 }, .{ .real = 2 } };
    var layer0 = [_]u32{ 0, 1 };
    var layers = [_][]u32{&layer0};
    var edges = [_]sugiyama.LayerEdge{};
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 100, .y = 0, .w = 6, .h = 3, .layer = 0 }, // span=106, way over budget
    };
    const before = geom;

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    try testing.expectEqualSlices(NodeGeom, &before, &geom);
}

// -- "all roots" qualifier is essential for the fan-IN exemption -------------

test "reflowWideRanks: a rank fed from above that ALSO converges to one child is not exempted as pure fan-IN — it still grids" {
    // 2 producers above, each feeding a distinct mid node (mid nodes are
    // NOT roots), both mid nodes converging on one shared child below.
    // Without the `allRoots` qualifier, sharedCommonNeighbour(.child) alone
    // would misclassify this as a pure fan-IN rank and leave it as one row.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 1 }, .{ .real = 2 }, // 0-1: producers (layer0)
        .{ .real = 3 }, .{ .real = 4 }, // 2-3: mid nodes (layer1)
        .{ .real = 5 }, // 4: shared child (layer2)
    };
    var layer0 = [_]u32{ 0, 1 };
    var layer1 = [_]u32{ 2, 3 };
    var layer2 = [_]u32{4};
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 2, .edge = 100, .reversed = false },
        .{ .from = 1, .to = 3, .edge = 101, .reversed = false },
        .{ .from = 2, .to = 4, .edge = 200, .reversed = false },
        .{ .from = 3, .to = 4, .edge = 201, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 20, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 100, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 12, .y = 100, .w = 10, .h = 3, .layer = 1 }, // tight but over budget
        .{ .x = 0, .y = 200, .w = 6, .h = 3, .layer = 2 },
    };

    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    // If wrongly exempted as pure fan-IN, both mid nodes would keep the
    // same y (untouched, single row). Correct behavior grids them apart.
    try testing.expect(geom[2].y != geom[3].y);
}

// -- rank_grid `>` vs `>=` shift boundary (moved from sugiyama_test.zig) ----
test "rank-grid pushes only strictly-below nodes by added_h; same-layer and above nodes are untouched" {
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 10 }, // 0: above the wide layer — must stay untouched
        .{ .real = 1 }, // 1..5: the wide layer's real nodes
        .{ .real = 2 },
        .{ .real = 3 },
        .{ .real = 4 },
        .{ .real = 5 },
        .{ .virtual = .{ .edge = 50, .index = 0 } }, // 6: same-layer virtual, y == base_y
        .{ .real = 11 }, // 7: below the wide layer — must shift by added_h
        .{ .virtual = .{ .edge = 51, .index = 0 } }, // 8: below, virtual — must shift too
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2, 3, 4, 5, 6 };
    var layer2 = [_]u32{ 7, 8 };
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    // Each wide-layer real has its own in+out edge pair (not a pure shared
    // fan-in/fan-out pivot), so layerWrappedByFan's exemptions don't apply
    // and the rank genuinely falls through to grid-stacking.
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 100, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 101, .reversed = false },
        .{ .from = 0, .to = 3, .edge = 102, .reversed = false },
        .{ .from = 0, .to = 4, .edge = 103, .reversed = false },
        .{ .from = 0, .to = 5, .edge = 104, .reversed = false },
        .{ .from = 1, .to = 7, .edge = 200, .reversed = false },
        .{ .from = 2, .to = 7, .edge = 201, .reversed = false },
        .{ .from = 3, .to = 7, .edge = 202, .reversed = false },
        .{ .from = 4, .to = 7, .edge = 203, .reversed = false },
        .{ .from = 5, .to = 7, .edge = 204, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 }, // above
        .{ .x = 0, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 40, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 60, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 80, .y = 100, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 100, .w = 0, .h = 0, .layer = 1 }, // same-layer virtual
        .{ .x = 0, .y = 150, .w = 6, .h = 3, .layer = 2 }, // below
        .{ .x = 0, .y = 150, .w = 0, .h = 0, .layer = 2 }, // below, virtual
    };

    const base_y = geom[1].y;
    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    // Derive the actually-applied added_h from a node we know shifted, so
    // the assertion pins the boundary behavior rather than a hardcoded
    // magic constant tied to today's column/row math.
    const added_h = geom[7].y - 150;
    try testing.expect(added_h > 0);

    try testing.expectEqual(@as(i32, 0), geom[0].y); // above base_y's layer: untouched
    try testing.expectEqual(base_y, geom[6].y); // same-layer virtual AT base_y: untouched
    try testing.expectEqual(@as(i32, 150) + added_h, geom[7].y); // strictly below: shifted
    try testing.expectEqual(@as(i32, 150) + added_h, geom[8].y); // strictly below, virtual: shifted
}

// -- rank-grid skips a layer already owned by fan-wrapping ------------------

test "rank-grid leaves a wrapped fan-OUT layer as one row but still grids an over-wide multi-pivot sibling layer" {
    // Layer1: P's fan-out children (leaves) — over-wide by span, but
    // `layerWrappedByFan` exempts it (wrapWideFanOut already owns this
    // shape; re-gridding it here would double-wrap and desync the fan
    // rail from the grid). Layer2: 4 independent roots each diverging to
    // a distinct child — over-wide AND genuinely multi-pivot (no shared
    // fan pivot), so it must still fall through to the grid.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // P
        .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 }, .{ .real = 4 }, // C1..C4 (layer1)
        .{ .real = 5 }, .{ .real = 6 }, .{ .real = 7 }, .{ .real = 8 }, // G1..G4 (layer2)
        .{ .real = 9 }, .{ .real = 10 }, .{ .real = 11 }, .{ .real = 12 }, // H1..H4 (layer3)
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2, 3, 4 };
    var layer2 = [_]u32{ 5, 6, 7, 8 };
    var layer3 = [_]u32{ 9, 10, 11, 12 };
    var layers = [_][]u32{ &layer0, &layer1, &layer2, &layer3 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 100, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 101, .reversed = false },
        .{ .from = 0, .to = 3, .edge = 102, .reversed = false },
        .{ .from = 0, .to = 4, .edge = 103, .reversed = false },
        .{ .from = 5, .to = 9, .edge = 200, .reversed = false },
        .{ .from = 6, .to = 10, .edge = 201, .reversed = false },
        .{ .from = 7, .to = 11, .edge = 202, .reversed = false },
        .{ .from = 8, .to = 12, .edge = 203, .reversed = false },
    };
    const lg = mkGraph(&nodes, &layers, &edges);

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 20, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 20, .y = 20, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 40, .y = 20, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 60, .y = 20, .w = 8, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 40, .w = 8, .h = 3, .layer = 2 },
        .{ .x = 20, .y = 40, .w = 8, .h = 3, .layer = 2 },
        .{ .x = 40, .y = 40, .w = 8, .h = 3, .layer = 2 },
        .{ .x = 60, .y = 40, .w = 8, .h = 3, .layer = 2 },
        .{ .x = 0, .y = 60, .w = 6, .h = 3, .layer = 3 },
        .{ .x = 20, .y = 60, .w = 6, .h = 3, .layer = 3 },
        .{ .x = 40, .y = 60, .w = 6, .h = 3, .layer = 3 },
        .{ .x = 60, .y = 60, .w = 6, .h = 3, .layer = 3 },
    };
    rank_grid.reflowWideRanks(NodeGeom, lg, &geom, 20, 2, 1);

    // Layer1 (C1..C4, indices 1-4): untouched — same y for every node,
    // still one row, despite a span (38) that exceeds the budget (20).
    const c_y = geom[1].y;
    for (1..5) |i| try testing.expectEqual(c_y, geom[i].y);

    // Layer2 (G1..G4, indices 5-8): gridded into at least two distinct
    // sub-rows — not left as a single over-wide row.
    var distinct_rows = std.AutoHashMapUnmanaged(i32, void).empty;
    defer distinct_rows.deinit(testing.allocator);
    for (5..9) |i| try distinct_rows.put(testing.allocator, geom[i].y, {});
    try testing.expect(distinct_rows.count() >= 2);
}

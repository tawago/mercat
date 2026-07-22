//! Tests for clusters.zig. Discovered via clusters.zig's `test { _ =
//! @import(...) }`. Only `buildClusters` and `computeBbox` are `pub` in
//! clusters.zig; most tests here drive those two entry points directly
//! (plus the shared sketch/prim primitives clusters.zig itself uses),
//! never reaching into its private helpers. One test (the back-edge rail
//! label lever) exercises `computeBbox`'s pass-2 relocation end-to-end
//! through `coords.layout`, since the lever's arming condition lives one
//! layer up in layout.zig.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const prim = @import("prim");
const fan_busbar = @import("fan_busbar.zig");
const clusters = @import("clusters.zig");
const coords = @import("../layout.zig");

const testing = std.testing;

fn mkNode(id: sg.NodeId, cluster: ?sg.ClusterId) sg.Node {
    return .{ .id = id, .raw_id = "n", .label = "n", .shape = .rect, .classes = &.{}, .cluster = cluster };
}

fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId, label: ?[]const u8, role: sketch.EdgeRole, poly: []const sketch.Point) sketch.EdgePath {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .polyline = poly,
        .port_from = .{ .node = from, .side = .south, .offset = 0 },
        .port_to = .{ .node = to, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = label,
        .kind = .solid,
        .role = role,
    };
}

// -- claim: outer cluster union sees the already-expanded inner rect --------

test "buildClusters: outer cluster bbox unions the already-expanded inner rect, not the raw inner member bbox" {
    const a = testing.allocator;

    // inner (id=0) directly contains node A; outer (id=1) contains ONLY
    // the inner cluster (no direct members), so outer's bbox is entirely
    // a function of what it sees for inner's rect.
    const clusters_arr = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "inner", .label = "", .parent = 1, .members = &[_]sg.NodeId{0}, .sub_clusters = &.{} },
        .{ .id = 1, .raw_id = "outer", .label = "", .parent = null, .members = &.{}, .sub_clusters = &[_]sg.ClusterId{0} },
    };
    const graph = sg.SemGraph{
        .direction = .TD,
        .nodes = &[_]sg.Node{mkNode(0, 0)},
        .edges = &.{},
        .clusters = &clusters_arr,
        .classes = &.{},
        .arena = null,
    };
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 4 }, .shape = .rect, .lines = &.{}, .cluster_id = 0 },
    };

    const out = try clusters.buildClusters(a, graph, &placements, 0);
    defer a.free(out);

    var inner: ?sketch.Rect = null;
    var outer: ?sketch.Rect = null;
    for (out) |cf| {
        if (cf.id == 0) inner = cf.rect;
        if (cf.id == 1) outer = cf.rect;
    }
    try testing.expect(inner != null);
    try testing.expect(outer != null);

    // Inner rect: node union {0,0,10,4} padded by (H_INSET+1=4, V_INSET+1=2)
    // on every side -> x=-4,y=-2,w=18,h=8.
    try testing.expectEqual(sketch.Rect{ .x = -4, .y = -2, .w = 18, .h = 8 }, inner.?);

    // Outer must pad AROUND that already-expanded inner rect (not around
    // the pre-expansion raw {0,0,10,4} union, which would collapse outer
    // to the same box as inner). If outer instead saw the pre-expansion
    // rect, its box would be {-4,-2,18,8} -- identical to inner.rect --
    // instead of strictly containing it.
    try testing.expectEqual(sketch.Rect{ .x = -8, .y = -4, .w = 26, .h = 12 }, outer.?);
    try testing.expect(outer.?.x < inner.?.x);
    try testing.expect(outer.?.y < inner.?.y);
    try testing.expect(outer.?.right() > inner.?.right());
    try testing.expect(outer.?.bottom() > inner.?.bottom());
}

// -- claim: ClusterFrames come out in original graph order -------------------

test "buildClusters: emitted ClusterFrame order matches input graph.clusters order, not the depth-sorted processing order" {
    const a = testing.allocator;

    // Array position order is OUTER, MIDDLE, INNER (ascending depth) --
    // the exact reverse of the deepest-first order buildClusters must
    // process internally. If emission followed the internal processing
    // (sorted) order instead of the input order, ids would come out
    // reversed: [30, 20, 10] instead of [10, 20, 30].
    const clusters_arr = [_]sg.Cluster{
        .{ .id = 10, .raw_id = "outer", .label = "", .parent = null, .members = &.{}, .sub_clusters = &[_]sg.ClusterId{20} },
        .{ .id = 20, .raw_id = "middle", .label = "", .parent = 10, .members = &.{}, .sub_clusters = &[_]sg.ClusterId{30} },
        .{ .id = 30, .raw_id = "inner", .label = "", .parent = 20, .members = &[_]sg.NodeId{0}, .sub_clusters = &.{} },
    };
    const graph = sg.SemGraph{
        .direction = .TD,
        .nodes = &[_]sg.Node{mkNode(0, 30)},
        .edges = &.{},
        .clusters = &clusters_arr,
        .classes = &.{},
        .arena = null,
    };
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 4 }, .shape = .rect, .lines = &.{}, .cluster_id = 30 },
    };

    const out = try clusters.buildClusters(a, graph, &placements, 0);
    defer a.free(out);

    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqual(@as(sg.ClusterId, 10), out[0].id);
    try testing.expectEqual(@as(sg.ClusterId, 20), out[1].id);
    try testing.expectEqual(@as(sg.ClusterId, 30), out[2].id);
}

// -- claim: polyline points are inclusive, bbox maxima exclusive (+1) -------

test "computeBbox: a self-loop detour point at the diagram's extreme corner extends the exclusive bbox by exactly +1" {
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    // Self-loop-style detour point sitting past the node's own bbox.
    var poly = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 20, .y = 10 } };
    var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, null, .forward, &poly)};
    var polylines = [_][]sketch.Point{&poly};
    var clusters_arr = [_]sketch.ClusterFrame{};
    var busbars = [_]fan_busbar.Built{};

    const bbox = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &busbars, false, 200);

    // The extreme point names inclusive cell (20,10); the exclusive bbox
    // extent must be point+1, i.e. w=21, h=11 -- not w=20,h=10.
    try testing.expectEqual(@as(u32, 21), bbox.w);
    try testing.expectEqual(@as(u32, 11), bbox.h);
}

// -- claim: back-edge rail relocation is deferred to pass 2, decided only
//    once pass 1 has established the diagram's full right extent ----------

test "computeBbox: back-edge rail label relocation depends on the diagram's full right extent, not just its own edge" {
    // A vertical back-edge (mid_x = 40) whose default (right-of-rail)
    // label placement busts max_width on its own, but whose LEFT
    // placement still lands at x >= 0 (mid_x - 1 - lbl_w = 27).
    const poly = [_]sketch.Point{ .{ .x = 40, .y = 0 }, .{ .x = 40, .y = 20 } };
    const label = "twelvechars!";
    const lbl_w = prim.displayWidth(label);
    try testing.expectEqual(@as(u32, 12), lbl_w);
    const max_width: u32 = 50;
    try testing.expect(40 + 2 + lbl_w > max_width); // right placement busts budget
    try testing.expect(40 - 1 - @as(i32, @intCast(lbl_w)) >= 0); // left placement stays on-canvas

    // Scenario A: nothing else in the diagram is wide. Pass 1's right
    // extent (`others_right`) stays small and fits comfortably, so the
    // necessity gate is satisfied and the lever relocates the label left.
    {
        var placements = [_]sketch.NodePlacement{
            .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        };
        var poly_a = poly;
        var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, label, .back_edge, &poly_a)};
        var polylines = [_][]sketch.Point{&poly_a};
        var clusters_arr = [_]sketch.ClusterFrame{};
        var busbars = [_]fan_busbar.Built{};

        _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &busbars, true, max_width);
        try testing.expect(edges[0].label_left_of_rail);
    }

    // Scenario B: an unrelated wide node alone pushes pass 1's right
    // extent (`others_right`) past max_width. The lever's necessity gate
    // requires `others_right <= max_width`, so even though this edge's
    // OWN right-side placement still busts the budget, the label must
    // stay right -- proving the decision genuinely waits on the extent
    // pass 1 established from EVERYTHING else, not a per-edge local view.
    {
        var placements = [_]sketch.NodePlacement{
            .{ .id = 1, .rect = .{ .x = 0, .y = 5, .w = 80, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        };
        var poly_b = poly;
        var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, label, .back_edge, &poly_b)};
        var polylines = [_][]sketch.Point{&poly_b};
        var clusters_arr = [_]sketch.ClusterFrame{};
        var busbars = [_]fan_busbar.Built{};

        _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &busbars, true, max_width);
        try testing.expect(!edges[0].label_left_of_rail);
    }
}

// -- claim: the rail lever only fires when necessary (right placement
//    would actually bust the budget) --------------------------------------

test "computeBbox: back-edge rail lever leaves the label right when the right placement already fits the budget" {
    // Narrow label whose default right-of-rail placement comfortably fits
    // a generous max_width -- the lever must stay dormant even though
    // `pressure` (the ladder-rung flag) is on.
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var poly = [_]sketch.Point{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 20 } };
    var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, "ok", .back_edge, &poly)};
    var polylines = [_][]sketch.Point{&poly};
    var clusters_arr = [_]sketch.ClusterFrame{};
    var busbars = [_]fan_busbar.Built{};

    _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &busbars, true, 200);
    try testing.expect(!edges[0].label_left_of_rail);
}

// -- claim: bus-bar tap label anchor reservation agrees with the shared
//    BusBar.tapLabelSeg + prim.edgeLabelAnchor formula raster/labels uses --

test "computeBbox: bus-bar tap label reservation matches BusBar.tapLabelSeg + prim.edgeLabelAnchor" {
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 5, .y = 8, .w = 4, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 10, .rect = .{ .x = 12, .y = 8, .w = 4, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var edges = [_]sketch.EdgePath{};
    var polylines = [_][]sketch.Point{};
    var clusters_arr = [_]sketch.ClusterFrame{};

    var stem = [_]sketch.Point{ .{ .x = 5, .y = 8 }, .{ .x = 5, .y = 3 } };
    // Off-column tap: at.x (12) != junction.x (5).
    var taps = [_]sketch.Tap{
        .{ .edge = 1, .node = 10, .at = .{ .x = 12, .y = 3 }, .landing = .{ .x = 12, .y = 8 }, .label = "tap label" },
    };
    var busbars = [_]fan_busbar.Built{.{
        .busbar = .{
            .pivot = 0,
            .stem = &stem,
            .rail = .{ .{ .x = 5, .y = 3 }, .{ .x = 20, .y = 3 } },
            .taps = &taps,
            .kind = .solid,
        },
        .stem = &stem,
        .taps = &taps,
    }};

    const bbox = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &busbars, false, 200);

    // Independently recompute the anchor exactly as raster/labels does:
    // BusBar.tapLabelSeg for the segment, then prim.edgeLabelAnchor.
    const bb = busbars[0].busbar;
    const seg = bb.tapLabelSeg(taps[0]);
    const lbl_w = prim.displayWidth(taps[0].label.?);
    const anchor = prim.edgeLabelAnchor(seg[0].x, seg[0].y, seg[1].x, seg[1].y, lbl_w, .{});

    // The reserved bbox must extend at least to cover that exact anchor
    // span -- if computeBbox used a different formula, this would drift.
    try testing.expect(bbox.w >= @as(u32, @intCast(anchor.x + @as(i32, @intCast(lbl_w)))));
    try testing.expect(bbox.h >= @as(u32, @intCast(anchor.y + 1)));
}

// -- claim: the bus-bar shift pass mutates memory shared by both the
//    `Built.taps` view and the embedded `BusBar.taps` slice ----------------

test "computeBbox: the shift pass updates both the Built.taps view and the aliased BusBar.taps slice" {
    // Placements chosen so min_x < 0, forcing computeBbox's shift pass to
    // fire (dx > 0).
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = -5, .y = 0, .w = 4, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var edges = [_]sketch.EdgePath{};
    var polylines = [_][]sketch.Point{};
    var clusters_arr = [_]sketch.ClusterFrame{};

    var stem = [_]sketch.Point{ .{ .x = -5, .y = 0 }, .{ .x = -5, .y = -2 } };
    var taps = [_]sketch.Tap{
        .{ .edge = 1, .node = 1, .at = .{ .x = -5, .y = -2 }, .landing = .{ .x = -5, .y = 0 } },
    };
    var busbars = [_]fan_busbar.Built{.{
        .busbar = .{
            .pivot = 0,
            .stem = &stem,
            .rail = .{ .{ .x = -5, .y = -2 }, .{ .x = -5, .y = -2 } },
            .taps = &taps, // aliases the SAME memory as `Built.taps` below
            .kind = .solid,
        },
        .stem = &stem,
        .taps = &taps,
    }};

    const pre_shift_tap_x = busbars[0].busbar.taps[0].at.x;
    _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &busbars, false, 200);

    // A shift must actually have happened (min_x was negative).
    try testing.expect(busbars[0].busbar.taps[0].at.x != pre_shift_tap_x);
    // Both views must agree on the post-shift value -- they alias the
    // same backing array (`fan_busbar.build` sets `.taps = taps` on both
    // the returned `Built` and the embedded `BusBar`).
    try testing.expectEqual(busbars[0].taps[0].at.x, busbars[0].busbar.taps[0].at.x);
    try testing.expectEqual(busbars[0].taps[0].at.y, busbars[0].busbar.taps[0].at.y);
}

// -- claim: label_left_of_rail's threshold is exactly prim.edgeLabelAnchor's
//    default right-of-rail offset (mid_x + 2) ------------------------------

test "computeBbox: label_left_of_rail is false exactly at prim.edgeLabelAnchor's default mid_x+2 offset" {
    // Lever active but with a small enough label that the default right
    // placement fits: prim.edgeLabelAnchor returns exactly (mid_x+2,
    // mid_y) -- clusters.zig's own left_of_rail check (`anchor.x < mid_x +
    // 2`) must therefore read false, matching prim's default exactly at
    // the boundary rather than drifting by an off-by-one.
    var placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    var poly = [_]sketch.Point{ .{ .x = 10, .y = 0 }, .{ .x = 10, .y = 20 } };
    var edges = [_]sketch.EdgePath{mkEdge(0, 0, 0, "x", .back_edge, &poly)};
    var polylines = [_][]sketch.Point{&poly};
    var clusters_arr = [_]sketch.ClusterFrame{};
    var busbars = [_]fan_busbar.Built{};

    _ = clusters.computeBbox(&placements, &edges, &clusters_arr, &polylines, &busbars, true, 200);

    const mid_x: i32 = @divTrunc(poly[0].x + poly[1].x, 2);
    const anchor = prim.edgeLabelAnchor(poly[0].x, poly[0].y, poly[1].x, poly[1].y, prim.displayWidth("x"), .{});
    try testing.expectEqual(mid_x + 2, anchor.x);
    try testing.expect(!edges[0].label_left_of_rail);
}

// -- claim: the back-edge rail label lever is armed by layout.zig only for
//    AUTHORED TD, not a rotation-probe TD (layout.zig ~line 282), and the
//    lever ITSELF (computeBbox's pass-2 relocation) lives here in
//    clusters.zig. Exercised end-to-end through `coords.layout` (moved from
//    the former `layout/lanes_test.zig`, which hosted it only to keep
//    `layout_test.zig` under the 500-line cap; the lever it exercises is not
//    a lanes.zig invariant). -------------------------------------------------

fn mkLeverNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

test "the back-edge rail label lever fires for authored TD but not for a rotation-probe TD" {
    // A -> B -> C -> D -> A: a back-edge whose default right-of-rail label
    // busts max_width while everything else already fits. On authored TD
    // (`is_direction_rotated = false`) the lever must relocate the label
    // left of the rail, shrinking the bbox. On the budget ladder's
    // `switch_direction` rotation PROBE (`is_direction_rotated = true`,
    // used when re-laying an LR/RL chain out as TD) the lever must stay
    // off, leaving the label at its default right placement and the wider
    // bbox — so the rail lever can never flip chain_wrap's acceptance
    // decision for a rotated candidate.
    const nodes = [_]sg.Node{ mkLeverNode(0, "A"), mkLeverNode(1, "B"), mkLeverNode(2, "C"), mkLeverNode(3, "D") };
    const back_edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 2, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 3, .from = 3, .to = 0, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = "loop" },
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &back_edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const s_authored = try coords.layout(arena.allocator(), g, .{ .spacing_scale = 1, .max_width = 12, .is_direction_rotated = false });
    const s_rotated = try coords.layout(arena.allocator(), g, .{ .spacing_scale = 1, .max_width = 12, .is_direction_rotated = true });

    var back_authored: ?sketch.EdgePath = null;
    for (s_authored.edges) |e| {
        if (e.role == .back_edge) back_authored = e;
    }
    var back_rotated: ?sketch.EdgePath = null;
    for (s_rotated.edges) |e| {
        if (e.role == .back_edge) back_rotated = e;
    }

    try testing.expect(back_authored.?.label_left_of_rail);
    try testing.expect(!back_rotated.?.label_left_of_rail);
    // The relocated label recovers width, so the authored render must be
    // strictly narrower than the rotation-probe render of the same graph.
    try testing.expect(s_authored.bbox.w < s_rotated.bbox.w);
}

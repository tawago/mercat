//! Unit tests for `x_assign.zig`: `centerLayer`'s fan-IN centroid override,
//! the min_cursor packing-drift/correction pair, the clustered+labeled-fork
//! skip gate, `flushLeftRows`'s bbox-never-widens invariant, and
//! `centerRunOnDesired`'s real-nodes-only averaging + width clamp.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const cx_mod = @import("x_assign.zig");

const testing = std.testing;

fn mkNode3(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

// -- x_assign centerLayer: fan-IN centroid override -------------------------

test "centerLayer's fan-IN override centers on the real-source centroid, excluding a reversed back-edge source" {
    // F has 3 incoming layered edges from the layer above: A, B (forward,
    // real) and C (reversed — a back-edge in layered-graph terms). The
    // naive per-layer average (as used for non-fan-in rows) does not
    // filter `reversed`, so it would pull F toward mean(A,B,C) = 45. The
    // fan-IN override must instead center F on the ALL-REAL, non-reversed
    // source centroid mean(A,B) = 15, ignoring C entirely.
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 100 }, // A
        .{ .real = 101 }, // B
        .{ .real = 102 }, // C
        .{ .real = 103 }, // F
    };
    var layer0 = [_]u32{ 0, 1, 2 };
    var layer1 = [_]u32{3};
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 3, .edge = 5, .reversed = false },
        .{ .from = 1, .to = 3, .edge = 6, .reversed = false },
        .{ .from = 2, .to = 3, .edge = 7, .reversed = true },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    var geom = [_]cx_mod.NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 }, // A center 5
        .{ .x = 20, .y = 0, .w = 10, .h = 3, .layer = 0 }, // B center 25
        .{ .x = 100, .y = 0, .w = 10, .h = 3, .layer = 0 }, // C center 105
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 }, // F
    };
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &geom, lg, 2, .down, true, 0);
    const f_cx = geom[3].x + @as(i32, @intCast(geom[3].w / 2));
    try testing.expectEqual(@as(i32, 15), f_cx);
    // Contrast value the naive (non-override) average over all 3 sources
    // would have produced, confirming the two paths really do diverge here.
    try testing.expect(f_cx != 45);
}

// -- x_assign centerLayer: min_cursor packing drift --------------------------

test "monotonic packing's min_cursor floor drifts a shared-barycenter run right of its target, and compact=true corrects it" {
    // B and C share a single parent A, so both independently compute the
    // same desired barycenter (A's center). The min_cursor floor packs B
    // first AT that shared target, then packs C to its right — so the pair
    // starts on the target instead of being centered on it, drifting the
    // row's mean center right of A. This isolates the packing loop itself
    // (compact=false, one sweep, no correction pass) as the drift's origin;
    // the paired `compact=true` correction pass (`centerRunOnDesired`) is
    // what pulls the mean back onto A afterward.
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 100 }, // A
        .{ .real = 101 }, // B
        .{ .real = 102 }, // C
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 5, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 6, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    // A is placed well clear of x=0 so the compact=true correction below
    // shifts leftward without tripping the separate width clamp (which
    // guards a different invariant, tested next to centerRunOnDesired in
    // lanes_test.zig).
    const initial = [_]cx_mod.NodeGeom{
        .{ .x = 50, .y = 0, .w = 10, .h = 3, .layer = 0 }, // A center 55
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 }, // B
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 }, // C
    };

    // Uncorrected packing (compact=false): the row's mean center must have
    // drifted away from A's center.
    var packed_only = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &packed_only, lg, 2, .down, false, 0);
    const a_cx = packed_only[0].x + @as(i32, @intCast(packed_only[0].w / 2));
    {
        const b_cx = packed_only[1].x + @as(i32, @intCast(packed_only[1].w / 2));
        const c_cx = packed_only[2].x + @as(i32, @intCast(packed_only[2].w / 2));
        const mean_bc = @divTrunc(b_cx + c_cx, 2);
        try testing.expect(mean_bc != a_cx);
    }

    // Corrected (compact=true): the row's mean center must match A's
    // center exactly — the min_cursor drift is fully absorbed.
    var corrected = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &corrected, lg, 2, .down, true, 0);
    const b_cx2 = corrected[1].x + @as(i32, @intCast(corrected[1].w / 2));
    const c_cx2 = corrected[2].x + @as(i32, @intCast(corrected[2].w / 2));
    const mean_bc2 = @divTrunc(b_cx2 + c_cx2, 2);
    try testing.expectEqual(a_cx, mean_bc2);
}

// -- x_assign centerLayer: clustered + labeled-fork skip gate ---------------

test "centerLayer skips re-centering a row that is both clustered and a labeled fork" {
    // B and C are fork targets of A via labeled edges, AND both belong to
    // cluster 10 — a row that trips BOTH exemption checks at once. Absent
    // either check the drifted pair (same shape as the min_cursor test
    // above) would get pulled back onto A's centroid; with the skip gate
    // active the packed (drifted) positions must survive untouched.
    const nodes = [_]sg.Node{
        mkNode3(0, "A"),
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 10 },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = 10 },
    };
    const clusters = [_]sg.Cluster{
        .{ .id = 10, .raw_id = "grp", .label = "grp", .parent = null, .members = &.{ 1, 2 }, .sub_clusters = &.{} },
    };
    const edges = [_]sg.Edge{
        .{ .id = 5, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = "lbl" },
        .{ .id = 6, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = "lbl" },
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &.{},
        .arena = null,
    };
    var lg_nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 } };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var lg_edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 5, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 6, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &lg_nodes,
        .layers = &layers,
        .edges = &lg_edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    const geom = [_]cx_mod.NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 },
    };
    var packed_only = geom;
    try cx_mod.centerByBarycenter(testing.allocator, g, &packed_only, lg, 2, .down, false, 0);
    var corrected = geom;
    try cx_mod.centerByBarycenter(testing.allocator, g, &corrected, lg, 2, .down, true, 0);

    // The clustered+labeled skip must make compact=true a no-op on this row:
    // corrected positions equal the raw packed positions exactly.
    try testing.expectEqual(packed_only[1].x, corrected[1].x);
    try testing.expectEqual(packed_only[2].x, corrected[2].x);

    // Sanity: the packed row really is drifted (non-trivial scenario), so
    // the equality above is actually exercising the skip, not vacuous.
    const b_cx = packed_only[1].x + @as(i32, @intCast(packed_only[1].w / 2));
    const c_cx = packed_only[2].x + @as(i32, @intCast(packed_only[2].w / 2));
    const mean_bc = @divTrunc(b_cx + c_cx, 2);
    const a_cx = packed_only[0].x + @as(i32, @intCast(packed_only[0].w / 2));
    try testing.expect(mean_bc != a_cx);
}

// -- x_assign flushLeftRows: connector-stretch floor -------------------------

test "flushLeftRows' connector-stretch floor stops short of the margin instead of stretching a connector" {
    // P sits at the left margin. B/C are a drifted 2-node row: B connects
    // up to P, C connects down to D. A naive full flush would slide the
    // whole row to margin (delta = -30), which would stretch C's edge to D
    // (D sits only at center 25) well past D — the "mermaid_frenzy"
    // regression the floor exists to prevent. The floor must instead bound
    // the shift so NEITHER B's nor C's left edge passes its neighbour's
    // center, landing short of the margin.
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, // P
        .{ .real = 1 }, // B
        .{ .real = 2 }, // C
        .{ .real = 3 }, // D
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layer2 = [_]u32{3};
    var layers = [_][]u32{ &layer0, &layer1, &layer2 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 0, .reversed = false },
        .{ .from = 2, .to = 3, .edge = 1, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    var geom = [_]cx_mod.NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 }, // P center 5, margin = 0
        .{ .x = 30, .y = 5, .w = 10, .h = 3, .layer = 1 }, // B
        .{ .x = 50, .y = 5, .w = 10, .h = 3, .layer = 1 }, // C
        .{ .x = 20, .y = 10, .w = 10, .h = 3, .layer = 2 }, // D center 25
    };
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };
    cx_mod.flushLeftRows(empty_g, &geom, lg);

    // Floored short of the margin: row_min after the shift (5) must be
    // strictly greater than the global margin (0) — a full flush did NOT
    // happen.
    try testing.expect(@min(geom[1].x, geom[2].x) > 0);

    // Neither connector stretched past its neighbour's center.
    try testing.expect(geom[1].x >= 5); // P's center
    try testing.expect(geom[2].x >= 25); // D's center

    // The floor is exact (not merely conservative) for this hand-derived
    // case: both nodes land precisely on their neighbour's center.
    try testing.expectEqual(@as(i32, 5), geom[1].x);
    try testing.expectEqual(@as(i32, 25), geom[2].x);
}

// -- x_assign flushLeftRows: never widens the bbox (moved from lanes_test.zig,
// which hosted this alongside `flushLeftRows`'s OTHER invariant above, but
// `flushLeftRows` itself lives in x_assign.zig) -----------------------------

fn bboxOf(geom: []const cx_mod.NodeGeom) i64 {
    var min_x: i32 = std.math.maxInt(i32);
    var max_r: i32 = std.math.minInt(i32);
    for (geom) |g| {
        if (g.x < min_x) min_x = g.x;
        const r = g.x + @as(i32, @intCast(g.w));
        if (r > max_r) max_r = r;
    }
    return @as(i64, max_r) - @as(i64, min_x);
}

test "flushLeftRows never widens the bounding box" {
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };

    // Case 1: a drifted 2-node row, connected to a single parent above —
    // must shrink (or at least not grow) the bbox.
    {
        var nodes = [_]sugiyama.LayerNode{ .{ .real = 10 }, .{ .real = 11 }, .{ .real = 12 } };
        var layer0 = [_]u32{0};
        var layer1 = [_]u32{ 1, 2 };
        var layers = [_][]u32{ &layer0, &layer1 };
        var edges = [_]sugiyama.LayerEdge{
            .{ .from = 0, .to = 1, .edge = 0, .reversed = false },
            .{ .from = 0, .to = 2, .edge = 1, .reversed = false },
        };
        const lg = sugiyama.LayeredGraph{
            .nodes = &nodes,
            .layers = &layers,
            .edges = &edges,
            .reversed_edges = &.{},
            .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
            .arena = null,
        };
        var geom = [_]cx_mod.NodeGeom{
            .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
            .{ .x = 30, .y = 5, .w = 10, .h = 3, .layer = 1 },
            .{ .x = 45, .y = 5, .w = 10, .h = 3, .layer = 1 },
        };
        const before = bboxOf(&geom);
        cx_mod.flushLeftRows(empty_g, &geom, lg);
        const after = bboxOf(&geom);
        try testing.expect(after <= before);
        // This scenario is drifted far enough that it must actually shrink,
        // not merely tie, or the test would pass vacuously.
        try testing.expect(after < before);
    }

    // Case 2: a lone single-node row is trunk-critical and exempt — must be
    // a complete no-op (bbox unchanged, not just non-increasing).
    {
        var nodes = [_]sugiyama.LayerNode{ .{ .real = 20 }, .{ .real = 21 } };
        var layer0 = [_]u32{0};
        var layer1 = [_]u32{1};
        var layers = [_][]u32{ &layer0, &layer1 };
        var edges = [_]sugiyama.LayerEdge{
            .{ .from = 0, .to = 1, .edge = 0, .reversed = false },
        };
        const lg = sugiyama.LayeredGraph{
            .nodes = &nodes,
            .layers = &layers,
            .edges = &edges,
            .reversed_edges = &.{},
            .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
            .arena = null,
        };
        var geom = [_]cx_mod.NodeGeom{
            .{ .x = 0, .y = 0, .w = 10, .h = 3, .layer = 0 },
            .{ .x = 50, .y = 5, .w = 10, .h = 3, .layer = 1 },
        };
        const before = bboxOf(&geom);
        cx_mod.flushLeftRows(empty_g, &geom, lg);
        const after = bboxOf(&geom);
        try testing.expectEqual(before, after);
    }
}

// -- x_assign centerRunOnDesired: real-nodes-only averaging + width clamp ---
// (moved from lanes_test.zig; centerRunOnDesired itself lives in x_assign.zig)

test "centerRunOnDesired re-centers using only real nodes, keeping the real node's trunk straight" {
    // Row = [virtual waypoint from an unrelated edge, real node R], both fed
    // solely by parent A above. R's own barycenter is A's center; the
    // virtual's packing footprint pushes R's PACKED position off that
    // center, but the real-nodes-only average must pull R back exactly onto
    // A's column (a straight vertical trunk).
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };

    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 100 },
        .{ .virtual = .{ .edge = 5, .index = 0 } },
        .{ .real = 101 },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 5, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 6, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    const initial = [_]cx_mod.NodeGeom{
        .{ .x = 50, .y = 0, .w = 6, .h = 3, .layer = 0 }, // A
        .{ .x = 0, .y = 5, .w = 0, .h = 0, .layer = 1 }, // virtual waypoint
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 }, // R
    };

    // Packed baseline (compact=false): monotonic packing only, no recentering.
    var packed_only = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &packed_only, lg, 2, .down, false, 0);

    // Actual behavior (compact=true, real-nodes-only average): R lands
    // exactly under A.
    var real = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &real, lg, 2, .down, true, 0);
    const a_cx = real[0].x + @as(i32, @intCast(real[0].w / 2));
    const r_cx = real[2].x + @as(i32, @intCast(real[2].w / 2));
    try testing.expectEqual(a_cx, r_cx);

    // Mutated contrast: had the average included the virtual waypoint (the
    // regression this invariant guards against), the shared delta would be
    // computed from BOTH nodes instead of R alone, landing R off A's column.
    const v_actual = packed_only[1].x; // w=0, so center == x
    const r_actual = packed_only[2].x + @as(i32, @intCast(packed_only[2].w / 2));
    const desired = a_cx; // both virtual and R share A as their sole neighbour
    const mutated_delta = @divTrunc((desired - v_actual) + (desired - r_actual), 2);
    const mutated_r_cx = r_actual + mutated_delta;
    try testing.expect(mutated_r_cx != a_cx);
}

test "centerRunOnDesired's width clamp keeps a recentered row from crossing x=0" {
    // Same shape as the straight-trunk case above, but with A placed near
    // the left margin so the unclamped real-nodes-only delta would drive
    // the row negative.
    const empty_g = sg.SemGraph{ .direction = .TD, .nodes = &.{}, .edges = &.{}, .clusters = &.{}, .classes = &.{}, .arena = null };

    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 100 },
        .{ .virtual = .{ .edge = 5, .index = 0 } },
        .{ .real = 101 },
    };
    var layer0 = [_]u32{0};
    var layer1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &layer0, &layer1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 1, .edge = 5, .reversed = false },
        .{ .from = 0, .to = 2, .edge = 6, .reversed = false },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &nodes,
        .layers = &layers,
        .edges = &edges,
        .reversed_edges = &.{},
        .real_index = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty,
        .arena = null,
    };
    const initial = [_]cx_mod.NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 3, .layer = 0 }, // A, right at the margin
        .{ .x = 0, .y = 5, .w = 0, .h = 0, .layer = 1 }, // virtual waypoint
        .{ .x = 0, .y = 5, .w = 10, .h = 3, .layer = 1 }, // R
    };

    // Packed baseline + the real-nodes-only delta the real code would want
    // to apply BEFORE clamping — confirm this scenario really does cross 0.
    var packed_only = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &packed_only, lg, 2, .down, false, 0);
    const a_cx = packed_only[0].x + @as(i32, @intCast(packed_only[0].w / 2));
    const r_actual = packed_only[2].x + @as(i32, @intCast(packed_only[2].w / 2));
    const unclamped_delta = a_cx - r_actual;
    const row_min_before = @min(packed_only[1].x, packed_only[2].x);
    try testing.expect(row_min_before + unclamped_delta < 0);

    // Actual (clamped) behavior: the row must never cross x = 0.
    var real = initial;
    try cx_mod.centerByBarycenter(testing.allocator, empty_g, &real, lg, 2, .down, true, 0);
    try testing.expect(real[1].x >= 0);
    try testing.expect(real[2].x >= 0);
}

//! Unit tests for cluster/bridges.zig + cluster/tracks.zig, split out to
//! keep bridges.zig under the 500-line cap. Hand-built placements/frames in,
//! routed polylines out — no layout involvement.

const std = @import("std");
const sketch = @import("../sketch.zig");
const bridges = @import("bridges.zig");
const tracks = @import("tracks.zig");

const Crossing = bridges.Crossing;

test "vertical stacked bridge routes straight when x-aligned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 10, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &.{}, .TD, &orig_to_merged);
    try std.testing.expectEqual(@as(usize, 1), edges.len);
    // straight: 2 points, both at x = 13 (center of x=10,w=6)
    try std.testing.expectEqual(@as(usize, 2), edges[0].polyline.len);
    try std.testing.expectEqual(@as(i32, 13), edges[0].polyline[0].x);
    try std.testing.expectEqual(@as(i32, 13), edges[0].polyline[1].x);
    try std.testing.expectEqual(sketch.Dir4.south, edges[0].port_from.side);
    try std.testing.expectEqual(sketch.Dir4.north, edges[0].port_to.side);
}

test "vertical bridge jogs when x-misaligned, final segment vertical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Vertically dominant separation (dy > dx) so the router stacks them and
    // the connector descends into a north port.
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 8, .y = 20, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &.{}, .TD, &orig_to_merged);
    const poly = edges[0].polyline;
    try std.testing.expectEqual(@as(usize, 4), poly.len);
    // Single bridge, no frames: the jog sits at the plain elbow's preferred
    // row (min(to_box.y-1, end.y-2) = 18), byte-identical to pre-track code.
    try std.testing.expectEqual(@as(i32, 18), poly[1].y);
    try std.testing.expectEqual(@as(i32, 18), poly[2].y);
    // final segment is vertical (same x), so the arrowhead reads as ▼
    try std.testing.expectEqual(poly[poly.len - 2].x, poly[poly.len - 1].x);
    try std.testing.expectEqual(sketch.Dir4.north, edges[0].port_to.side);
}

test "jog landing on a drawn frame border row is displaced outside it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Microservices-shape repro: the target sits in a SYNTHETIC packing
    // frame (zero pad, top row == node top row) nested in a REAL frame whose
    // top border row is exactly the elbow's preferred jog row
    // (min(synthetic.y - 1, end.y - 2) = 6 == real frame top border).
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 20, .y = 8, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = 9 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 9, .rect = .{ .x = 20, .y = 8, .w = 6, .h = 3 }, .parent_id = 7, .label = "", .depth = 1, .synthetic = true },
        .{ .id = 7, .rect = .{ .x = 18, .y = 6, .w = 12, .h = 7 }, .parent_id = null, .label = "Real", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, .TD, &orig_to_merged);
    const poly = edges[0].polyline;
    try std.testing.expectEqual(@as(usize, 4), poly.len);
    // Preferred row 6 fuses into frame 7's top border → displaced OUTWARD
    // (up, away from the entered side) to the clear row 5.
    try std.testing.expectEqual(@as(i32, 5), poly[1].y);
    try std.testing.expectEqual(@as(i32, 5), poly[2].y);
    // Final drop is still perpendicular into the port.
    try std.testing.expectEqual(poly[2].x, poly[3].x);
}

test "two same-side bridges with overlapping spans get distinct tracks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two sources whose bridges CROSS into one real frame: overlapping jog
    // x-spans on the same (north) entry side must not share a jog row.
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 30, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 8, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = 7 },
        .{ .id = 3, .rect = .{ .x = 22, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"Q"}, .cluster_id = 7 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 6, .y = 8, .w = 24, .h = 7 }, .parent_id = null, .label = "Real", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2, 3 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, .TD, &orig_to_merged);
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    const jog0 = edges[0].polyline[1].y;
    const jog1 = edges[1].polyline[1].y;
    // Distinct tracks (stack_gap 1), both strictly above the frame's top
    // border row (8) and never ON it.
    try std.testing.expect(jog0 != jog1);
    try std.testing.expect(jog0 < 8 and jog1 < 8);
    try std.testing.expectEqual(@as(i32, 1), @max(jog0, jog1) - @min(jog0, jog1));
}

test "bridges sharing one source port share a single rail track" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A fan: one source, two targets in the same frame. Overlapping spans,
    // but the shared exit port means one rail row for both (no ladder).
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 12, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 8, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = 7 },
        .{ .id = 2, .rect = .{ .x = 22, .y = 10, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"Q"}, .cluster_id = 7 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 6, .y = 8, .w = 24, .h = 7 }, .parent_id = null, .label = "Real", .depth = 0 },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, .TD, &orig_to_merged);
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    try std.testing.expectEqual(edges[0].polyline[1].y, edges[1].polyline[1].y);
}

test "tracks.onFrameBorder ignores synthetic frames and disjoint spans" {
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 10, .y = 5, .w = 10, .h = 6 }, .parent_id = null, .label = "R", .depth = 0 },
        .{ .id = 2, .rect = .{ .x = 40, .y = 5, .w = 10, .h = 6 }, .parent_id = null, .label = "", .depth = 0, .synthetic = true },
    };
    // On the real frame's top border row, span overlapping → hit.
    try std.testing.expect(tracks.onFrameBorder(true, 5, 0, 15, &clusters));
    // Same row but span entirely left of the frame → no hit.
    try std.testing.expect(!tracks.onFrameBorder(true, 5, 0, 9, &clusters));
    // Synthetic frame's border row → never a hit.
    try std.testing.expect(!tracks.onFrameBorder(true, 5, 40, 49, &clusters));
    // Bottom border row (y + h - 1 = 10) → hit; interior row → no hit.
    try std.testing.expect(tracks.onFrameBorder(true, 10, 12, 18, &clusters));
    try std.testing.expect(!tracks.onFrameBorder(true, 7, 12, 18, &clusters));
    // Column form: left border col 10 with y-span overlap → hit.
    try std.testing.expect(tracks.onFrameBorder(false, 10, 6, 9, &clusters));
    try std.testing.expect(!tracks.onFrameBorder(false, 11, 6, 9, &clusters));
}

test "assignJogs: shared-request merge across different cluster depths picks the closest-to-target preference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One source fans into two targets sharing the same real-frame anchor
    // but sitting at DIFFERENT nesting depths: P is a direct member of the
    // real frame (id 7); Q is nested one level deeper inside a synthetic
    // packing frame (id 8, parent 7). Both crossings share the exact same
    // source port, so they fold into ONE shared jog request — the
    // "shared-request merge" whose preference must pick whichever member's
    // jog sits CLOSEST to the target (the deeper Q, at the inner frame's
    // border), not whichever crossing happened to be processed first.
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 12, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 8, .y = 25, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = 7 },
        .{ .id = 2, .rect = .{ .x = 22, .y = 25, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"Q"}, .cluster_id = 8 },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 7, .rect = .{ .x = 6, .y = 20, .w = 24, .h = 10 }, .parent_id = null, .label = "Real", .depth = 0 },
        .{ .id = 8, .rect = .{ .x = 20, .y = 22, .w = 8, .h = 6 }, .parent_id = 7, .label = "", .depth = 1, .synthetic = true },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1, 2 };
    const crossings = [_]Crossing{
        // P first: if the merge were first-writer-wins, the shared jog
        // would freeze at P's shallower preference (19) and Q's edge
        // would inherit it too.
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &clusters, .TD, &orig_to_merged);
    try std.testing.expectEqual(@as(usize, 2), edges.len);
    // P's own preference (to_box=frame7, min(19, 23)=19) loses; the merge
    // must pick Q's deeper preference (to_box=frame8, min(21, 23)=21) for
    // BOTH edges, since they share one rail.
    try std.testing.expectEqual(@as(i32, 21), edges[0].polyline[1].y);
    try std.testing.expectEqual(@as(i32, 21), edges[1].polyline[1].y);
}

test "verticalCorridor: the source-side jog row (one past the source) is collision-free above the pierced child" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The plain elbow's straight vertical run (x=15, source's mid column)
    // pierces an intra-cluster child sitting directly below the source, so
    // `route` re-routes via `verticalCorridor`. Its source-side jog sits
    // one row past the source (y=3) — ABOVE the child (which starts at
    // y=5, leaving rows 3-4 clear) — and must never collide with it.
    const placements = [_]sketch.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 12, .y = 0, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 10, .y = 5, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{"child"}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 40, .y = 20, .w = 6, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const orig_to_merged = [_]sketch.NodeId{ 0, 1 };
    const crossings = [_]Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const edges = try bridges.route(a, &crossings, &placements, &.{}, .TD, &orig_to_merged);
    const poly = edges[0].polyline;

    // Corridor engaged (not the plain 4-point elbow, whose jog row would
    // have been 18 — straight through the child).
    try std.testing.expectEqual(@as(usize, 5), poly.len);
    try std.testing.expectEqual(@as(i32, 15), poly[1].x);
    try std.testing.expectEqual(@as(i32, 3), poly[1].y);

    // The claim under test: this derived row is ACTUALLY collision-free,
    // not merely assumed so — checked against every real placement other
    // than the edge's own endpoints, exactly as `polyPierces` would.
    try std.testing.expect(!sketch.columnTouchesAny(poly[1].x, poly[0].y, poly[1].y, &placements, 0, 1));
}

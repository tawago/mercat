//! Unit tests for layout/validate.zig. Split out to keep validate.zig
//! under the 500-line cap.

const std = @import("std");
const sketch = @import("../sketch.zig");
const validate_mod = @import("validate.zig");
const validate = validate_mod.validate;

const testing = std.testing;

fn makeNode(
    id: sketch.NodeId,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    cluster_id: ?sketch.ClusterId,
) sketch.NodePlacement {
    return .{
        .id = id,
        .rect = .{ .x = x, .y = y, .w = w, .h = h },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = cluster_id,
    };
}

fn makeEdge(
    id: sketch.EdgeId,
    from: sketch.NodeId,
    to: sketch.NodeId,
    poly: []const sketch.Point,
) sketch.EdgePath {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .polyline = poly,
        .port_from = .{ .node = from, .side = .east, .offset = 0 },
        .port_to = .{ .node = to, .side = .west, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
        .kind = .solid,
    };
}

test "ok sketch passes all validators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sketch.NodePlacement{
        makeNode(1, 0, 0, 5, 3, null),
        makeNode(2, 10, 0, 5, 3, null),
    };
    const poly = [_]sketch.Point{
        .{ .x = 5, .y = 1 },
        .{ .x = 10, .y = 1 },
    };
    const edges = [_]sketch.EdgePath{makeEdge(1, 1, 2, &poly)};

    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 15, .h = 3 },
        .direction = .LR,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const result = try validate(a, s);
    try testing.expect(result == .ok);
}

test "overlapping nodes flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sketch.NodePlacement{
        makeNode(1, 0, 0, 5, 3, null),
        makeNode(2, 2, 1, 5, 3, null),
    };
    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 7, .h = 4 },
        .direction = .LR,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const result = try validate(a, s);
    try testing.expect(result == .failed);
    var saw_overlap = false;
    for (result.failed) |v| {
        if (v.kind == .node_overlap) saw_overlap = true;
    }
    try testing.expect(saw_overlap);
}

test "edge through node interior flagged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sketch.NodePlacement{
        makeNode(1, 0, 0, 5, 5, null),
        makeNode(2, 20, 0, 5, 5, null),
        makeNode(3, 10, 0, 5, 5, null),
    };
    const poly = [_]sketch.Point{
        .{ .x = 5, .y = 2 },
        .{ .x = 20, .y = 2 },
    };
    const edges = [_]sketch.EdgePath{makeEdge(1, 1, 2, &poly)};

    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 5 },
        .direction = .LR,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const result = try validate(a, s);
    try testing.expect(result == .failed);
    var saw_interior = false;
    for (result.failed) |v| {
        if (v.kind == .path_through_interior) saw_interior = true;
    }
    try testing.expect(saw_interior);
}

test "bbox overflow is informational, not a validation failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 100, .h = 5 },
        .direction = .LR,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const result = try validate(a, s);
    try testing.expect(result == .ok);
}

test "cluster containment violated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const clusters = [_]sketch.ClusterFrame{.{
        .id = 1,
        .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .parent_id = null,
        .label = "C",
        .depth = 0,
    }};
    const nodes = [_]sketch.NodePlacement{
        makeNode(1, 8, 1, 5, 3, 1),
    };
    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 15, .h = 10 },
        .direction = .LR,
        .nodes = &nodes,
        .clusters = &clusters,
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const result = try validate(a, s);
    try testing.expect(result == .failed);
    var saw = false;
    for (result.failed) |v| {
        if (v.kind == .cluster_does_not_contain) saw = true;
    }
    try testing.expect(saw);
}

test "checkPathInteriors exempts a segment adjacent to its own edge's endpoint but flags a genuine cross by an unrelated edge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node_a = [_]sketch.NodePlacement{makeNode(1, 0, 0, 5, 5, null)};

    const poly_own = [_]sketch.Point{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 20 } };
    const edge_own = [_]sketch.EdgePath{makeEdge(10, 1, 99, &poly_own)};
    var v_own: std.ArrayList(validate_mod.Violation) = .empty;
    try validate_mod.checkPathInteriors(a, .{
        .bbox = .{ .x = -10, .y = 0, .w = 40, .h = 20 },
        .direction = .LR,
        .nodes = &node_a,
        .clusters = &.{},
        .edges = &edge_own,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }, &v_own);
    try testing.expectEqual(@as(usize, 0), v_own.items.len);

    const poly_foreign = [_]sketch.Point{ .{ .x = -8, .y = 2 }, .{ .x = 13, .y = 2 } };
    const edge_foreign = [_]sketch.EdgePath{makeEdge(11, 3, 4, &poly_foreign)};
    var v_foreign: std.ArrayList(validate_mod.Violation) = .empty;
    try validate_mod.checkPathInteriors(a, .{
        .bbox = .{ .x = -10, .y = 0, .w = 40, .h = 20 },
        .direction = .LR,
        .nodes = &node_a,
        .clusters = &.{},
        .edges = &edge_foreign,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }, &v_foreign);
    try testing.expectEqual(@as(usize, 1), v_foreign.items.len);
    try testing.expectEqual(validate_mod.Violation.Kind.path_through_interior, v_foreign.items[0].kind);
}

test "checkPathInteriors' diagonal fallback is a conservative bbox-overlap test, not a precise line-rect intersection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const node = [_]sketch.NodePlacement{makeNode(5, 10, 10, 5, 5, null)};

    const poly_bbox_overlap = [_]sketch.Point{ .{ .x = 0, .y = 20 }, .{ .x = 20, .y = 0 } };
    const edge_overlap = [_]sketch.EdgePath{makeEdge(20, 100, 101, &poly_bbox_overlap)};
    var v_overlap: std.ArrayList(validate_mod.Violation) = .empty;
    try validate_mod.checkPathInteriors(a, .{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 25 },
        .direction = .LR,
        .nodes = &node,
        .clusters = &.{},
        .edges = &edge_overlap,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }, &v_overlap);
    try testing.expectEqual(@as(usize, 1), v_overlap.items.len);

    const poly_clear = [_]sketch.Point{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 } };
    const edge_clear = [_]sketch.EdgePath{makeEdge(21, 100, 101, &poly_clear)};
    var v_clear: std.ArrayList(validate_mod.Violation) = .empty;
    try validate_mod.checkPathInteriors(a, .{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 25 },
        .direction = .LR,
        .nodes = &node,
        .clusters = &.{},
        .edges = &edge_clear,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    }, &v_clear);
    try testing.expectEqual(@as(usize, 0), v_clear.items.len);
}

test "counts: clean sketch tallies all-zero" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sketch.NodePlacement{
        makeNode(1, 0, 0, 5, 3, null),
        makeNode(2, 10, 0, 5, 3, null),
    };
    const poly = [_]sketch.Point{
        .{ .x = 5, .y = 1 },
        .{ .x = 10, .y = 1 },
    };
    const edges = [_]sketch.EdgePath{makeEdge(1, 1, 2, &poly)};

    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 15, .h = 3 },
        .direction = .LR,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const c = validate_mod.counts(try validate(a, s), s);
    try testing.expectEqual(validate_mod.Counts{}, c);
}

test "counts: interior crossing and overlap tally per kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sketch.NodePlacement{
        makeNode(1, 0, 0, 5, 5, null),
        makeNode(2, 20, 0, 5, 5, null),
        makeNode(3, 10, 0, 5, 5, null),
        makeNode(4, 12, 2, 5, 5, null),
    };
    const poly = [_]sketch.Point{
        .{ .x = 5, .y = 2 },
        .{ .x = 20, .y = 2 },
    };
    const edges = [_]sketch.EdgePath{makeEdge(1, 1, 2, &poly)};

    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 7 },
        .direction = .LR,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const c = validate_mod.counts(try validate(a, s), s);
    try testing.expect(c.node_overlap >= 1);
    try testing.expect(c.path_through_interior >= 1);
    try testing.expectEqual(@as(u32, 0), c.path_off_perimeter);
    try testing.expectEqual(@as(u32, 0), c.cluster_containment);
    try testing.expectEqual(@as(u32, 0), c.bbox_overflow);
}

test "counts: over-budget bbox reports bbox_overflow without a Violation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s: sketch.Sketch = .{
        .bbox = .{ .x = 0, .y = 0, .w = 100, .h = 5 },
        .direction = .LR,
        .nodes = &.{},
        .clusters = &.{},
        .edges = &.{},
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    const vr = try validate(a, s);
    try testing.expect(vr == .ok);
    const c = validate_mod.counts(vr, s);
    try testing.expectEqual(@as(u32, 1), c.bbox_overflow);
}

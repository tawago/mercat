const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const coords = @import("../layout.zig");
const lt = @import("layout_test.zig");
const mkNode = lt.mkNode;
const mkEdge = lt.mkEdge;
const deinitSketch = lt.deinitSketch;

const testing = std.testing;

test "a production render carries the closure licence's counts on its Sketch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]sg.Node{ mkNode(0, "Z"), mkNode(1, "A"), mkNode(2, "B"), mkNode(3, "C") };
    var edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 0, 2), mkEdge(2, 0, 3) };
    for (&edges) |*e| e.arrow_to = .none;
    const g: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var s = try coords.layout(arena.allocator(), g, .{});
    defer deinitSketch(&s, arena.allocator());
    try testing.expectEqual(@as(u32, 1), s.closure.rail_closure_undeclared);
    try testing.expectEqual(@as(u32, 3), s.closure.co_undeclared);
    try testing.expectEqual(@as(u32, 0), s.closure.co_double_discharge);

    var declared = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 0, 2), mkEdge(2, 0, 3), mkEdge(3, 1, 2), mkEdge(4, 1, 3), mkEdge(5, 2, 3) };
    for (&declared) |*e| e.arrow_to = .none;
    var clean = try coords.layout(arena.allocator(), .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &declared,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    }, .{});
    defer deinitSketch(&clean, arena.allocator());
    try testing.expectEqual(@as(u32, 0), clean.closure.rail_closure_undeclared);
    try testing.expectEqual(@as(u32, 0), clean.closure.co_undeclared);
}

test "construction-time rail exclusions are reported on the shipped Sketch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const nodes = [_]sg.Node{ mkNode(0, "P"), mkNode(1, "A"), mkNode(2, "B"), mkNode(3, "C") };
    var edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 0, 2), mkEdge(2, 0, 3), mkEdge(3, 0, 1) };
    edges[2].arrow_from = .circle;
    edges[3].arrow_from = .circle;
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    var s = try coords.layout(arena.allocator(), g, .{});
    defer deinitSketch(&s, arena.allocator());
    try testing.expectEqual(@as(u32, 1), s.closure.rail_deco_mixed);
    try testing.expectEqual(@as(u32, 2), s.closure.rail_star_violation);
}

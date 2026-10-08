const std = @import("std");
const sg = @import("../sem_graph.zig");
const token = @import("token.zig");
const builder = @import("builder.zig");

const Builder = builder.Builder;
const t = std.testing;

const solid: token.Link = .{ .kind = .solid, .from = .none, .to = .filled, .label = null };

/// A builder over an arena, with its named nodes already made in the current subgraph.
fn nodes(b: *Builder, names: []const []const u8) !void {
    for (names) |name| _ = try b.node(name);
}

fn id(b: *Builder, name: []const u8) sg.NodeId {
    return b.node_ids.get(name).?;
}

test "a source stands for the last member with no edge to another member" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("S", "S");
    try nodes(&b, &.{ "a", "b" });
    try b.addEdge(id(&b, "a"), id(&b, "b"), solid, null);
    _ = b.closeCluster();
    try t.expectEqual(@as(?sg.NodeId, id(&b, "b")), b.representative(0, .source));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(0, .target));
}

test "with no edge inside, a source is the last member and a target the first" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("S", "S");
    try nodes(&b, &.{ "a", "b", "c" });
    _ = b.closeCluster();
    try t.expectEqual(@as(?sg.NodeId, id(&b, "c")), b.representative(0, .source));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(0, .target));
}

test "an edge that leaves the subgraph does not count as an edge to a member" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("S", "S");
    try nodes(&b, &.{ "a", "b" });
    _ = b.closeCluster();
    try nodes(&b, &.{"x"});
    try b.addEdge(id(&b, "b"), id(&b, "a"), solid, null);
    try b.addEdge(id(&b, "a"), id(&b, "x"), solid, null);
    try b.addEdge(id(&b, "x"), id(&b, "b"), solid, null);
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(0, .source));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "b")), b.representative(0, .target));
}

test "an edge between members of a nested subgraph counts in every enclosing subgraph" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("outer", "outer");
    try b.openCluster("left", "left");
    try nodes(&b, &.{ "a", "b" });
    _ = b.closeCluster();
    try b.openCluster("right", "right");
    try nodes(&b, &.{"c"});
    _ = b.closeCluster();
    _ = b.closeCluster();
    try b.addEdge(id(&b, "a"), id(&b, "b"), solid, null);
    try b.addEdge(id(&b, "b"), id(&b, "c"), solid, null);
    try t.expectEqual(@as(?sg.NodeId, id(&b, "c")), b.representative(0, .source));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "b")), b.representative(1, .source));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(0, .target));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "c")), b.representative(2, .target));
}

test "a subgraph still open counts the members of the subgraphs opened inside it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("outer", "outer");
    try b.openCluster("inner", "inner");
    try nodes(&b, &.{"a"});
    _ = b.closeCluster();
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(0, .source));
    try b.openCluster("next", "next");
    try nodes(&b, &.{"b"});
    try t.expectEqual(@as(?sg.NodeId, id(&b, "b")), b.representative(0, .source));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(1, .source));
}

test "rollback drops the nodes and edges added since begin" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("S", "S");
    try nodes(&b, &.{"a"});
    const mark = b.begin();
    try nodes(&b, &.{ "b", "c" });
    try b.addEdge(id(&b, "a"), id(&b, "b"), solid, null);
    b.rollback(mark);
    try t.expectEqual(@as(usize, 1), b.nodes.items.len);
    try t.expectEqual(@as(usize, 0), b.edges.items.len);
    try t.expect(b.node_ids.get("b") == null);
    try t.expectEqual(@as(sg.NodeId, 1), try b.node("d"));
    _ = b.closeCluster();
    const built = try b.finish();
    try t.expectEqual(@as(usize, 2), built.clusters[0].members.len);
}

test "a node that existed before begin keeps the shape a rolled back line gave it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    const a = try b.node("a");
    const mark = b.begin();
    b.declare(a, .circle, "kept");
    b.rollback(mark);
    try t.expectEqual(sg.NodeShape.circle, b.nodes.items[a].shape);
    try t.expectEqualStrings("kept", b.nodes.items[a].label);
}

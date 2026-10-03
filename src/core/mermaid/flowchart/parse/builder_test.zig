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

test "only the edges added before an endpoint is read count" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("S", "S");
    try nodes(&b, &.{ "a", "b" });
    _ = b.closeCluster();
    try t.expectEqual(@as(?sg.NodeId, id(&b, "b")), b.representative(0, .source));
    try b.addEdge(id(&b, "b"), id(&b, "a"), solid, null);
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(0, .source));
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

test "a subgraph with no node has no representative" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("empty", "empty");
    _ = b.closeCluster();
    try nodes(&b, &.{"x"});
    try t.expectEqual(@as(?sg.NodeId, null), b.representative(0, .source));
    try t.expectEqual(@as(?sg.NodeId, null), b.representative(0, .target));
}

test "rollback restores what the undone edges had linked" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("S", "S");
    try nodes(&b, &.{ "a", "b" });
    _ = b.closeCluster();
    const mark = b.begin();
    try b.addEdge(id(&b, "b"), id(&b, "a"), solid, null);
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(0, .source));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "b")), b.representative(0, .target));
    b.rollback(mark);
    try t.expectEqual(@as(?sg.NodeId, id(&b, "b")), b.representative(0, .source));
    try t.expectEqual(@as(?sg.NodeId, id(&b, "a")), b.representative(0, .target));
    try t.expectEqual(@as(usize, 0), b.edges.items.len);
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

test "a declaration without a label keeps the id as the label" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    const a = try b.node("a");
    b.declare(a, .hexagon, null);
    try t.expectEqual(sg.NodeShape.hexagon, b.nodes.items[a].shape);
    try t.expectEqualStrings("a", b.nodes.items[a].label);
}

test "subgraphs with no node below them are dropped and the rest renumbered" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("empty", "empty");
    _ = b.closeCluster();
    try b.openCluster("outer", "Outer");
    try b.openCluster("hollow", "hollow");
    _ = b.closeCluster();
    try b.openCluster("inner", "inner");
    try nodes(&b, &.{"a"});
    _ = b.closeCluster();
    _ = b.closeCluster();
    const built = try b.finish();
    try t.expectEqual(@as(usize, 2), built.clusters.len);
    try t.expectEqualStrings("outer", built.clusters[0].raw_id);
    try t.expectEqualStrings("inner", built.clusters[1].raw_id);
    try t.expectEqual(@as(?sg.ClusterId, 0), built.clusters[1].parent);
    try t.expectEqualSlices(sg.ClusterId, &.{1}, built.clusters[0].sub_clusters);
    try t.expectEqual(@as(?sg.ClusterId, 1), built.nodes[0].cluster);
}

test "closing with nothing open reports it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try t.expect(!b.closeCluster());
    try b.openCluster("S", "S");
    try t.expect(b.closeCluster());
    try t.expect(!b.closeCluster());
}

test "a repeated subgraph id names the latest subgraph" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var b = Builder.init(arena.allocator());
    try b.openCluster("S", "first");
    try nodes(&b, &.{"a"});
    _ = b.closeCluster();
    try b.openCluster("S", "second");
    try nodes(&b, &.{"b"});
    _ = b.closeCluster();
    try t.expectEqual(@as(?sg.ClusterId, 1), b.clusterNamed("S"));
    try t.expectEqual(@as(?sg.ClusterId, null), b.clusterNamed("T"));
}

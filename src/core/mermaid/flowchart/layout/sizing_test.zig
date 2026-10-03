const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const sizing = @import("sizing.zig");
const mirror = @import("mirror.zig");
const node_geom = @import("node_geom.zig");

const testing = std.testing;
const NodeGeom = node_geom.NodeGeom;

test "labelLines hard-break-only path matches wrapToWidth at an effectively infinite cap" {
    const a = testing.allocator;
    const label = "Alpha One\nBeta Gamma Delta\nEcho";

    const hard = try sizing.labelLines(a, label, null);
    defer a.free(hard);
    const wrapped = try prim.wrapToWidth(a, label, 1_000_000);
    defer a.free(wrapped);

    try testing.expectEqual(hard.len, wrapped.len);
    for (hard, wrapped) |h, w| {
        try testing.expectEqualStrings(h, w);
    }
}

test "sizeNodes pre-swaps an LR multi-line label so post-applyDirection dims match the visual box" {
    const a = testing.allocator;
    const nodes = [_]sg.Node{
        .{ .id = 1, .raw_id = "A", .label = "AB\nCDEF", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const graph: sg.SemGraph = .{
        .direction = .LR,
        .nodes = &nodes,
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(a, graph);
    defer lg.deinit(a);

    var geom: [1]NodeGeom = undefined;
    var node_lines: [1][]const []const u8 = undefined;
    try sizing.sizeNodes(a, graph, lg, &geom, 0, &.{}, null, &node_lines);
    defer a.free(node_lines[0]);

    mirror.applyDirection(&geom, .LR);
    try testing.expectEqual(@as(u32, 6), geom[0].w);
    try testing.expectEqual(@as(u32, 4), geom[0].h);
}

test "forcedWraps names each node whose label wrapped beyond its authored line breaks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{
        .{ .id = 1, .raw_id = "A", .label = "AAAA BBBB CCCC", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 2, .raw_id = "B", .label = "AB" ++ [_]u8{prim.LINE_BREAK} ++ "CD", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 3, .raw_id = "C", .label = "OK", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const graph: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(a, graph);
    defer lg.deinit(a);

    var geom: [3]NodeGeom = undefined;
    var node_lines: [3][]const []const u8 = undefined;
    try sizing.sizeNodes(a, graph, lg, &geom, 0, &.{}, 4, &node_lines);

    const wraps = try sizing.forcedWraps(a, graph, lg, &node_lines);
    try testing.expectEqual(@as(usize, 1), wraps.len);
    try testing.expectEqual(@as(sg.NodeId, 1), wraps[0].forced_label_wrap.node);
}

const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const sizing = @import("sizing.zig");
const mirror = @import("mirror.zig");
const routing = @import("routing.zig");

const testing = std.testing;
const NodeGeom = routing.NodeGeom;

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

    mirror.applyDirection(NodeGeom, &geom, .LR);
    try testing.expectEqual(@as(u32, 6), geom[0].w);
    try testing.expectEqual(@as(u32, 4), geom[0].h);
}

//! Tests for `components.zig`'s `packComponents` no-op invariant. Moved
//! here from `sugiyama_test.zig` (which built the synthetic `LayeredGraph`
//! fixtures by hand but was testing `components.zig`, not `sugiyama.zig`),
//! per the mermaid_v2/ test-file convention. Discovered via components.zig's
//! top-level `test { _ = @import("components_test.zig"); }` block.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const components = @import("components.zig");

const testing = std.testing;

fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{
        .id = id,
        .raw_id = raw,
        .label = raw,
        .shape = .rect,
        .classes = &.{},
        .cluster = null,
    };
}

fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
    };
}

// -- component packing no-op (layout/components.zig `packComponents`) -------

test "packComponents leaves node geometry unchanged for a single connected component" {
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "C") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 2) };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var lg = try sugiyama.assignLayers(testing.allocator, g);
    defer lg.deinit(testing.allocator);

    const geom = try testing.allocator.alloc(components.NodeGeom, lg.nodes.len);
    defer testing.allocator.free(geom);
    for (geom, 0..) |*gm, i| {
        gm.* = .{ .x = @intCast(i * 10 + 3), .y = @intCast(i * 5 + 1), .w = 6, .h = 3, .layer = 0 };
    }
    const before = try testing.allocator.dupe(components.NodeGeom, geom);
    defer testing.allocator.free(before);

    try components.packComponents(testing.allocator, g, geom, lg);

    try testing.expectEqualSlices(components.NodeGeom, before, geom);
}

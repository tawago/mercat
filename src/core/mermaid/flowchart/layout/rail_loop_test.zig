const std = @import("std");
const parse = @import("../parse.zig").parse;
const permits = @import("../ledger/permits.zig");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const coords = @import("../layout.zig");

const source =
    \\flowchart TD
    \\check -->|yes| proc[Process item]
    \\proc --> loop{More?}
    \\loop -->|yes| proc
    \\loop -->|no| done((Done))
    \\err --> done
    \\proc -.-> log[(Log store)]
    \\err -.-> log
    \\
;

const Laid = struct { graph: sg.SemGraph, sketch: sketch.Sketch };

fn laidOut(a: std.mem.Allocator, h_spacing: u32) !Laid {
    const graph = try parse(a, source);
    const built = try permits.build(a, graph, .joined);
    return .{
        .graph = graph,
        .sketch = try coords.layout(a, graph, .{ .bundle_permits = &built.plan, .h_spacing = h_spacing }),
    };
}

fn nodeId(graph: sg.SemGraph, raw: []const u8) sg.NodeId {
    for (graph.nodes) |n| if (std.mem.eql(u8, n.raw_id, raw)) return n.id;
    unreachable;
}

fn edgeId(graph: sg.SemGraph, from: []const u8, to: []const u8) sg.EdgeId {
    for (graph.edges) |e| if (e.from == nodeId(graph, from) and e.to == nodeId(graph, to)) return e.id;
    unreachable;
}

fn pathOf(s: sketch.Sketch, id: sg.EdgeId) sketch.EdgePath {
    for (s.edges) |path| if (path.id == id) return path;
    unreachable;
}

fn railAt(s: sketch.Sketch, pivot: sg.NodeId) ?sketch.Rail {
    for (s.rails) |rail| if (rail.pivot == pivot) return rail;
    return null;
}

test "a long member whose stroke clears nowhere is cut from its fan, and a fan left with one peer draws no rail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const laid = try laidOut(arena.allocator(), 2);
    const s = laid.sketch;

    try std.testing.expect(railAt(s, nodeId(laid.graph, "log")) == null);
    try std.testing.expectEqual(sketch.EdgeRole.forward, pathOf(s, edgeId(laid.graph, "err", "log")).role);
    try std.testing.expectEqual(sketch.EdgeRole.fan_out_dropper, pathOf(s, edgeId(laid.graph, "proc", "log")).role);

    const done = railAt(s, nodeId(laid.graph, "done")) orelse return error.MissingRail;
    try std.testing.expectEqual(@as(usize, 2), done.taps.len);
    try std.testing.expectEqual(sketch.EdgeRole.member_stroke, pathOf(s, edgeId(laid.graph, "err", "done")).role);
}

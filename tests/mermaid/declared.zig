//! The relation a flowchart source declares, in the form check.judge takes.

const std = @import("std");
const check = @import("check");
const mermaid_v2 = @import("mermaid_v2");

/// Parses `source` and lists its node labels and drawn edges.
pub fn declared(arena: std.mem.Allocator, source: []const u8) !check.Declared {
    const graph = try mermaid_v2.parse(arena, source);
    const labels = try arena.alloc([]const u8, graph.nodes.len);
    for (graph.nodes, labels) |n, *l| l.* = n.label;
    var edges: std.ArrayList(check.Relation) = .empty;
    for (graph.edges) |e| {
        const stroke: check.Stroke = switch (e.kind) {
            .invisible => continue,
            .solid => .solid,
            .dotted => .dotted,
            .thick => .thick,
        };
        try edges.append(arena, .{
            .a = .{ .label = labels[e.from] },
            .end_a = end(e.arrow_from),
            .b = .{ .label = labels[e.to] },
            .end_b = end(e.arrow_to),
            .stroke = stroke,
        });
    }
    return .{ .labels = labels, .edges = edges.items };
}

fn end(a: mermaid_v2.sem_graph.ArrowEnd) check.End {
    return switch (a) {
        .none => .none,
        .filled => .filled,
        .open => .open,
        .circle => .circle,
        .cross => .cross,
    };
}

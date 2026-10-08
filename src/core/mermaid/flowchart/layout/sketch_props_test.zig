//! Seeded random diamonds and small DAGs lay out without sketch-validator
//! violations. This is the only end-to-end use of `validateSketch`: the
//! readback props only see the final candidate render.
const std = @import("std");
const layoutFlowchart = @import("../layout.zig").layout;
const validateSketch = @import("validate.zig").validate;
const sem_graph = @import("../sem_graph.zig");

/// A diamond (one source, k siblings in one layer, one sink) or a random DAG
/// with a chain backbone plus forward edges.
fn genGraph(a: std.mem.Allocator, rng: std.Random, diamond: bool) !sem_graph.SemGraph {
    var edges: std.ArrayList(sem_graph.Edge) = .empty;
    const n: u32 = if (diamond) 2 + rng.intRangeAtMost(u32, 2, 4) else rng.intRangeAtMost(u32, 2, 10);
    if (diamond) {
        for (1..n - 1) |i| {
            try edges.append(a, edge(edges.items.len, 0, @intCast(i)));
            try edges.append(a, edge(edges.items.len, @intCast(i), n - 1));
        }
    } else {
        for (0..n - 1) |k| try edges.append(a, edge(edges.items.len, @intCast(k), @intCast(k + 1)));
        const max_edges = (n * 3) / 2 + 1;
        var attempts: u32 = 0;
        while (attempts < max_edges and edges.items.len < max_edges) : (attempts += 1) {
            const u = rng.uintLessThan(u32, n);
            const v = rng.uintLessThan(u32, n);
            if (u >= v or v == u + 1) continue;
            try edges.append(a, edge(edges.items.len, u, v));
        }
    }
    const nodes = try a.alloc(sem_graph.Node, n);
    for (nodes, 0..) |*node, i| {
        const label = try std.fmt.allocPrint(a, "N{d}", .{i});
        node.* = .{ .id = @intCast(i), .raw_id = label, .label = label, .shape = .rect, .classes = &.{}, .cluster = null };
    }
    return .{ .direction = .TD, .nodes = nodes, .edges = edges.items, .clusters = &.{}, .classes = &.{}, .arena = null };
}

fn edge(id: usize, from: u32, to: u32) sem_graph.Edge {
    return .{ .id = @intCast(id), .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

test "random diamonds and small DAGs lay out without validator violations" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = prng.random();
    for ([_]bool{ true, false }) |diamond| for (0..64) |i| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try genGraph(a, rng, diamond);
        const sketch = try layoutFlowchart(a, graph, .{});
        switch (try validateSketch(a, sketch)) {
            .ok => {},
            .failed => |violations| {
                std.debug.print("diamond={} case {d}: {d} violation(s), first [{s}] {s}\n", .{ diamond, i, violations.len, @tagName(violations[0].kind), violations[0].message });
                return error.SketchValidationFailed;
            },
        }
    };
}

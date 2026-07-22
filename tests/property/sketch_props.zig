//! Property tests for the Sketch IR. Generates small SemGraphs by hand
//! (the `gen.semGraph` helper is still a panicking stub at week 3), runs
//! `coords.layout`, and asserts `validate.validate` returns `.ok`.
//!
//! Each property uses the property runner's per-iteration arena to hold
//! the generated SemGraph storage. The property body creates its own
//! transient arena for layout+validate output, kept rooted at
//! `std.testing.allocator` so it lives independently of the runner arena.

const std = @import("std");
const v2 = @import("mermaid_v2");
const gen = @import("gen.zig");
const runner = @import("runner.zig");

// ----- Helpers --------------------------------------------------------------

/// Manually-built SemGraph plus borrowed slices, all allocated in the
/// iteration arena passed to the generator.
const BuiltGraph = struct {
    graph: v2.sem_graph.SemGraph,
};

fn ascii(allocator: std.mem.Allocator, i: u32) ![]const u8 {
    // Produce a short distinct identifier: "N0", "N1", ...
    return std.fmt.allocPrint(allocator, "N{d}", .{i});
}

fn buildNode(
    allocator: std.mem.Allocator,
    id: v2.NodeId,
    label: []const u8,
    shape: v2.sem_graph.NodeShape,
) !v2.sem_graph.Node {
    return .{
        .id = id,
        .raw_id = label,
        .label = label,
        .shape = shape,
        .classes = try allocator.alloc(v2.ClusterId, 0),
        .cluster = null,
    };
}

fn buildEdge(id: v2.EdgeId, from: v2.NodeId, to: v2.NodeId) v2.sem_graph.Edge {
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

/// Run layout+validate on a freshly built SemGraph and expect .ok. Uses
/// std.testing.allocator for the layout arena; we tear it down with the
/// reusable trick of catching the (typically arena-internal) leak via
/// the layout function allocating its own `ArenaAllocator` on this
/// allocator. The `coords.layout` implementation creates an arena and
/// never returns it, so we must wrap in our own outer arena to recover
/// memory.
fn layoutAndExpectOk(graph: v2.sem_graph.SemGraph) !void {
    var outer = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer outer.deinit();
    const a = outer.allocator();

    const sketch = v2.layoutFlowchart(a, graph, .{}) catch |err| {
        std.debug.print(
            "[sketch_props] layout failed: {s}\n",
            .{@errorName(err)},
        );
        return err;
    };

    const result = try v2.validateSketch(a, sketch);
    switch (result) {
        .ok => {},
        .failed => |violations| {
            std.debug.print(
                "[sketch_props] validation failed with {d} violation(s):\n",
                .{violations.len},
            );
            var shown: usize = 0;
            for (violations) |viol| {
                if (shown >= 3) break;
                std.debug.print(
                    "[sketch_props]   - [{s}] {s}\n",
                    .{ @tagName(viol.kind), viol.message },
                );
                shown += 1;
            }
            return error.SketchValidationFailed;
        },
    }
}

// ----- Generators -----------------------------------------------------------

fn genLinearChain(allocator: std.mem.Allocator, rng: std.Random, _: u32) !BuiltGraph {
    const n = gen.intRange(rng, u32, 2, 8);
    const nodes = try allocator.alloc(v2.sem_graph.Node, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const label = try ascii(allocator, i);
        nodes[i] = try buildNode(allocator, i, label, .rect);
    }
    const edges = try allocator.alloc(v2.sem_graph.Edge, n - 1);
    i = 0;
    while (i + 1 < n) : (i += 1) {
        edges[i] = buildEdge(i, i, i + 1);
    }
    return .{
        .graph = .{
            .direction = .TD,
            .nodes = nodes,
            .edges = edges,
            .clusters = try allocator.alloc(v2.sem_graph.Cluster, 0),
            .classes = try allocator.alloc(v2.sem_graph.ClassDef, 0),
            .arena = null,
        },
    };
}

fn genDiamond(allocator: std.mem.Allocator, rng: std.Random, _: u32) !BuiltGraph {
    // A -> {B0, B1, ..., Bk} -> C
    const k = gen.intRange(rng, u32, 2, 4);
    const total: u32 = 2 + k;
    const nodes = try allocator.alloc(v2.sem_graph.Node, total);

    // 0 = A (source), 1..k = middles, k+1 = C (sink)
    nodes[0] = try buildNode(allocator, 0, try ascii(allocator, 0), .rect);
    var i: u32 = 1;
    while (i <= k) : (i += 1) {
        nodes[i] = try buildNode(allocator, i, try ascii(allocator, i), .rect);
    }
    const sink_id: v2.NodeId = k + 1;
    nodes[sink_id] = try buildNode(allocator, sink_id, try ascii(allocator, sink_id), .rect);

    const edges = try allocator.alloc(v2.sem_graph.Edge, 2 * k);
    var e: u32 = 0;
    i = 1;
    while (i <= k) : (i += 1) {
        edges[e] = buildEdge(e, 0, i);
        e += 1;
        edges[e] = buildEdge(e, i, sink_id);
        e += 1;
    }
    return .{
        .graph = .{
            .direction = .TD,
            .nodes = nodes,
            .edges = edges,
            .clusters = try allocator.alloc(v2.sem_graph.Cluster, 0),
            .classes = try allocator.alloc(v2.sem_graph.ClassDef, 0),
            .arena = null,
        },
    };
}

fn genSmallDag(allocator: std.mem.Allocator, rng: std.Random, _: u32) !BuiltGraph {
    const n = gen.intRange(rng, u32, 2, 10);
    const nodes = try allocator.alloc(v2.sem_graph.Node, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        nodes[i] = try buildNode(allocator, i, try ascii(allocator, i), .rect);
    }
    // Build a DAG by only adding edges (u -> v) with u < v. Cap edges
    // around 1.5x node count.
    const max_edges = (n * 3) / 2 + 1;
    var edges_buf: std.ArrayList(v2.sem_graph.Edge) = .empty;
    defer edges_buf.deinit(allocator);

    // Ensure connectivity: chain 0->1->...->n-1.
    var k: u32 = 0;
    while (k + 1 < n) : (k += 1) {
        try edges_buf.append(allocator, buildEdge(@intCast(edges_buf.items.len), k, k + 1));
    }
    // Add extra forward edges sparsely.
    var attempts: u32 = 0;
    while (attempts < max_edges and edges_buf.items.len < max_edges) : (attempts += 1) {
        const u = gen.intRange(rng, u32, 0, n - 1);
        const v = gen.intRange(rng, u32, 0, n - 1);
        if (u >= v) continue;
        // skip if duplicate of chain
        if (v == u + 1) continue;
        try edges_buf.append(allocator, buildEdge(@intCast(edges_buf.items.len), u, v));
    }
    const edges = try edges_buf.toOwnedSlice(allocator);
    return .{
        .graph = .{
            .direction = .TD,
            .nodes = nodes,
            .edges = edges,
            .clusters = try allocator.alloc(v2.sem_graph.Cluster, 0),
            .classes = try allocator.alloc(v2.sem_graph.ClassDef, 0),
            .arena = null,
        },
    };
}

// ----- Property bodies ------------------------------------------------------

fn propValid(bg: BuiltGraph) anyerror!void {
    try layoutAndExpectOk(bg.graph);
}

// ----- Tests ----------------------------------------------------------------

test "property: linear chains lay out without validator violations" {
    try runner.forAll(BuiltGraph, genLinearChain, propValid, .{ .count = 64 });
}

test "property: diamonds lay out without validator violations" {
    try runner.forAll(BuiltGraph, genDiamond, propValid, .{ .count = 64 });
}

test "property: small random DAGs validate" {
    try runner.forAll(BuiltGraph, genSmallDag, propValid, .{ .count = 64 });
}

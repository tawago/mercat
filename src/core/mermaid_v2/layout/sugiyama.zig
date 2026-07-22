//! Sugiyama layered-graph layout for mermaid_v2 flowcharts: cycle removal
//! (DFS, back-edges reversed), layer assignment (Kahn / longest-path), and
//! virtual-node insertion so every LayerEdge spans exactly one layer.
//! Feeds `crossing.zig` (crossing reduction) and `layout.zig` (coordinate
//! assignment), which consume the `LayeredGraph` produced here.
//! Runs top-to-bottom internally (layer 0 = sources); for BT/RL the final
//! layers array is reversed so layout.zig treats layer 0 as top/left
//! uniformly. Imports: only `std` and `../sem_graph.zig` (lint-enforced).

const std = @import("std");
const sg = @import("../sem_graph.zig");

/// A node in the layered graph — either a real node from SemGraph or a
/// virtual node inserted to span an edge across multiple layers.
pub const LayerNode = union(enum) {
    real: sg.NodeId,
    virtual: struct {
        /// The original edge this virtual node belongs to.
        edge: sg.EdgeId,
        /// Index of this virtual node along the edge's chain
        /// (0 = first virtual after source, monotone increasing).
        index: u16,
    },
};

/// Stable hash key for a LayerNode (lets crossing.zig keep adjacency maps).
pub fn layerNodeKey(n: LayerNode) u64 {
    return switch (n) {
        .real => |id| (@as(u64, 0) << 63) | @as(u64, id),
        .virtual => |v| (@as(u64, 1) << 63) |
            (@as(u64, v.edge) << 16) |
            @as(u64, v.index),
    };
}

pub const LayerEdge = struct {
    from: u32, // index into the flat layer_nodes array
    to: u32,
    /// Original SemGraph edge id (one virtual chain shares the same edge_id).
    edge: sg.EdgeId,
    /// True if this edge was reversed during cycle removal.
    reversed: bool,
};

pub const LayeredGraph = struct {
    /// All nodes (real + virtual) in a single flat array, indexed by u32.
    nodes: []LayerNode,

    /// layers[i] is a list of node indices into `nodes`, in their current
    /// horizontal order. Crossing reduction mutates these in place.
    layers: [][]u32,

    /// Every edge in the layered graph, ordered by source layer ascending.
    edges: []LayerEdge,

    /// Set of original SemGraph edge ids that were reversed during cycle
    /// removal — layout.zig needs this to flip arrows back at paint time.
    reversed_edges: []sg.EdgeId,

    /// Reverse lookup: original NodeId → index in `nodes` (real nodes only).
    real_index: std.AutoHashMapUnmanaged(sg.NodeId, u32),

    arena: ?*std.heap.ArenaAllocator,

    pub fn deinit(self: *LayeredGraph, allocator: std.mem.Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
        self.* = undefined;
    }

    /// Number of layers.
    pub fn layerCount(self: LayeredGraph) usize {
        return self.layers.len;
    }

    /// Total node count (real + virtual).
    pub fn nodeCount(self: LayeredGraph) usize {
        return self.nodes.len;
    }
};

pub const LayoutError = error{
    OutOfMemory,
    EmptyGraph,
    InconsistentEdge,
};

/// Working edge during cycle removal — tracks reversal state.
const WorkEdge = struct {
    id: sg.EdgeId,
    from: sg.NodeId,
    to: sg.NodeId,
    reversed: bool,
};

const Color = enum(u2) { white, gray, black };

/// Run cycle removal + layer assignment + virtual-node insertion.
pub fn assignLayers(allocator: std.mem.Allocator, graph: sg.SemGraph) LayoutError!LayeredGraph {
    if (graph.nodes.len == 0) return error.EmptyGraph;

    // All allocations go through this arena, returned with the graph.
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();

    // Self-loops (from == to) are excluded from the layered graph. // guarded-by: sugiyama_test.zig "self-loop excluded from LayeredGraph but still drawn by routing.zig from graph.edges"
    var work_edges_list = std.ArrayListUnmanaged(WorkEdge).empty;
    {
        var valid = std.AutoHashMapUnmanaged(sg.NodeId, void).empty;
        for (graph.nodes) |n| try valid.put(a, n.id, {});
        for (graph.edges) |e| {
            if (!valid.contains(e.from) or !valid.contains(e.to)) {
                return error.InconsistentEdge;
            }
            if (e.from == e.to) continue;
            try work_edges_list.append(a, .{
                .id = e.id,
                .from = e.from,
                .to = e.to,
                .reversed = false,
            });
        }
    }
    const work_edges = work_edges_list.items;

    var color = std.AutoHashMapUnmanaged(sg.NodeId, Color).empty;
    for (graph.nodes) |n| try color.put(a, n.id, .white);

    var out_idx = std.AutoHashMapUnmanaged(sg.NodeId, std.ArrayListUnmanaged(u32)).empty;
    for (work_edges, 0..) |we, i| {
        const gop = try out_idx.getOrPut(a, we.from);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, @intCast(i));
    }

    var reversed_list = std.ArrayListUnmanaged(sg.EdgeId).empty;

    // Iterative DFS to avoid stack blow-up on large graphs. // guarded-by: sugiyama_test.zig "iterative cycle-removal DFS handles a very deep chain without stack overflow"
    var stack = std.ArrayListUnmanaged(struct { node: sg.NodeId, cursor: u32 }).empty;
    for (graph.nodes) |seed| {
        const c = color.get(seed.id).?;
        if (c != .white) continue;

        try color.put(a, seed.id, .gray);
        stack.clearRetainingCapacity();
        try stack.append(a, .{ .node = seed.id, .cursor = 0 });

        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            const edges_for_node: []const u32 = if (out_idx.get(top.node)) |list|
                list.items
            else
                &[_]u32{};

            if (top.cursor >= edges_for_node.len) {
                // Done with this node — mark black, pop.
                try color.put(a, top.node, .black);
                _ = stack.pop();
                continue;
            }

            const edge_index = edges_for_node[top.cursor];
            top.cursor += 1;
            const we = &work_edges[edge_index];
            if (we.reversed) continue;

            const target = we.to;
            const tc = color.get(target).?;
            switch (tc) {
                .gray => {
                    // Back edge → flip.
                    we.reversed = true;
                    try reversed_list.append(a, we.id);
                },
                .white => {
                    try color.put(a, target, .gray);
                    try stack.append(a, .{ .node = target, .cursor = 0 });
                },
                .black => {},
            }
        }
    }

    var in_degree = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty;
    for (graph.nodes) |n| try in_degree.put(a, n.id, 0);

    const EffEdge = struct {
        fn from(we: WorkEdge) sg.NodeId {
            return if (we.reversed) we.to else we.from;
        }
        fn to(we: WorkEdge) sg.NodeId {
            return if (we.reversed) we.from else we.to;
        }
    };

    for (work_edges) |we| {
        const t = EffEdge.to(we);
        const ptr = in_degree.getPtr(t).?;
        ptr.* += 1;
    }

    var layer_of = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty;
    for (graph.nodes) |n| try layer_of.put(a, n.id, 0);

    var queue = std.ArrayListUnmanaged(sg.NodeId).empty;
    for (graph.nodes) |n| {
        if (in_degree.get(n.id).? == 0) {
            try queue.append(a, n.id);
        }
    }

    // Outgoing adjacency keyed by effective source for the layering walk.
    var out_eff = std.AutoHashMapUnmanaged(sg.NodeId, std.ArrayListUnmanaged(u32)).empty;
    for (work_edges, 0..) |we, i| {
        const s = EffEdge.from(we);
        const gop = try out_eff.getOrPut(a, s);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, @intCast(i));
    }

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        const cur_layer = layer_of.get(cur).?;
        const outs: []const u32 = if (out_eff.get(cur)) |l| l.items else &[_]u32{};
        for (outs) |ei| {
            const we = work_edges[ei];
            const tgt = EffEdge.to(we);
            const new_layer = cur_layer + 1;
            const lp = layer_of.getPtr(tgt).?;
            if (lp.* < new_layer) lp.* = new_layer;

            const dp = in_degree.getPtr(tgt).?;
            if (dp.* > 0) {
                dp.* -= 1;
                if (dp.* == 0) try queue.append(a, tgt);
            }
        }
    }

    // Compute layer count.
    var max_layer: u32 = 0;
    for (graph.nodes) |n| {
        const l = layer_of.get(n.id).?;
        if (l > max_layer) max_layer = l;
    }
    const layer_count: u32 = max_layer + 1;

    // ---- Build flat nodes array + real_index, layer order = decl order
    var flat_nodes = std.ArrayListUnmanaged(LayerNode).empty;
    var real_index_map = std.AutoHashMapUnmanaged(sg.NodeId, u32).empty;

    // Bucket node ids per layer in declaration order.
    const buckets = try a.alloc(std.ArrayListUnmanaged(sg.NodeId), layer_count);
    for (buckets) |*b| b.* = .empty;
    for (graph.nodes) |n| {
        const l = layer_of.get(n.id).?;
        try buckets[l].append(a, n.id);
    }

    // Flatten real nodes, assigning indices as we go.
    var layers_out = try a.alloc([]u32, layer_count);
    for (buckets, 0..) |bucket, li| {
        var row = try a.alloc(u32, bucket.items.len);
        for (bucket.items, 0..) |nid, k| {
            const idx: u32 = @intCast(flat_nodes.items.len);
            try flat_nodes.append(a, .{ .real = nid });
            try real_index_map.put(a, nid, idx);
            row[k] = idx;
        }
        layers_out[li] = row;
    }

    // ---- Virtual-node insertion + per-layer LayerEdges ------------------
    // We rebuild `layers_out[i]` to include virtuals, in declaration order
    // of their generating edges.

    // Build per-layer lists as growable arrays first.
    var grow_layers = try a.alloc(std.ArrayListUnmanaged(u32), layer_count);
    for (grow_layers, 0..) |*gl, i| {
        gl.* = .empty;
        try gl.appendSlice(a, layers_out[i]);
    }

    var edges_out = std.ArrayListUnmanaged(LayerEdge).empty;

    for (work_edges) |we| {
        const src = EffEdge.from(we);
        const dst = EffEdge.to(we);
        const ls = layer_of.get(src).?;
        const ld = layer_of.get(dst).?;
        // If somehow ls >= ld (unassigned cycle remnant), force a one-step.
        const lo = if (ls < ld) ls else ld;
        const hi = if (ls < ld) ld else ls;
        const span = hi - lo;

        const src_idx = real_index_map.get(src).?;
        const dst_idx = real_index_map.get(dst).?;

        if (span <= 1) {
            try edges_out.append(a, .{
                .from = if (ls < ld) src_idx else dst_idx,
                .to = if (ls < ld) dst_idx else src_idx,
                .edge = we.id,
                .reversed = we.reversed,
            });
            continue;
        }

        // Insert (span - 1) virtual nodes on layers lo+1 .. hi-1.
        var prev_idx: u32 = if (ls < ld) src_idx else dst_idx;
        const end_idx: u32 = if (ls < ld) dst_idx else src_idx;
        var vi: u16 = 0;
        var layer_cursor: u32 = lo + 1;
        while (layer_cursor < hi) : (layer_cursor += 1) {
            const new_idx: u32 = @intCast(flat_nodes.items.len);
            try flat_nodes.append(a, .{ .virtual = .{ .edge = we.id, .index = vi } });
            try grow_layers[layer_cursor].append(a, new_idx);
            try edges_out.append(a, .{
                .from = prev_idx,
                .to = new_idx,
                .edge = we.id,
                .reversed = we.reversed,
            });
            prev_idx = new_idx;
            vi += 1;
        }
        try edges_out.append(a, .{
            .from = prev_idx,
            .to = end_idx,
            .edge = we.id,
            .reversed = we.reversed,
        });
    }

    // Finalise layers_out from grow_layers.
    for (grow_layers, 0..) |gl, i| {
        layers_out[i] = try a.dupe(u32, gl.items);
    }

    // ---- Sort edges by source layer ascending --------------------------
    // We need the layer of each flat node — recompute via lookup.
    const node_layer = try a.alloc(u32, flat_nodes.items.len);
    for (layers_out, 0..) |row, li| {
        for (row) |idx| node_layer[idx] = @intCast(li);
    }
    const SortCtx = struct {
        layers: []const u32,
        pub fn lessThan(ctx: @This(), x: LayerEdge, y: LayerEdge) bool {
            return ctx.layers[x.from] < ctx.layers[y.from];
        }
    };
    std.mem.sort(LayerEdge, edges_out.items, SortCtx{ .layers = node_layer }, SortCtx.lessThan);

    // ---- BT/RL: reverse the layers array so layer 0 is render-top -----
    switch (graph.direction) {
        .BT, .RL => {
            const n = layers_out.len;
            var i: usize = 0;
            while (i < n / 2) : (i += 1) {
                const tmp = layers_out[i];
                layers_out[i] = layers_out[n - 1 - i];
                layers_out[n - 1 - i] = tmp;
            }
        },
        .TD, .LR => {},
    }

    return LayeredGraph{
        .nodes = try a.dupe(LayerNode, flat_nodes.items),
        .layers = layers_out,
        .edges = try a.dupe(LayerEdge, edges_out.items),
        .reversed_edges = try a.dupe(sg.EdgeId, reversed_list.items),
        .real_index = real_index_map,
        .arena = arena,
    };
}

test {
    _ = @import("sugiyama_test.zig");
}

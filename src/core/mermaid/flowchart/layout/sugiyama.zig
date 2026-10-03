const std = @import("std");
const sg = @import("../sem_graph.zig");

pub const LayerNode = union(enum) {
    real: sg.NodeId,
    virtual: struct {
        edge: sg.EdgeId,
        index: u16,
    },
};

pub const LayerEdge = struct {
    from: u32,
    to: u32,
    edge: sg.EdgeId,
    reversed: bool,
};

pub const LayeredGraph = struct {
    nodes: []LayerNode,

    layers: [][]u32,

    edges: []LayerEdge,

    reversed_edges: []sg.EdgeId,

    real_index: std.AutoHashMapUnmanaged(sg.NodeId, u32),

    arena: ?*std.heap.ArenaAllocator,

    pub fn deinit(self: *LayeredGraph, allocator: std.mem.Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
        self.* = undefined;
    }
};

pub const LayoutError = error{
    OutOfMemory,
    EmptyGraph,
    InconsistentEdge,
};

const Link = struct {
    id: sg.EdgeId,
    from: u32,
    to: u32,
    reversed: bool = false,

    fn tail(l: Link) u32 {
        return if (l.reversed) l.to else l.from;
    }

    fn head(l: Link) u32 {
        return if (l.reversed) l.from else l.to;
    }
};

pub fn assignLayers(allocator: std.mem.Allocator, graph: sg.SemGraph) LayoutError!LayeredGraph {
    if (graph.nodes.len == 0) return error.EmptyGraph;

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    const a = arena.allocator();

    const n: u32 = @intCast(graph.nodes.len);
    var index: std.AutoHashMapUnmanaged(sg.NodeId, u32) = .empty;
    for (graph.nodes, 0..) |node, i| try index.put(a, node.id, @intCast(i));

    var links: std.ArrayListUnmanaged(Link) = .empty;
    for (graph.edges) |e| {
        const from = index.get(e.from) orelse return error.InconsistentEdge;
        const to = index.get(e.to) orelse return error.InconsistentEdge;
        if (from != to) try links.append(a, .{ .id = e.id, .from = from, .to = to });
    }

    const reversed = try breakCycles(a, n, links.items);
    const layer_of = try longestPaths(a, n, links.items);

    var depth: u32 = 0;
    for (layer_of) |l| depth = @max(depth, l + 1);
    const rows = try a.alloc(std.ArrayListUnmanaged(u32), depth);
    for (rows) |*row| row.* = .empty;
    for (layer_of, 0..) |l, v| try rows[l].append(a, @intCast(v));

    var nodes: std.ArrayListUnmanaged(LayerNode) = .empty;
    var node_layer: std.ArrayListUnmanaged(u32) = .empty;
    const flat = try a.alloc(u32, n);
    for (rows, 0..) |row, l| for (row.items) |*v| {
        const idx: u32 = @intCast(nodes.items.len);
        try nodes.append(a, .{ .real = graph.nodes[v.*].id });
        try node_layer.append(a, @intCast(l));
        flat[v.*] = idx;
        v.* = idx;
    };
    for (graph.nodes, flat) |node, idx| index.putAssumeCapacity(node.id, idx);

    var edges: std.ArrayListUnmanaged(LayerEdge) = .empty;
    for (links.items) |link| {
        const last = layer_of[link.head()];
        var prev = flat[link.tail()];
        var layer = layer_of[link.tail()] + 1;
        var step: u16 = 0;
        while (layer < last) : ({
            layer += 1;
            step += 1;
        }) {
            const v: u32 = @intCast(nodes.items.len);
            try nodes.append(a, .{ .virtual = .{ .edge = link.id, .index = step } });
            try node_layer.append(a, layer);
            try rows[layer].append(a, v);
            try edges.append(a, .{ .from = prev, .to = v, .edge = link.id, .reversed = link.reversed });
            prev = v;
        }
        try edges.append(a, .{ .from = prev, .to = flat[link.head()], .edge = link.id, .reversed = link.reversed });
    }
    std.mem.sort(LayerEdge, edges.items, node_layer.items, fromLayerFirst);

    const layers = try a.alloc([]u32, depth);
    for (rows, layers) |row, *out| out.* = row.items;
    if (graph.direction == .BT or graph.direction == .RL) std.mem.reverse([]u32, layers);

    return .{
        .nodes = nodes.items,
        .layers = layers,
        .edges = edges.items,
        .reversed_edges = reversed,
        .real_index = index,
        .arena = arena,
    };
}

fn fromLayerFirst(layer_of: []const u32, x: LayerEdge, y: LayerEdge) bool {
    return layer_of[x.from] < layer_of[y.from];
}

fn outLists(a: std.mem.Allocator, n: u32, links: []const Link) ![]const []const u32 {
    const lists = try a.alloc(std.ArrayListUnmanaged(u32), n);
    for (lists) |*list| list.* = .empty;
    for (links, 0..) |link, i| try lists[link.tail()].append(a, @intCast(i));
    const out = try a.alloc([]const u32, n);
    for (lists, out) |list, *o| o.* = list.items;
    return out;
}

fn breakCycles(a: std.mem.Allocator, n: u32, links: []Link) ![]sg.EdgeId {
    const out = try outLists(a, n, links);
    const State = enum { new, open, done };
    const state = try a.alloc(State, n);
    @memset(state, .new);

    const Frame = struct { node: u32, next: u32 = 0 };
    var stack: std.ArrayListUnmanaged(Frame) = .empty;
    var reversed: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    for (0..n) |root| {
        if (state[root] != .new) continue;
        state[root] = .open;
        try stack.append(a, .{ .node = @intCast(root) });
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next == out[top.node].len) {
                state[top.node] = .done;
                _ = stack.pop();
                continue;
            }
            const link = &links[out[top.node][top.next]];
            top.next += 1;
            switch (state[link.to]) {
                .open => {
                    link.reversed = true;
                    try reversed.append(a, link.id);
                },
                .new => {
                    state[link.to] = .open;
                    try stack.append(a, .{ .node = link.to });
                },
                .done => {},
            }
        }
    }
    return reversed.items;
}

fn longestPaths(a: std.mem.Allocator, n: u32, links: []const Link) ![]u32 {
    const out = try outLists(a, n, links);
    const indegree = try a.alloc(u32, n);
    @memset(indegree, 0);
    for (links) |link| indegree[link.head()] += 1;

    const layer = try a.alloc(u32, n);
    @memset(layer, 0);
    var queue: std.ArrayListUnmanaged(u32) = .empty;
    for (indegree, 0..) |d, v| if (d == 0) try queue.append(a, @intCast(v));
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const v = queue.items[i];
        for (out[v]) |li| {
            const t = links[li].head();
            layer[t] = @max(layer[t], layer[v] + 1);
            indegree[t] -= 1;
            if (indegree[t] == 0) try queue.append(a, t);
        }
    }
    return layer;
}

test {
    _ = @import("sugiyama_test.zig");
}

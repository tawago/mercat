const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const sugiyama = @import("sugiyama.zig");
const port_plan = @import("port_plan.zig");
const ports = @import("ports.zig");
const rt = @import("routing_terminal.zig");
const grid = @import("gap_rows_grid.zig");

pub const Super = struct { node: sg.NodeId, drawn: bool = true };

pub fn centerOf(comptime G: type, geom: []const G, idx: u32) i32 {
    const g = geom[idx];
    return g.x + @divTrunc(@as(i32, @intCast(g.w)), 2);
}

pub fn edgeById(graph: sg.SemGraph, id: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |e| if (e.id == id) return e;
    return null;
}

pub fn predictPorts(
    comptime G: type,
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const G,
    derived: []const ports.DerivedAttachment,
    bundles: pb.RealizedBundles,
    active: bool,
    rung: u8,
) error{OutOfMemory}!port_plan.Plan {
    const top_of = try a.alloc(i32, lg.nodes.len);
    @memset(top_of, 0);
    var top: i32 = 0;
    for (lg.layers) |row| {
        var tallest: u32 = 0;
        for (row) |idx| {
            top_of[idx] = top;
            tallest = @max(tallest, geom[idx].h);
        }
        top += @as(i32, @intCast(tallest)) + 1;
    }
    const transposed = graph.direction == .LR or graph.direction == .RL;
    var placements: std.ArrayListUnmanaged(sketch.NodePlacement) = .empty;
    for (lg.nodes, 0..) |ln, i| switch (ln) {
        .real => |nid| try placements.append(a, .{
            .id = nid,
            .rect = if (transposed)
                .{ .x = top_of[i], .y = geom[i].x, .w = geom[i].h, .h = geom[i].w }
            else
                .{ .x = geom[i].x, .y = top_of[i], .w = geom[i].w, .h = geom[i].h },
            .shape = .rect,
            .lines = &.{},
            .cluster_id = null,
        }),
        .virtual => {},
    };
    if (placements.items.len == 0) return .{};
    return if (active)
        port_plan.allocate(a, graph, placements.items, derived, bundles, rung)
    else
        port_plan.midpoint(a, graph, placements.items);
}

pub const Census = struct {
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    plan: port_plan.Plan,
    node_layer: []const u32,
    idx_of: std.AutoHashMapUnmanaged(sg.NodeId, u32),
    sub: grid.SubRows,
    supers: []const Super,
    departures: []const sg.NodeId,
    flow_down: bool,
    ngaps: usize,

    pub fn layerOfNode(self: Census, id: sg.NodeId) ?u32 {
        const idx = self.idx_of.get(id) orelse return null;
        return self.node_layer[idx];
    }

    pub fn isSuper(self: Census, id: sg.NodeId) bool {
        for (self.supers) |s| if (s.node == id) return true;
        return false;
    }

    pub fn isDrawnSuper(self: Census, id: sg.NodeId) bool {
        for (self.supers) |s| if (s.node == id) return s.drawn;
        return false;
    }

    pub fn isPlacement(self: Census, e: sg.Edge) bool {
        return self.isSuper(e.from) or self.isSuper(e.to);
    }

    pub fn isReversed(self: Census, id: sg.EdgeId) bool {
        return rt.isReversed(self.lg, id);
    }

    pub fn gapOf(self: Census, sl: u32, tl: u32) ?u32 {
        if (self.flow_down) {
            if (tl <= sl or tl - 1 >= self.ngaps) return null;
            return tl - 1;
        }
        if (tl >= sl or tl >= self.ngaps) return null;
        return tl;
    }

    pub fn gapBelow(self: Census, sl: u32) ?u32 {
        if (self.flow_down) return if (sl < self.ngaps) sl else null;
        return if (sl > 0 and sl - 1 < self.ngaps) sl - 1 else null;
    }

    pub fn layerDistance(self: Census, sl: u32, tl: u32) u32 {
        _ = self;
        return if (tl > sl) tl - sl else sl - tl;
    }

    pub fn portCol(self: Census, comptime G: type, geom: []const G, e: sg.Edge, end: pb.EndpointSide) i32 {
        const node = if (end == .source_exit) e.from else e.to;
        const idx = self.idx_of.get(node) orelse return 0;
        const g = geom[idx];
        const offset: i32 = if (self.plan.forEdge(e.id)) |ep|
            @intCast(if (end == .source_exit) ep.source.offset else ep.target.offset)
        else
            @intCast(g.w / 2);
        return g.x + offset;
    }
};

pub const Group = struct {
    key: u32,
    private: bool,
    gap: u32,
    comb: bool = false,
    lo: i32,
    hi: i32,
    labeled: bool = false,
    decorated_source: bool = false,
    lift: u32 = 0,
    edges: std.ArrayListUnmanaged(sg.EdgeId) = .empty,
    stems: std.ArrayListUnmanaged(i32) = .empty,
    taps: std.ArrayListUnmanaged(i32) = .empty,
    label_widths: std.ArrayListUnmanaged(u32) = .empty,
};

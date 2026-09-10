//! gap_rows_census.zig — what the row ledger reads before it claims: the
//! ports the allocation will hand out, and the piece's layers, stand-ins,
//! departures and flow as one `Census`.
//!
//! Imports (layout zone): std + sem_graph + sketch + base/ledger + siblings.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const sugiyama = @import("sugiyama.zig");
const port_plan = @import("port_plan.zig");
const ports = @import("ports.zig");
const rt = @import("routing_terminal.zig");
const grid = @import("gap_rows_grid.zig");

/// A cluster stand-in of an outer piece: `drawn` when its frame is painted
/// (a bridge into it jogs on the arrival row), false for a packing cluster.
pub const Super = struct { node: sg.NodeId, drawn: bool = true };

pub fn centerOf(comptime G: type, geom: []const G, idx: u32) i32 {
    const g = geom[idx];
    return g.x + @divTrunc(@as(i32, @intCast(g.w)), 2);
}

pub fn edgeById(graph: sg.SemGraph, id: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |e| if (e.id == id) return e;
    return null;
}

/// The ports a layout will allocate, read before rows are placed. Each
/// node is handed to the allocator in the frame it will occupy after
/// `mirror.applyDirection` (LR/RL transpose the rect), so every face —
/// the forward faces the ledger reads and the side faces back edges and
/// self-loops demand — has its final length. The layer-axis coordinate
/// is not assigned yet; a layer's stand-in keeps the order the real
/// centres will have, which is all the allocation reads from it.
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
    /// The nodes a cross-border edge departs toward the flow.
    departures: []const sg.NodeId,
    /// Layer indices grow toward the targets (every direction but RL).
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

    /// A stand-in whose frame is painted.
    pub fn isDrawnSuper(self: Census, id: sg.NodeId) bool {
        for (self.supers) |s| if (s.node == id) return s.drawn;
        return false;
    }

    /// A cross-border edge to a cluster stand-in: the bridges paint it.
    pub fn isPlacement(self: Census, e: sg.Edge) bool {
        return self.isSuper(e.from) or self.isSuper(e.to);
    }

    pub fn isReversed(self: Census, id: sg.EdgeId) bool {
        return rt.isReversed(self.lg, id);
    }

    /// The gap whose wall is the target layer's near edge, for a forward
    /// edge from layer `sl` to layer `tl`; null when the edge does not
    /// advance.
    pub fn gapOf(self: Census, sl: u32, tl: u32) ?u32 {
        if (self.flow_down) {
            if (tl <= sl or tl - 1 >= self.ngaps) return null;
            return tl - 1;
        }
        if (tl >= sl or tl >= self.ngaps) return null;
        return tl;
    }

    /// The gap under layer `sl`'s departure cells.
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
    /// Drawn per peer beside an eligible rail: never the rail's run.
    private: bool,
    /// The gap the run lands in: the pivot's for a rail, the one above the peer's sub-row per peer.
    gap: u32,
    /// A gridded fan's run to a stacked sub-row: the grid's comb row.
    comb: bool = false,
    lo: i32,
    hi: i32,
    labeled: bool = false,
    /// A decorated source keeps its departure cell straight: the run needs the row below it.
    decorated_source: bool = false,
    /// Rows the run is lifted above a cluster frame it would otherwise ride.
    lift: u32 = 0,
    edges: std.ArrayListUnmanaged(sg.EdgeId) = .empty,
    stems: std.ArrayListUnmanaged(i32) = .empty,
    taps: std.ArrayListUnmanaged(i32) = .empty,
    /// Parallel to `taps`: the display width of the member's label, 0 when it has none.
    label_widths: std.ArrayListUnmanaged(u32) = .empty,
};


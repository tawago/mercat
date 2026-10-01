const std = @import("std");
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const sugiyama = @import("sugiyama.zig");
const port_plan = @import("port_plan.zig");
const rt = @import("routing_terminal.zig");
const pack_mod = @import("gap_rows_pack.zig");
const NodeGeom = @import("node_geom.zig").NodeGeom;

const MARGIN_BOUND: i32 = 24;

pub const Super = struct { node: sg.NodeId, drawn: bool = true };

pub const Census = struct {
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
    plan: port_plan.Plan,
    sub_gaps: []pack_mod.SubGap,
    supers: []const Super,
    departures: []const sg.NodeId,
    flow_down: bool,
    ngaps: usize,

    pub fn init(
        a: std.mem.Allocator,
        graph: sg.SemGraph,
        lg: sugiyama.LayeredGraph,
        geom: []const NodeGeom,
        plan: port_plan.Plan,
        supers: []const Super,
        departures: []const sg.NodeId,
        ngaps: usize,
    ) error{OutOfMemory}!Census {
        return .{
            .graph = graph,
            .lg = lg,
            .geom = geom,
            .plan = plan,
            .sub_gaps = try stackedGaps(a, lg, geom, @intCast(ngaps)),
            .supers = supers,
            .departures = departures,
            .flow_down = graph.direction != .RL,
            .ngaps = ngaps,
        };
    }

    pub fn layerOfNode(self: Census, id: sg.NodeId) ?u32 {
        const idx = self.lg.real_index.get(id) orelse return null;
        return self.geom[idx].layer;
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

    pub fn portCol(self: Census, e: sg.Edge, end: pb.EndpointSide) i32 {
        const node = if (end == .source_exit) e.from else e.to;
        const idx = self.lg.real_index.get(node) orelse return 0;
        const g = self.geom[idx];
        const offset: i32 = if (self.plan.forEdge(e.id)) |ep|
            @intCast(if (end == .source_exit) ep.source.offset else ep.target.offset)
        else
            @intCast(g.w / 2);
        return g.x + offset;
    }

    pub fn gapAbove(self: Census, idx: u32) ?u32 {
        const layer = self.geom[idx].layer;
        if (self.geom[idx].y == 0) return if (layer == 0) null else layer - 1;
        for (self.sub_gaps) |s| if (s.layer == layer and s.top == self.geom[idx].y) return s.gap;
        return null;
    }

    pub fn stackedObstacle(self: Census, from: u32, to: u32, col: i32) ?u32 {
        const geom = self.geom;
        var best: ?u32 = null;
        for (self.lg.layers[self.geom[from].layer]) |idx| {
            if (idx == from or self.lg.nodes[idx] != .real or geom[idx].y <= geom[from].y) continue;
            if (!coversColumn(geom[idx], col)) continue;
            if (best == null or geom[idx].y < geom[best.?].y) best = idx;
        }
        if (best != null) return best;
        for (self.lg.layers[self.geom[to].layer]) |idx| {
            if (idx == to or self.lg.nodes[idx] != .real or geom[idx].y >= geom[to].y) continue;
            if (!coversColumn(geom[idx], col)) continue;
            if (best == null or geom[idx].y < geom[best.?].y) best = idx;
        }
        return best;
    }

    pub fn corridorColumn(self: Census, from: u32, to: u32, want: i32, margin: bool) i32 {
        var plain: ?i32 = null;
        var delta: i32 = 0;
        while (delta < 4096) : (delta += 1) {
            for ([2]i32{ want - delta, want + delta }) |c| {
                const center = self.columnFree(from, to, c);
                if (margin and delta < MARGIN_BOUND) {
                    if (center and self.columnFree(from, to, c - 1) and self.columnFree(from, to, c + 1)) return c;
                    if (center and plain == null) plain = c;
                } else if (center) return plain orelse c;
                if (delta == 0) break;
            }
        }
        return plain orelse want;
    }

    fn columnFree(self: Census, from: u32, to: u32, col: i32) bool {
        const geom = self.geom;
        for (self.lg.layers[self.geom[from].layer]) |idx| {
            if (idx == from or self.lg.nodes[idx] != .real or geom[idx].y <= geom[from].y) continue;
            if (coversColumn(geom[idx], col)) return false;
        }
        for (self.lg.layers[self.geom[to].layer]) |idx| {
            if (idx == to or self.lg.nodes[idx] != .real or geom[idx].y >= geom[to].y) continue;
            if (coversColumn(geom[idx], col)) return false;
        }
        return true;
    }
};

fn coversColumn(g: NodeGeom, col: i32) bool {
    return g.x <= col and col < g.right();
}

fn stackedGaps(a: std.mem.Allocator, lg: sugiyama.LayeredGraph, geom: []const NodeGeom, real: u32) error{OutOfMemory}![]pack_mod.SubGap {
    var gaps: std.ArrayListUnmanaged(pack_mod.SubGap) = .empty;
    for (lg.layers, 0..) |row, li| {
        var tops: std.ArrayListUnmanaged(i32) = .empty;
        for (row) |idx| {
            if (lg.nodes[idx] != .real) continue;
            if (std.mem.indexOfScalar(i32, tops.items, geom[idx].y) == null) try tops.append(a, geom[idx].y);
        }
        std.mem.sort(i32, tops.items, {}, std.sort.asc(i32));
        for (tops.items[1..], 1..) |top, k| {
            var far: i32 = std.math.minInt(i32);
            for (row) |idx| {
                if (lg.nodes[idx] != .real or geom[idx].y != tops.items[k - 1]) continue;
                far = @max(far, geom[idx].y + @as(i32, @intCast(geom[idx].h)));
            }
            if (far >= top) continue;
            try gaps.append(a, .{ .gap = real + @as(u32, @intCast(gaps.items.len)), .layer = @intCast(li), .top = top, .far = far, .base = @intCast(top - far) });
        }
    }
    return gaps.toOwnedSlice(a);
}

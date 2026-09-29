const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const rp = @import("routing_polyline.zig");

pub fn findGraphEdge(graph: sg.SemGraph, id: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |e| {
        if (e.id == id) return e;
    }
    return null;
}

pub fn findPlacement(
    placements: []const sketch.NodePlacement,
    id: sg.NodeId,
) sketch.NodePlacement {
    for (placements) |p| {
        if (p.id == id) return p;
    }
    return placements[0];
}

fn nodeCluster(graph: sg.SemGraph, nid: sg.NodeId) ?sg.ClusterId {
    for (graph.nodes) |n| {
        if (n.id == nid) return n.cluster;
    }
    return null;
}

fn clusterAncestorOrSelf(graph: sg.SemGraph, anc: sg.ClusterId, desc: sg.ClusterId) bool {
    var cur: ?sg.ClusterId = desc;
    while (cur) |id| {
        if (id == anc) return true;
        var found: ?sg.Cluster = null;
        for (graph.clusters) |c| {
            if (c.id == id) {
                found = c;
                break;
            }
        }
        cur = if (found) |c| c.parent else null;
    }
    return false;
}

/// @guarded-by: routing_test.zig "rail pre-pass and forced per-peer path lift the same fan-OUT geometry to the same rail row"
pub fn fanRailLift(graph: sg.SemGraph, from: sg.NodeId, to: sg.NodeId) u32 {
    return if (crossesIntoCluster(graph, from, to)) 1 else 0;
}

/// @guarded-by: routing_test.zig "fan-OUT per-peer rail does not lift when the source is a member of (or ancestor of) the target's cluster"
fn crossesIntoCluster(graph: sg.SemGraph, from: sg.NodeId, to: sg.NodeId) bool {
    const dst_cluster = nodeCluster(graph, to) orelse return false;
    const src_cluster = nodeCluster(graph, from);
    if (src_cluster) |sc| {
        if (clusterAncestorOrSelf(graph, dst_cluster, sc)) return false;
    }
    return true;
}

pub fn isReversed(lg: sugiyama.LayeredGraph, eid: sg.EdgeId) bool {
    for (lg.reversed_edges) |r| {
        if (r == eid) return true;
    }
    return false;
}

pub fn collectVirtuals(
    a: std.mem.Allocator,
    lg: sugiyama.LayeredGraph,
    eid: sg.EdgeId,
) error{OutOfMemory}![]const u32 {
    var list: std.ArrayListUnmanaged(u32) = .empty;
    for (lg.nodes, 0..) |n, i| {
        switch (n) {
            .virtual => |v| {
                if (v.edge == eid) try list.append(a, @intCast(i));
            },
            .real => {},
        }
    }
    const Ctx = struct {
        nodes: []const sugiyama.LayerNode,
        fn lt(ctx: @This(), x: u32, y: u32) bool {
            const ix = switch (ctx.nodes[x]) {
                .virtual => |v| v.index,
                .real => 0,
            };
            const iy = switch (ctx.nodes[y]) {
                .virtual => |v| v.index,
                .real => 0,
            };
            return ix < iy;
        }
    };
    std.mem.sort(u32, list.items, Ctx{ .nodes = lg.nodes }, Ctx.lt);
    return try list.toOwnedSlice(a);
}

pub fn mapArrow(e: sg.ArrowEnd) sketch.ArrowKind {
    return switch (e) {
        .none => .none,
        .open => .open,
        .filled => .filled,
        .circle => .circle,
        .cross => .cross,
    };
}

/// @guarded-by: routing_terminal_test.zig "satisfyApproach grows a corner-fed len-2 final into a straight base approach"
pub fn satisfyApproach(
    a: std.mem.Allocator,
    poly: []sketch.Point,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]sketch.Point {
    const fed = rp.detectCornerFedTerminal(poly) orelse return poly;
    const bi = fed.bi;
    if (bi < 2) return poly;
    const b = fed.b;
    const p = fed.p;
    const q = poly[bi - 2];
    const lx = fed.lx;
    const ly = fed.ly;
    if (lx != 0 and ly != 0) return poly;
    if (@as(i32, @intCast(@abs(lx))) + @as(i32, @intCast(@abs(ly))) != 2) return poly;
    const ux: i32 = if (lx > 0) 1 else if (lx < 0) -1 else 0;
    const uy: i32 = if (ly > 0) 1 else if (ly < 0) -1 else 0;
    const base_horizontal = (ux != 0);
    const qp_perp: i32 = if (base_horizontal) (q.y - p.y) else (q.x - p.x);
    if (qp_perp != 0) return poly;
    const q_base: i32 = if (base_horizontal) q.x else q.y;
    const p_base: i32 = if (base_horizontal) p.x else p.y;
    const np_base: i32 = p_base - (if (base_horizontal) ux else uy);
    if (np_base == q_base or (p_base > q_base) != (np_base > q_base)) return poly;
    const nb = sketch.Point{ .x = b.x - ux, .y = b.y - uy };
    const np = sketch.Point{ .x = p.x - ux, .y = p.y - uy };
    var lo_axis: i32 = if (base_horizontal) poly[0].x else poly[0].y;
    var hi_axis: i32 = lo_axis;
    for (poly) |pt| {
        const v = if (base_horizontal) pt.x else pt.y;
        lo_axis = @min(lo_axis, v);
        hi_axis = @max(hi_axis, v);
    }
    const nb_axis: i32 = if (base_horizontal) nb.x else nb.y;
    if (nb_axis < lo_axis or nb_axis > hi_axis) return poly;
    const run_horizontal = (np.y == nb.y);
    const cross: i32 = if (run_horizontal) np.y else np.x;
    const lo: i32 = if (run_horizontal) @min(np.x, nb.x) else @min(np.y, nb.y);
    const hi: i32 = if (run_horizontal) @max(np.x, nb.x) else @max(np.y, nb.y);
    for (placements) |pl| {
        if (sketch.lineTouchesRect(run_horizontal, cross, lo, hi, pl.rect)) return poly;
    }
    var grown: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try grown.appendSlice(a, poly);
    grown.items[bi] = nb;
    grown.items[bi - 1] = np;
    return try grown.toOwnedSlice(a);
}

/// @guarded-by: routing_terminal_test.zig "terminalsStraight refuses a turn inside a decorated terminal cell at either end and admits one two cells out"
pub fn terminalsStraight(poly: []const sketch.Point, rule: rp.Straight) bool {
    if (rule.from and distanceToFirstTurn(poly, false) < 2) return false;
    if (rule.to and distanceToFirstTurn(poly, true) < 2) return false;
    return true;
}

fn distanceToFirstTurn(poly: []const sketch.Point, from_end: bool) i32 {
    var heading: ?[2]i32 = null;
    var walked: i32 = 0;
    var i: usize = 0;
    while (i + 1 < poly.len) : (i += 1) {
        const p = if (from_end) poly[poly.len - 1 - i] else poly[i];
        const q = if (from_end) poly[poly.len - 2 - i] else poly[i + 1];
        const step = [2]i32{ std.math.sign(q.x - p.x), std.math.sign(q.y - p.y) };
        if (step[0] == 0 and step[1] == 0) continue;
        if (heading) |h| {
            if (h[0] != step[0] or h[1] != step[1]) return walked;
        } else heading = step;
        walked += rp.absDiff(q.x, p.x) + rp.absDiff(q.y, p.y);
    }
    return walked;
}

test {
    _ = @import("routing_terminal_test.zig");
}

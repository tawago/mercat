const std = @import("std");
const prim = @import("prim");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");
const fan_rail = @import("fan_rail.zig");

const NodeGeom = routing.NodeGeom;

fn mapDir(d: ?sg.Direction) ?sketch.Direction {
    return switch (d orelse return null) {
        .TD => .TD,
        .BT => .BT,
        .LR => .LR,
        .RL => .RL,
    };
}

const H_INSET: u32 = 3;
const V_INSET: u32 = 1;

pub fn buildClusters(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    placements: []const sketch.NodePlacement,
    pad: u32,
) error{OutOfMemory}![]sketch.ClusterFrame {
    _ = pad;

    const order = try a.alloc(u32, graph.clusters.len);
    defer a.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    const Ctx = struct {
        graph: sg.SemGraph,
        fn lessThan(self: @This(), x: u32, y: u32) bool {
            return clusterDepth(self.graph, self.graph.clusters[x]) >
                clusterDepth(self.graph, self.graph.clusters[y]);
        }
    };
    std.mem.sort(u32, order, Ctx{ .graph = graph }, Ctx.lessThan);

    // @guarded-by: layout/clusters_test.zig "buildClusters: outer cluster bbox unions the already-expanded inner rect, not the raw inner member bbox"
    var rects = try a.alloc(?sketch.Rect, graph.clusters.len);
    defer a.free(rects);
    for (rects) |*r| r.* = null;

    for (order) |idx| {
        const c = graph.clusters[idx];
        rects[idx] = clusterBbox(graph, c, placements, rects);
    }

    // @guarded-by: layout/clusters_test.zig "buildClusters: emitted ClusterFrame order matches input graph.clusters order, not the depth-sorted processing order"
    var out: std.ArrayListUnmanaged(sketch.ClusterFrame) = .empty;
    for (graph.clusters, 0..) |c, i| {
        const r = rects[i] orelse continue;
        try out.append(a, .{
            .id = c.id,
            .rect = r,
            .parent_id = c.parent,
            .label = c.label,
            .depth = clusterDepth(graph, c),
            .direction = mapDir(c.direction),
        });
    }
    return try out.toOwnedSlice(a);
}

fn findPlacement(
    placements: []const sketch.NodePlacement,
    id: sg.NodeId,
) sketch.NodePlacement {
    for (placements) |p| {
        if (p.id == id) return p;
    }
    return placements[0];
}

fn indexOfCluster(graph: sg.SemGraph, id: sg.ClusterId) ?usize {
    for (graph.clusters, 0..) |c, i| {
        if (c.id == id) return i;
    }
    return null;
}

fn clusterBbox(
    graph: sg.SemGraph,
    c: sg.Cluster,
    placements: []const sketch.NodePlacement,
    rects: []const ?sketch.Rect,
) ?sketch.Rect {
    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    var seen = false;

    for (c.members) |nid| {
        const p = findPlacement(placements, nid);
        if (p.rect.x < min_x) min_x = p.rect.x;
        if (p.rect.y < min_y) min_y = p.rect.y;
        if (p.rect.right() > max_x) max_x = p.rect.right();
        if (p.rect.bottom() > max_y) max_y = p.rect.bottom();
        seen = true;
    }
    for (c.sub_clusters) |sid| {
        const sub_idx = indexOfCluster(graph, sid) orelse continue;
        const sb = rects[sub_idx] orelse continue;
        if (sb.x < min_x) min_x = sb.x;
        if (sb.y < min_y) min_y = sb.y;
        if (sb.right() > max_x) max_x = sb.right();
        if (sb.bottom() > max_y) max_y = sb.bottom();
        seen = true;
    }
    if (!seen) return null;

    const dx: i32 = @intCast(H_INSET + 1);
    const dy: i32 = @intCast(V_INSET + 1);
    return .{
        .x = min_x - dx,
        .y = min_y - dy,
        .w = @intCast(max_x - min_x + 2 * dx),
        .h = @intCast(max_y - min_y + 2 * dy),
    };
}

fn findCluster(graph: sg.SemGraph, id: sg.ClusterId) ?sg.Cluster {
    for (graph.clusters) |c| {
        if (c.id == id) return c;
    }
    return null;
}

fn clusterDepth(graph: sg.SemGraph, c: sg.Cluster) u8 {
    var depth: u8 = 0;
    var cur = c.parent;
    while (cur) |pid| : (depth += 1) {
        const parent = findCluster(graph, pid) orelse break;
        cur = parent.parent;
    }
    return depth;
}

pub fn computeBbox(
    placements: []sketch.NodePlacement,
    edges: []sketch.EdgePath,
    clusters: []sketch.ClusterFrame,
    polylines: [][]sketch.Point,
    rails: []fan_rail.Built,
    pressure: bool,
    max_width: u32,
) sketch.Rect {
    if (placements.len == 0) {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }
    var min_x: i32 = placements[0].rect.x;
    var min_y: i32 = placements[0].rect.y;
    var max_x: i32 = placements[0].rect.right();
    var max_y: i32 = placements[0].rect.bottom();
    for (placements) |p| {
        if (p.rect.x < min_x) min_x = p.rect.x;
        if (p.rect.y < min_y) min_y = p.rect.y;
        if (p.rect.right() > max_x) max_x = p.rect.right();
        if (p.rect.bottom() > max_y) max_y = p.rect.bottom();
    }
    for (clusters) |c| {
        if (c.rect.x < min_x) min_x = c.rect.x;
        if (c.rect.y < min_y) min_y = c.rect.y;
        if (c.rect.right() > max_x) max_x = c.rect.right();
        if (c.rect.bottom() > max_y) max_y = c.rect.bottom();
    }
    // @guarded-by: layout/clusters_test.zig "computeBbox: back-edge rail label relocation depends on the diagram's full right extent, not just its own edge"
    for (edges) |e| {
        for (e.polyline) |pt| {
            // @guarded-by: layout/clusters_test.zig "computeBbox: a self-loop detour point at the diagram's extreme corner extends the exclusive bbox by exactly +1"
            if (pt.x < min_x) min_x = pt.x;
            if (pt.y < min_y) min_y = pt.y;
            if (pt.x + 1 > max_x) max_x = pt.x + 1;
            if (pt.y + 1 > max_y) max_y = pt.y + 1;
        }
        const relocatable = pressure and e.role == .back_edge;
        if (relocatable) continue;
        if (labelFootprint(e, false, max_width, 0)) |fp| {
            if (fp.lx < min_x) min_x = fp.lx;
            if (fp.ly < min_y) min_y = fp.ly;
            if (fp.lend_x > max_x) max_x = fp.lend_x;
            if (fp.ly + 1 > max_y) max_y = fp.ly + 1;
        }
    }
    // @guarded-by: layout/clusters_test.zig "computeBbox: rail tap label reservation matches Rail.tapLabelSeg + prim.edgeLabelAnchor"
    for (rails) |b| {
        const rail = b.rail;
        for (rail.stem) |pt| extendPoint(&min_x, &min_y, &max_x, &max_y, pt);
        extendPoint(&min_x, &min_y, &max_x, &max_y, rail.crossbar[0]);
        extendPoint(&min_x, &min_y, &max_x, &max_y, rail.crossbar[1]);
        for (rail.taps) |tap| {
            extendPoint(&min_x, &min_y, &max_x, &max_y, tap.at);
            extendPoint(&min_x, &min_y, &max_x, &max_y, tap.landing);
            const lbl = tap.label orelse continue;
            if (lbl.len == 0) continue;
            const seg = rail.tapLabelSeg(tap);
            const lbl_w = prim.displayWidth(lbl);
            const anchor = prim.edgeLabelAnchor(seg[0].x, seg[0].y, seg[1].x, seg[1].y, lbl_w, .{});
            if (anchor.x < min_x) min_x = anchor.x;
            if (anchor.y < min_y) min_y = anchor.y;
            if (anchor.x + @as(i32, @intCast(lbl_w)) > max_x) max_x = anchor.x + @as(i32, @intCast(lbl_w));
            if (anchor.y + 1 > max_y) max_y = anchor.y + 1;
        }
    }

    // @guarded-by: layout/clusters_test.zig "computeBbox: back-edge rail lever leaves the label right when the right placement already fits the budget"
    for (edges) |*e| {
        if (!(pressure and e.role == .back_edge)) continue;
        if (labelFootprint(e.*, true, max_width, max_x)) |fp| {
            e.label_left_of_run = fp.left_of_run;
            if (fp.lx < min_x) min_x = fp.lx;
            if (fp.ly < min_y) min_y = fp.ly;
            if (fp.lend_x > max_x) max_x = fp.lend_x;
            if (fp.ly + 1 > max_y) max_y = fp.ly + 1;
        }
    }

    const dx: i32 = -min_x;
    const dy: i32 = -min_y;
    if (dx != 0 or dy != 0) {
        shiftAll(placements, edges, clusters, polylines, rails, dx, dy);
    }

    return .{
        .x = 0,
        .y = 0,
        .w = @intCast(max_x - min_x),
        .h = @intCast(max_y - min_y),
    };
}

fn shiftAll(
    placements: []sketch.NodePlacement,
    edges: []sketch.EdgePath,
    clusters: []sketch.ClusterFrame,
    polylines: [][]sketch.Point,
    rails: []fan_rail.Built,
    dx: i32,
    dy: i32,
) void {
    _ = edges;
    for (placements) |*p| {
        p.rect.x += dx;
        p.rect.y += dy;
    }
    for (clusters) |*c| {
        c.rect.x += dx;
        c.rect.y += dy;
    }
    for (polylines) |pts| {
        for (pts) |*pt| {
            pt.x += dx;
            pt.y += dy;
        }
    }
    // @guarded-by: layout/clusters_test.zig "computeBbox: the shift pass updates both the Built.taps view and the aliased Rail.taps slice"
    for (rails) |*b| {
        for (&b.rail.crossbar) |*pt| {
            pt.x += dx;
            pt.y += dy;
        }
        for (b.taps) |*tap| {
            tap.at.x += dx;
            tap.at.y += dy;
            tap.landing.x += dx;
            tap.landing.y += dy;
        }
    }
}

fn extendPoint(min_x: *i32, min_y: *i32, max_x: *i32, max_y: *i32, pt: sketch.Point) void {
    if (pt.x < min_x.*) min_x.* = pt.x;
    if (pt.y < min_y.*) min_y.* = pt.y;
    if (pt.x + 1 > max_x.*) max_x.* = pt.x + 1;
    if (pt.y + 1 > max_y.*) max_y.* = pt.y + 1;
}

const LabelFootprint = struct {
    lx: i32,
    ly: i32,
    lend_x: i32,
    left_of_run: bool,
};

fn labelFootprint(
    e: sketch.EdgePath,
    back_ctx: bool,
    max_width: u32,
    others_right: i32,
) ?LabelFootprint {
    const lbl = e.label orelse return null;
    if (lbl.len == 0 or e.polyline.len < 2) return null;
    const seg = pickMidSegmentBbox(e.polyline) orelse return null;
    const lbl_w = prim.displayWidth(lbl);
    const ctx: prim.BackRailCtx = if (back_ctx) .{
        .active = true,
        .max_width = max_width,
        .others_right = others_right,
    } else .{};
    const anchor = prim.edgeLabelAnchor(seg.a.x, seg.a.y, seg.b.x, seg.b.y, lbl_w, ctx);
    const mid_x: i32 = @divTrunc(seg.a.x + seg.b.x, 2);
    return .{
        .lx = anchor.x,
        .ly = anchor.y,
        .lend_x = anchor.x + @as(i32, @intCast(lbl_w)),
        // @guarded-by: layout/clusters_test.zig "computeBbox: label_left_of_run is false exactly at prim.edgeLabelAnchor's default mid_x+2 offset"
        .left_of_run = anchor.x < mid_x + 2,
    };
}

const SegPair = struct { a: sketch.Point, b: sketch.Point };

fn pickMidSegmentBbox(poly: []const sketch.Point) ?SegPair {
    var count: usize = 0;
    for (poly[0 .. poly.len - 1], 0..) |p, i| {
        const q = poly[i + 1];
        if (p.x != q.x or p.y != q.y) count += 1;
    }
    if (count == 0) return null;
    const target = count / 2;
    var seen: usize = 0;
    for (poly[0 .. poly.len - 1], 0..) |p, i| {
        const q = poly[i + 1];
        if (p.x == q.x and p.y == q.y) continue;
        if (seen == target) return .{ .a = p, .b = q };
        seen += 1;
    }
    return null;
}

test {
    _ = @import("clusters_test.zig");
}

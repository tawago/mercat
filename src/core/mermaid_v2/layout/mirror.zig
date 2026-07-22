//! Sketch mirroring helpers for direction canonicalization in layout/.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");

pub fn vertical(a: std.mem.Allocator, s: sketch.Sketch, direction: sketch.Direction) error{OutOfMemory}!sketch.Sketch {
    const nodes = try a.alloc(sketch.NodePlacement, s.nodes.len);
    for (s.nodes, 0..) |n, i| {
        nodes[i] = n;
        nodes[i].rect = mirrorRect(s.bbox, n.rect);
    }

    const clusters = try a.alloc(sketch.ClusterFrame, s.clusters.len);
    for (s.clusters, 0..) |c, i| {
        clusters[i] = c;
        clusters[i].rect = mirrorRect(s.bbox, c.rect);
    }

    const edges = try a.alloc(sketch.EdgePath, s.edges.len);
    for (s.edges, 0..) |e, i| {
        const polyline = try a.alloc(sketch.Point, e.polyline.len);
        for (e.polyline, 0..) |pt, k| {
            polyline[k] = mirrorPoint(s.bbox, pt);
        }

        edges[i] = e;
        edges[i].polyline = polyline;
        edges[i].port_from = mirrorPort(s.nodes, e.port_from);
        edges[i].port_to = mirrorPort(s.nodes, e.port_to);
    }

    const busbars = try a.alloc(sketch.BusBar, s.busbars.len);
    for (s.busbars, 0..) |bb, i| {
        const stem = try a.alloc(sketch.Point, bb.stem.len);
        for (bb.stem, 0..) |pt, k| stem[k] = mirrorPoint(s.bbox, pt);
        const taps = try a.alloc(sketch.Tap, bb.taps.len);
        for (bb.taps, 0..) |tap, k| {
            taps[k] = tap;
            taps[k].at = mirrorPoint(s.bbox, tap.at);
            taps[k].landing = mirrorPoint(s.bbox, tap.landing);
        }
        busbars[i] = bb;
        busbars[i].stem = stem;
        busbars[i].taps = taps;
        // Vertical mirror keeps x order; only the shared rail row moves. // guarded-by: mirror.zig "vertical mirror preserves bus-bar tap x-order; only the rail row shifts"
        busbars[i].rail = .{ mirrorPoint(s.bbox, bb.rail[0]), mirrorPoint(s.bbox, bb.rail[1]) };
    }

    return .{
        .bbox = s.bbox,
        .direction = direction,
        .nodes = nodes,
        .clusters = clusters,
        .edges = edges,
        .busbars = busbars,
        .joins = s.joins,
        .diagnostics = s.diagnostics,
        .budget = s.budget,
    };
}

/// Transpose node geometry for the declared flow direction. Layout runs in an
/// internal top-down frame (flow axis = y); for LR/RL we swap positions AND
/// dimensions so the stack runs horizontally. TD is identity; BT is
/// canonicalized to TD upstream and must never reach here. Generic over the
/// NodeGeom type via `comptime G` (exposes `x,y: i32` and `w,h: u32`), mirroring
/// the lever modules so this stays in the layout/ zone without importing
/// routing.zig. `sketch.Direction` is the same `prim.Direction` the SemGraph
/// uses, so the caller passes `graph.direction` directly.
pub fn applyDirection(comptime G: type, geom: []G, dir: sketch.Direction) void {
    switch (dir) {
        .TD => {},
        .BT => unreachable,
        .LR, .RL => {
            for (geom) |*g| {
                const ox = g.x;
                const oy = g.y;
                const ow = g.w;
                const oh = g.h;
                g.x = oy;
                g.y = ox;
                g.w = oh;
                g.h = ow;
            }
            // sugiyama.assignLayers already reverses layer order for RL. // guarded-by: mirror.zig "RL: sugiyama's own layer reversal plus applyDirection's axis swap alone yields correct right-to-left order"
        },
    }
}

fn mirrorRect(bbox: sketch.Rect, rect: sketch.Rect) sketch.Rect {
    var out = rect;
    out.y = bbox.y + @as(i32, @intCast(bbox.h - rect.h)) - (rect.y - bbox.y);
    return out;
}

fn mirrorPoint(bbox: sketch.Rect, pt: sketch.Point) sketch.Point {
    return .{
        .x = pt.x,
        .y = bbox.y + @as(i32, @intCast(bbox.h - 1)) - (pt.y - bbox.y),
    };
}

fn mirrorPort(nodes: []const sketch.NodePlacement, port: sketch.Port) sketch.Port {
    var out = port;
    switch (port.side) {
        .north => out.side = .south,
        .south => out.side = .north,
        .east, .west => {
            const h = nodeHeight(nodes, port.node);
            out.offset = if (h == 0) port.offset else h - 1 - port.offset;
        },
    }
    return out;
}

fn nodeHeight(nodes: []const sketch.NodePlacement, node: sketch.NodeId) u32 {
    for (nodes) |n| {
        if (n.id == node) return n.rect.h;
    }
    return 0;
}

test "vertical mirror flips y geometry and ports" {
    const nodes = [_]sketch.NodePlacement{
        .{ .id = 1, .rect = .{ .x = 2, .y = 1, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"A"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 2, .y = 6, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"B"}, .cluster_id = null },
    };
    const clusters = [_]sketch.ClusterFrame{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 9, .h = 10 }, .parent_id = null, .label = "C", .depth = 0 },
    };
    const poly = [_]sketch.Point{ .{ .x = 4, .y = 3 }, .{ .x = 4, .y = 5 } };
    const edges = [_]sketch.EdgePath{
        .{
            .id = 1,
            .from = 1,
            .to = 2,
            .polyline = &poly,
            .port_from = .{ .node = 1, .side = .south, .offset = 2 },
            .port_to = .{ .node = 2, .side = .west, .offset = 0 },
            .arrow_from = .none,
            .arrow_to = .filled,
            .label = null,
            .kind = .solid,
        },
    };
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 9, .h = 10 },
        .direction = .TD,
        .nodes = &nodes,
        .clusters = &clusters,
        .edges = &edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try vertical(arena.allocator(), s, .BT);

    try std.testing.expectEqual(sketch.Direction.BT, out.direction);
    try std.testing.expectEqual(@as(i32, 6), out.nodes[0].rect.y);
    try std.testing.expectEqual(@as(i32, 1), out.nodes[1].rect.y);
    try std.testing.expectEqual(@as(i32, 6), out.edges[0].polyline[0].y);
    try std.testing.expectEqual(@as(i32, 4), out.edges[0].polyline[1].y);
    try std.testing.expectEqual(sketch.Dir4.north, out.edges[0].port_from.side);
    try std.testing.expectEqual(sketch.Dir4.west, out.edges[0].port_to.side);
    try std.testing.expectEqual(@as(u32, 2), out.edges[0].port_to.offset);
}

test "vertical mirror preserves bus-bar tap x-order; only the rail row shifts" {
    const nodes = [_]sketch.NodePlacement{
        .{ .id = 1, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"P"}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 0, .y = 8, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"L"}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 20, .y = 8, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{"R"}, .cluster_id = null },
    };
    const stem = [_]sketch.Point{ .{ .x = 2, .y = 3 }, .{ .x = 2, .y = 5 } };
    const taps = [_]sketch.Tap{
        .{ .edge = 1, .node = 2, .at = .{ .x = 2, .y = 5 }, .landing = .{ .x = 2, .y = 8 } },
        .{ .edge = 2, .node = 3, .at = .{ .x = 22, .y = 5 }, .landing = .{ .x = 22, .y = 8 } },
    };
    const busbars = [_]sketch.BusBar{
        .{ .pivot = 1, .stem = &stem, .rail = .{ .{ .x = 2, .y = 5 }, .{ .x = 22, .y = 5 } }, .taps = &taps, .kind = .solid },
    };
    const s = sketch.Sketch{
        // h is even (12, rows 0..11) so mirroring has no fixed row: every
        // y strictly moves, which is what this test needs to observe.
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 12 },
        .direction = .TD,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &.{},
        .busbars = &busbars,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try vertical(arena.allocator(), s, .BT);

    // Tap x-values (and therefore their relative x-order) are unchanged —
    // vertical mirroring only touches y.
    try std.testing.expectEqual(taps[0].at.x, out.busbars[0].taps[0].at.x);
    try std.testing.expectEqual(taps[1].at.x, out.busbars[0].taps[1].at.x);
    try std.testing.expectEqual(taps[0].landing.x, out.busbars[0].taps[0].landing.x);
    try std.testing.expectEqual(taps[1].landing.x, out.busbars[0].taps[1].landing.x);

    // The rail stays a single shared row (both endpoints keep equal y)
    // and stays x-ordered — but that row actually moved.
    try std.testing.expect(out.busbars[0].rail[0].x <= out.busbars[0].rail[1].x);
    try std.testing.expectEqual(out.busbars[0].rail[0].y, out.busbars[0].rail[1].y);
    try std.testing.expect(out.busbars[0].rail[0].y != busbars[0].rail[0].y);
}

test "RL: sugiyama's own layer reversal plus applyDirection's axis swap alone yields correct right-to-left order" {
    // A -> B -> C, direction RL. sugiyama.assignLayers already reverses
    // the internal layers array for RL so layer-index 0 (post-reversal)
    // is the sink end; applyDirection's LR/RL branch then only swaps
    // x<->y/w<->h — no extra x-reflection is applied on top.
    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = null },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const g = sg.SemGraph{
        .direction = .RL,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    var lg = try sugiyama.assignLayers(std.testing.allocator, g);
    defer lg.deinit(std.testing.allocator);

    // Build geometry the way layout.zig's internal-TD coordinate
    // assignment does: y increases monotonically with (already-reversed)
    // layer index.
    const TGeom = struct { x: i32, y: i32, w: u32, h: u32 };
    var geom = try std.testing.allocator.alloc(TGeom, lg.nodes.len);
    defer std.testing.allocator.free(geom);
    for (lg.layers, 0..) |row, li| {
        for (row) |idx| geom[idx] = .{ .x = 0, .y = @as(i32, @intCast(li)) * 10, .w = 6, .h = 3 };
    }

    applyDirection(TGeom, geom, .RL);

    // RL renders flow right-to-left: the source (A) must land strictly
    // to the right of the sink (C), using applyDirection's swap alone.
    const idx_a = lg.real_index.get(0).?;
    const idx_c = lg.real_index.get(2).?;
    try std.testing.expect(geom[idx_a].x > geom[idx_c].x);
}

test {
    _ = @import("mirror_test.zig");
}

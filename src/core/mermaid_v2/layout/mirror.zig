//! Sketch mirroring helpers for direction canonicalization in layout/.

const std = @import("std");
const ledger = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");

pub fn vertical(a: std.mem.Allocator, s: sketch.Sketch, direction: sketch.Direction) error{OutOfMemory}!sketch.Sketch {
    const nodes = try a.alloc(sketch.NodePlacement, s.nodes.len);
    errdefer a.free(nodes);
    for (s.nodes, 0..) |n, i| {
        nodes[i] = n;
        nodes[i].rect = mirrorRect(s.bbox, n.rect);
    }

    const clusters = try a.alloc(sketch.ClusterFrame, s.clusters.len);
    errdefer a.free(clusters);
    for (s.clusters, 0..) |c, i| {
        clusters[i] = c;
        clusters[i].rect = mirrorRect(s.bbox, c.rect);
    }

    const edges = try a.alloc(sketch.EdgePath, s.edges.len);
    var edges_done: usize = 0;
    errdefer {
        for (edges[0..edges_done]) |edge| a.free(edge.polyline);
        a.free(edges);
    }
    for (s.edges, 0..) |e, i| {
        const polyline = try a.alloc(sketch.Point, e.polyline.len);
        for (e.polyline, 0..) |pt, k| {
            polyline[k] = mirrorPoint(s.bbox, pt);
        }

        edges[i] = e;
        edges[i].polyline = polyline;
        edges[i].port_from = mirrorPort(s.nodes, e.port_from);
        edges[i].port_to = mirrorPort(s.nodes, e.port_to);
        edges_done += 1;
    }

    const rails = try a.alloc(sketch.Rail, s.rails.len);
    var rails_done: usize = 0;
    errdefer {
        for (rails[0..rails_done]) |rail| {
            a.free(rail.stem);
            a.free(rail.taps);
        }
        a.free(rails);
    }
    for (s.rails, 0..) |rail, i| {
        const stem = try a.alloc(sketch.Point, rail.stem.len);
        errdefer a.free(stem);
        for (rail.stem, 0..) |pt, k| stem[k] = mirrorPoint(s.bbox, pt);
        const taps = try a.alloc(sketch.Tap, rail.taps.len);
        errdefer a.free(taps);
        for (rail.taps, 0..) |tap, k| {
            taps[k] = tap;
            taps[k].at = mirrorPoint(s.bbox, tap.at);
            taps[k].landing = mirrorPoint(s.bbox, tap.landing);
        }
        rails[i] = rail;
        rails[i].stem = stem;
        rails[i].taps = taps;
        // Vertical mirror keeps x order; only the shared rail row moves. // @guarded-by: mirror.zig "vertical mirror preserves rail tap x-order; only the rail row shifts"
        rails[i].crossbar = .{ mirrorPoint(s.bbox, rail.crossbar[0]), mirrorPoint(s.bbox, rail.crossbar[1]) };
        rails_done += 1;
    }

    const bundle_sets = try mirrorBundles(a, s.bbox, s.bundle_sets);
    errdefer if (bundle_sets.ptr != s.bundle_sets.ptr) freeMirroredSets(a, @constCast(bundle_sets));
    const rail_claims = try mirrorRailClaims(a, s.nodes, s.rail_claims);
    // A gap's two wall cells flip with the ink; its rows still count from `near`.
    const gap_rows = try a.alloc(ledger.GapRows, s.gap_rows.len);
    for (s.gap_rows, gap_rows) |g, *out| {
        out.* = g;
        out.near = mirrorPoint(s.bbox, .{ .x = 0, .y = g.near }).y;
        out.far = mirrorPoint(s.bbox, .{ .x = 0, .y = g.far }).y;
    }

    return .{
        .bbox = s.bbox,
        .direction = direction,
        .nodes = nodes,
        .clusters = clusters,
        .edges = edges,
        .rails = rails,
        .rail_claims = rail_claims,
        .bundles = s.bundles,
        .closure = s.closure,
        .gap_rows = gap_rows,
        .bundle_sets = bundle_sets,
        .bundle_stamp_state = s.bundle_stamp_state,
        .diagnostics = s.diagnostics,
        .budget = s.budget,
    };
}

fn mirrorRailClaims(
    a: std.mem.Allocator,
    nodes: []const sketch.NodePlacement,
    claims: []const ledger.RailClaim,
) error{OutOfMemory}![]const ledger.RailClaim {
    if (claims.len == 0) return claims;
    const out = try a.alloc(ledger.RailClaim, claims.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |claim| a.free(claim.members);
        a.free(out);
    }
    for (claims, out) |claim, *copy| {
        const members = try a.alloc(ledger.RailClaimMember, claim.members.len);
        for (claim.members, members) |member, *mirrored| {
            mirrored.* = member;
            for (&mirrored.sites) |*site| {
                if (site.*) |value| site.* = mirrorSite(nodes, value);
            }
        }
        copy.* = claim;
        copy.members = members;
        initialized += 1;
    }
    return out;
}

fn mirrorSite(nodes: []const sketch.NodePlacement, site: ledger.AttachmentSite) ledger.AttachmentSite {
    const port = mirrorPort(nodes, .{ .node = site.node, .side = site.side, .offset = site.offset });
    return .{ .node = port.node, .side = port.side, .offset = port.offset };
}

fn mirrorBundles(a: std.mem.Allocator, bbox: sketch.Rect, sets: []const ledger.Bundle) error{OutOfMemory}![]const ledger.Bundle {
    var has_cells = false;
    for (sets) |set| {
        if (set.cells) |cells| has_cells = has_cells or cells.len != 0;
        if (set.pairwise) |pairs| for (pairs) |pair| {
            has_cells = has_cells or pair.cells.len != 0;
        };
    }
    if (!has_cells) return sets;

    const out = try a.alloc(ledger.Bundle, sets.len);
    var initialized: usize = 0;
    errdefer freeMirroredSets(a, out[0..initialized]);
    for (sets, out) |set, *slot| {
        slot.* = set;
        slot.cells = null;
        slot.pairwise = null;
        initialized += 1;

        if (set.cells) |cells| slot.cells = try mirrorCells(a, bbox, cells);
        if (set.pairwise) |pairs| {
            if (pairs.len == 0) {
                slot.pairwise = pairs;
                continue;
            }
            const mirrored = try a.alloc(ledger.PairCells, pairs.len);
            for (mirrored) |*pair| pair.* = .{ .a = 0, .b = 0, .cells = &.{} };
            slot.pairwise = mirrored;
            for (pairs, mirrored) |pair, *copy| {
                copy.a = pair.a;
                copy.b = pair.b;
                copy.cells = try mirrorCells(a, bbox, pair.cells);
            }
        }
    }
    return out;
}

fn mirrorCells(a: std.mem.Allocator, bbox: sketch.Rect, cells: []const ledger.BundleCell) error{OutOfMemory}![]const ledger.BundleCell {
    if (cells.len == 0) return cells;
    const out = try a.alloc(ledger.BundleCell, cells.len);
    for (cells, out) |cell, *copy| {
        const point = mirrorPoint(bbox, .{ .x = cell.x, .y = cell.y });
        copy.* = .{ .x = point.x, .y = point.y };
    }
    return out;
}

fn freeMirroredSets(a: std.mem.Allocator, sets: []const ledger.Bundle) void {
    for (sets) |set| {
        if (set.cells) |cells| if (cells.len != 0) a.free(cells);
        if (set.pairwise) |pairs| if (pairs.len != 0) {
            for (pairs) |pair| if (pair.cells.len != 0) a.free(pair.cells);
            a.free(pairs);
        };
    }
    a.free(sets);
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
            // sugiyama.assignLayers already reverses layer order for RL. // @guarded-by: mirror.zig "RL: sugiyama's own layer reversal plus applyDirection's axis swap alone yields correct right-to-left order"
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

test "vertical mirror preserves rail tap x-order; only the rail row shifts" {
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
    const rails = [_]sketch.Rail{
        .{ .pivot = 1, .stem = &stem, .crossbar = .{ .{ .x = 2, .y = 5 }, .{ .x = 22, .y = 5 } }, .taps = &taps, .kind = .solid },
    };
    const s = sketch.Sketch{
        .bbox = .{ .x = 0, .y = 0, .w = 25, .h = 12 },
        .direction = .TD,
        .nodes = &nodes,
        .clusters = &.{},
        .edges = &.{},
        .rails = &rails,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try vertical(arena.allocator(), s, .BT);

    try std.testing.expectEqual(taps[0].at.x, out.rails[0].taps[0].at.x);
    try std.testing.expectEqual(taps[1].at.x, out.rails[0].taps[1].at.x);
    try std.testing.expectEqual(taps[0].landing.x, out.rails[0].taps[0].landing.x);
    try std.testing.expectEqual(taps[1].landing.x, out.rails[0].taps[1].landing.x);

    try std.testing.expect(out.rails[0].crossbar[0].x <= out.rails[0].crossbar[1].x);
    try std.testing.expectEqual(out.rails[0].crossbar[0].y, out.rails[0].crossbar[1].y);
    try std.testing.expect(out.rails[0].crossbar[0].y != rails[0].crossbar[0].y);
}

test "RL: sugiyama's own layer reversal plus applyDirection's axis swap alone yields correct right-to-left order" {
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

    const TGeom = struct { x: i32, y: i32, w: u32, h: u32 };
    var geom = try std.testing.allocator.alloc(TGeom, lg.nodes.len);
    defer std.testing.allocator.free(geom);
    for (lg.layers, 0..) |row, li| {
        for (row) |idx| geom[idx] = .{ .x = 0, .y = @as(i32, @intCast(li)) * 10, .w = 6, .h = 3 };
    }

    applyDirection(TGeom, geom, .RL);

    const idx_a = lg.real_index.get(0).?;
    const idx_c = lg.real_index.get(2).?;
    try std.testing.expect(geom[idx_a].x > geom[idx_c].x);
}

test {
    _ = @import("mirror_test.zig");
}

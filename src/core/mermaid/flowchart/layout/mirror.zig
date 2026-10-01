const std = @import("std");
const rail_star = @import("../base/rail_star.zig");
const bundle_mod = @import("../base/bundle.zig");
const sketch = @import("../sketch.zig");
const node_geom = @import("node_geom.zig");

const NodeGeom = node_geom.NodeGeom;

pub fn vertical(a: std.mem.Allocator, s: sketch.Sketch, direction: sketch.Direction) error{OutOfMemory}!sketch.Sketch {
    const nodes = try a.alloc(sketch.NodePlacement, s.nodes.len);
    errdefer a.free(nodes);
    for (s.nodes, 0..) |n, i| {
        nodes[i] = n;
        nodes[i].rect = mirrorRect(s.bbox, n.rect);
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
        rails[i].crossbar = .{ mirrorPoint(s.bbox, rail.crossbar[0]), mirrorPoint(s.bbox, rail.crossbar[1]) };
        rails_done += 1;
    }

    const bundles = try mirrorBundles(a, s.bbox, s.sharing.bundles);
    errdefer if (bundles.ptr != s.sharing.bundles.ptr) freeMirroredSets(a, @constCast(bundles));
    const claims = try mirrorRailClaims(a, s.nodes, s.sharing.claims);

    return .{
        .bbox = s.bbox,
        .direction = direction,
        .nodes = nodes,
        .clusters = s.clusters,
        .edges = edges,
        .rails = rails,
        .sharing = .{ .realized = s.sharing.realized, .bundles = bundles, .claims = claims },
        .diagnostics = s.diagnostics,
        .budget = s.budget,
    };
}

fn mirrorRailClaims(
    a: std.mem.Allocator,
    nodes: []const sketch.NodePlacement,
    claims: []const rail_star.RailClaim,
) error{OutOfMemory}![]const rail_star.RailClaim {
    if (claims.len == 0) return claims;
    const out = try a.alloc(rail_star.RailClaim, claims.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |claim| a.free(claim.members);
        a.free(out);
    }
    for (claims, out) |claim, *copy| {
        const members = try a.alloc(rail_star.RailClaimMember, claim.members.len);
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

fn mirrorSite(nodes: []const sketch.NodePlacement, site: rail_star.AttachmentSite) rail_star.AttachmentSite {
    const port = mirrorPort(nodes, .{ .node = site.node, .side = site.side, .offset = site.offset });
    return .{ .node = port.node, .side = port.side, .offset = port.offset };
}

fn mirrorBundles(a: std.mem.Allocator, bbox: sketch.Rect, sets: []const bundle_mod.Bundle) error{OutOfMemory}![]const bundle_mod.Bundle {
    var has_cells = false;
    for (sets) |set| {
        if (set.cells) |cells| has_cells = has_cells or cells.len != 0;
        if (set.pairwise) |pairs| for (pairs) |pair| {
            has_cells = has_cells or pair.cells.len != 0;
        };
    }
    if (!has_cells) return sets;

    const out = try a.alloc(bundle_mod.Bundle, sets.len);
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
            const mirrored = try a.alloc(bundle_mod.PairCells, pairs.len);
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

fn mirrorCells(a: std.mem.Allocator, bbox: sketch.Rect, cells: []const bundle_mod.BundleCell) error{OutOfMemory}![]const bundle_mod.BundleCell {
    if (cells.len == 0) return cells;
    const out = try a.alloc(bundle_mod.BundleCell, cells.len);
    for (cells, out) |cell, *copy| {
        const point = mirrorPoint(bbox, .{ .x = cell.x, .y = cell.y });
        copy.* = .{ .x = point.x, .y = point.y };
    }
    return out;
}

fn freeMirroredSets(a: std.mem.Allocator, sets: []const bundle_mod.Bundle) void {
    for (sets) |set| {
        if (set.cells) |cells| if (cells.len != 0) a.free(cells);
        if (set.pairwise) |pairs| if (pairs.len != 0) {
            for (pairs) |pair| if (pair.cells.len != 0) a.free(pair.cells);
            a.free(pairs);
        };
    }
    a.free(sets);
}

pub fn applyDirection(geom: []NodeGeom, dir: sketch.Direction) void {
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

test {
    _ = @import("mirror_test.zig");
}

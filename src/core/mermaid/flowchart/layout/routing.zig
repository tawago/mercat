const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const back_edges = @import("back_edges.zig");
const fan_mod = @import("fan.zig");
const fan_provenance = @import("fan_provenance.zig");
const rail_loop = @import("rail_loop.zig");
const fan_polyline = @import("fan_polyline.zig");
const fan_rail = @import("fan_rail.zig");
const gap_rows = @import("gap_rows.zig");
const self_loops = @import("routing_self_loops.zig");
const rp = @import("routing_polyline.zig");
const rt = @import("routing_terminal.zig");
const node_geom = @import("node_geom.zig");
const ledger = @import("../base/ledger.zig");
const rail_star = @import("../base/rail_star.zig");
const bundle_mod = @import("../base/bundle.zig");
const rail_closure = @import("../base/rail_closure.zig");
const port_plan = @import("port_plan.zig");
const route_clearance = @import("route_clearance.zig");
const route_detour = @import("route_detour.zig");

pub const findGraphEdge = rt.findGraphEdge;
pub const findPlacement = rt.findPlacement;
pub const isReversed = rt.isReversed;
pub const mapArrow = rt.mapArrow;
const collectVirtuals = rt.collectVirtuals;

pub const NodeGeom = node_geom.NodeGeom;

pub const LaneLadder = struct {
    planned: u32,
    lane: u32,
    descending: bool = false,

    pub fn next(self: *LaneLadder) bool {
        if (!self.descending) {
            if (self.lane < 16) {
                self.lane += 1;
                return true;
            }
            if (self.planned == 0) return false;
            self.descending = true;
            self.lane = self.planned - 1;
            return true;
        }
        if (self.lane == 0) return false;
        self.lane -= 1;
        return true;
    }
};

pub fn accepts(
    a: std.mem.Allocator,
    edge: sg.Edge,
    poly: []const sketch.Point,
    straight: rp.Straight,
    existing: []const sketch.EdgePath,
    bar_views: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
    edge_ports: []const port_plan.EdgePorts,
    bundles: ledger.RealizedBundles,
) error{OutOfMemory}!bool {
    return rt.terminalsStraight(poly, straight) and
        try route_clearance.polylineClears(a, edge.id, poly, existing, bar_views, placements, edge_ports, bundles, edge.from, edge.to);
}

pub fn detour(
    a: std.mem.Allocator,
    direction: sg.Direction,
    edge: sg.Edge,
    from_p: sketch.NodePlacement,
    to_p: sketch.NodePlacement,
    ep: port_plan.EdgePorts,
    straight: rp.Straight,
    existing: []const sketch.EdgePath,
    bar_views: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
    edge_ports: []const port_plan.EdgePorts,
    bundles: ledger.RealizedBundles,
) error{OutOfMemory}!?[]sketch.Point {
    const limit = route_detour.detourLimit(existing.len);
    var distance: u32 = 0;
    while (distance <= limit) : (distance += 1) {
        var source_extra: u32 = 0;
        while (source_extra <= route_detour.ROW_REACH) : (source_extra += 1) {
            var target_extra: u32 = 0;
            while (target_extra <= route_detour.ROW_REACH) : (target_extra += 1) {
                const rows: route_detour.Rows = .{ .source_extra = source_extra, .target_extra = target_extra };
                const poly = (try route_detour.outsideDetour(a, direction, from_p, to_p, ep.source, ep.target, placements, distance, straight, rows)) orelse continue;
                if (try accepts(a, edge, poly, straight, existing, bar_views, placements, edge_ports, bundles)) return poly;
            }
        }
    }
    return null;
}

pub fn selfLoop(
    a: std.mem.Allocator,
    direction: sg.Direction,
    edge: sg.Edge,
    node_p: sketch.NodePlacement,
    ep: port_plan.EdgePorts,
    existing: []const sketch.EdgePath,
    bar_views: []const sketch.Rail,
    placements: []const sketch.NodePlacement,
    edge_ports: []const port_plan.EdgePorts,
    bundles: ledger.RealizedBundles,
) error{OutOfMemory}!self_loops.SelfLoop {
    const straight = rp.Straight.forEdge(edge);
    var step: u32 = 0;
    while (try self_loops.loopCandidate(a, direction, node_p, ep.source, ep.target, step)) |cand| : (step += 1) {
        if (route_clearance.touchesForeignNode(cand.polyline, placements, edge.from, edge.to)) continue;
        if (try accepts(a, edge, cand.polyline, straight, existing, bar_views, placements, edge_ports, bundles)) return cand;
    }
    return .{ .polyline = try unrouted(a), .port_from = ep.source, .port_to = ep.target };
}

pub fn unrouted(a: std.mem.Allocator) error{OutOfMemory}![]sketch.Point {
    return a.alloc(sketch.Point, 0);
}

pub fn growBaseApproach(
    a: std.mem.Allocator,
    poly: []sketch.Point,
    placements: []const sketch.NodePlacement,
    edge: sg.Edge,
    existing: []const sketch.EdgePath,
    bar_views: []const sketch.Rail,
    edge_ports: []const port_plan.EdgePorts,
    bundles: ledger.RealizedBundles,
) error{OutOfMemory}![]sketch.Point {
    const grown = try rt.satisfyApproach(a, poly, placements);
    if (grown.ptr == poly.ptr) return poly;
    if (try accepts(a, edge, grown, rp.Straight.forEdge(edge), existing, bar_views, placements, edge_ports, bundles))
        return grown;
    return poly;
}

pub const EdgesResult = struct {
    edges: []sketch.EdgePath,
    polylines: [][]sketch.Point,
    rails: []fan_rail.Built,
    bundles: []const bundle_mod.Bundle,
    claims: []const rail_star.RailClaim,
};

pub fn buildEdgesWithPlan(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
    placements: []const sketch.NodePlacement,
    fans: []const fan_mod.Fan,
    bundles: ledger.RealizedBundles,
    allocated_ports: port_plan.Plan,
    rows: gap_rows.Ledger,
) error{OutOfMemory}!EdgesResult {
    const rail_alloc = try back_edges.allocateBackEdgeRails(a, graph, lg, geom, placements);
    defer a.free(rail_alloc);

    const reserved = try a.alloc(i32, rail_alloc.len);
    for (rail_alloc, reserved) |r, *x| x.* = r.rail_pos;
    const drawn = try rail_loop.run(a, graph, lg, geom, placements, fans, bundles, allocated_ports, rows, reserved);
    var out = drawn.edges;
    var polys = drawn.polylines;
    const bar_views = drawn.views;

    var routing_edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    if (bundles.memberships.len == 0) {
        for (graph.edges) |edge| if (!rows.isProxy(edge.id)) try routing_edges.append(a, edge);
    } else {
        for (graph.edges) |edge| if (edge.kind != .invisible and !rows.isProxy(edge.id) and !route_clearance.isIndependent(edge.id, bundles)) try routing_edges.append(a, edge);
        for (graph.edges) |edge| if (edge.kind != .invisible and !rows.isProxy(edge.id) and route_clearance.isIndependent(edge.id, bundles)) try routing_edges.append(a, edge);
        for (graph.edges) |edge| if (edge.kind == .invisible and !rows.isProxy(edge.id)) try routing_edges.append(a, edge);
    }
    for (graph.edges) |edge| if (rows.isProxy(edge.id)) try routing_edges.append(a, edge);
    for (routing_edges.items) |orig| {
        const proxy = rows.isProxy(orig.id);
        if (rail_closure.contains(bundles.discharged, orig.id)) continue;
        if (std.mem.indexOfScalar(sg.EdgeId, drawn.claimed, orig.id) != null) continue;
        if (orig.from != orig.to) {
            if (fan_mod.lookup(fans, orig.id)) |hit| if (!hit.peer.long) {
                const ep = allocated_ports.forEdge(orig.id) orelse unreachable;
                const src_p = findPlacement(placements, orig.from);
                const dst_p = findPlacement(placements, orig.to);
                const pivot_p = if (hit.fan.direction == .out) src_p else dst_p;
                const peer_p = if (hit.fan.direction == .out) dst_p else src_p;
                const planned = rows.laneOfEdge(orig.id, .exit);
                var ladder = LaneLadder{ .planned = planned, .lane = planned };
                const dodge_y: ?i32 = if (hit.fan.direction == .out) dodgeRow(rows, lg, geom, orig) else null;
                const source_x = src_p.rect.x + @as(i32, @intCast(ep.source.offset));
                const target_x = dst_p.rect.x + @as(i32, @intCast(ep.target.offset));
                const routed_role: fan_mod.ChildRole = if (hit.peer.role == .center and source_x != target_x) .middle else hit.peer.role;
                var poly: []sketch.Point = undefined;
                var routed_fan = hit.fan.*;
                routed_fan.labeled = orig.label != null and orig.label.?.len != 0;
                const straight = rp.Straight.forEdge(orig);
                while (true) {
                    const lane = ladder.lane;
                    poly = if (lane == planned and orig.label == null and (ep.source_duplicate or ep.target_duplicate))
                        try port_plan.duplicateDetour(a, graph.direction, src_p, dst_p, ep, placements)
                    else
                        try fan_polyline.buildPolylineAt(a, graph.direction, routed_fan, pivot_p, peer_p, ep.source, ep.target, routed_role, lane, dodge_y, placements, straight);
                    if (proxy or try accepts(a, orig, poly, straight, out.items, bar_views, placements, allocated_ports.edges, bundles)) break;
                    if (ladder.next()) continue;
                    poly = if (orig.kind == .invisible)
                        try route_detour.clearInvisiblePath(a, orig.id, src_p, dst_p, ep.source, ep.target, placements, out.items, bundles)
                    else
                        (try detour(a, graph.direction, orig, src_p, dst_p, ep, straight, out.items, bar_views, placements, allocated_ports.edges, bundles)) orelse try unrouted(a);
                    break;
                }
                const role: sketch.EdgeRole = if (hit.fan.direction == .out)
                    .fan_out_dropper
                else
                    .fan_in_dropper;
                try out.append(a, .{
                    .id = orig.id,
                    .from = orig.from,
                    .to = orig.to,
                    .polyline = poly,
                    .port_from = ep.source,
                    .port_to = ep.target,
                    .arrow_from = mapArrow(orig.arrow_from),
                    .arrow_to = mapArrow(orig.arrow_to),
                    .label = orig.label,
                    .kind = orig.kind,
                    .role = role,
                    .origin = orig.declaredId(),
                });
                try polys.append(a, poly);
                continue;
            };
        }
        if (orig.from == orig.to) {
            const node_p = findPlacement(placements, orig.from);
            const sl: self_loops.SelfLoop = if (bundles.memberships.len == 0)
                try self_loops.selfLoop(a, graph.direction, node_p, placements)
            else
                try selfLoop(a, graph.direction, orig, node_p, allocated_ports.forEdge(orig.id) orelse unreachable, out.items, bar_views, placements, allocated_ports.edges, bundles);
            try out.append(a, .{
                .id = orig.id,
                .from = orig.from,
                .to = orig.to,
                .polyline = sl.polyline,
                .port_from = sl.port_from,
                .port_to = sl.port_to,
                .arrow_from = mapArrow(orig.arrow_from),
                .arrow_to = mapArrow(orig.arrow_to),
                .label = orig.label,
                .kind = orig.kind,
                .role = .self_loop,
                .origin = orig.declaredId(),
            });
            try polys.append(a, sl.polyline);
            continue;
        }

        const reversed = isReversed(lg, orig.id);

        if (reversed) {
            const rail = back_edges.findRail(rail_alloc, orig.id);
            const src_p = findPlacement(placements, orig.from);
            const dst_p = findPlacement(placements, orig.to);
            const ep = allocated_ports.forEdge(orig.id) orelse unreachable;
            const guarded = try route_clearance.withDecoratedTerminalBoxes(a, orig.id, placements, allocated_ports.edges, bundles);
            const poly = if (bundles.memberships.len == 0)
                try back_edges.backEdgePolyline(a, graph.direction, src_p, dst_p, rail, guarded)
            else
                try back_edges.backEdgePolylineAt(a, graph.direction, src_p, dst_p, ep.source, ep.target, rail, guarded);
            const port_from = if (bundles.memberships.len == 0) back_edges.backEdgePortFrom(graph.direction, src_p) else ep.source;
            const port_to = if (bundles.memberships.len == 0) back_edges.backEdgePortTo(graph.direction, dst_p) else ep.target;
            _ = rp.ensureBaseStub(poly, placements, orig.from, orig.to);
            try out.append(a, .{
                .id = orig.id,
                .from = orig.from,
                .to = orig.to,
                .polyline = poly,
                .port_from = port_from,
                .port_to = port_to,
                .arrow_from = mapArrow(orig.arrow_from),
                .arrow_to = mapArrow(orig.arrow_to),
                .label = orig.label,
                .kind = orig.kind,
                .role = .back_edge,
                .origin = orig.declaredId(),
            });
            try polys.append(a, poly);
            continue;
        }

        const eff_from: sg.NodeId = if (reversed) orig.to else orig.from;
        const eff_to: sg.NodeId = if (reversed) orig.from else orig.to;

        const eff_from_p = findPlacement(placements, eff_from);
        const eff_to_p = findPlacement(placements, eff_to);

        const virtuals = try collectVirtuals(a, lg, orig.id);
        defer a.free(virtuals);

        const eff_dir: sg.Direction = graph.direction;

        const ep = allocated_ports.forEdge(orig.id) orelse unreachable;
        const eff_port_from = ep.source;
        const eff_port_to = ep.target;

        const lanes: rp.Lanes = .{ .entry = rows.laneOfEdge(orig.id, .entry), .exit = rows.laneOfEdge(orig.id, .exit) };
        var ladder = LaneLadder{ .planned = lanes.exit, .lane = lanes.exit };
        const straight = rp.Straight.forEdge(orig);
        var poly: []sketch.Point = undefined;
        while (true) {
            const lane = ladder.lane;
            poly = if (lane == lanes.exit and orig.label == null and (ep.source_duplicate or ep.target_duplicate))
                try port_plan.duplicateDetour(a, eff_dir, eff_from_p, eff_to_p, ep, placements)
            else
                try rp.routePolyline(a, eff_dir, eff_from_p, eff_to_p, eff_port_from, eff_port_to, virtuals, geom, placements, 0, 0, .{ .entry = lanes.entry, .exit = lane }, straight);
            if (proxy) break;
            if (try route_clearance.conflictsRailArrows(a, poly, bar_views, orig.from, orig.to))
                poly = try route_detour.shiftInteriorRun(a, poly, eff_dir, 2 * ((lane -| lanes.exit) + 1));
            if (try accepts(a, orig, poly, straight, out.items, bar_views, placements, allocated_ports.edges, bundles)) break;
            if (ladder.next()) continue;
            poly = if (orig.kind == .invisible)
                try route_detour.clearInvisiblePath(a, orig.id, eff_from_p, eff_to_p, ep.source, ep.target, placements, out.items, bundles)
            else
                (try detour(a, eff_dir, orig, eff_from_p, eff_to_p, ep, straight, out.items, bar_views, placements, allocated_ports.edges, bundles)) orelse try unrouted(a);
            break;
        }

        const port_from = eff_port_from;
        const port_to = rp.reconcileTerminalSide(poly, eff_to_p, eff_port_to);
        if (poly.len != 0 and !rp.ensureBaseStub(poly, placements, orig.from, orig.to))
            poly = try growBaseApproach(a, poly, placements, orig, out.items, bar_views, allocated_ports.edges, bundles);

        try out.append(a, .{
            .id = orig.id,
            .from = orig.from,
            .to = orig.to,
            .polyline = poly,
            .port_from = port_from,
            .port_to = port_to,
            .arrow_from = mapArrow(orig.arrow_from),
            .arrow_to = mapArrow(orig.arrow_to),
            .label = orig.label,
            .kind = orig.kind,
            .role = .forward,
            .origin = orig.declaredId(),
        });
        try polys.append(a, poly);
    }
    const rail_claims = try fan_provenance.build(a, graph, placements, fans, bundles, out.items, bar_views);
    return .{
        .edges = try out.toOwnedSlice(a),
        .polylines = try polys.toOwnedSlice(a),
        .rails = drawn.rails,
        .bundles = try fan_mod.coSets(a, fans),
        .claims = rail_claims,
    };
}

fn dodgeRow(rows: gap_rows.Ledger, lg: sugiyama.LayeredGraph, geom: []const NodeGeom, edge: sg.Edge) ?i32 {
    const c = rows.claimOfEdge(edge.id, .entry) orelse return null;
    const real: u32 = @intCast(rows.gaps.len - rows.sub_gaps.len);
    const layer: u32 = if (c.gap < real) c.gap + 1 else rows.sub_gaps[c.gap - real].layer;
    if (layer >= lg.layers.len) return null;
    var wall: i32 = std.math.maxInt(i32);
    for (lg.layers[layer]) |i| wall = @min(wall, geom[i].y);
    if (c.gap >= real) wall += rows.sub_gaps[c.gap - real].top;
    return wall - 3 - c.row;
}

pub fn buildEdges(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
    placements: []const sketch.NodePlacement,
    fans: []const fan_mod.Fan,
    rows: gap_rows.Ledger,
) error{OutOfMemory}!EdgesResult {
    return buildEdgesWithPlan(a, graph, lg, geom, placements, fans, .{}, try port_plan.midpoint(a, graph, placements), rows);
}

test {
    _ = @import("routing_test.zig");
}

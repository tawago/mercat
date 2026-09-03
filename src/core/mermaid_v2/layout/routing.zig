//! Edge routing helpers for `layout.zig`: orthogonal polylines through
//! virtual nodes from `sugiyama.zig`, perimeter ports, and SemGraph→Sketch
//! arrow mapping. Self-loop geometry lives in `routing_self_loops.zig`;
//! polyline + skip-corridor routing lives in `routing_polyline.zig`; fan
//! and back-edge routing delegate to their sibling layout/ modules.
//!
//! Imports: `std`, `../sem_graph.zig`, `../sketch.zig`, and layout/*
//! siblings only. layout/* must not reach into raster/lattice/paint.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const back_edges = @import("back_edges.zig");
const fan_mod = @import("fan.zig");
const fan_provenance = @import("fan_provenance.zig");
const member_stroke = @import("member_stroke.zig");
const fan_polyline = @import("fan_polyline.zig");
const fan_rail = @import("fan_rail.zig");
const fan_lane_order = @import("fan_lane_order.zig");
const self_loops = @import("routing_self_loops.zig");
const rp = @import("routing_polyline.zig");
const rt = @import("routing_terminal.zig");
const ledger = @import("../base/ledger.zig");
const rail_closure = @import("../base/rail_closure.zig");
const port_plan = @import("port_plan.zig");
const route_clearance = @import("route_clearance.zig");

/// Per-gap extra rows for skip-edge corridors. See routing_polyline.zig.
pub const skipCorridorExtraRows = rp.skipCorridorExtraRows;

/// Per-gap extra rows for offset corner-fed forward terminals. See
/// routing_terminal.zig.
pub const terminalApproachExtraRows = rt.terminalApproachExtraRows;

pub const findGraphEdge = rt.findGraphEdge;
pub const findPlacement = rt.findPlacement;
pub const isReversed = rt.isReversed;
pub const perimeterPort = rt.perimeterPort;
pub const mapArrow = rt.mapArrow;
const fanRailLift = rt.fanRailLift;
const collectVirtuals = rt.collectVirtuals;

pub const NodeGeom = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    layer: u32,
};

/// Result of `buildEdges`: the produced `EdgePath` slice plus a
/// parallel slice of mutable polyline buffers. Layout retains the
/// mutable view so `computeBbox` can shift polyline points in place
/// without const-cast escape hatches — the `EdgePath.polyline` field still presents
/// the same underlying memory as `[]const Point` to downstream
/// consumers.
pub const EdgesResult = struct {
    edges: []sketch.EdgePath,
    polylines: [][]sketch.Point,
    /// First-class fan rails, each holding its
    /// `sketch.Rail` plus the MUTABLE tap view so `clusters.computeBbox`'s
    /// shift pass can translate rail + tap points in place (stems are
    /// additionally registered in `polylines` for the same reason). layout.zig
    /// copies the `.rail` fields out AFTER the shift for the final Sketch.
    rails: []fan_rail.Built,
    /// Bundle sets from the live fans (`fan.coSets`), read off the same
    /// peer/lane facts this routing pass just used. Geometry-free, so the
    /// bbox shift pass never touches them. On a flat graph select.zig
    /// replaces them with the plan-derived sets; on a clustered one they are
    /// the whole population.
    bundle_sets: []const ledger.Bundle,
    /// Semantic fan records derived after every local path and Rail is final.
    rail_claims: []const ledger.RailClaim,
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
) error{OutOfMemory}!EdgesResult {
    var out: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
    var polys: std.ArrayListUnmanaged([]sketch.Point) = .empty;

    const rail_alloc = try back_edges.allocateBackEdgeRails(a, graph, lg, geom, placements);
    defer a.free(rail_alloc);

    var rails: std.ArrayListUnmanaged(fan_rail.Built) = .empty;
    var claimed: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    const Pending = struct { fan: fan_mod.Fan, resolved: fan_rail.Resolved, lift: u32 };
    var pending: std.ArrayListUnmanaged(Pending) = .empty;
    var lane_rails: std.ArrayListUnmanaged(fan_lane_order.Rail) = .empty;
    for (fans) |f| {
        const resolved = (try fan_rail.resolve(a, graph.direction, f, graph, placements, geom, bundles, allocated_ports)) orelse continue;
        // Shared-rail lift: same rule as the per-peer path below — any peer descending into a cluster lifts the rail above the frame. // @guarded-by: routing_test.zig "rail pre-pass and forced per-peer path lift the same fan-OUT geometry to the same rail row"
        var lift: u32 = 0;
        for (resolved.peers) |p| {
            lift = @max(lift, fanRailLift(graph, p.edge.from, p.edge.to));
        }
        if (f.direction == .out) lift += fan_mod.additionalLabelLift(f, f.lane);
        try pending.append(a, .{ .fan = f, .resolved = resolved, .lift = lift });
        try lane_rails.append(a, .{
            .gap = f.source_layer,
            .lane = f.lane,
            .fan_in = resolved.direction == .in,
            .stem_x = fan_lane_order.stemX(resolved),
            .tap_xs = try fan_lane_order.tapXs(a, resolved),
        });
    }
    try fan_lane_order.reorder(a, lane_rails.items);
    // Build the rails, then every long member's own stroke. A stroke that
    // finds no clear route refuses its member: the member leaves its rail
    // (the rail stays when two members remain) and routes privately below,
    // and the rails are rebuilt without it — the theory's per-member
    // degradation, decided once here.
    // @guarded-by: port_plan_test.zig "a long fan-in member the plan selected gets a continuing tap and a member stroke"
    var bar_views: []sketch.Rail = &.{};
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        rails.clearRetainingCapacity();
        claimed.clearRetainingCapacity();
        out.clearRetainingCapacity();
        polys.clearRetainingCapacity();
        var rail_pending: std.ArrayListUnmanaged(usize) = .empty;
        for (pending.items, lane_rails.items, 0..) |p, t, pi| {
            if (p.resolved.peers.len < 2) continue;
            const built = try fan_rail.build(a, p.resolved, p.lift, t.lane);
            // Integrity gate: a rail is straight-only geometry; if any run touches a foreign box, fall back to the per-peer polyline path, which can dodge. // @guarded-by: fan_rail_test.zig "fan_rail.blocked rejects a built rail whose tap drop touches a foreign node's box"
            if (fan_rail.blocked(built, p.resolved.pivot.id, placements)) continue;
            try rails.append(a, built);
            try rail_pending.append(a, pi);
        }
        bar_views = try a.alloc(sketch.Rail, rails.items.len);
        for (rails.items, bar_views) |rail, *view| view.* = rail.rail;
        const refused = try member_stroke.buildAll(a, graph, lg, geom, placements, rails.items, bar_views, bundles, allocated_ports, &out, &polys);
        if (refused.len == 0 or attempt >= 8) {
            for (rails.items) |built| {
                try polys.append(a, built.stem);
                for (built.rail.taps) |tap| try claimed.append(a, tap.edge);
            }
            break;
        }
        for (refused) |r| {
            const p = &pending.items[rail_pending.items[r.rail]];
            var kept: std.ArrayListUnmanaged(fan_rail.Peer) = .empty;
            for (p.resolved.peers) |peer| if (peer.edge.id != r.edge) try kept.append(a, peer);
            p.resolved.peers = try kept.toOwnedSlice(a);
        }
    }

    var routing_edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    if (bundles.memberships.len == 0) {
        try routing_edges.appendSlice(a, graph.edges);
    } else {
        for (graph.edges) |edge| if (edge.kind != .invisible and !route_clearance.isIndependent(edge.id, bundles)) try routing_edges.append(a, edge);
        for (graph.edges) |edge| if (edge.kind != .invisible and route_clearance.isIndependent(edge.id, bundles)) try routing_edges.append(a, edge);
        for (graph.edges) |edge| if (edge.kind == .invisible) try routing_edges.append(a, edge);
    }
    for (routing_edges.items) |orig| {
        // CO-REALIZED: a leaf-pair edge an all-arrow-free rail discharges is
        // rendered BY that rail's crossbar (base/rail_closure.zig). It owns no
        // polyline, no port and no label of its own — drawing one would state
        // the relation twice — so it never enters the router at all.
        // @guarded-by: routing_test.zig "a discharged edge is withheld from routing entirely"
        if (rail_closure.contains(bundles.discharged, orig.id)) continue;
        if (std.mem.indexOfScalar(sg.EdgeId, claimed.items, orig.id) != null) continue;
        if (orig.from != orig.to) {
            // A long peer whose fan built no rail is an ordinary skip edge:
            // the per-peer fan polyline assumes a next-layer leaf.
            if (fan_mod.lookup(fans, orig.id)) |hit| if (!hit.peer.long) {
                const ep = allocated_ports.forEdge(orig.id) orelse unreachable;
                const src_p = findPlacement(placements, orig.from);
                const dst_p = findPlacement(placements, orig.to);
                const pivot_p = if (hit.fan.direction == .out) src_p else dst_p;
                const peer_p = if (hit.fan.direction == .out) dst_p else src_p;
                // Lift the rail above any cluster frame-border row it would otherwise be painted along (fusing sibling peers' top borders). // @guarded-by: routing_test.zig "fan-OUT per-peer rail lifts exactly one row for the peer crossing into a cluster its source is not part of"
                var rail_lift: u32 = if (hit.fan.direction == .out)
                    fanRailLift(graph, orig.from, orig.to)
                else
                    0;
                if (hit.fan.direction == .out)
                    rail_lift += fan_mod.additionalLabelLift(hit.fan.*, fan_mod.effectiveLane(hit.fan.*, hit.peer.lane));
                var lane = @max(hit.peer.lane, ep.route_lane);
                const source_x = src_p.rect.x + @as(i32, @intCast(ep.source.offset));
                const target_x = dst_p.rect.x + @as(i32, @intCast(ep.target.offset));
                const routed_role: fan_mod.ChildRole = if (hit.peer.role == .center and source_x != target_x) .middle else hit.peer.role;
                var poly: []sketch.Point = undefined;
                var routed_fan = hit.fan.*;
                routed_fan.labeled = orig.label != null and orig.label.?.len != 0;
                while (true) : (lane += 1) {
                    poly = if (lane == @max(hit.peer.lane, ep.route_lane) and orig.label == null and (ep.source_duplicate or ep.target_duplicate))
                        try port_plan.duplicateDetour(a, graph.direction, src_p, dst_p, ep, placements)
                    else
                        try fan_polyline.buildPolylineAt(a, graph.direction, routed_fan, pivot_p, peer_p, ep.source, ep.target, routed_role, lane, rail_lift, placements);
                    if (try route_clearance.polylineClears(a, orig.id, orig.kind, poly, out.items, bar_views, placements, allocated_ports.edges, bundles, orig.from, orig.to)) break;
                    if (lane >= 16) {
                        if (orig.kind == .invisible) {
                            poly = try route_clearance.clearInvisiblePath(a, orig.id, orig.kind, src_p, dst_p, ep.source, ep.target, placements, out.items, bundles);
                            break;
                        }
                        var distance: u32 = 0;
                        const limit = route_clearance.detourLimit(out.items.len);
                        while (true) : (distance += 1) {
                            poly = try route_clearance.outsideDetour(a, graph.direction, src_p, dst_p, ep.source, ep.target, placements, distance);
                            if ((try route_clearance.polylineClears(a, orig.id, orig.kind, poly, out.items, bar_views, placements, allocated_ports.edges, bundles, orig.from, orig.to)) or distance >= limit) break;
                        }
                        break;
                    }
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
                });
                try polys.append(a, poly);
                continue;
            };
        }
        if (orig.from == orig.to) {
            const node_p = findPlacement(placements, orig.from);
            const sl = if (bundles.memberships.len == 0)
                try self_loops.selfLoop(a, graph.direction, node_p, placements)
            else blk: {
                const ep = allocated_ports.forEdge(orig.id) orelse unreachable;
                break :blk try self_loops.selfLoopAt(a, graph.direction, node_p, placements, ep.source, ep.target);
            };
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
            const poly = if (bundles.memberships.len == 0)
                try back_edges.backEdgePolyline(a, graph.direction, src_p, dst_p, rail, placements)
            else
                try back_edges.backEdgePolylineAt(a, graph.direction, src_p, dst_p, ep.source, ep.target, rail, placements);
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

        var lane = ep.route_lane;
        var poly: []sketch.Point = undefined;
        while (true) : (lane += 1) {
            poly = if (lane == ep.route_lane and orig.label == null and (ep.source_duplicate or ep.target_duplicate))
                try port_plan.duplicateDetour(a, eff_dir, eff_from_p, eff_to_p, ep, placements)
            else
                try routePolyline(a, eff_dir, eff_from_p, eff_to_p, eff_port_from, eff_port_to, virtuals, geom, placements, 0, 0, lane);
            if (try route_clearance.conflictsRailArrows(a, poly, bar_views, orig.from, orig.to))
                poly = try route_clearance.shiftInteriorRun(a, poly, eff_dir, 2 * (lane - ep.route_lane + 1));
            if (try route_clearance.polylineClears(a, orig.id, orig.kind, poly, out.items, bar_views, placements, allocated_ports.edges, bundles, orig.from, orig.to)) break;
            if (lane >= 16) {
                if (orig.kind == .invisible) {
                    poly = try route_clearance.clearInvisiblePath(a, orig.id, orig.kind, eff_from_p, eff_to_p, ep.source, ep.target, placements, out.items, bundles);
                    break;
                }
                var distance: u32 = 0;
                const limit = route_clearance.detourLimit(out.items.len);
                while (true) : (distance += 1) {
                    poly = try route_clearance.outsideDetour(a, eff_dir, eff_from_p, eff_to_p, eff_port_from, eff_port_to, placements, distance);
                    if ((try route_clearance.polylineClears(a, orig.id, orig.kind, poly, out.items, bar_views, placements, allocated_ports.edges, bundles, orig.from, orig.to)) or distance >= limit) break;
                }
                break;
            }
        }

        const port_from = eff_port_from;
        const port_to = rp.reconcileTerminalSide(poly, eff_to_p, eff_port_to);
        if (!rp.ensureBaseStub(poly, placements, orig.from, orig.to))
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
        });
        try polys.append(a, poly);
    }
    const rail_claims = try fan_provenance.build(a, graph, placements, fans, bundles, out.items, bar_views);
    return .{
        .edges = try out.toOwnedSlice(a),
        .polylines = try polys.toOwnedSlice(a),
        .rails = try rails.toOwnedSlice(a),
        .bundle_sets = try fan_mod.coSets(a, fans),
        .rail_claims = rail_claims,
    };
}

pub fn buildEdges(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
    placements: []const sketch.NodePlacement,
    fans: []const fan_mod.Fan,
) error{OutOfMemory}!EdgesResult {
    return buildEdgesWithPlan(a, graph, lg, geom, placements, fans, .{}, try port_plan.midpoint(a, graph, placements));
}

fn routePolyline(
    a: std.mem.Allocator,
    dir: sg.Direction,
    from_p: sketch.NodePlacement,
    to_p: sketch.NodePlacement,
    port_from: sketch.Port,
    port_to: sketch.Port,
    virtuals: []const u32,
    geom: []const NodeGeom,
    placements: []const sketch.NodePlacement,
    inset_from: i32,
    inset_to: i32,
    route_lane: u32,
) error{OutOfMemory}![]sketch.Point {
    return rp.routePolyline(
        a,
        dir,
        from_p,
        to_p,
        port_from,
        port_to,
        virtuals,
        geom,
        placements,
        inset_from,
        inset_to,
        route_lane,
    );
}

/// Apply the base-approach GROW (routing_terminal.zig) to a freshly-routed
/// terminal and keep it only if the grown geometry still clears the same gates
/// the lane loop enforces — a grown final run can push one cell into a
/// neighbour, so it MUST re-clear. `satisfyApproach` never mutates
/// its input, so reverting to the ungrown polyline on conflict is exact.
/// Returns the grown polyline when it fires and clears, else the original.
fn growBaseApproach(
    a: std.mem.Allocator,
    poly: []sketch.Point,
    placements: []const sketch.NodePlacement,
    edge: sg.Edge,
    existing: []const sketch.EdgePath,
    bar_views: []const sketch.Rail,
    edge_ports: []const port_plan.EdgePorts,
    bundles: ledger.RealizedBundles,
) error{OutOfMemory}![]sketch.Point {
    if (edge.arrow_from != .none) return poly;
    const grown = try rt.satisfyApproach(a, poly, placements);
    if (grown.ptr == poly.ptr) return poly;
    if (try route_clearance.polylineClears(a, edge.id, edge.kind, grown, existing, bar_views, placements, edge_ports, bundles, edge.from, edge.to))
        return grown;
    return poly;
}

test {
    _ = @import("routing_test.zig");
}

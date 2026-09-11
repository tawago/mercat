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
const gap_rows = @import("gap_rows.zig");
const self_loops = @import("routing_self_loops.zig");
const rp = @import("routing_polyline.zig");
const rt = @import("routing_terminal.zig");
const ledger = @import("../base/ledger.zig");
const rail_closure = @import("../base/rail_closure.zig");
const port_plan = @import("port_plan.zig");
const route_clearance = @import("route_clearance.zig");
const route_detour = @import("route_detour.zig");
const route_search = @import("route_search.zig");

/// The lane loops' acceptance, ladder, detour fallback and base-approach
/// grow live in route_search.zig; re-exported for the tests that pin them.
pub const LaneLadder = route_search.LaneLadder;
pub const detour = route_search.detour;
pub const growBaseApproach = route_search.growBaseApproach;
const accepts = route_search.accepts;
const unrouted = route_search.unrouted;

pub const findGraphEdge = rt.findGraphEdge;
pub const findPlacement = rt.findPlacement;
pub const isReversed = rt.isReversed;
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
    /// The gap row ledger every run reads its row from.
    rows: gap_rows.Ledger,
) error{OutOfMemory}!EdgesResult {
    var out: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
    var polys: std.ArrayListUnmanaged([]sketch.Point) = .empty;

    const rail_alloc = try back_edges.allocateBackEdgeRails(a, graph, lg, geom, placements);
    defer a.free(rail_alloc);

    var rails: std.ArrayListUnmanaged(fan_rail.Built) = .empty;
    var claimed: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    const Pending = struct { fan: fan_mod.Fan, resolved: fan_rail.Resolved, lift: u32 };
    var pending: std.ArrayListUnmanaged(Pending) = .empty;
    for (fans) |f| {
        const resolved = (try fan_rail.resolve(a, graph.direction, f, graph, placements, geom, bundles, allocated_ports)) orelse continue;
        // Shared-rail lift: same rule as the per-peer path below — any peer descending into a cluster lifts the rail above the frame. // @guarded-by: routing_test.zig "rail pre-pass and forced per-peer path lift the same fan-OUT geometry to the same rail row"
        var lift: u32 = 0;
        for (resolved.peers) |p| {
            lift = @max(lift, fanRailLift(graph, p.edge.from, p.edge.to));
        }
        try pending.append(a, .{ .fan = f, .resolved = resolved, .lift = lift });
    }
    // A member long at both ends taps its two rails on ONE column — the
    // departure's — so its stroke between them is one straight run.
    // @guarded-by: port_plan_test.zig "a member long at both ends runs straight between its two taps"
    for (pending.items) |p| {
        if (p.resolved.direction != .out) continue;
        for (p.resolved.peers) |peer| {
            if (!peer.long) continue;
            for (pending.items) |q| {
                if (q.resolved.direction != .in) continue;
                for (q.resolved.peers) |*other| if (other.long and other.edge.id == peer.edge.id) {
                    other.column = peer.column;
                };
            }
        }
    }
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
        for (pending.items, 0..) |p, pi| {
            if (p.resolved.peers.len < 2) continue;
            // The rail's row is the ledger's — the row its members' per-peer fallback reads too.
            const row = rows.rowOfFan(p.fan.pivot_idx, p.fan.direction) orelse 0;
            const built = try fan_rail.build(a, p.resolved, p.lift, @intCast(@max(row, 0)));
            // Integrity gate: a rail is straight-only geometry; if any run touches a foreign box, fall back to the per-peer polyline path, which can dodge. // @guarded-by: fan_rail_test.zig "fan_rail.blocked rejects a built rail whose tap drop touches a foreign node's box"
            if (fan_rail.blocked(built, p.resolved.pivot.id, placements)) continue;
            // A rail is laid before every private route, so it must honour the
            // terminal cells those routes' ports reserve (a foreign decorated
            // cell and its laterals) or yield to the per-peer path.
            // @guarded-by: route_clearance_test.zig "a rail honours a foreign decorated terminal's reservation and ignores its own members'"
            if (try route_clearance.railConflictsReservedTerminals(a, built.rail, placements, allocated_ports.edges, bundles)) continue;
            try rails.append(a, built);
            try rail_pending.append(a, pi);
        }
        bar_views = try a.alloc(sketch.Rail, rails.items.len);
        for (rails.items, bar_views) |rail, *view| view.* = rail.rail;
        const reserved = try a.alloc(i32, rail_alloc.len);
        for (rail_alloc, reserved) |r, *x| x.* = r.rail_pos;
        const refused = try member_stroke.buildAll(a, graph, lg, geom, placements, rails.items, bar_views, bundles, allocated_ports, reserved, rows, &out, &polys);
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

    // A placement edge's ink is the bridges': it is routed last, once, and
    // without contest, so it never blocks a run the stitch will keep and
    // never detours into the margin.
    // @guarded-by: routing_test.zig "a placement edge routes last and uncontested"
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
                const rail_lift: u32 = if (hit.fan.direction == .out)
                    fanRailLift(graph, orig.from, orig.to)
                else
                    0;
                // The member's run sits on the row the ledger gave its fan — the
                // same row the rail pre-pass would have painted — so the lane
                // ladder starts there, climbs when the row is refused, and
                // descends to the base row before the outside detour. A dodge
                // under the pivot takes the row the ledger gave the fan's jog.
                // @guarded-by: routing_test.zig "the lane ladder climbs from the planned lane, then descends to lane 0, then ends"
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
                        try fan_polyline.buildPolylineAt(a, graph.direction, routed_fan, pivot_p, peer_p, ep.source, ep.target, routed_role, lane, rail_lift, dodge_y, placements, straight);
                    if (proxy or try accepts(a, orig, poly, straight, out.items, bar_views, placements, allocated_ports.edges, bundles)) break;
                    if (ladder.next()) continue;
                    poly = if (orig.kind == .invisible)
                        try route_detour.clearInvisiblePath(a, orig.id, orig.kind, src_p, dst_p, ep.source, ep.target, placements, out.items, bundles)
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
                });
                try polys.append(a, poly);
                continue;
            };
        }
        if (orig.from == orig.to) {
            const node_p = findPlacement(placements, orig.from);
            // A planned self loop walks its candidate ladder through the same
            // acceptance as every other route (route_search.selfLoop).
            const sl: self_loops.SelfLoop = if (bundles.memberships.len == 0)
                try self_loops.selfLoop(a, graph.direction, node_p, placements)
            else
                try route_search.selfLoop(a, graph.direction, orig, node_p, allocated_ports.forEdge(orig.id) orelse unreachable, out.items, bar_views, placements, allocated_ports.edges, bundles);
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
            // A back edge's stub hop searches clear lines against boxes
            // only; the decorated terminal cells other edges reserved join
            // that search as pseudo-boxes so the hop never runs a head.
            // @guarded-by: routing_test.zig "a back edge's stub hop keeps off a foreign decorated arrival cell"
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

        // The route's runs take the rows the ledger gave them; the ladder
        // starts at the exit run's lane, and the entry run keeps its own
        // row — the two are independent claims.
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
                try route_detour.clearInvisiblePath(a, orig.id, orig.kind, eff_from_p, eff_to_p, ep.source, ep.target, placements, out.items, bundles)
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

/// The line a fan-OUT member's dodge jog takes under its pivot: the row
/// the ledger gave the fan's jog, counted from the wall of the gap it
/// claimed it in — an inter-layer gap's wall is its lower layer's top, a
/// grid sub-gap's the stacked sub-row's.
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

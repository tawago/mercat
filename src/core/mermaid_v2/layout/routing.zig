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
const fan_polyline = @import("fan_polyline.zig");
const fan_busbar = @import("fan_busbar.zig");
const self_loops = @import("routing_self_loops.zig");
const rp = @import("routing_polyline.zig");
const rt = @import("routing_terminal.zig");
const ledger = @import("../base/ledger.zig");
const port_plan = @import("port_plan.zig");
const route_clearance = @import("route_clearance.zig");

/// Per-gap extra rows for skip-edge corridors. See routing_polyline.zig.
pub const skipCorridorExtraRows = rp.skipCorridorExtraRows;

/// Per-gap extra rows for offset corner-fed forward terminals. See
/// routing_terminal.zig.
pub const terminalApproachExtraRows = rt.terminalApproachExtraRows;

// Graph/placement lookup + perimeter-port + arrow-mapping helpers live in
// routing_terminal.zig; re-export them so both this file's call sites and
// external importers (fan_busbar.zig, back_edges.zig, ports_test.zig) address
// them unchanged.
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
    /// First-class fan trunks, each holding its
    /// `sketch.BusBar` plus the MUTABLE tap view so `clusters.computeBbox`'s
    /// shift pass can translate rail + tap points in place (stems are
    /// additionally registered in `polylines` for the same reason). layout.zig
    /// copies the `.busbar` fields out AFTER the shift for the final Sketch.
    busbars: []fan_busbar.Built,
};

pub fn buildEdgesWithPlan(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
    placements: []const sketch.NodePlacement,
    fans: []const fan_mod.Fan,
    joins: ledger.RealizedJoins,
    allocated_ports: port_plan.Plan,
    /// Only true on the `chain_wrap` rung; enables the serpentine band-return route for left-and-below forward edges. guarded-by: budget.zig "chain_wrap rung sets the serpentine flag; sibling rungs do not"
    chain_wrap: bool,
) error{OutOfMemory}!EdgesResult {
    var out: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
    var polys: std.ArrayListUnmanaged([]sketch.Point) = .empty;

    const rail_alloc = try back_edges.allocateBackEdgeRails(a, graph, lg, geom, placements);
    defer a.free(rail_alloc);

    // Bus-bar pre-pass: every ELIGIBLE single-row fan-OUT becomes ONE
    // sketch.BusBar; its member edges are claimed and emit no EdgePath
    // below. Grid fans / fan-IN / mixed-arrow or mixed-kind fans fall
    // through to the per-peer polyline path.
    var busbars: std.ArrayListUnmanaged(fan_busbar.Built) = .empty;
    var claimed: std.ArrayListUnmanaged(sg.EdgeId) = .empty;
    for (fans) |f| {
        const resolved = (try fan_busbar.resolve(a, graph.direction, f, graph, placements, joins, allocated_ports)) orelse continue;
        // Shared-rail lift: same rule as the per-peer path below — any peer descending into a cluster lifts the rail above the frame. // guarded-by: routing_test.zig "bus-bar pre-pass and forced per-peer path lift the same fan-OUT geometry to the same rail row"
        var lift: u32 = 0;
        for (resolved.peers) |p| {
            lift = @max(lift, fanRailLift(graph, p.edge.from, p.edge.to));
        }
        const built = try fan_busbar.build(a, resolved, lift, f.lane);
        // Integrity gate: a bus-bar is straight-only geometry; if any run touches a foreign box, fall back to the per-peer polyline path, which can dodge. // guarded-by: fan_busbar_test.zig "fan_busbar.blocked rejects a built bus-bar whose tap drop touches a foreign node's box"
        if (fan_busbar.blocked(built, resolved.pivot.id, placements)) continue;
        try busbars.append(a, built);
        try polys.append(a, built.stem);
        for (f.peers) |p| try claimed.append(a, p.edge_id);
    }
    const bar_views = try a.alloc(sketch.BusBar, busbars.items.len);
    for (busbars.items, bar_views) |bar, *view| view.* = bar.busbar;

    var routing_edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    if (joins.memberships.len == 0) {
        try routing_edges.appendSlice(a, graph.edges);
    } else {
        for (graph.edges) |edge| if (edge.kind != .invisible and !route_clearance.isIndependent(edge.id, joins)) try routing_edges.append(a, edge);
        for (graph.edges) |edge| if (edge.kind != .invisible and route_clearance.isIndependent(edge.id, joins)) try routing_edges.append(a, edge);
        for (graph.edges) |edge| if (edge.kind == .invisible) try routing_edges.append(a, edge);
    }
    for (routing_edges.items) |orig| {
        // Edge owned by a bus-bar: its sole geometry is the trunk + tap.
        if (std.mem.indexOfScalar(sg.EdgeId, claimed.items, orig.id) != null) continue;
        // Decision-fan path: if this edge belongs to a detected fan,
        // synthesize the coordinated polyline that shares a rail row
        // with its siblings (see layout/fan.zig).
        if (orig.from != orig.to) {
            if (fan_mod.lookup(fans, orig.id)) |hit| {
                const ep = allocated_ports.forEdge(orig.id) orelse unreachable;
                const src_p = findPlacement(placements, orig.from);
                const dst_p = findPlacement(placements, orig.to);
                // For fan-OUT: pivot = source; for fan-IN: pivot = target.
                const pivot_p = if (hit.fan.direction == .out) src_p else dst_p;
                const peer_p = if (hit.fan.direction == .out) dst_p else src_p;
                // Lift the rail above any cluster frame-border row it would otherwise be painted along (fusing sibling peers' top borders). // guarded-by: routing_test.zig "fan-OUT per-peer rail lifts exactly one row for the peer crossing into a cluster its source is not part of"
                const rail_lift: u32 = if (hit.fan.direction == .out)
                    fanRailLift(graph, orig.from, orig.to)
                else
                    0;
                var lane = @max(hit.peer.lane, ep.route_lane);
                var poly: []sketch.Point = undefined;
                while (true) : (lane += 1) {
                    poly = try fan_polyline.buildPolylineAt(
                        a,
                        graph.direction,
                        hit.fan.*,
                        pivot_p,
                        peer_p,
                        ep.source,
                        ep.target,
                        hit.peer.role,
                        lane,
                        rail_lift,
                        placements,
                    );
                    if (try route_clearance.polylineClears(a, orig.id, orig.kind, poly, out.items, bar_views, placements, allocated_ports.edges, joins, orig.from, orig.to)) break;
                    if (lane >= 16) {
                        if (orig.kind == .invisible) {
                            poly = try route_clearance.clearInvisiblePath(a, orig.id, orig.kind, src_p, dst_p, ep.source, ep.target, placements, out.items, joins);
                            break;
                        }
                        var distance: u32 = 0;
                        while (true) : (distance += 1) {
                            poly = try route_clearance.outsideDetour(a, graph.direction, src_p, dst_p, ep.source, ep.target, placements, distance);
                            if ((try route_clearance.polylineClears(a, orig.id, orig.kind, poly, out.items, bar_views, placements, allocated_ports.edges, joins, orig.from, orig.to)) or distance >= 64) break;
                        }
                        break;
                    }
                }
                // Base-approach GROW is deliberately NOT wired on the fan
                // per-peer path: a fan peer's second vertex is its point on the
                // SHARED rail row, so pulling a corner-fed tap back one cell
                // lifts only that peer's rail segment and de-syncs it from its
                // siblings (a visible rail break). Fixing a corner-fed fan tap
                // needs coordinated, rail-aware handling that cannot be done
                // per-peer without a spare row — out of scope for this
                // zero-height tranche. Forward + back-edge terminals are grown
                // below/above; fan taps stay a report-only residual.
                const role: sketch.EdgeRole = if (hit.fan.direction == .out)
                    .fan_out_rail
                else
                    .fan_in_rail;
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
            }
        }
        // Self-loop: bypass the layered router entirely. The Sugiyama
        // pipeline produces a degenerate layer edge (from==to, span=0),
        // which would otherwise yield a polyline that overlaps the node
        // body. Goldens render self-loops as a "lollipop" detour above
        // and to the right of the node, so we synthesize that path here.
        if (orig.from == orig.to) {
            const node_p = findPlacement(placements, orig.from);
            const sl = if (joins.memberships.len == 0)
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

        // Reversed edges become "back edges" that loop UNDER (LR) or
        // BESIDE (TD) the node row. We synthesize a dedicated U-shape
        // polyline rather than routing through the layered graph.
        if (reversed) {
            const rail = back_edges.findRail(rail_alloc, orig.id);
            const src_p = findPlacement(placements, orig.from);
            const dst_p = findPlacement(placements, orig.to);
            const ep = allocated_ports.forEdge(orig.id) orelse unreachable;
            const poly = if (joins.memberships.len == 0)
                try back_edges.backEdgePolyline(a, graph.direction, src_p, dst_p, rail, placements)
            else
                try back_edges.backEdgePolylineAt(a, graph.direction, src_p, dst_p, ep.source, ep.target, rail, placements);
            const port_from = if (joins.memberships.len == 0) back_edges.backEdgePortFrom(graph.direction, src_p) else ep.source;
            const port_to = if (joins.memberships.len == 0) back_edges.backEdgePortTo(graph.direction, dst_p) else ep.target;
            // Base-approach GROW is NOT wired on the back-edge path: a back edge's
            // U-shape (and the bidirectional case, where BOTH ends carry an
            // arrow) breaks the "clean perpendicular final approach" the grow
            // assumes, and pulling a loop corner can flip the terminal's
            // direction. Only ensureBaseStub's in-place length-1 shift applies
            // here; corner-fed back-edge terminals stay a report-only residual.
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

        // The layered graph routes from eff_from to eff_to. If the edge
        // was reversed during cycle removal, the layered source is the
        // original target and vice versa.
        const eff_from: sg.NodeId = if (reversed) orig.to else orig.from;
        const eff_to: sg.NodeId = if (reversed) orig.from else orig.to;

        const eff_from_p = findPlacement(placements, eff_from);
        const eff_to_p = findPlacement(placements, eff_to);

        const virtuals = try collectVirtuals(a, lg, orig.id);
        defer a.free(virtuals);

        // Same-subgraph edges never reach this router: a subgraph is laid
        // out as its own flowchart by the cluster/ recursion, so every edge
        // here is between top-level (cluster-free) nodes; routing uses the
        // global direction with on-perimeter endpoints.
        const eff_dir: sg.Direction = graph.direction;

        const ep = allocated_ports.forEdge(orig.id) orelse unreachable;
        const eff_port_from = ep.source;
        const eff_port_to = ep.target;

        var lane = ep.route_lane;
        var poly: []sketch.Point = undefined;
        while (true) : (lane += 1) {
            poly = try routePolyline(
                a,
                eff_dir,
                eff_from_p,
                eff_to_p,
                eff_port_from,
                eff_port_to,
                virtuals,
                geom,
                placements,
                0,
                0,
                lane,
                chain_wrap,
            );
            if (!route_clearance.hasIndependent(joins) and try route_clearance.conflictsBusBarArrows(a, poly, bar_views, orig.from, orig.to))
                poly = try route_clearance.shiftInteriorRun(a, poly, eff_dir, 2 * (lane - ep.route_lane + 1));
            if (try route_clearance.polylineClears(a, orig.id, orig.kind, poly, out.items, bar_views, placements, allocated_ports.edges, joins, orig.from, orig.to)) break;
            if (lane >= 16) {
                if (orig.kind == .invisible) {
                    poly = try route_clearance.clearInvisiblePath(a, orig.id, orig.kind, eff_from_p, eff_to_p, ep.source, ep.target, placements, out.items, joins);
                    break;
                }
                var distance: u32 = 0;
                while (true) : (distance += 1) {
                    poly = try route_clearance.outsideDetour(a, eff_dir, eff_from_p, eff_to_p, eff_port_from, eff_port_to, placements, distance);
                    if ((try route_clearance.polylineClears(a, orig.id, orig.kind, poly, out.items, bar_views, placements, allocated_ports.edges, joins, orig.from, orig.to)) or distance >= 64) break;
                }
                break;
            }
        }

        const port_from = eff_port_from;
        // Snap the terminal port to the side the final leg actually enters
        // from: an obstacle-dodging interior shift can leave the approach on
        // the OPPOSITE side of the allocated port, piercing the box. See
        // rp.reconcileTerminalSide (guarded there).
        const port_to = rp.reconcileTerminalSide(poly, eff_to_p, eff_port_to);
        // Base-approach: shift a length-1 turn-at-tip in place (byte-identical),
        // else GROW a corner-fed length-2 final into a formal straight base.
        if (!rp.ensureBaseStub(poly, placements, orig.from, orig.to))
            poly = try growBaseApproach(a, poly, placements, orig, out.items, bar_views, allocated_ports.edges, joins);

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
    return .{
        .edges = try out.toOwnedSlice(a),
        .polylines = try polys.toOwnedSlice(a),
        .busbars = try busbars.toOwnedSlice(a),
    };
}

pub fn buildEdges(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
    placements: []const sketch.NodePlacement,
    fans: []const fan_mod.Fan,
    chain_wrap: bool,
) error{OutOfMemory}!EdgesResult {
    return buildEdgesWithPlan(a, graph, lg, geom, placements, fans, .{}, try port_plan.midpoint(a, graph, placements), chain_wrap);
}

// Polyline routing: delegates to routing_polyline.zig.
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
    chain_wrap: bool,
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
        chain_wrap,
    );
}

// Self-loop geometry: see routing_self_loops.zig (`self_loops.selfLoop`,
// called directly at the self-loop branch above).

/// Apply the base-approach GROW (routing_terminal.zig) to a freshly-routed
/// terminal and keep it only if the grown geometry still clears the same gates
/// the lane loop enforces — a grown final run can push one cell into a
/// neighbour, so it MUST re-clear. `ensureBaseApproachLengthen` never mutates
/// its input, so reverting to the ungrown polyline on conflict is exact.
/// Returns the grown polyline when it fires and clears, else the original.
fn growBaseApproach(
    a: std.mem.Allocator,
    poly: []sketch.Point,
    placements: []const sketch.NodePlacement,
    edge: sg.Edge,
    existing: []const sketch.EdgePath,
    bar_views: []const sketch.BusBar,
    edge_ports: []const port_plan.EdgePorts,
    joins: ledger.RealizedJoins,
) error{OutOfMemory}![]sketch.Point {
    // A source-side arrowhead means BOTH ends of the polyline are terminals
    // (a bidirectional or reverse-arrow edge); which end is poly[last] is then
    // ambiguous, and growing one end can re-route the whole edge. Restrict the
    // grow to pure single-target terminals.
    if (edge.arrow_from != .none) return poly;
    const grown = try rt.ensureBaseApproachLengthen(a, poly, placements);
    if (grown.ptr == poly.ptr) return poly; // did not fire
    if (try route_clearance.polylineClears(a, edge.id, edge.kind, grown, existing, bar_views, placements, edge_ports, joins, edge.from, edge.to))
        return grown;
    return poly; // grown geometry conflicts — revert to the ungrown route
}

test {
    _ = @import("routing_test.zig");
}

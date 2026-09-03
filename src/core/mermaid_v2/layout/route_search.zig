//! The search every lane loop in `routing.zig` runs: the acceptance a
//! candidate polyline must pass (`accepts`), the order of lanes a forward
//! route tries (`LaneLadder`), the outside-detour ladder it falls to
//! (`detour`), the no-ink result when that ladder ends (`unrouted`), and
//! the base-approach grow re-cleared through the same acceptance
//! (`growBaseApproach`). Split from `routing.zig` (500-line cap); the
//! loops themselves stay there.
//!
//! Imports (layout zone): std, sem_graph, sketch, base/ledger, siblings.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const port_plan = @import("port_plan.zig");
const route_clearance = @import("route_clearance.zig");
const route_detour = @import("route_detour.zig");
const rp = @import("routing_polyline.zig");
const rt = @import("routing_terminal.zig");
const self_loops = @import("routing_self_loops.zig");

/// The lane order a forward route tries: its planned lane and every lane
/// above it, then the lanes below it nearest first. The plan's lane keeps
/// a gap's runs apart but is a preference, not a licence: a neighbour's
/// base-approach grow may have taken the planned row, and a route that
/// clears nowhere above may still clear below. The outside detour stays
/// the last resort.
/// @guarded-by: routing_test.zig "the lane ladder climbs from the planned lane, then descends to lane 0, then ends"
pub const LaneLadder = struct {
    planned: u32,
    lane: u32,
    descending: bool = false,

    /// Advance to the next lane; false when every lane was tried.
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

/// The exact break condition of every lane loop: the route keeps each
/// decorated terminal cell straight AND clears every clearance gate.
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
        try route_clearance.polylineClears(a, edge.id, edge.kind, poly, existing, bar_views, placements, edge_ports, bundles, edge.from, edge.to);
}

/// The outside-detour ladder every lane loop falls to: widen until a
/// detour is accepted, trying at each distance every push of the two
/// port-adjacent runs (`route_detour.Rows`), and null when the search
/// limit is reached with nothing accepted. A refused candidate is never
/// shipped: the reservation and straight-through gates refuse exactly the
/// ink that would lie collinear with a foreign run, bend beside a head, or
/// turn in a decoration cell, and shipping it anyway converts the refusal
/// into a fabricated junction. The edge goes unrouted instead (`unrouted`).
/// @guarded-by: routing_test.zig "the detour ladder pushes a port run past a foreign jog row, and is null when every row is taken"
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

/// A planned self loop's search: walk `routing_self_loops.loopCandidate`'s
/// ladder and ship the first candidate that keeps out of every foreign box
/// and passes the acceptance every other route passes. Box termination is
/// checked here with or without a realized plan — the plan-aware gates
/// stand down on a candidate with no memberships, and a loop lifted past
/// its own gap can otherwise run through the layer above. None clearing,
/// the loop goes unrouted like a forward route whose detour ladder ends.
/// @guarded-by: routing_test.zig "a self loop lifts past foreign ink instead of lying along it"
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

/// The geometry of an edge no producer could lay legally: no ink. The
/// edge keeps its record (ends, ports, decoration, label) so the sketch
/// still declares it; the validator counts it (`edge_unrouted`), the
/// raster draws nothing for it, and the relation's absence surfaces as its
/// own defect — honest degradation, never a lying route.
/// @guarded-by: validate_test.zig "an edge with no polyline counts as unrouted, not off-perimeter"
pub fn unrouted(a: std.mem.Allocator) error{OutOfMemory}![]sketch.Point {
    return a.alloc(sketch.Point, 0);
}

/// Apply the base-approach GROW (routing_terminal.zig) to a freshly-routed
/// terminal and keep it only if the grown geometry still clears the same gates
/// the lane loop enforces — a grown final run can push one cell into a
/// neighbour, and pulling the jog toward the source can shorten the first
/// leg into a decorated departure cell, so it MUST re-clear through the
/// same acceptance (straight terminals, then clearance). `satisfyApproach`
/// never mutates its input, so reverting to the ungrown polyline is exact.
/// Returns the grown polyline when it fires and is accepted, else the original.
/// @guarded-by: routing_test.zig "the base-approach grow is reverted when it would bend a decorated departure cell"
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


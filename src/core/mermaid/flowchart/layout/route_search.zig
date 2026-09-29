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

/// @guarded-by: routing_test.zig "the lane ladder climbs from the planned lane, then descends to lane 0, then ends"
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

/// @guarded-by: validate_test.zig "an edge with no polyline counts as unrouted"
pub fn unrouted(a: std.mem.Allocator) error{OutOfMemory}![]sketch.Point {
    return a.alloc(sketch.Point, 0);
}

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

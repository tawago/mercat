//! Cross-bundle vector clearance for candidate edge routes.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");

const Cell = struct { x: i32, y: i32 };
const Pass = struct {
    horizontal: bool = false,
    vertical: bool = false,
    bend: bool = false,

    fn merge(self: *Pass, other: Pass) void {
        self.horizontal = self.horizontal or other.horizontal;
        self.vertical = self.vertical or other.vertical;
        self.bend = self.bend or other.bend;
    }
};

const CellMap = std.AutoArrayHashMapUnmanaged(Cell, Pass);

/// True when `polyline` has a non-transversal cell contact with an existing
/// edge from another ownership bundle.
pub fn conflicts(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    kind: sk.EdgeKind,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    bundles: pb.RealizedBundles,
) error{OutOfMemory}!bool {
    _ = kind;
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (existing) |other| {
        if (other.kind == .invisible) continue;
        if (sameBundle(edge, other.id, bundles)) continue;
        var occupied = try cells(a, other.polyline);
        defer occupied.deinit(a);
        for (candidate.keys()) |cell| {
            const theirs = occupied.get(cell) orelse continue;
            if (arrowCell(other, cell)) return true;
            if (!transversal(candidate.get(cell).?, theirs)) return true;
        }
    }
    return false;
}

pub fn conflictsRails(a: std.mem.Allocator, polyline: []const sk.Point, rails: []const sk.Rail) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (rails) |rail| {
        if (try conflictsPolyline(a, candidate, rail.stem, rail.pivot_arrow != .none, false)) return true;
        if (try conflictsPolyline(a, candidate, &rail.crossbar, false, false)) return true;
        for (rail.taps) |tap| {
            const segment = [_]sk.Point{ tap.at, tap.landing };
            if (try conflictsPolyline(a, candidate, &segment, false, tap.arrow != .none)) return true;
        }
    }
    return false;
}

pub fn conflictsRailArrows(a: std.mem.Allocator, polyline: []const sk.Point, rails: []const sk.Rail, from: pb.NodeId, to: pb.NodeId) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (rails) |rail| {
        for (candidate.keys()) |cell| {
            if ((rail.pivot == from or rail.pivot == to) and rail.pivot_arrow != .none and arrowPoint(rail.stem, cell, true, false)) return true;
            for (rail.taps) |tap| {
                if (tap.node != from and tap.node != to) continue;
                const segment = [_]sk.Point{ tap.at, tap.landing };
                if (tap.arrow != .none and arrowPoint(&segment, cell, false, true)) return true;
            }
        }
    }
    return false;
}

pub fn conflictsRailJunctions(a: std.mem.Allocator, polyline: []const sk.Point, rails: []const sk.Rail) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (rails) |rail| {
        if (rail.stem.len != 0) {
            const pivot = rail.stem[rail.stem.len - 1];
            if (candidate.contains(.{ .x = pivot.x, .y = pivot.y })) return true;
        }
        for (rail.taps) |tap| {
            if (candidate.contains(.{ .x = tap.at.x, .y = tap.at.y })) return true;
        }
    }
    return false;
}

pub fn conflictsReservedDepartures(a: std.mem.Allocator, edge: pb.EdgeId, polyline: []const sk.Point, placements: []const sk.NodePlacement, edge_ports: anytype, bundles: pb.RealizedBundles) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (edge_ports) |item| {
        if (item.edge == edge) continue;
        // A selected rail's members share one departure by design (attribution-only
        // merged ink), so they must not reserve departures against each other.
        // guarded-by: route_clearance_test.zig "reserved departures exempt same selected rail"
        if (sameBundle(edge, item.edge, bundles)) continue;
        // A discharged edge's entire rendering IS a rail span: it owns no
        // polyline and no port, so its port allocation reserves nothing.
        // guarded-by: route_clearance_test.zig "a discharged edge's port allocation reserves no departure"
        if (contains(bundles.discharged, item.edge)) continue;
        const placement = placementById(placements, item.source.node) orelse continue;
        const point = offNodePoint(placement, item.source);
        const theirs = candidate.get(.{ .x = point.x, .y = point.y }) orelse continue;
        // A decorated departure cell holds the reserved edge's source-end
        // decoration; decoration ink blocks ALL foreign transit — a
        // through-run there ships as an arrowhead transit.
        // guarded-by: route_clearance_test.zig "a decorated departure cell blocks even a perpendicular crossing"
        if (item.source_decorated) return true;
        // An undecorated reservation follows the plain-run obstacle model:
        // only collinear occupancy (or a bend lingering in the cell) claims
        // the departure; a perpendicular through-run is a legal crossing.
        // guarded-by: route_clearance_test.zig "a reserved departure blocks collinear occupancy and admits a perpendicular crossing"
        var departure: Pass = .{};
        switch (item.source.side) {
            .north, .south => departure.vertical = true,
            .west, .east => departure.horizontal = true,
        }
        if (!transversal(theirs, departure)) return true;
    }
    return false;
}

fn placementById(placements: []const sk.NodePlacement, id: pb.NodeId) ?sk.NodePlacement {
    for (placements) |placement| if (placement.id == id) return placement;
    return null;
}

fn offNodePoint(placement: sk.NodePlacement, port: sk.Port) sk.Point {
    const point = portPoint(placement, port);
    return switch (port.side) {
        .north => .{ .x = point.x, .y = point.y - 1 },
        .south => .{ .x = point.x, .y = point.y + 1 },
        .west => .{ .x = point.x - 1, .y = point.y },
        .east => .{ .x = point.x + 1, .y = point.y },
    };
}

fn conflictsPolyline(a: std.mem.Allocator, candidate: CellMap, points: []const sk.Point, arrow_from: bool, arrow_to: bool) error{OutOfMemory}!bool {
    var occupied = try cells(a, points);
    defer occupied.deinit(a);
    for (candidate.keys()) |cell| {
        const theirs = occupied.get(cell) orelse continue;
        if ((arrow_from or arrow_to) and arrowPoint(points, cell, arrow_from, arrow_to)) return true;
        if (!transversal(candidate.get(cell).?, theirs)) return true;
    }
    return false;
}

/// True when a candidate either shares a non-transversal cell with another
/// ownership bundle or touches a foreign node, including its border cells.
pub fn blocked(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    kind: sk.EdgeKind,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    bundles: pb.RealizedBundles,
    placements: []const sk.NodePlacement,
    from: pb.NodeId,
    to: pb.NodeId,
) error{OutOfMemory}!bool {
    if (touchesForeignNode(polyline, placements, from, to)) return true;
    return conflicts(a, edge, kind, polyline, existing, bundles);
}

pub fn isIndependent(edge: pb.EdgeId, bundles: pb.RealizedBundles) bool {
    for (bundles.memberships) |membership| {
        if (membership.edge != edge) continue;
        inline for ([2]?pb.MembershipDisposition{ membership.source, membership.target }) |disposition| {
            if (disposition) |value| if (value == .independent) return true;
        }
        return false;
    }
    return false;
}

/// True iff `polyline` clears every gate the forward/fan lane loop uses to
/// ACCEPT a route — the exact break condition inlined at those loops. Callers
/// that MUTATE a polyline after routing (the base-approach GROW in
/// routing_terminal.zig) use this to re-validate the mutated geometry against
/// rails and independent-bundle reservations, reverting to the ungrown route
/// on failure. When there are no realized bundles there is nothing to clear —
/// no rails, no junctions, no bundle-attributed reservations — so it returns
/// true (the plain non-bundle path is cleared by the route builders themselves).
/// All four gates run unconditionally: foreign-node/cross-bundle contact
/// (T1/I2), rail junctions (I2: unrelated ink over an owner-set change),
/// rail arrowheads, and reserved departures are independent legality facts,
/// never alternatives.
/// guarded-by: routing_terminal_test.zig "satisfyApproach grows a corner-fed len-2 final into a straight base approach"
/// guarded-by: route_clearance_test.zig "polylineClears refuses every clearance violation regardless of membership disposition"
pub fn polylineClears(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    kind: sk.EdgeKind,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    rails: []const sk.Rail,
    placements: []const sk.NodePlacement,
    edge_ports: anytype,
    bundles: pb.RealizedBundles,
    from: pb.NodeId,
    to: pb.NodeId,
) error{OutOfMemory}!bool {
    if (bundles.memberships.len == 0) return true;
    return !try blocked(a, edge, kind, polyline, existing, bundles, placements, from, to) and
        !try conflictsRailJunctions(a, polyline, rails) and
        !try conflictsRailArrows(a, polyline, rails, from, to) and
        !try conflictsReservedDepartures(a, edge, polyline, placements, edge_ports, bundles);
}

/// How far the outside-detour search may widen before it gives up.
///
/// Each step pushes the detour one cell further outside every placement, and
/// the canvas bbox grows with it, so a search that never clears is billed for
/// every step it took. What it dodges is the paths already routed: with
/// `routed` of them and two sides to alternate between, `2 * routed + 2`
/// tracks exhaust every distinct answer widening can give — past that the
/// walk is only buying frame. The absolute ceiling stays 64 so a pathological
/// graph cannot make it quadratic.
///
/// This bound is why one unroutable edge in a complete undirected mesh no
/// longer drags ~60 empty rows of frame around the whole diagram.
/// guarded-by: route_clearance_test.zig "the detour search widens once per already-routed path, never past the ceiling"
pub fn detourLimit(routed: usize) u32 {
    const want = 2 * @as(u64, routed) + 2;
    return @intCast(@min(want, 64));
}

/// A clear line for a detour's port-adjacent run. No box is exempt — the
/// route's OWN boxes terminate it too (T1: a box is a terminus, never a
/// corridor); the only legal own-box footprint is the port cell itself,
/// which sits one cell before `want` and off the searched line. The result
/// is also confined to the port's outward half-plane, so the perpendicular
/// leg from the port can never run back through the box; when nothing on
/// that side is clear, `want` (the first off-box line) stands.
/// guarded-by: route_clearance_test.zig "a detour's port run never crosses the route's own box"
fn offSideClearLine(horizontal: bool, want: i32, lo: i32, hi: i32, placements: []const sk.NodePlacement, outward: i32) i32 {
    const none = std.math.maxInt(pb.NodeId);
    const found = sk.clearLine(horizontal, want, lo, hi, placements, none, none, .{});
    return if ((found - want) * outward >= 0) found else want;
}

/// Route around the outside of the placed diagram when all local gap lanes
/// are occupied. The first and last legs remain perpendicular to the ports.
pub fn outsideDetour(
    a: std.mem.Allocator,
    direction: sg.Direction,
    from: sk.NodePlacement,
    to: sk.NodePlacement,
    port_from: sk.Port,
    port_to: sk.Port,
    placements: []const sk.NodePlacement,
    distance: u32,
) error{OutOfMemory}![]sk.Point {
    const start = portPoint(from, port_from);
    const end = portPoint(to, port_to);
    var min_x = @min(start.x, end.x);
    var min_y = @min(start.y, end.y);
    var max_x = @max(start.x, end.x);
    var max_y = @max(start.y, end.y);
    for (placements) |placement| {
        min_x = @min(min_x, placement.rect.x);
        min_y = @min(min_y, placement.rect.y);
        max_x = @max(max_x, placement.rect.right() - 1);
        max_y = @max(max_y, placement.rect.bottom() - 1);
    }
    const offset: i32 = @intCast(distance + 2);
    const points = try a.alloc(sk.Point, 6);
    if (direction == .TD or direction == .BT) {
        const outside_x = if (distance % 2 == 0) min_x - offset else max_x + offset;
        const source_want = start.y + (if (port_from.side == .south) @as(i32, 1) else -1);
        const target_want = end.y + (if (port_to.side == .north) @as(i32, -1) else 1);
        const source_y = offSideClearLine(true, source_want, @min(outside_x, start.x), @max(outside_x, start.x), placements, if (port_from.side == .south) 1 else -1);
        const target_y = offSideClearLine(true, target_want, @min(outside_x, end.x), @max(outside_x, end.x), placements, if (port_to.side == .north) -1 else 1);
        @memcpy(points, &[_]sk.Point{
            start,
            .{ .x = start.x, .y = source_y },
            .{ .x = outside_x, .y = source_y },
            .{ .x = outside_x, .y = target_y },
            .{ .x = end.x, .y = target_y },
            end,
        });
    } else {
        const outside_y = if (distance % 2 == 0) min_y - offset else max_y + offset;
        const source_want = start.x + (if (port_from.side == .east) @as(i32, 1) else -1);
        const target_want = end.x + (if (port_to.side == .west) @as(i32, -1) else 1);
        const source_x = offSideClearLine(false, source_want, @min(outside_y, start.y), @max(outside_y, start.y), placements, if (port_from.side == .east) 1 else -1);
        const target_x = offSideClearLine(false, target_want, @min(outside_y, end.y), @max(outside_y, end.y), placements, if (port_to.side == .west) -1 else 1);
        @memcpy(points, &[_]sk.Point{
            start,
            .{ .x = source_x, .y = start.y },
            .{ .x = source_x, .y = outside_y },
            .{ .x = target_x, .y = outside_y },
            .{ .x = target_x, .y = end.y },
            end,
        });
    }
    return points;
}

pub fn dogleg(
    a: std.mem.Allocator,
    from: sk.NodePlacement,
    to: sk.NodePlacement,
    port_from: sk.Port,
    port_to: sk.Port,
    via: i32,
    vertical_middle: bool,
) error{OutOfMemory}![]sk.Point {
    const start = portPoint(from, port_from);
    const end = portPoint(to, port_to);
    const points = try a.alloc(sk.Point, 4);
    points[0] = start;
    points[3] = end;
    if (vertical_middle) {
        points[1] = .{ .x = via, .y = start.y };
        points[2] = .{ .x = via, .y = end.y };
    } else {
        points[1] = .{ .x = start.x, .y = via };
        points[2] = .{ .x = end.x, .y = via };
    }
    return points;
}

pub fn shiftInteriorRun(a: std.mem.Allocator, polyline: []const sk.Point, direction: sg.Direction, distance: u32) error{OutOfMemory}![]sk.Point {
    const shifted = try a.dupe(sk.Point, polyline);
    if (shifted.len < 4) return shifted;
    const delta: i32 = @intCast(distance);
    for (1..shifted.len - 2) |i| {
        const horizontal = shifted[i].y == shifted[i + 1].y;
        if ((direction == .TD or direction == .BT) != horizontal) continue;
        if (horizontal) {
            const dy = if (direction == .TD) delta else -delta;
            shifted[i].y += dy;
            shifted[i + 1].y += dy;
        } else {
            const dx = if (direction == .LR) delta else -delta;
            shifted[i].x += dx;
            shifted[i + 1].x += dx;
        }
        break;
    }
    return shifted;
}

pub fn clearInvisiblePath(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    kind: sk.EdgeKind,
    from: sk.NodePlacement,
    to: sk.NodePlacement,
    port_from: sk.Port,
    port_to: sk.Port,
    placements: []const sk.NodePlacement,
    existing: []const sk.EdgePath,
    bundles: pb.RealizedBundles,
) error{OutOfMemory}![]sk.Point {
    var min_x = placements[0].rect.x;
    var max_x = placements[0].rect.right() - 1;
    var min_y = placements[0].rect.y;
    var max_y = placements[0].rect.bottom() - 1;
    for (placements[1..]) |placement| {
        min_x = @min(min_x, placement.rect.x);
        max_x = @max(max_x, placement.rect.right() - 1);
        min_y = @min(min_y, placement.rect.y);
        max_y = @max(max_y, placement.rect.bottom() - 1);
    }
    var x = min_x;
    while (x <= max_x) : (x += 1) {
        const poly = try dogleg(a, from, to, port_from, port_to, x, true);
        if (!try blocked(a, edge, kind, poly, existing, bundles, placements, from.id, to.id)) return poly;
    }
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const poly = try dogleg(a, from, to, port_from, port_to, y, false);
        if (!try blocked(a, edge, kind, poly, existing, bundles, placements, from.id, to.id)) return poly;
    }
    return a.alloc(sk.Point, 0);
}

pub fn touchesForeignNode(polyline: []const sk.Point, placements: []const sk.NodePlacement, from: pb.NodeId, to: pb.NodeId) bool {
    if (polyline.len == 0) return false;
    const from_rect = placementRect(placements, from);
    const to_rect = placementRect(placements, to);
    for (polyline[1..], 0..) |point, i| {
        const prev = polyline[i];
        if (i == 0 and from_rect != null and perpendicularEndpointLeg(prev, point, from_rect.?)) continue;
        if (i + 2 == polyline.len and to_rect != null and perpendicularEndpointLeg(point, prev, to_rect.?)) continue;
        const horizontal = prev.y == point.y;
        const lo = if (horizontal) @min(prev.x, point.x) else @min(prev.y, point.y);
        const hi = if (horizontal) @max(prev.x, point.x) else @max(prev.y, point.y);
        if (sk.lineTouchesAny(horizontal, if (horizontal) prev.y else prev.x, lo, hi, placements, from, to)) return true;
    }
    return false;
}

fn placementRect(placements: []const sk.NodePlacement, id: pb.NodeId) ?sk.Rect {
    for (placements) |placement| if (placement.id == id) return placement.rect;
    return null;
}

fn perpendicularEndpointLeg(endpoint: sk.Point, adjacent: sk.Point, rect: sk.Rect) bool {
    if (endpoint.y == rect.y or endpoint.y == rect.bottom() - 1) return endpoint.x == adjacent.x;
    if (endpoint.x == rect.x or endpoint.x == rect.right() - 1) return endpoint.y == adjacent.y;
    return false;
}

fn portPoint(placement: sk.NodePlacement, port: sk.Port) sk.Point {
    const offset: i32 = @intCast(port.offset);
    return switch (port.side) {
        .north => .{ .x = placement.rect.x + offset, .y = placement.rect.y },
        .south => .{ .x = placement.rect.x + offset, .y = placement.rect.bottom() - 1 },
        .west => .{ .x = placement.rect.x, .y = placement.rect.y + offset },
        .east => .{ .x = placement.rect.right() - 1, .y = placement.rect.y + offset },
    };
}

fn sameBundle(a: pb.EdgeId, b: pb.EdgeId, bundles: pb.RealizedBundles) bool {
    for (bundles.selected_bundles) |sel| {
        if (contains(sel.members, a) and contains(sel.members, b)) return true;
    }
    return false;
}

fn contains(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |item| if (item == edge) return true;
    return false;
}

fn cells(a: std.mem.Allocator, points: []const sk.Point) error{OutOfMemory}!CellMap {
    var out: CellMap = .empty;
    if (points.len == 0) return out;
    var path: std.ArrayListUnmanaged(Cell) = .empty;
    defer path.deinit(a);
    try path.append(a, .{ .x = points[0].x, .y = points[0].y });
    for (points[1..], 0..) |point, i| {
        var cursor = points[i];
        while (cursor.x != point.x) {
            cursor.x += if (point.x > cursor.x) 1 else -1;
            try path.append(a, .{ .x = cursor.x, .y = cursor.y });
        }
        while (cursor.y != point.y) {
            cursor.y += if (point.y > cursor.y) 1 else -1;
            try path.append(a, .{ .x = cursor.x, .y = cursor.y });
        }
    }
    for (path.items, 0..) |cell, i| {
        var pass: Pass = .{};
        if (i == 0 or i + 1 == path.items.len) {
            pass.bend = true;
        } else {
            const prev = path.items[i - 1];
            const next = path.items[i + 1];
            if (prev.y == cell.y and next.y == cell.y) {
                pass.horizontal = true;
            } else if (prev.x == cell.x and next.x == cell.x) {
                pass.vertical = true;
            } else {
                pass.bend = true;
            }
        }
        const slot = try out.getOrPut(a, cell);
        if (!slot.found_existing) slot.value_ptr.* = .{};
        slot.value_ptr.merge(pass);
    }
    return out;
}

fn transversal(a: Pass, b: Pass) bool {
    if (a.bend or b.bend) return false;
    const a_horizontal = a.horizontal and !a.vertical;
    const a_vertical = a.vertical and !a.horizontal;
    const b_horizontal = b.horizontal and !b.vertical;
    const b_vertical = b.vertical and !b.horizontal;
    return (a_horizontal and b_vertical) or (a_vertical and b_horizontal);
}

fn arrowCell(edge: sk.EdgePath, cell: Cell) bool {
    return arrowPoint(edge.polyline, cell, edge.arrow_from != .none, edge.arrow_to != .none);
}

fn arrowPoint(points: []const sk.Point, cell: Cell, arrow_from: bool, arrow_to: bool) bool {
    if (points.len < 2) return false;
    if (arrow_from) {
        const first = unitStep(points[0], points[1]);
        if (cell.x == first.x and cell.y == first.y) return true;
    }
    if (arrow_to) {
        const last = unitStep(points[points.len - 1], points[points.len - 2]);
        if (cell.x == last.x and cell.y == last.y) return true;
    }
    return false;
}

fn unitStep(from: sk.Point, toward: sk.Point) sk.Point {
    return .{
        .x = from.x + std.math.sign(toward.x - from.x),
        .y = from.y + std.math.sign(toward.y - from.y),
    };
}

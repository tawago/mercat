//! Cross-channel vector clearance for candidate edge routes.

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
/// edge from another ownership channel.
pub fn conflicts(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    kind: sk.EdgeKind,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    joins: pb.RealizedJoins,
) error{OutOfMemory}!bool {
    _ = kind;
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (existing) |other| {
        if (other.kind == .invisible) continue;
        if (sameChannel(edge, other.id, joins)) continue;
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

pub fn conflictsBusBars(a: std.mem.Allocator, polyline: []const sk.Point, busbars: []const sk.BusBar) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (busbars) |bb| {
        if (try conflictsPolyline(a, candidate, bb.stem, bb.pivot_arrow != .none, false)) return true;
        if (try conflictsPolyline(a, candidate, &bb.rail, false, false)) return true;
        for (bb.taps) |tap| {
            const segment = [_]sk.Point{ tap.at, tap.landing };
            if (try conflictsPolyline(a, candidate, &segment, false, tap.arrow != .none)) return true;
        }
    }
    return false;
}

pub fn conflictsBusBarArrows(a: std.mem.Allocator, polyline: []const sk.Point, busbars: []const sk.BusBar, from: pb.NodeId, to: pb.NodeId) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (busbars) |bb| {
        for (candidate.keys()) |cell| {
            if ((bb.pivot == from or bb.pivot == to) and bb.pivot_arrow != .none and arrowPoint(bb.stem, cell, true, false)) return true;
            for (bb.taps) |tap| {
                if (tap.node != from and tap.node != to) continue;
                const segment = [_]sk.Point{ tap.at, tap.landing };
                if (tap.arrow != .none and arrowPoint(&segment, cell, false, true)) return true;
            }
        }
    }
    return false;
}

pub fn conflictsBusBarJunctions(a: std.mem.Allocator, polyline: []const sk.Point, busbars: []const sk.BusBar) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (busbars) |bb| {
        if (bb.stem.len != 0) {
            const pivot = bb.stem[bb.stem.len - 1];
            if (candidate.contains(.{ .x = pivot.x, .y = pivot.y })) return true;
        }
        for (bb.taps) |tap| {
            if (candidate.contains(.{ .x = tap.at.x, .y = tap.at.y })) return true;
        }
    }
    return false;
}

pub fn conflictsReservedDepartures(a: std.mem.Allocator, edge: pb.EdgeId, polyline: []const sk.Point, placements: []const sk.NodePlacement, edge_ports: anytype, joins: pb.RealizedJoins) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (edge_ports) |item| {
        if (item.edge == edge) continue;
        // A selected trunk's members share one departure by design (attribution-only
        // merged ink), so they must not reserve departures against each other.
        // guarded-by: route_clearance_test.zig "reserved departures exempt same selected trunk"
        if (sameChannel(edge, item.edge, joins)) continue;
        const placement = placementById(placements, item.source.node) orelse continue;
        const point = offNodePoint(placement, item.source);
        if (candidate.contains(.{ .x = point.x, .y = point.y })) return true;
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
/// ownership channel or touches a foreign node, including its border cells.
pub fn blocked(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    kind: sk.EdgeKind,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    joins: pb.RealizedJoins,
    placements: []const sk.NodePlacement,
    from: pb.NodeId,
    to: pb.NodeId,
) error{OutOfMemory}!bool {
    if (touchesForeignNode(polyline, placements, from, to)) return true;
    return conflicts(a, edge, kind, polyline, existing, joins);
}

pub fn isIndependent(edge: pb.EdgeId, joins: pb.RealizedJoins) bool {
    for (joins.memberships) |membership| {
        if (membership.edge != edge) continue;
        inline for ([2]?pb.MembershipDisposition{ membership.source, membership.target }) |disposition| {
            if (disposition) |value| if (value == .independent) return true;
        }
        return false;
    }
    return false;
}

pub fn hasIndependent(joins: pb.RealizedJoins) bool {
    for (joins.memberships) |membership| {
        inline for ([2]?pb.MembershipDisposition{ membership.source, membership.target }) |disposition| {
            if (disposition) |value| if (value == .independent) return true;
        }
    }
    return false;
}

/// True iff `polyline` clears every gate the forward/fan lane loop uses to
/// ACCEPT a route — the exact break condition inlined at those loops. Callers
/// that MUTATE a polyline after routing (the base-approach GROW in
/// routing_terminal.zig) use this to re-validate the mutated geometry against
/// bus-bars and independent-join reservations, reverting to the ungrown route
/// on failure. When there are no realized joins the gates do not apply, so it
/// returns true (the plain non-CI path is unaffected).
/// guarded-by: routing_terminal_test.zig "ensureBaseApproachLengthen grows a corner-fed len-2 final into a straight base approach"
pub fn polylineClears(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    kind: sk.EdgeKind,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    busbars: []const sk.BusBar,
    placements: []const sk.NodePlacement,
    edge_ports: anytype,
    joins: pb.RealizedJoins,
    from: pb.NodeId,
    to: pb.NodeId,
) error{OutOfMemory}!bool {
    if (joins.memberships.len == 0) return true;
    const indep = hasIndependent(joins);
    return (indep == false or !try blocked(a, edge, kind, polyline, existing, joins, placements, from, to)) and
        (indep == false or !try conflictsBusBarJunctions(a, polyline, busbars)) and
        (indep or !try conflictsBusBarArrows(a, polyline, busbars, from, to)) and
        (indep or !try conflictsReservedDepartures(a, edge, polyline, placements, edge_ports, joins));
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
        const source_y = sk.clearLine(true, source_want, @min(outside_x, start.x), @max(outside_x, start.x), placements, from.id, to.id, .{});
        const target_y = sk.clearLine(true, target_want, @min(outside_x, end.x), @max(outside_x, end.x), placements, from.id, to.id, .{});
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
        const source_x = sk.clearLine(false, source_want, @min(outside_y, start.y), @max(outside_y, start.y), placements, from.id, to.id, .{});
        const target_x = sk.clearLine(false, target_want, @min(outside_y, end.y), @max(outside_y, end.y), placements, from.id, to.id, .{});
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
    joins: pb.RealizedJoins,
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
        if (!try blocked(a, edge, kind, poly, existing, joins, placements, from.id, to.id)) return poly;
    }
    var y = min_y;
    while (y <= max_y) : (y += 1) {
        const poly = try dogleg(a, from, to, port_from, port_to, y, false);
        if (!try blocked(a, edge, kind, poly, existing, joins, placements, from.id, to.id)) return poly;
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

fn sameChannel(a: pb.EdgeId, b: pb.EdgeId, joins: pb.RealizedJoins) bool {
    for (joins.selected_joins) |join| {
        if (contains(join.members, a) and contains(join.members, b)) return true;
    }
    for (joins.mesh_unions) |mesh| {
        if (contains(mesh.members, a) and contains(mesh.members, b)) return true;
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

//! Cross-bundle vector clearance for candidate edge routes.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");

const Cell = struct { x: i32, y: i32 };
/// The arms a cell's ink shows, one per side: the glyph the raster will
/// draw there reaches its neighbour on every set side.
const Arms = struct {
    north: bool = false,
    south: bool = false,
    east: bool = false,
    west: bool = false,

    fn toward(self: *Arms, from: Cell, to: Cell) void {
        if (to.x > from.x) self.east = true;
        if (to.x < from.x) self.west = true;
        if (to.y > from.y) self.south = true;
        if (to.y < from.y) self.north = true;
    }
};

const Pass = struct {
    horizontal: bool = false,
    vertical: bool = false,
    bend: bool = false,
    arms: Arms = .{},

    fn merge(self: *Pass, other: Pass) void {
        self.horizontal = self.horizontal or other.horizontal;
        self.vertical = self.vertical or other.vertical;
        self.bend = self.bend or other.bend;
        self.arms.north = self.arms.north or other.arms.north;
        self.arms.south = self.arms.south or other.arms.south;
        self.arms.east = self.arms.east or other.arms.east;
        self.arms.west = self.arms.west or other.arms.west;
    }
};

const CellMap = std.AutoArrayHashMapUnmanaged(Cell, Pass);

/// True when `polyline` has a non-transversal cell contact with an existing
/// edge from another ownership bundle.
pub fn conflicts(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    bundles: pb.RealizedBundles,
) error{OutOfMemory}!bool {
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

pub fn conflictsRailArrows(a: std.mem.Allocator, polyline: []const sk.Point, rails: []const sk.Rail, from: pb.NodeId, to: pb.NodeId) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    for (rails) |rail| {
        for (candidate.keys()) |cell| {
            if ((rail.pivot == from or rail.pivot == to) and rail.pivot_arrow != .none and arrowPoint(rail.stem, cell, true, false)) return true;
            for (rail.taps) |tap| {
                if (tap.node != from and tap.node != to) continue;
                // A continuing tap paints no head; its member's head is at the far end.
                if (tap.continues) continue;
                const segment = [_]sk.Point{ tap.at, tap.landing };
                if (tap.arrow != .none and arrowPoint(&segment, cell, false, true)) return true;
            }
        }
    }
    return false;
}

/// True iff a segment of `polyline` shares two or more consecutive cells
/// with a rail's stem, crossbar, or drop: collinear overlap with another
/// owner's ink (a junction glyph with no licence behind it), as opposed to
/// a single-cell transversal crossing, which is legal.
/// @guarded-by: route_clearance_test.zig "a route may cross a rail's run but never lie along it"
pub fn ridesRail(a: std.mem.Allocator, polyline: []const sk.Point, rails: []const sk.Rail) error{OutOfMemory}!bool {
    var ink: CellMap = .empty;
    defer ink.deinit(a);
    for (rails) |rail| {
        try cellsInto(a, &ink, rail.stem);
        try cellsInto(a, &ink, &rail.crossbar);
        for (rail.taps) |tap| try cellsInto(a, &ink, &[_]sk.Point{ tap.at, tap.landing });
    }
    if (ink.count() == 0) return false;
    var i: usize = 0;
    while (i + 1 < polyline.len) : (i += 1) {
        var c = polyline[i];
        const q = polyline[i + 1];
        const dx = std.math.sign(q.x - c.x);
        const dy = std.math.sign(q.y - c.y);
        if (dx == 0 and dy == 0) continue;
        var run: u32 = 0;
        while (true) : (c = .{ .x = c.x + dx, .y = c.y + dy }) {
            if (ink.contains(.{ .x = c.x, .y = c.y })) {
                run += 1;
                if (run >= 2) return true;
            } else run = 0;
            if (c.x == q.x and c.y == q.y) break;
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

/// True when `polyline` enters a terminal cell another edge's port
/// allocation reserved — its departure cell or its arrival cell — in a way
/// the reservation forbids. Both ends are reserved before any route is
/// laid, so the protection does not depend on routing order.
pub fn conflictsReservedTerminals(a: std.mem.Allocator, edge: pb.EdgeId, polyline: []const sk.Point, placements: []const sk.NodePlacement, edge_ports: anytype, bundles: pb.RealizedBundles) error{OutOfMemory}!bool {
    var candidate = try cells(a, polyline);
    defer candidate.deinit(a);
    var own: ?[2]sk.Port = null;
    for (edge_ports) |item| if (item.edge == edge) {
        own = .{ item.source, item.target };
    };
    for (edge_ports) |item| {
        if (item.edge == edge) continue;
        // A selected rail's members share one departure by design (attribution-only
        // merged ink), so they must not reserve departures against each other.
        // @guarded-by: route_clearance_test.zig "reserved departures exempt same selected rail"
        if (sameBundle(edge, item.edge, bundles)) continue;
        const ends = [2]struct { port: sk.Port, decorated: bool }{
            .{ .port = item.source, .decorated = item.source_decorated },
            .{ .port = item.target, .decorated = item.target_decorated },
        };
        for (ends) |end| {
            // Two edges the plan attached to ONE port share that port's
            // terminal cell by construction (a fan's shared pivot); the
            // shared cell is not a reservation against its own co-attached edge.
            if (own) |ports| if (samePort(ports[0], end.port) or samePort(ports[1], end.port)) continue;
            const placement = placementById(placements, end.port.node) orelse continue;
            if (reservedConflict(candidate, offNodePoint(placement, end.port), end.port.side, end.decorated)) return true;
        }
    }
    return false;
}

/// The reservation one terminal cell holds against a candidate's occupancy.
/// An undecorated cell is a future plain run: collinear occupancy or a bend
/// there claims it, a perpendicular through-run is a legal crossing. A
/// decorated cell is a future decoration cell: it blocks all transit, and
/// its two lateral neighbours are guarded against foreign arms — ink there
/// whose glyph reaches the head cell (a run toward it, or a bend whose arm
/// faces it). A run parallel to the port axis, and a bend that turns away
/// from the head, show no arm on the head's side and are admitted.
/// @guarded-by: route_clearance_test.zig "a reserved departure blocks collinear occupancy and admits a perpendicular crossing"
/// @guarded-by: route_clearance_test.zig "a decorated departure cell blocks even a perpendicular crossing"
/// @guarded-by: route_clearance_test.zig "a decorated arrival cell blocks even a perpendicular crossing"
/// @guarded-by: route_clearance_test.zig "a decorated terminal's lateral neighbours refuse a foreign arm toward the head, admit a parallel through-run and a bend turning away"
fn reservedConflict(candidate: CellMap, reserved: sk.Point, side: sk.Dir4, decorated: bool) bool {
    const vertical = side == .north or side == .south;
    if (candidate.get(.{ .x = reserved.x, .y = reserved.y })) |theirs| {
        if (decorated) return true;
        const run: Pass = if (vertical) .{ .vertical = true } else .{ .horizontal = true };
        if (!transversal(theirs, run)) return true;
    }
    if (!decorated) return false;
    if (vertical) {
        if (candidate.get(.{ .x = reserved.x - 1, .y = reserved.y })) |west| if (west.arms.east) return true;
        if (candidate.get(.{ .x = reserved.x + 1, .y = reserved.y })) |east| if (east.arms.west) return true;
    } else {
        if (candidate.get(.{ .x = reserved.x, .y = reserved.y - 1 })) |north| if (north.arms.south) return true;
        if (candidate.get(.{ .x = reserved.x, .y = reserved.y + 1 })) |south| if (south.arms.north) return true;
    }
    return false;
}

/// True when a built rail's ink (stem, crossbar, drops) enters a terminal
/// cell reserved by an edge that is not one of the rail's members. Rails
/// are laid before every private route, so this is the only gate between a
/// rail and the reservations it must honour.
/// @guarded-by: route_clearance_test.zig "a rail honours a foreign decorated terminal's reservation and ignores its own members'"
pub fn railConflictsReservedTerminals(a: std.mem.Allocator, rail: sk.Rail, placements: []const sk.NodePlacement, edge_ports: anytype, bundles: pb.RealizedBundles) error{OutOfMemory}!bool {
    var candidate: CellMap = .empty;
    defer candidate.deinit(a);
    try cellsInto(a, &candidate, rail.stem);
    try cellsInto(a, &candidate, &rail.crossbar);
    for (rail.taps) |tap| try cellsInto(a, &candidate, &[_]sk.Point{ tap.at, tap.landing });
    for (edge_ports) |item| {
        if (railMember(rail, item.edge, bundles)) continue;
        const ends = [2]struct { port: sk.Port, decorated: bool }{
            .{ .port = item.source, .decorated = item.source_decorated },
            .{ .port = item.target, .decorated = item.target_decorated },
        };
        for (ends) |end| {
            const placement = placementById(placements, end.port.node) orelse continue;
            // A port the rail already lands on (a tap's landing, the stem's
            // pivot port) is shared with that edge by the plan — a fused
            // run's far-side port share — not reserved against the rail.
            if (railLandsOn(rail, portPoint(placement, end.port))) continue;
            if (reservedConflict(candidate, offNodePoint(placement, end.port), end.port.side, end.decorated)) return true;
        }
    }
    return false;
}

/// `placements` plus one pseudo-box per DECORATED terminal cell another
/// edge reserved — the cell and its two lateral neighbours as a 3x1 (or
/// 1x3) rect under a sentinel id — for producers that search clear lines
/// against boxes only (the back-edge stub hop). A line through the head
/// cell or a lateral then reads as touching a box, so the hop lands on a
/// row the reservation admits. Conservative on purpose: a parallel run
/// through a lateral is legal, and this refuses it too; back-edge stubs
/// rarely want one. Same exemptions as `conflictsReservedTerminals`.
/// @guarded-by: route_clearance_test.zig "decorated terminal pseudo-boxes cover the head cell and its laterals for foreign edges only"
pub fn withDecoratedTerminalBoxes(a: std.mem.Allocator, edge: pb.EdgeId, placements: []const sk.NodePlacement, edge_ports: anytype, bundles: pb.RealizedBundles) error{OutOfMemory}![]const sk.NodePlacement {
    var out: std.ArrayListUnmanaged(sk.NodePlacement) = .empty;
    try out.appendSlice(a, placements);
    var sentinel: pb.NodeId = std.math.maxInt(pb.NodeId);
    for (edge_ports) |item| {
        if (item.edge == edge or sameBundle(edge, item.edge, bundles)) continue;
        const ends = [2]struct { port: sk.Port, decorated: bool }{
            .{ .port = item.source, .decorated = item.source_decorated },
            .{ .port = item.target, .decorated = item.target_decorated },
        };
        for (ends) |end| {
            if (!end.decorated) continue;
            const placement = placementById(placements, end.port.node) orelse continue;
            const cell = offNodePoint(placement, end.port);
            const rect: sk.Rect = switch (end.port.side) {
                .north, .south => .{ .x = cell.x - 1, .y = cell.y, .w = 3, .h = 1 },
                .west, .east => .{ .x = cell.x, .y = cell.y - 1, .w = 1, .h = 3 },
            };
            try out.append(a, .{ .id = sentinel, .rect = rect, .shape = .rect, .lines = &.{}, .cluster_id = null });
            sentinel -= 1;
        }
    }
    return out.toOwnedSlice(a);
}

fn railLandsOn(rail: sk.Rail, point: sk.Point) bool {
    if (rail.stem.len != 0 and rail.stem[0].x == point.x and rail.stem[0].y == point.y) return true;
    for (rail.taps) |tap| if (tap.landing.x == point.x and tap.landing.y == point.y) return true;
    return false;
}

fn railMember(rail: sk.Rail, edge: pb.EdgeId, bundles: pb.RealizedBundles) bool {
    for (rail.taps) |tap| if (tap.edge == edge or sameBundle(tap.edge, edge, bundles)) return true;
    return false;
}

fn samePort(x: sk.Port, y: sk.Port) bool {
    return x.node == y.node and x.side == y.side and x.offset == y.offset;
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

/// True when a candidate either shares a non-transversal cell with another
/// ownership bundle or touches a foreign node, including its border cells.
pub fn blocked(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    bundles: pb.RealizedBundles,
    placements: []const sk.NodePlacement,
    from: pb.NodeId,
    to: pb.NodeId,
) error{OutOfMemory}!bool {
    if (touchesForeignNode(polyline, placements, from, to)) return true;
    return conflicts(a, edge, polyline, existing, bundles);
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
/// rails and reservations, reverting to the ungrown route on failure.
/// The reserved-terminal gate runs whether or not any bundle was realized:
/// a port allocation exists for every plan, and a reservation is what
/// protects a decoration cell from foreign arms regardless of routing
/// order; so does the rail-ink gate (`ridesRail`) — a rail is laid before
/// every private route, and a run along it is a foreign junction under any
/// plan. The three bundle-attributed gates — foreign-node/cross-bundle
/// contact (box termination / ink attribution), rail junctions (ink
/// attribution: unrelated ink over an owner-set change) and rail
/// arrowheads — are independent legality facts, never alternatives; with no
/// realized bundles they have nothing to read (the plain non-bundle path is
/// cleared by the route builders themselves).
/// @guarded-by: routing_terminal_test.zig "satisfyApproach grows a corner-fed len-2 final into a straight base approach"
/// @guarded-by: route_clearance_test.zig "polylineClears refuses every clearance violation regardless of membership disposition"
/// @guarded-by: route_clearance_test.zig "reservations hold with no realized memberships"
pub fn polylineClears(
    a: std.mem.Allocator,
    edge: pb.EdgeId,
    polyline: []const sk.Point,
    existing: []const sk.EdgePath,
    rails: []const sk.Rail,
    placements: []const sk.NodePlacement,
    edge_ports: anytype,
    bundles: pb.RealizedBundles,
    from: pb.NodeId,
    to: pb.NodeId,
) error{OutOfMemory}!bool {
    if (try conflictsReservedTerminals(a, edge, polyline, placements, edge_ports, bundles)) return false;
    if (try ridesRail(a, polyline, rails)) return false;
    // Box termination holds under any plan: a box is a terminus, never a
    // corridor, so a run through a foreign box is refused with or without
    // realized memberships.
    // @guarded-by: route_clearance_test.zig "a route through a foreign box is refused with no realized memberships"
    if (touchesForeignNode(polyline, placements, from, to)) return false;
    if (bundles.memberships.len == 0) return true;
    return !try blocked(a, edge, polyline, existing, bundles, placements, from, to) and
        !try conflictsRailJunctions(a, polyline, rails) and
        !try conflictsRailArrows(a, polyline, rails, from, to);
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

pub fn portPoint(placement: sk.NodePlacement, port: sk.Port) sk.Point {
    const offset: i32 = @intCast(port.offset);
    return switch (port.side) {
        .north => .{ .x = placement.rect.x + offset, .y = placement.rect.y },
        .south => .{ .x = placement.rect.x + offset, .y = placement.rect.bottom() - 1 },
        .west => .{ .x = placement.rect.x, .y = placement.rect.y + offset },
        .east => .{ .x = placement.rect.right() - 1, .y = placement.rect.y + offset },
    };
}

/// True iff `a` and `b` are members of one selected bundle. A licensed shared
/// approach blocks nothing among its own members — their shared stub is
/// attribution-only merged ink, not an overlap.
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
    try cellsInto(a, &out, points);
    return out;
}

fn cellsInto(a: std.mem.Allocator, out: *CellMap, points: []const sk.Point) error{OutOfMemory}!void {
    if (points.len == 0) return;
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
        if (i > 0) pass.arms.toward(cell, path.items[i - 1]);
        if (i + 1 < path.items.len) pass.arms.toward(cell, path.items[i + 1]);
        if (i == 0 or i + 1 == path.items.len) {
            // A terminal cell is drawn as a plain line glyph, which reaches
            // both of its neighbours along the segment's axis.
            pass.bend = true;
            if (pass.arms.north or pass.arms.south) {
                pass.arms.north = true;
                pass.arms.south = true;
            }
            if (pass.arms.east or pass.arms.west) {
                pass.arms.east = true;
                pass.arms.west = true;
            }
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

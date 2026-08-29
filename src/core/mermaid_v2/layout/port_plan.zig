//! Candidate-local D-PORT sizing, allocation, and routing lookup.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const rail_closure = @import("../base/rail_closure.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const fan_mod = @import("fan.zig");
const ports = @import("ports.zig");
const sugiyama = @import("sugiyama.zig");

pub const EdgePorts = struct {
    edge: pb.EdgeId,
    source: sk.Port,
    target: sk.Port,
    source_ordinal: u32,
    target_ordinal: u32,
    source_duplicate: bool = false,
    /// Source-end decoration exists: the reserved off-node departure cell
    /// will hold it, so that cell blocks ALL foreign transit (the plain-run
    /// obstacle model applies only to undecorated departures).
    source_decorated: bool = false,
    target_duplicate: bool = false,
    route_lane: u32 = 0,
};

pub const LanePlan = struct { lanes: []const EdgeLane = &.{}, extra_rows: []const u32 = &.{} };
pub const EdgeLane = struct { edge: pb.EdgeId, lane: u32 };

pub const Plan = struct {
    edges: []const EdgePorts = &.{},
    terminals: []const pb.TerminalPort = &.{},

    pub fn forEdge(self: Plan, edge: pb.EdgeId) ?EdgePorts {
        for (self.edges) |item| if (item.edge == edge) return item;
        return null;
    }
};

pub fn midpoint(a: std.mem.Allocator, graph: sg.SemGraph, placements: []const sk.NodePlacement) error{OutOfMemory}!Plan {
    const edges = try a.alloc(EdgePorts, graph.edges.len);
    for (graph.edges, edges) |edge, *out| {
        const source_p = placementById(placements, edge.from) orelse placements[0];
        const target_p = placementById(placements, edge.to) orelse placements[0];
        const source = midpointPort(graph.direction, source_p, edge, .source_exit);
        const target = midpointPort(graph.direction, target_p, edge, .target_entry);
        out.* = .{ .edge = edge.id, .source = source.port, .target = target.port, .source_ordinal = 0, .target_ordinal = 0, .source_decorated = edge.arrow_from != .none };
    }
    return .{ .edges = edges };
}

/// Derive the structural fan attachment population when no flat realization
/// plan exists. Shared members consume one pivot attachment per fan; private
/// members and every leaf endpoint stay independent. This preserves the shared
/// rail while preventing an excluded member from reusing its attachment.
pub fn deriveFanAttachments(a: std.mem.Allocator, graph: sg.SemGraph, direction: sg.Direction, reversed_edges: []const pb.EdgeId, fans: []const fan_mod.Fan) ports.DeriveError![]const ports.DerivedAttachment {
    var out: std.ArrayListUnmanaged(ports.DerivedAttachment) = .empty;
    for (graph.edges) |edge| {
        if (edge.kind == .invisible) continue;
        for ([2]pb.EndpointSide{ .source_exit, .target_entry }) |endpoint| {
            const node = if (endpoint == .source_exit) edge.from else edge.to;
            const side = if (edge.from == edge.to)
                ports.selfLoopSide(direction, endpoint)
            else if (containsEdge(reversed_edges, edge.id))
                ports.reversedSide(direction)
            else
                ports.forwardSide(direction, endpoint);
            if (sharedFan(fans, edge.id, endpoint)) |fan| {
                const trunk = try fanAttachment(a, graph, fan, endpoint);
                if (trunk.edge != edge.id) continue;
                try out.append(a, .{ .node = node, .side = side, .attachment = trunk });
                continue;
            }
            try out.append(a, .{
                .node = node,
                .side = side,
                .attachment = .{ .key = try ports.edgeAttachmentKey(graph, edge, endpoint), .edge = edge.id },
            });
        }
    }
    return try out.toOwnedSlice(a);
}

fn sharedFan(fans: []const fan_mod.Fan, edge: pb.EdgeId, endpoint: pb.EndpointSide) ?fan_mod.Fan {
    for (fans) |fan| {
        const pivot_endpoint = if (fan.direction == .out) pb.EndpointSide.source_exit else .target_entry;
        if (endpoint != pivot_endpoint) continue;
        for (fan.peers) |peer| if (peer.shared and peer.edge_id == edge) return fan;
    }
    return null;
}

fn fanAttachment(a: std.mem.Allocator, graph: sg.SemGraph, fan: fan_mod.Fan, endpoint: pb.EndpointSide) ports.DeriveError!ports.Attachment {
    var best: ?pb.AttachmentKey = null;
    var best_edge: pb.EdgeId = 0;
    var members: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (fan.peers) |peer| {
        if (!peer.shared) continue;
        const edge = edgeById(graph, peer.edge_id) orelse return error.InvalidSemGraph;
        const key = try ports.edgeAttachmentKey(graph, edge, endpoint);
        if (best == null or pb.attachmentKeyOrder(key, best.?) == .lt) {
            best = key;
            best_edge = edge.id;
        }
        try members.append(a, edge.id);
    }
    return .{
        .class = .trunk_pivot,
        .key = best orelse return error.InvalidSemGraph,
        .edge = best_edge,
        .members = try members.toOwnedSlice(a),
    };
}

/// The derived attachment set minus every CO-REALIZED edge. Such an edge is
/// rendered by an all-arrow-free rail's crossbar and never routed, so it
/// claims no attachment on either endpoint: leaving it in would widen a face,
/// shift its siblings' port ordinals, and reserve a terminal nothing arrives
/// at. Applied where `derive` is consumed rather than inside it, so the pure
/// D-PORT derivation keeps reading the permits plan and nothing else.
/// guarded-by: port_plan_test.zig "a co-realized edge claims no attachment and consumes no route lane"
pub fn withoutCoRealized(
    a: std.mem.Allocator,
    derived: []const ports.DerivedAttachment,
    joins: pb.RealizedJoins,
) error{OutOfMemory}![]const ports.DerivedAttachment {
    if (joins.co_realized.len == 0) return derived;
    var out: std.ArrayListUnmanaged(ports.DerivedAttachment) = .empty;
    for (derived) |item| {
        const edge = item.attachment.edge orelse {
            try out.append(a, item);
            continue;
        };
        if (rail_closure.contains(joins.co_realized, edge)) continue;
        try out.append(a, item);
    }
    return out.toOwnedSlice(a);
}

pub fn planLanes(a: std.mem.Allocator, graph: sg.SemGraph, lg: sugiyama.LayeredGraph, joins: pb.RealizedJoins) error{OutOfMemory}!LanePlan {
    if (lg.layers.len < 2) return .{};
    const node_layers = try a.alloc(u32, graph.nodes.len);
    @memset(node_layers, 0);
    for (lg.layers, 0..) |layer, li| for (layer) |idx| switch (lg.nodes[idx]) {
        .real => |id| if (id < node_layers.len) {
            node_layers[id] = @intCast(li);
        },
        .virtual => {},
    };
    const sorted = try a.dupe(sg.Edge, graph.edges);
    std.mem.sort(sg.Edge, sorted, graph, edgeLess);
    const next = try a.alloc(u32, lg.layers.len - 1);
    @memset(next, 0);
    var lanes: std.ArrayListUnmanaged(EdgeLane) = .empty;
    for (sorted) |edge| {
        // A co-realized leaf-pair edge is drawn by a rail's crossbar, never
        // routed — so it consumes no route lane and reserves no gap row.
        // Likewise an edge a FUSED union licenses: its whole gap is one rail
        // (`RealizedJoins.fused`), so it owes no per-edge lane row.
        if (edge.kind == .invisible or edge.from == edge.to or !edgeIsIndependent(joins.memberships, edge.id) or
            fusedContains(joins.fused, edge.id) or
            rail_closure.contains(joins.co_realized, edge.id)) continue;
        const high = @max(node_layers[edge.from], node_layers[edge.to]);
        if (high == 0) continue;
        const gap = high - 1;
        try lanes.append(a, .{ .edge = edge.id, .lane = next[gap] });
        next[gap] += 1;
    }
    const extras = try a.alloc(u32, next.len);
    for (next, extras) |count, *extra| extra.* = count -| 1;
    return .{ .lanes = try lanes.toOwnedSlice(a), .extra_rows = extras };
}

const FaceAssignments = struct { node: pb.NodeId, side: sk.Dir4, items: []const ports.Assignment };

pub fn allocate(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    placements: []const sk.NodePlacement,
    derived: []const ports.DerivedAttachment,
    joins: pb.RealizedJoins,
    lane_plan: LanePlan,
    rung: u8,
) error{OutOfMemory}!Plan {
    const resolved = try a.dupe(ports.DerivedAttachment, derived);
    for (resolved) |*item| {
        const edge = edgeById(graph, item.attachment.edge orelse continue) orelse continue;
        const opposite_id = if (item.node == edge.from) edge.to else edge.from;
        const opposite = placementById(placements, opposite_id) orelse continue;
        item.attachment.opposite_center = switch (item.side) {
            .north, .south => opposite.rect.x + @divTrunc(@as(i32, @intCast(opposite.rect.w)), 2),
            .east, .west => opposite.rect.y + @divTrunc(@as(i32, @intCast(opposite.rect.h)), 2),
        };
    }

    var faces: std.ArrayListUnmanaged(FaceAssignments) = .empty;
    const sides = [_]sk.Dir4{ .north, .south, .east, .west };
    for (placements) |placement| for (sides) |side| {
        const attachments = try ports.forSide(a, resolved, placement.id, side);
        if (attachments.len == 0) continue;
        const len = switch (side) {
            .north, .south => placement.rect.w,
            .east, .west => placement.rect.h,
        };
        const items = try allocateFace(a, placement.id, side, len, attachments, rung);
        try faces.append(a, .{ .node = placement.id, .side = side, .items = items });
    };

    const edge_ports = try a.alloc(EdgePorts, graph.edges.len);
    var terminals: std.ArrayListUnmanaged(pb.TerminalPort) = .empty;
    for (graph.edges, edge_ports) |edge, *out| {
        const source = resolvePort(graph, placements, faces.items, resolved, joins, edge, .source_exit);
        const target = resolvePort(graph, placements, faces.items, resolved, joins, edge, .target_entry);
        out.* = .{
            .edge = edge.id,
            .source = source.port,
            .target = target.port,
            .source_ordinal = source.ordinal,
            .target_ordinal = target.ordinal,
            .source_duplicate = hasDuplicatePrivateClaim(resolved, joins, edge.from, edge, .source_exit),
            .source_decorated = edge.arrow_from != .none,
            .target_duplicate = hasDuplicatePrivateClaim(resolved, joins, edge.to, edge, .target_entry),
            .route_lane = laneFor(lane_plan.lanes, edge.id),
        };
        try terminals.append(a, .{ .node = edge.from, .edge = edge.id, .endpoint_side = .source_exit, .port = source.ordinal });
        try terminals.append(a, .{ .node = edge.to, .edge = edge.id, .endpoint_side = .target_entry, .port = target.ordinal });
    }
    return .{ .edges = edge_ports, .terminals = try terminals.toOwnedSlice(a) };
}

fn allocateFace(a: std.mem.Allocator, node: pb.NodeId, side: sk.Dir4, side_len: u32, attachments: []const ports.Attachment, rung: u8) error{OutOfMemory}![]const ports.Assignment {
    return switch (try ports.allocate(a, .{ .rung = rung }, node, side, side_len, attachments)) {
        .assigned => |items| items,
        .failed => |failure| switch (failure) {
            // The exact allocator correctly reports equal semantic keys. At
            // plan level, distinct edge/end claims are the duplicate policy:
            // each private claim receives its own stable slot.
            .key_collision => allocateCollidingClaims(a, node, side, side_len, attachments),
            .capacity_exceeded => portCapacityInvariant(node, side, side_len, attachments.len),
        },
    };
}

fn allocateCollidingClaims(a: std.mem.Allocator, node: pb.NodeId, side: sk.Dir4, side_len: u32, attachments: []const ports.Attachment) error{OutOfMemory}![]const ports.Assignment {
    if (!ports.satisfiable(side_len, @intCast(attachments.len)))
        portCapacityInvariant(node, side, side_len, attachments.len);
    const sorted = try a.dupe(ports.Attachment, attachments);
    std.mem.sort(ports.Attachment, sorted, {}, attachmentLess);
    const out = try a.alloc(ports.Assignment, sorted.len);
    for (sorted, out, 0..) |attachment, *assignment, i| assignment.* = .{
        .attachment = attachment,
        .ordinal = @intCast(i),
        .offset = ports.offsetAt(side_len, @intCast(sorted.len), @intCast(i)),
    };
    return out;
}

fn attachmentLess(_: void, x: ports.Attachment, y: ports.Attachment) bool {
    if (x.opposite_center != y.opposite_center) return x.opposite_center < y.opposite_center;
    const key_order = pb.attachmentKeyOrder(x.key, y.key);
    if (key_order != .eq) return key_order == .lt;
    const x_edge = x.edge orelse std.math.maxInt(pb.EdgeId);
    const y_edge = y.edge orelse std.math.maxInt(pb.EdgeId);
    if (x_edge != y_edge) return x_edge < y_edge;
    if (x.class != y.class) return @intFromEnum(x.class) < @intFromEnum(y.class);
    const x_group = x.group orelse std.math.maxInt(pb.JoinGroupId);
    const y_group = y.group orelse std.math.maxInt(pb.JoinGroupId);
    return x_group < y_group;
}

fn portCapacityInvariant(node: pb.NodeId, side: sk.Dir4, side_len: u32, demand: usize) noreturn {
    std.debug.panic("port demand was not applied before allocation: node={d} side={s} len={d} demand={d}", .{ node, @tagName(side), side_len, demand });
}

/// Exact private duplicates use separate outside tracks. Endpoint ordinals
/// select both the track and the perpendicular bases.
pub fn duplicateDetour(a: std.mem.Allocator, direction: sg.Direction, from: sk.NodePlacement, to: sk.NodePlacement, owner: EdgePorts, placements: []const sk.NodePlacement) error{OutOfMemory}![]sk.Point {
    const start = portPoint(from, owner.source);
    const end = portPoint(to, owner.target);
    const depth: i32 = @intCast(@max(owner.source_ordinal, owner.target_ordinal) + 2);
    var min_x = @min(start.x, end.x);
    var min_y = @min(start.y, end.y);
    for (placements) |placement| {
        min_x = @min(min_x, placement.rect.x);
        min_y = @min(min_y, placement.rect.y);
    }
    const source_base = outward(start, owner.source.side, depth);
    const target_base = outward(end, owner.target.side, depth);
    const out = try a.alloc(sk.Point, 6);
    if (direction == .TD or direction == .BT) {
        const outside_x = min_x - depth;
        @memcpy(out, &[_]sk.Point{ start, source_base, .{ .x = outside_x, .y = source_base.y }, .{ .x = outside_x, .y = target_base.y }, target_base, end });
    } else {
        const outside_y = min_y - depth;
        @memcpy(out, &[_]sk.Point{ start, source_base, .{ .x = source_base.x, .y = outside_y }, .{ .x = target_base.x, .y = outside_y }, target_base, end });
    }
    return out;
}

fn outward(point: sk.Point, side: sk.Dir4, distance: i32) sk.Point {
    return switch (side) {
        .north => .{ .x = point.x, .y = point.y - distance },
        .south => .{ .x = point.x, .y = point.y + distance },
        .west => .{ .x = point.x - distance, .y = point.y },
        .east => .{ .x = point.x + distance, .y = point.y },
    };
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

fn edgeIsIndependent(memberships: []const pb.RealizedEdgeMembership, edge: pb.EdgeId) bool {
    for (memberships) |membership| {
        if (membership.edge != edge) continue;
        inline for ([2]?pb.MembershipDisposition{ membership.source, membership.target }) |disposition| {
            if (disposition) |d| if (d == .independent) return true;
        }
        return false;
    }
    return false;
}

fn fusedContains(fused: []const []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (fused) |u| if (containsEdge(u, edge)) return true;
    return false;
}

fn containsEdge(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |candidate| if (candidate == edge) return true;
    return false;
}

fn laneFor(lanes: []const EdgeLane, edge: pb.EdgeId) u32 {
    for (lanes) |item| if (item.edge == edge) return item.lane;
    return 0;
}

fn edgeLess(graph: sg.SemGraph, x: sg.Edge, y: sg.Edge) bool {
    const x_from = nodeKey(graph, x.from);
    const y_from = nodeKey(graph, y.from);
    const from = std.mem.order(u8, x_from, y_from);
    if (from != .eq) return from == .lt;
    const to = std.mem.order(u8, nodeKey(graph, x.to), nodeKey(graph, y.to));
    if (to != .eq) return to == .lt;
    if (x.kind != y.kind) return @intFromEnum(x.kind) < @intFromEnum(y.kind);
    if (x.arrow_from != y.arrow_from) return @intFromEnum(x.arrow_from) < @intFromEnum(y.arrow_from);
    if (x.arrow_to != y.arrow_to) return @intFromEnum(x.arrow_to) < @intFromEnum(y.arrow_to);
    const xl = x.label orelse "";
    const yl = y.label orelse "";
    const label = std.mem.order(u8, xl, yl);
    return if (label == .eq) x.id < y.id else label == .lt;
}

fn nodeKey(graph: sg.SemGraph, id: pb.NodeId) []const u8 {
    for (graph.nodes) |node| if (node.id == id) return node.raw_id;
    return "";
}

const ResolvedPort = struct { port: sk.Port, ordinal: u32 };

fn resolvePort(
    graph: sg.SemGraph,
    placements: []const sk.NodePlacement,
    faces: []const FaceAssignments,
    derived: []const ports.DerivedAttachment,
    joins: pb.RealizedJoins,
    edge: sg.Edge,
    endpoint: pb.EndpointSide,
) ResolvedPort {
    const node = if (endpoint == .source_exit) edge.from else edge.to;
    const placement = placementById(placements, node) orelse placements[0];
    const selected_group = selectedGroup(joins, edge.id, endpoint);
    for (faces) |face| {
        if (face.node != node) continue;
        for (face.items) |assignment| {
            const matches = if (selected_group) |group|
                assignment.attachment.class == .trunk_pivot and assignment.attachment.group == group
            else
                assignment.attachment.key.endpoint_side == endpoint and
                    ((assignment.attachment.class == .independent and assignment.attachment.edge == edge.id) or
                        (assignment.attachment.class == .trunk_pivot and containsEdge(assignment.attachment.members, edge.id)));
            if (matches) return .{
                .port = .{ .node = node, .side = face.side, .offset = assignment.offset },
                .ordinal = assignment.ordinal,
            };
        }
    }
    if (hasDemandedClaim(derived, joins, node, edge, endpoint))
        std.debug.panic("derived port claim was not assigned: edge={d} endpoint={s}", .{ edge.id, @tagName(endpoint) });
    return midpointPort(graph.direction, placement, edge, endpoint);
}

fn hasDemandedClaim(derived: []const ports.DerivedAttachment, joins: pb.RealizedJoins, node: pb.NodeId, edge: sg.Edge, endpoint: pb.EndpointSide) bool {
    const selected_group = selectedGroup(joins, edge.id, endpoint);
    for (derived) |item| {
        if (item.node != node or item.attachment.key.endpoint_side != endpoint) continue;
        if (selected_group) |group| {
            if (item.attachment.class == .trunk_pivot and item.attachment.group == group) return true;
        } else if ((item.attachment.class == .independent and item.attachment.edge == edge.id) or
            (item.attachment.class == .trunk_pivot and containsEdge(item.attachment.members, edge.id))) return true;
    }
    return false;
}

fn hasDuplicatePrivateClaim(derived: []const ports.DerivedAttachment, joins: pb.RealizedJoins, node: pb.NodeId, edge: sg.Edge, endpoint: pb.EndpointSide) bool {
    if (selectedGroup(joins, edge.id, endpoint) != null) return false;
    for (derived) |owner| {
        if (owner.node != node or owner.attachment.key.endpoint_side != endpoint or
            owner.attachment.class != .independent or owner.attachment.edge != edge.id) continue;
        for (derived) |other| {
            if (other.node == node and other.side == owner.side and other.attachment.class == .independent and
                other.attachment.edge != edge.id and pb.attachmentKeyOrder(other.attachment.key, owner.attachment.key) == .eq) return true;
        }
        return false;
    }
    return false;
}

fn midpointPort(direction: sg.Direction, placement: sk.NodePlacement, edge: sg.Edge, endpoint: pb.EndpointSide) ResolvedPort {
    const side = if (edge.from == edge.to)
        ports.selfLoopSide(direction, endpoint)
    else
        ports.forwardSide(direction, endpoint);
    const len = switch (side) {
        .north, .south => placement.rect.w,
        .east, .west => placement.rect.h,
    };
    return .{ .port = .{ .node = placement.id, .side = side, .offset = ports.midpoint(len) }, .ordinal = 0 };
}

fn selectedGroup(joins: pb.RealizedJoins, edge: pb.EdgeId, endpoint: pb.EndpointSide) ?pb.JoinGroupId {
    for (joins.memberships) |membership| {
        if (membership.edge != edge) continue;
        const disposition = if (endpoint == .source_exit) membership.source else membership.target;
        const selected = disposition orelse return null;
        const jid = switch (selected) {
            .selected => |id| id,
            .independent => return null,
        };
        for (joins.selected_joins) |join| if (join.id == jid) return join.permission_group;
    }
    return null;
}

fn placementById(placements: []const sk.NodePlacement, id: pb.NodeId) ?sk.NodePlacement {
    for (placements) |placement| if (placement.id == id) return placement;
    return null;
}

fn edgeById(graph: sg.SemGraph, id: pb.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| if (edge.id == id) return edge;
    return null;
}

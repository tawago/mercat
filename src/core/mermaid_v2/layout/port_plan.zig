//! Candidate-local D-PORT sizing, allocation, and routing lookup.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const ports = @import("ports.zig");
const sugiyama = @import("sugiyama.zig");

pub const EdgePorts = struct { edge: pb.EdgeId, source: sk.Port, target: sk.Port, source_ordinal: u32, target_ordinal: u32, route_lane: u32 = 0 };

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
        out.* = .{ .edge = edge.id, .source = source.port, .target = target.port, .source_ordinal = 0, .target_ordinal = 0 };
    }
    return .{ .edges = edges };
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
        if (edge.kind == .invisible or edge.from == edge.to or !edgeIsIndependent(joins.memberships, edge.id) or inMesh(joins.mesh_unions, edge.id)) continue;
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
        const allocation = try ports.allocate(a, .{ .rung = rung }, placement.id, side, len, attachments);
        switch (allocation) {
            .assigned => |items| try faces.append(a, .{ .node = placement.id, .side = side, .items = items }),
            .failed => continue,
        }
    };

    const edge_ports = try a.alloc(EdgePorts, graph.edges.len);
    var terminals: std.ArrayListUnmanaged(pb.TerminalPort) = .empty;
    for (graph.edges, edge_ports) |edge, *out| {
        const source = resolvePort(graph, placements, faces.items, joins, edge, .source_exit);
        const target = resolvePort(graph, placements, faces.items, joins, edge, .target_entry);
        out.* = .{
            .edge = edge.id,
            .source = source.port,
            .target = target.port,
            .source_ordinal = source.ordinal,
            .target_ordinal = target.ordinal,
            .route_lane = laneFor(lane_plan.lanes, edge.id),
        };
        try terminals.append(a, .{ .node = edge.from, .edge = edge.id, .endpoint_side = .source_exit, .port = source.ordinal });
        try terminals.append(a, .{ .node = edge.to, .edge = edge.id, .endpoint_side = .target_entry, .port = target.ordinal });
    }
    return .{ .edges = edge_ports, .terminals = try terminals.toOwnedSlice(a) };
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
    return std.mem.lessThan(u8, xl, yl);
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
    joins: pb.RealizedJoins,
    edge: sg.Edge,
    endpoint: pb.EndpointSide,
) ResolvedPort {
    const node = if (endpoint == .source_exit) edge.from else edge.to;
    const placement = placementById(placements, node) orelse placements[0];
    if (inMesh(joins.mesh_unions, edge.id)) return midpointPort(graph.direction, placement, edge, endpoint);
    const selected_group = selectedGroup(joins, edge.id, endpoint);
    for (faces) |face| {
        if (face.node != node) continue;
        for (face.items) |assignment| {
            const matches = if (selected_group) |group|
                assignment.attachment.class == .trunk_pivot and assignment.attachment.group == group
            else
                assignment.attachment.class == .independent and assignment.attachment.edge == edge.id and
                    assignment.attachment.key.endpoint_side == endpoint;
            if (matches) return .{
                .port = .{ .node = node, .side = face.side, .offset = assignment.offset },
                .ordinal = assignment.ordinal,
            };
        }
    }
    return midpointPort(graph.direction, placement, edge, endpoint);
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

fn inMesh(unions: []const pb.MeshUnion, edge: pb.EdgeId) bool {
    for (unions) |u| for (u.members) |member| if (member == edge) return true;
    return false;
}

fn placementById(placements: []const sk.NodePlacement, id: pb.NodeId) ?sk.NodePlacement {
    for (placements) |placement| if (placement.id == id) return placement;
    return null;
}

fn edgeById(graph: sg.SemGraph, id: pb.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| if (edge.id == id) return edge;
    return null;
}

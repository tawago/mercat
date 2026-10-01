const std = @import("std");
const pb = @import("../base/ledger.zig");
const tie_break = @import("../base/tie_break.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const rail_closure = @import("../base/rail_closure.zig");
const fan_types = @import("fan_types.zig");

pub fn forwardSide(direction: sg.Direction, endpoint_side: pb.EndpointSide) sk.Dir4 {
    const out = endpoint_side == .source_exit;
    return switch (direction) {
        .TD => if (out) sk.Dir4.south else .north,
        .BT => if (out) sk.Dir4.north else .south,
        .LR => if (out) sk.Dir4.east else .west,
        .RL => if (out) sk.Dir4.west else .east,
    };
}

pub fn reversedSide(direction: sg.Direction) sk.Dir4 {
    return switch (direction) {
        .TD, .BT => .east,
        .LR, .RL => .south,
    };
}

pub fn selfLoopSide(direction: sg.Direction, endpoint_side: pb.EndpointSide) sk.Dir4 {
    return switch (direction) {
        .TD, .BT => if (endpoint_side == .source_exit) sk.Dir4.east else .north,
        .LR, .RL => .south,
    };
}

pub fn midpoint(side_len: u32) u32 {
    return side_len / 2;
}

pub fn satisfiable(side_len: u32, demand: u32) bool {
    return side_len >= 2 * demand + 1;
}

pub fn offsetAt(side_len: u32, demand: u32, i: u32) u32 {
    return midpoint(side_len) + 1 - demand + 2 * i;
}

pub const AttachmentClass = enum { independent, rail_pivot };

pub const Attachment = struct {
    class: AttachmentClass = .independent,
    key: tie_break.AttachmentKey,
    edge: ?pb.EdgeId = null,
    group: ?pb.CandidateBundleId = null,
    members: []const pb.EdgeId = &.{},
    opposite_center: i32 = 0,
};

fn attachmentLess(_: void, x: Attachment, y: Attachment) bool {
    if (x.opposite_center != y.opposite_center) return x.opposite_center < y.opposite_center;
    return tie_break.attachmentKeyOrder(x.key, y.key) == .lt;
}

pub const DerivedAttachment = struct {
    node: pb.NodeId,
    side: sk.Dir4,
    attachment: Attachment,
};

pub const DeriveError = error{ OutOfMemory, InvalidSemGraph };

pub fn edgeAttachmentKey(graph: sg.SemGraph, edge: sg.Edge, endpoint_side: pb.EndpointSide) error{InvalidSemGraph}!tie_break.AttachmentKey {
    const opposite_id = if (endpoint_side == .source_exit) edge.to else edge.from;
    const opposite = graph.nodeById(opposite_id) orelse return error.InvalidSemGraph;
    return .{
        .opposite = opposite.raw_id,
        .endpoint_side = endpoint_side,
        .kind = tie_break.edgeKindOrdinal(edge.kind),
        .arrow_from = tie_break.arrowEndOrdinal(edge.arrow_from),
        .arrow_to = tie_break.arrowEndOrdinal(edge.arrow_to),
        .label = edge.label,
    };
}

pub fn derive(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    plan: pb.BundlePermits,
    bundles: pb.RealizedBundles,
    direction: sg.Direction,
    reversed_edges: []const pb.EdgeId,
) DeriveError![]const DerivedAttachment {
    var out: std.ArrayListUnmanaged(DerivedAttachment) = .empty;
    var fused_leaves: std.ArrayListUnmanaged(FusedLeaf) = .empty;
    for (graph.edges) |edge| {
        if (edge.from == edge.to) {
            inline for ([2]pb.EndpointSide{ .source_exit, .target_entry }) |es| {
                try out.append(a, .{
                    .node = edge.from,
                    .side = selfLoopSide(direction, es),
                    .attachment = .{ .key = try edgeAttachmentKey(graph, edge, es), .edge = edge.id },
                });
            }
            continue;
        }
        const membership = membershipOf(bundles, edge.id);
        const reversed = pb.containsEdge(reversed_edges, edge.id);
        if (!reversed and (membership == null or (membership.?.source == null and membership.?.target == null))) {
            inline for ([2]pb.EndpointSide{ .source_exit, .target_entry }) |es| {
                const n = if (es == .source_exit) edge.from else edge.to;
                const sd = forwardSide(direction, es);
                if (hasSelfLoopSide(graph, direction, n, sd))
                    try out.append(a, .{ .node = n, .side = sd, .attachment = .{ .key = try edgeAttachmentKey(graph, edge, es), .edge = edge.id } });
            }
            continue;
        }
        inline for ([2]pb.EndpointSide{ .source_exit, .target_entry }) |es| {
            const disp = if (membership) |m| (if (es == .source_exit) m.source else m.target) else null;
            if (!isSelected(disp)) {
                const n = if (es == .source_exit) edge.from else edge.to;
                const sd = if (reversed) reversedSide(direction) else forwardSide(direction, es);
                const poolable = !reversed and (edge.label == null or edge.label.?.len == 0);
                const fused_u = if (poolable) fusedUnionIndex(bundles.fused, edge.id) else null;
                if (fused_u) |ui| {
                    try fused_leaves.append(a, .{ .u = ui, .node = n, .side = sd, .es = es, .edge = edge.id });
                } else {
                    try out.append(a, .{
                        .node = n,
                        .side = sd,
                        .attachment = .{
                            .key = try edgeAttachmentKey(graph, edge, es),
                            .edge = edge.id,
                            .group = independentGroup(disp),
                        },
                    });
                }
            }
        }
    }
    for (bundles.selected_bundles) |sel| {
        const gi = groupIndexById(plan.groups, sel.candidate_bundle) orelse return error.InvalidSemGraph;
        const group = plan.groups[gi];
        const es: pb.EndpointSide = if (group.direction == .out) .source_exit else .target_entry;
        var best: ?tie_break.AttachmentKey = null;
        var best_edge: pb.EdgeId = 0;
        for (sel.members) |member| {
            const edge = graph.edgeById(member) orelse return error.InvalidSemGraph;
            const key = try edgeAttachmentKey(graph, edge, es);
            if (best == null or tie_break.attachmentKeyOrder(key, best.?) == .lt) {
                best = key;
                best_edge = member;
            }
        }
        try out.append(a, .{
            .node = group.pivot,
            .side = forwardSide(direction, es),
            .attachment = .{
                .class = .rail_pivot,
                .key = best orelse return error.InvalidSemGraph,
                .edge = best_edge,
                .group = sel.candidate_bundle,
                .members = sel.members,
            },
        });
    }
    for (fused_leaves.items, 0..) |head, i| {
        if (seenLeaf(fused_leaves.items[0..i], head)) continue;
        var best: ?tie_break.AttachmentKey = null;
        var best_edge: pb.EdgeId = 0;
        var members: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        for (fused_leaves.items[i..]) |leaf| {
            if (leaf.u != head.u or leaf.node != head.node or leaf.side != head.side) continue;
            const edge = graph.edgeById(leaf.edge) orelse return error.InvalidSemGraph;
            const key = try edgeAttachmentKey(graph, edge, leaf.es);
            if (best == null or tie_break.attachmentKeyOrder(key, best.?) == .lt) {
                best = key;
                best_edge = leaf.edge;
            }
            try members.append(a, leaf.edge);
        }
        try out.append(a, .{
            .node = head.node,
            .side = head.side,
            .attachment = .{
                .class = .rail_pivot,
                .key = best orelse return error.InvalidSemGraph,
                .edge = best_edge,
                .members = try members.toOwnedSlice(a),
            },
        });
    }
    return try out.toOwnedSlice(a);
}

const FusedLeaf = struct { u: usize, node: pb.NodeId, side: sk.Dir4, es: pb.EndpointSide, edge: pb.EdgeId };

fn seenLeaf(prior: []const FusedLeaf, head: FusedLeaf) bool {
    for (prior) |leaf| if (leaf.u == head.u and leaf.node == head.node and leaf.side == head.side) return true;
    return false;
}

fn fusedUnionIndex(fused: []const []const pb.EdgeId, edge: pb.EdgeId) ?usize {
    for (fused, 0..) |u, i| if (pb.containsEdge(u, edge)) return i;
    return null;
}

pub fn deriveFanAttachments(a: std.mem.Allocator, graph: sg.SemGraph, direction: sg.Direction, reversed_edges: []const pb.EdgeId, fans: []const fan_types.Fan) DeriveError![]const DerivedAttachment {
    var out: std.ArrayListUnmanaged(DerivedAttachment) = .empty;
    for (graph.edges) |edge| {
        if (edge.kind == .invisible) continue;
        for ([2]pb.EndpointSide{ .source_exit, .target_entry }) |endpoint| {
            const node = if (endpoint == .source_exit) edge.from else edge.to;
            const side = if (edge.from == edge.to)
                selfLoopSide(direction, endpoint)
            else if (pb.containsEdge(reversed_edges, edge.id))
                reversedSide(direction)
            else
                forwardSide(direction, endpoint);
            if (sharedFan(fans, edge.id, endpoint)) |fan| {
                const rail = try fanAttachment(a, graph, fan, endpoint);
                if (rail.edge != edge.id) continue;
                try out.append(a, .{ .node = node, .side = side, .attachment = rail });
                continue;
            }
            try out.append(a, .{
                .node = node,
                .side = side,
                .attachment = .{ .key = try edgeAttachmentKey(graph, edge, endpoint), .edge = edge.id },
            });
        }
    }
    return try out.toOwnedSlice(a);
}

fn sharedFan(fans: []const fan_types.Fan, edge: pb.EdgeId, endpoint: pb.EndpointSide) ?fan_types.Fan {
    for (fans) |fan| {
        const pivot_endpoint = if (fan.direction == .out) pb.EndpointSide.source_exit else .target_entry;
        if (endpoint != pivot_endpoint) continue;
        for (fan.peers) |peer| if (peer.shared and peer.edge_id == edge) return fan;
    }
    return null;
}

fn fanAttachment(a: std.mem.Allocator, graph: sg.SemGraph, fan: fan_types.Fan, endpoint: pb.EndpointSide) DeriveError!Attachment {
    var best: ?tie_break.AttachmentKey = null;
    var best_edge: pb.EdgeId = 0;
    var members: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (fan.peers) |peer| {
        if (!peer.shared) continue;
        const edge = graph.edgeById(peer.edge_id) orelse return error.InvalidSemGraph;
        const key = try edgeAttachmentKey(graph, edge, endpoint);
        if (best == null or tie_break.attachmentKeyOrder(key, best.?) == .lt) {
            best = key;
            best_edge = edge.id;
        }
        try members.append(a, edge.id);
    }
    return .{
        .class = .rail_pivot,
        .key = best orelse return error.InvalidSemGraph,
        .edge = best_edge,
        .members = try members.toOwnedSlice(a),
    };
}

pub fn withoutDischarged(
    a: std.mem.Allocator,
    derived: []const DerivedAttachment,
    bundles: pb.RealizedBundles,
) error{OutOfMemory}![]const DerivedAttachment {
    if (bundles.discharged.len == 0) return derived;
    var out: std.ArrayListUnmanaged(DerivedAttachment) = .empty;
    for (derived) |item| {
        const edge = item.attachment.edge orelse {
            try out.append(a, item);
            continue;
        };
        if (rail_closure.contains(bundles.discharged, edge)) continue;
        try out.append(a, item);
    }
    return out.toOwnedSlice(a);
}

pub fn forSide(a: std.mem.Allocator, derived: []const DerivedAttachment, node: pb.NodeId, side: sk.Dir4) error{OutOfMemory}![]const Attachment {
    var out: std.ArrayListUnmanaged(Attachment) = .empty;
    for (derived) |item| {
        if (item.node == node and item.side == side) try out.append(a, item.attachment);
    }
    return try out.toOwnedSlice(a);
}

pub const SideDemand = struct { north: u32 = 0, south: u32 = 0, east: u32 = 0, west: u32 = 0 };

pub fn sideDemand(derived: []const DerivedAttachment, node: pb.NodeId) SideDemand {
    var d: SideDemand = .{};
    for (derived) |item| {
        if (item.node != node) continue;
        switch (item.side) {
            .north => d.north += 1,
            .south => d.south += 1,
            .east => d.east += 1,
            .west => d.west += 1,
        }
    }
    return d;
}

pub const MinDims = struct { w_min: u32, h_min: u32 };

pub fn demandDims(d: SideDemand) MinDims {
    return .{ .w_min = 2 * @max(d.north, d.south) + 1, .h_min = 2 * @max(d.east, d.west) + 1 };
}

pub const Assignment = struct { attachment: Attachment, ordinal: u32, offset: u32 };

pub const Allocation = union(enum) { assigned: []const Assignment, key_collision, capacity_exceeded };

pub fn allocate(a: std.mem.Allocator, side_len: u32, attachments: []const Attachment) error{OutOfMemory}!Allocation {
    if (hasKeyCollision(attachments)) return .key_collision;
    const demand: u32 = @intCast(attachments.len);
    if (!satisfiable(side_len, demand)) return .capacity_exceeded;
    const sorted = try a.dupe(Attachment, attachments);
    std.mem.sort(Attachment, sorted, {}, attachmentLess);
    const out = try a.alloc(Assignment, sorted.len);
    for (sorted, out, 0..) |att, *slot, i| slot.* = .{
        .attachment = att,
        .ordinal = @intCast(i),
        .offset = offsetAt(side_len, demand, @intCast(i)),
    };
    return .{ .assigned = out };
}

fn hasKeyCollision(attachments: []const Attachment) bool {
    for (attachments, 0..) |x, i| {
        for (attachments[0..i]) |y| {
            if (tie_break.attachmentKeyOrder(x.key, y.key) == .eq) return true;
        }
    }
    return false;
}

fn hasSelfLoopSide(graph: sg.SemGraph, dir: sg.Direction, node: pb.NodeId, side: sk.Dir4) bool {
    for (graph.edges) |e|
        if (e.from == e.to and e.from == node and
            (selfLoopSide(dir, .source_exit) == side or selfLoopSide(dir, .target_entry) == side)) return true;
    return false;
}

fn groupIndexById(groups: []const pb.CandidateBundle, id: pb.CandidateBundleId) ?usize {
    for (groups, 0..) |group, i| if (group.id == id) return i;
    return null;
}

fn membershipOf(bundles: pb.RealizedBundles, edge: pb.EdgeId) ?pb.RealizedEdgeMembership {
    for (bundles.memberships) |m| if (m.edge == edge) return m;
    return null;
}

fn isSelected(disp: ?pb.MembershipDisposition) bool {
    const d = disp orelse return false;
    return d == .selected;
}

fn independentGroup(disp: ?pb.MembershipDisposition) ?pb.CandidateBundleId {
    const d = disp orelse return null;
    return switch (d) {
        .selected => null,
        .independent => |ind| ind.candidate_bundle,
    };
}

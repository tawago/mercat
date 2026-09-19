const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");

/// @guarded-by: ports_test.zig "side conventions are frozen per direction for forward, reversed, and self-loop attachments"
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

/// @guarded-by: ports_test.zig "V-D-PORT-12: a TD self-loop derives two typed terminals (east exit, north entry)"
pub fn selfLoopSide(direction: sg.Direction, endpoint_side: pb.EndpointSide) sk.Dir4 {
    return switch (direction) {
        .TD, .BT => if (endpoint_side == .source_exit) sk.Dir4.east else .north,
        .LR, .RL => .south,
    };
}

/// @guarded-by: ports_test.zig "V-D-PORT-04: a singleton port is exactly today's midpoint floor(L/2)"
pub fn midpoint(side_len: u32) u32 {
    return side_len / 2;
}

pub fn satisfiable(side_len: u32, demand: u32) bool {
    return side_len >= 2 * demand + 1;
}

/// @guarded-by: ports_test.zig "V-D-PORT-03: offsets follow o_i = m-(p-1)+2i with pitch 2 and corners excluded on odd and even faces"
pub fn offsetAt(side_len: u32, demand: u32, i: u32) u32 {
    return midpoint(side_len) + 1 - demand + 2 * i;
}

pub const AttachmentClass = enum { independent, rail_pivot };

pub const Attachment = struct {
    class: AttachmentClass = .independent,
    key: pb.AttachmentKey,
    edge: ?pb.EdgeId = null,
    group: ?pb.CandidateBundleId = null,
    members: []const pb.EdgeId = &.{},
    opposite_center: i32 = 0,
};

/// @guarded-by: ports_test.zig "clause-6 order: opposite center is primary, K breaks ties with no-label first and pinned ordinals"
fn attachmentLess(_: void, x: Attachment, y: Attachment) bool {
    if (x.opposite_center != y.opposite_center) return x.opposite_center < y.opposite_center;
    return pb.attachmentKeyOrder(x.key, y.key) == .lt;
}

pub const DerivedAttachment = struct {
    node: pb.NodeId,
    side: sk.Dir4,
    attachment: Attachment,
};

pub const DeriveError = error{ OutOfMemory, InvalidSemGraph };

pub fn edgeAttachmentKey(graph: sg.SemGraph, edge: sg.Edge, endpoint_side: pb.EndpointSide) error{InvalidSemGraph}!pb.AttachmentKey {
    const opposite_id = if (endpoint_side == .source_exit) edge.to else edge.from;
    const opposite = nodeById(graph, opposite_id) orelse return error.InvalidSemGraph;
    return .{
        .opposite = opposite.raw_id,
        .endpoint_side = endpoint_side,
        .kind = pb.edgeKindOrdinal(edge.kind),
        .arrow_from = pb.arrowEndOrdinal(edge.arrow_from),
        .arrow_to = pb.arrowEndOrdinal(edge.arrow_to),
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
        const reversed = containsEdge(reversed_edges, edge.id);
        if (!reversed and (membership == null or (membership.?.source == null and membership.?.target == null))) {
            // @guarded-by: ports_step7_test.zig "a plain forward arrival co-located with a self-loop terminal joins the side allocation"
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
            // @guarded-by: ports_test.zig "a fused union's leaf node exits through one shared attachment"
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
    // @guarded-by: ports_test.zig "derivation: a committed group consumes one rail pivot attachment keyed by its smallest member K"
    for (bundles.selected_bundles) |sel| {
        const gi = groupIndexById(plan.groups, sel.candidate_bundle) orelse return error.InvalidSemGraph;
        const group = plan.groups[gi];
        const es: pb.EndpointSide = if (group.direction == .out) .source_exit else .target_entry;
        var best: ?pb.AttachmentKey = null;
        var best_edge: pb.EdgeId = 0;
        for (sel.members) |member| {
            const edge = edgeById(graph, member) orelse return error.InvalidSemGraph;
            const key = try edgeAttachmentKey(graph, edge, es);
            if (best == null or pb.attachmentKeyOrder(key, best.?) == .lt) {
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
        var best: ?pb.AttachmentKey = null;
        var best_edge: pb.EdgeId = 0;
        var members: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        for (fused_leaves.items[i..]) |leaf| {
            if (leaf.u != head.u or leaf.node != head.node or leaf.side != head.side) continue;
            const edge = edgeById(graph, leaf.edge) orelse return error.InvalidSemGraph;
            const key = try edgeAttachmentKey(graph, edge, leaf.es);
            if (best == null or pb.attachmentKeyOrder(key, best.?) == .lt) {
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
    for (fused, 0..) |u, i| if (containsEdge(u, edge)) return i;
    return null;
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

/// @guarded-by: ports_test.zig "demandDims computes 2*max+1 per axis"
pub fn demandDims(d: SideDemand) MinDims {
    return .{ .w_min = 2 * @max(d.north, d.south) + 1, .h_min = 2 * @max(d.east, d.west) + 1 };
}

pub const CandidateRef = struct { candidate: u32 = 0, rung: u8 = 0 };

pub const Assignment = struct { attachment: Attachment, ordinal: u32, offset: u32 };

pub const decision_row_clause_12 = "D-PORT clause 12";
pub const capacity_reason =
    "demanded side cannot reach 2p+1 under an external clamp; MUST NOT share a cell, " ++
    "drop an attachment, or fall back to the shared midpoint";
pub const capacity_action = "reject candidate and report, per D-DISPOSITION";

pub const CapacityExceeded = struct {
    candidate: CandidateRef,
    node: pb.NodeId,
    side: sk.Dir4,
    demand: u32,
    available: u32,
    classes: []const AttachmentClass,
    edges: []const pb.EdgeId,
    groups: []const pb.CandidateBundleId,
    decision_row: []const u8 = decision_row_clause_12,
    reason: []const u8 = capacity_reason,
    expected_action: []const u8 = capacity_action,
};

pub const KeyCollision = struct {
    node: pb.NodeId,
    side: sk.Dir4,
    key: pb.AttachmentKey,
    edges: []const pb.EdgeId,
    deferred_to: []const u8 = "D-DUPLICATE",
};

pub const Failure = union(enum) { capacity_exceeded: CapacityExceeded, key_collision: KeyCollision };

pub const Allocation = union(enum) { assigned: []const Assignment, failed: Failure };

/// @guarded-by: ports_test.zig "V-D-PORT-02: attachment input permutation yields byte-identical assignments"
/// @guarded-by: ports_test.zig "V-D-PORT-10: clamped L=3 with p=2 emits port_capacity_exceeded with the full clause-12 payload and no allocation"
pub fn allocate(a: std.mem.Allocator, candidate: CandidateRef, node: pb.NodeId, side: sk.Dir4, side_len: u32, attachments: []const Attachment) error{OutOfMemory}!Allocation {
    if (try findCollision(a, node, side, attachments)) |kc|
        return .{ .failed = .{ .key_collision = kc } };
    const demand: u32 = @intCast(attachments.len);
    if (!satisfiable(side_len, demand))
        return .{ .failed = .{ .capacity_exceeded = try capacityPayload(a, candidate, node, side, side_len, attachments) } };
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

fn findCollision(a: std.mem.Allocator, node: pb.NodeId, side: sk.Dir4, attachments: []const Attachment) error{OutOfMemory}!?KeyCollision {
    var dup: ?pb.AttachmentKey = null;
    for (attachments, 0..) |x, i| {
        for (attachments[0..i]) |y| {
            if (pb.attachmentKeyOrder(x.key, y.key) != .eq) continue;
            if (dup == null or pb.attachmentKeyOrder(x.key, dup.?) == .lt) dup = x.key;
        }
    }
    const key = dup orelse return null;
    var edges: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (attachments) |x| {
        if (pb.attachmentKeyOrder(x.key, key) != .eq) continue;
        if (x.edge) |e| try appendUnique(pb.EdgeId, a, &edges, e);
        for (x.members) |member| try appendUnique(pb.EdgeId, a, &edges, member);
    }
    std.mem.sort(pb.EdgeId, edges.items, {}, std.sort.asc(pb.EdgeId));
    return .{ .node = node, .side = side, .key = key, .edges = try edges.toOwnedSlice(a) };
}

fn capacityPayload(a: std.mem.Allocator, candidate: CandidateRef, node: pb.NodeId, side: sk.Dir4, side_len: u32, attachments: []const Attachment) error{OutOfMemory}!CapacityExceeded {
    const sorted = try a.dupe(Attachment, attachments);
    std.mem.sort(Attachment, sorted, {}, attachmentLess);
    const classes = try a.alloc(AttachmentClass, sorted.len);
    var edges: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    var groups: std.ArrayListUnmanaged(pb.CandidateBundleId) = .empty;
    for (sorted, classes) |att, *class| {
        class.* = att.class;
        if (att.edge) |e| try appendUnique(pb.EdgeId, a, &edges, e);
        for (att.members) |member| try appendUnique(pb.EdgeId, a, &edges, member);
        if (att.group) |g| try appendUnique(pb.CandidateBundleId, a, &groups, g);
    }
    return .{
        .candidate = candidate,
        .node = node,
        .side = side,
        .demand = @intCast(sorted.len),
        .available = side_len,
        .classes = classes,
        .edges = try edges.toOwnedSlice(a),
        .groups = try groups.toOwnedSlice(a),
    };
}

fn nodeById(graph: sg.SemGraph, id: sg.NodeId) ?sg.Node {
    for (graph.nodes) |node| if (node.id == id) return node;
    return null;
}

fn edgeById(graph: sg.SemGraph, id: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| if (edge.id == id) return edge;
    return null;
}

fn containsEdge(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |candidate| if (candidate == edge) return true;
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

fn appendUnique(comptime T: type, a: std.mem.Allocator, list: *std.ArrayListUnmanaged(T), value: T) error{OutOfMemory}!void {
    for (list.items) |x| if (x == value) return;
    try list.append(a, value);
}

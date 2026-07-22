//! Pure D-PORT allocator consumed by the Step 7 layout path.
//!
//! Split per D-PORT clause 5: the attachment SET per (node, side) + each
//! terminal's identity derive from SemGraph + plan records only (`derive` —
//! never geometry); perimeter COORDINATES are a pure function of (final
//! placements, K) (`allocate` — caller fills `opposite_center`). Whether a
//! fan group yields one trunk pivot or per-member independents is the input
//! plan's statement (`joins.selected_joins`), never a default here (both
//! OPEN-1 readings stay expressible). Failures are typed DATA results (never
//! panics, never silent coalescing — TSD §7.7).
//!
//! Imports (layout/ zone): std, ../ledger.zig, ../sem_graph.zig,
//! ../sketch.zig. Tests live in ports_test.zig (aggregated from entry.zig).

const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");

// -- Side conventions (D-PORT clause 3, current conventions frozen) ----------

/// Forward: TD out=south/in=north; BT out=north/in=south; LR out=east/in=west; RL out=west/in=east (routing.zig:355-360).
/// guarded-by: ports_test.zig "side conventions are frozen per direction for forward, reversed, and self-loop attachments"
pub fn forwardSide(direction: sg.Direction, endpoint_side: pb.EndpointSide) sk.Dir4 {
    const out = endpoint_side == .source_exit;
    return switch (direction) {
        .TD => if (out) sk.Dir4.south else .north,
        .BT => if (out) sk.Dir4.north else .south,
        .LR => if (out) sk.Dir4.east else .west,
        .RL => if (out) sk.Dir4.west else .east,
    };
}

/// Reversed (back-)edges, exit and entry alike: TD/BT → east, LR/RL → south (back_edges.zig:132-144).
pub fn reversedSide(direction: sg.Direction) sk.Dir4 {
    return switch (direction) {
        .TD, .BT => .east,
        .LR, .RL => .south,
    };
}

/// Self-loops keep their classic side pairs but occupy TWO distinct typed terminals.
/// guarded-by: ports_test.zig "V-D-PORT-12: a TD self-loop derives two typed terminals (east exit, north entry)"
pub fn selfLoopSide(direction: sg.Direction, endpoint_side: pb.EndpointSide) sk.Dir4 {
    return switch (direction) {
        .TD, .BT => if (endpoint_side == .source_exit) sk.Dir4.east else .north,
        .LR, .RL => .south,
    };
}

// -- Offset formula, pitch, corners (D-PORT clause 7) -------------------------

/// p = 1 yields exactly today's midpoint (routing.zig:361-365) — the zero-change anchor.
/// guarded-by: ports_test.zig "V-D-PORT-04: a singleton port is exactly today's midpoint floor(L/2)"
pub fn midpoint(side_len: u32) u32 {
    return side_len / 2;
}

/// Capacity of one side: floor((L-1)/2). Demand p is satisfiable iff L >= 2p+1.
/// guarded-by: ports_test.zig "V-D-PORT-04: capacity boundary L=2p+1 allocates and L=2p fails typed"
pub fn capacity(side_len: u32) u32 {
    return (side_len -| 1) / 2;
}

pub fn satisfiable(side_len: u32, demand: u32) bool {
    return side_len >= 2 * demand + 1;
}

/// o_i = m - (p-1) + 2*i, m = floor(L/2) — pitch 2, centered on m, corners excluded. Needs `satisfiable(side_len, demand)`.
/// guarded-by: ports_test.zig "V-D-PORT-03: offsets follow o_i = m-(p-1)+2i with pitch 2 and corners excluded on odd and even faces"
pub fn offsetAt(side_len: u32, demand: u32, i: u32) u32 {
    return midpoint(side_len) + 1 - demand + 2 * i;
}

// -- Attachments (identity side, clause 5) ------------------------------------

pub const AttachmentClass = enum { independent, trunk_pivot };

/// One demanded terminal on a (node, side) face. Identity fields derive
/// from SemGraph + plan records only; `opposite_center` is the ONE geometric
/// input (clause 6 primary), filled by the caller. A self-loop terminal's
/// opposite center is the node's own center.
pub const Attachment = struct {
    class: AttachmentClass = .independent,
    /// Canonical attachment key K (clause 4); trunk pivot: smallest member K (clause 10).
    key: pb.AttachmentKey,
    /// independent: the owning edge. trunk_pivot: clause-10 smallest member (whose opposite center the pivot orders by).
    edge: ?pb.EdgeId = null,
    /// independent: its permission group, if any. trunk_pivot: the committed group.
    group: ?pb.JoinGroupId = null,
    /// trunk_pivot: the full committed member set; else empty.
    members: []const pb.EdgeId = &.{},
    /// Opposite endpoint's placed center along the side axis (clause 6: x for north/south, y for east/west).
    opposite_center: i32 = 0,
};

/// Clause-6 within-side total order: opposite placed center ascending, then K
/// ascending. Byte-identical K is a clause-13 collision caught before this, so
/// the order is total and input-order-independent.
/// guarded-by: ports_test.zig "clause-6 order: opposite center is primary, K breaks ties with no-label first and pinned ordinals"
fn attachmentLess(_: void, x: Attachment, y: Attachment) bool {
    if (x.opposite_center != y.opposite_center) return x.opposite_center < y.opposite_center;
    return pb.attachmentKeyOrder(x.key, y.key) == .lt;
}

// -- Attachment-set derivation (SemGraph + plan records only, clause 5) -------

pub const DerivedAttachment = struct {
    node: pb.NodeId,
    side: sk.Dir4,
    attachment: Attachment,
};

pub const DeriveError = error{ OutOfMemory, InvalidSemGraph };

/// Canonical attachment key K for one endpoint of one edge (clause 4):
/// (opposite raw_id, endpoint_side, EdgeKind ordinal, arrow ordinals, label). Purely semantic.
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

/// Derive the attachment set per (node, side): independent attachments +
/// one trunk pivot per committed group (clause 10) + self-loop terminals
/// (two typed terminals, clause 3) + reversed-edge side entries/exits
/// (endpoint_side splits K). `direction`/`reversed_edges` are plan-level
/// records, not geometry. Output order is incidental (`allocate` sorts).
pub fn derive(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    plan: pb.JoinPermits,
    joins: pb.RealizedJoins,
    direction: sg.Direction,
    reversed_edges: []const pb.EdgeId,
) DeriveError![]const DerivedAttachment {
    var out: std.ArrayListUnmanaged(DerivedAttachment) = .empty;
    for (graph.edges) |edge| {
        // Exempt complete meshes retain their fused midpoint terminals.
        if (meshContains(joins.mesh_unions, edge.id)) continue;
        if (edge.from == edge.to) {
            // Self-loop: always two distinct typed terminals (clause 3),
            // regardless of any group membership.
            inline for ([2]pb.EndpointSide{ .source_exit, .target_entry }) |es| {
                try out.append(a, .{
                    .node = edge.from,
                    .side = selfLoopSide(direction, es),
                    .attachment = .{ .key = try edgeAttachmentKey(graph, edge, es), .edge = edge.id },
                });
            }
            continue;
        }
        const membership = membershipOf(joins, edge.id);
        const reversed = containsEdge(reversed_edges, edge.id);
        if (!reversed and (membership == null or (membership.?.source == null and membership.?.target == null))) {
            // Plain forward edge keeps its midpoint UNLESS an endpoint lands on
            // a (node, side) hosting a self-loop terminal: then it joins that
            // side's allocation so the two get distinct pitch-2 cells, never a
            // shared midpoint (D-PORT clause 3 / D-REACH clause 9(a): a self-
            // loop owns its own two terminals, unshared with a foreign edge).
            // guarded-by: ports_step7_test.zig "a plain forward arrival co-located with a self-loop terminal joins the side allocation"
            inline for ([2]pb.EndpointSide{ .source_exit, .target_entry }) |es| {
                const n = if (es == .source_exit) edge.from else edge.to;
                const sd = forwardSide(direction, es);
                if (hasSelfLoopSide(graph, joins, direction, n, sd))
                    try out.append(a, .{ .node = n, .side = sd, .attachment = .{ .key = try edgeAttachmentKey(graph, edge, es), .edge = edge.id } });
            }
            continue;
        }
        inline for ([2]pb.EndpointSide{ .source_exit, .target_entry }) |es| {
            const disp = if (membership) |m| (if (es == .source_exit) m.source else m.target) else null;
            // A selected endpoint is covered by its group's one pivot
            // attachment; the opposite endpoint stays a per-member entry/exit.
            if (!isSelected(disp)) {
                try out.append(a, .{
                    .node = if (es == .source_exit) edge.from else edge.to,
                    .side = if (reversed) reversedSide(direction) else forwardSide(direction, es),
                    .attachment = .{
                        .key = try edgeAttachmentKey(graph, edge, es),
                        .edge = edge.id,
                        .group = independentGroup(disp),
                    },
                });
            }
        }
    }
    // One pivot attachment per committed group (clause 10), keyed by the
    // lexicographically-smallest member K; forward BusBar geometry → forward side.
    // guarded-by: ports_test.zig "derivation: a committed group consumes one trunk pivot attachment keyed by its smallest member K"
    for (joins.selected_joins) |join| {
        const gi = groupIndexById(plan.groups, join.permission_group) orelse return error.InvalidSemGraph;
        const group = plan.groups[gi];
        const es: pb.EndpointSide = if (group.direction == .out) .source_exit else .target_entry;
        var best: ?pb.AttachmentKey = null;
        var best_edge: pb.EdgeId = 0;
        for (join.members) |member| {
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
                .class = .trunk_pivot,
                .key = best orelse return error.InvalidSemGraph,
                .edge = best_edge,
                .group = join.permission_group,
                .members = join.members,
            },
        });
    }
    return try out.toOwnedSlice(a);
}

/// Attachments of one (node, side) face, in derived (incidental) order —
/// the `allocate` input shape.
pub fn forSide(a: std.mem.Allocator, derived: []const DerivedAttachment, node: pb.NodeId, side: sk.Dir4) error{OutOfMemory}![]const Attachment {
    var out: std.ArrayListUnmanaged(Attachment) = .empty;
    for (derived) |item| {
        if (item.node == node and item.side == side) try out.append(a, item.attachment);
    }
    return try out.toOwnedSlice(a);
}

// -- Port-demand sizing helper (clause 9, returned for Step 7) ----------------

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

/// Visual (pre-LR/RL-swap) capacity minima: w_min = 2*max(p_n, p_s)+1,
/// h_min = 2*max(p_e, p_w)+1; maxed against today's minima, mapped like label dims.
/// guarded-by: ports_test.zig "demandDims computes 2*max+1 per axis"
pub fn demandDims(d: SideDemand) MinDims {
    return .{ .w_min = 2 * @max(d.north, d.south) + 1, .h_min = 2 * @max(d.east, d.west) + 1 };
}

// -- Allocation (coordinate side, clauses 6-7, 12-13) --------------------------

/// Candidate/rung attribution for the §12.2 payload (allocator is candidate-blind).
pub const CandidateRef = struct { candidate: u32 = 0, rung: u8 = 0 };

/// `ordinal` = rank i in the clause-6 total order (0..p-1); `offset` =
/// clause-7 o_i along the side (sketch.Port.offset semantics).
pub const Assignment = struct { attachment: Attachment, ordinal: u32, offset: u32 };

pub const decision_row_clause_12 = "D-PORT clause 12";
pub const capacity_reason =
    "demanded side cannot reach 2p+1 under an external clamp; MUST NOT share a cell, " ++
    "drop an attachment, or fall back to the shared midpoint (TSD §7.7)";
pub const capacity_action = "reject candidate and report, per D-DISPOSITION";

/// Full clause-12 / TSD §12.2 payload. `classes` follows the clause-6
/// recorded order; `edges`/`groups` list every involved edge id and
/// branch group id demanded on the side (trunk members included).
pub const CapacityExceeded = struct {
    tag: pb.DiagnosticTag = .port_capacity_exceeded,
    candidate: CandidateRef,
    node: pb.NodeId,
    side: sk.Dir4,
    demand: u32,
    available: u32,
    classes: []const AttachmentClass,
    edges: []const pb.EdgeId,
    groups: []const pb.JoinGroupId,
    decision_row: []const u8 = decision_row_clause_12,
    reason: []const u8 = capacity_reason,
    expected_action: []const u8 = capacity_action,
};

/// Clause 13: byte-identical K = duplicate parallel edges. NO order is
/// frozen between the twins (declaration order is the forbidden default);
/// disposition per D-DISPOSITION, multiplicity D-DUPLICATE's. `edges` is a
/// canonicalized report inventory (ascending, deduped), never a port order.
pub const KeyCollision = struct {
    tag: pb.DiagnosticTag = .port_key_collision,
    node: pb.NodeId,
    side: sk.Dir4,
    key: pb.AttachmentKey,
    edges: []const pb.EdgeId,
    deferred_to: []const u8 = "D-DUPLICATE",
};

pub const Failure = union(enum) { capacity_exceeded: CapacityExceeded, key_collision: KeyCollision };

pub const Allocation = union(enum) { assigned: []const Assignment, failed: Failure };

/// Map one (node, side) attachment set onto a face of length `side_len`:
/// clause-6 total order → clause-7 offsets. Same attachment set in any
/// input order → identical assignments. The clause-13 identity check runs
/// FIRST — identity precedes coordinates (clause 5) and the collision is
/// semantic (RF, recurs in every candidate), so it outranks the coordinate-
/// level capacity check. On failure NOTHING is allocated: never a shared
/// cell, never a dropped attachment, never a midpoint fallback.
/// guarded-by: ports_test.zig "V-D-PORT-02: attachment input permutation yields byte-identical assignments"
/// guarded-by: ports_test.zig "V-D-PORT-10: clamped L=3 with p=2 emits port_capacity_exceeded with the full clause-12 payload and no allocation"
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
    // Report the SMALLEST duplicated key: payload is input-order-independent.
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
    var groups: std.ArrayListUnmanaged(pb.JoinGroupId) = .empty;
    for (sorted, classes) |att, *class| {
        class.* = att.class;
        if (att.edge) |e| try appendUnique(pb.EdgeId, a, &edges, e);
        for (att.members) |member| try appendUnique(pb.EdgeId, a, &edges, member);
        if (att.group) |g| try appendUnique(pb.JoinGroupId, a, &groups, g);
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

// -- Departure-cell ownership (clause 8) ---------------------------------------

/// The two cells one attachment owns: its border attachment cell and the
/// first off-node cell collinear with the port. The route MUST run
/// straight (perpendicular to the side) through the departure cell — no
/// turn there — and no other attachment's ink may enter it.
pub const DepartureOwnership = struct { port_cell: sk.Point, departure_cell: sk.Point };

/// guarded-by: ports_test.zig "departure ownership: first off-node cell collinear with the port on all four sides"
pub fn departureOwnership(rect: sk.Rect, side: sk.Dir4, offset: u32) DepartureOwnership {
    const off: i32 = @intCast(offset);
    const x = rect.x + off;
    const y = rect.y + off;
    return switch (side) {
        .north => .{ .port_cell = .{ .x = x, .y = rect.y }, .departure_cell = .{ .x = x, .y = rect.y - 1 } },
        .south => .{ .port_cell = .{ .x = x, .y = rect.bottom() - 1 }, .departure_cell = .{ .x = x, .y = rect.bottom() } },
        .west => .{ .port_cell = .{ .x = rect.x, .y = y }, .departure_cell = .{ .x = rect.x - 1, .y = y } },
        .east => .{ .port_cell = .{ .x = rect.right() - 1, .y = y }, .departure_cell = .{ .x = rect.right(), .y = y } },
    };
}

// -- Post-allocation check (clause 14 allocation half) ------------------------

/// shared_cell: two terminals resolve to one cell. departure_ownership:
/// departure cells 4-adjacent (offset delta 1) — clause-8 ownership
/// breached even though the border cells are distinct. offset_formula:
/// offsets/ordinals drift from the clause-7 formula.
pub const CoalesceDetail = enum { shared_cell, departure_ownership, offset_formula };

pub const Coalesced = struct {
    tag: pb.DiagnosticTag = .port_coalesced,
    node: pb.NodeId,
    side: sk.Dir4,
    detail: CoalesceDetail,
    /// The offending offset pair (equal for a single-assignment breach).
    offsets: [2]u32,
};

/// Verify an allocation result: no two terminals on one cell, clause-8
/// departure ownership, clause-7 offsets. Null = clean. Checks run in
/// that order so each detail is reachable.
/// guarded-by: ports_test.zig "validateAssignments accepts clause-7 output and flags shared cells, departure breaches, and formula drift as port_coalesced"
pub fn validateAssignments(node: pb.NodeId, side: sk.Dir4, side_len: u32, assignments: []const Assignment) ?Coalesced {
    const p: u32 = @intCast(assignments.len);
    for (assignments, 0..) |x, i| for (assignments[0..i]) |y| {
        if (x.offset == y.offset)
            return .{ .node = node, .side = side, .detail = .shared_cell, .offsets = .{ y.offset, x.offset } };
    };
    for (assignments, 0..) |x, i| for (assignments[0..i]) |y| {
        const delta = if (x.offset > y.offset) x.offset - y.offset else y.offset - x.offset;
        if (delta == 1)
            return .{ .tag = .port_departure_conflict, .node = node, .side = side, .detail = .departure_ownership, .offsets = .{ y.offset, x.offset } };
    };
    for (assignments, 0..) |x, i| {
        if (x.ordinal != i or !satisfiable(side_len, p) or x.offset != offsetAt(side_len, p, @intCast(i)))
            return .{ .node = node, .side = side, .detail = .offset_formula, .offsets = .{ x.offset, x.offset } };
    }
    return null;
}

// -- Local identity helpers ----------------------------------------------------

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

fn meshContains(unions: []const pb.MeshUnion, edge: pb.EdgeId) bool {
    for (unions) |u| if (containsEdge(u.members, edge)) return true;
    return false;
}

/// True iff `node` hosts a non-mesh self-loop whose (clause-3) terminal
/// occupies `side` — the side a co-located plain forward edge must join.
fn hasSelfLoopSide(graph: sg.SemGraph, joins: pb.RealizedJoins, dir: sg.Direction, node: pb.NodeId, side: sk.Dir4) bool {
    for (graph.edges) |e|
        if (e.from == e.to and e.from == node and !meshContains(joins.mesh_unions, e.id) and
            (selfLoopSide(dir, .source_exit) == side or selfLoopSide(dir, .target_entry) == side)) return true;
    return false;
}

fn groupIndexById(groups: []const pb.JoinGroup, id: pb.JoinGroupId) ?usize {
    for (groups, 0..) |group, i| if (group.id == id) return i;
    return null;
}

fn membershipOf(joins: pb.RealizedJoins, edge: pb.EdgeId) ?pb.RealizedEdgeMembership {
    for (joins.memberships) |m| if (m.edge == edge) return m;
    return null;
}

fn isSelected(disp: ?pb.MembershipDisposition) bool {
    const d = disp orelse return false;
    return d == .selected;
}

fn independentGroup(disp: ?pb.MembershipDisposition) ?pb.JoinGroupId {
    const d = disp orelse return null;
    return switch (d) {
        .selected => null,
        .independent => |ind| ind.permission_group,
    };
}

fn appendUnique(comptime T: type, a: std.mem.Allocator, list: *std.ArrayListUnmanaged(T), value: T) error{OutOfMemory}!void {
    for (list.items) |x| if (x == value) return;
    try list.append(a, value);
}

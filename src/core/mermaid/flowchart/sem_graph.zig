const std = @import("std");
const prim = @import("prim");

pub const NodeId = prim.NodeId;
pub const EdgeId = prim.EdgeId;
pub const ClusterId = prim.ClusterId;
pub const ClassId = u32;

pub const SENTINEL: u32 = std.math.maxInt(u32);

pub const Direction = prim.Direction;

pub const NodeShape = enum {
    rect,
    round,
    stadium,
    subroutine,
    cylinder,
    circle,
    double_circle,
    asymmetric_right,
    rhombus,
    hexagon,
    parallelogram,
    parallelogram_alt,
    trapezoid,
    trapezoid_alt,
};

pub const EdgeKind = prim.EdgeKind;

pub const ArrowEnd = prim.ArrowKind;

pub const Node = struct {
    id: NodeId,
    raw_id: []const u8,
    label: []const u8,
    shape: NodeShape,
    classes: []const ClassId,
    cluster: ?ClusterId,
};

pub const Edge = struct {
    id: EdgeId,
    from: NodeId,
    to: NodeId,
    kind: EdgeKind,
    arrow_from: ArrowEnd,
    arrow_to: ArrowEnd,
    label: ?[]const u8,
    stands_for: StandsFor = .arrow_free,
    crossings: u32 = 0,
    origin: EdgeId = SENTINEL,

    pub fn declaredId(self: Edge) EdgeId {
        return if (self.origin == SENTINEL) self.id else self.origin;
    }

    pub fn labelText(self: Edge) ?[]const u8 {
        const label = self.label orelse return null;
        return if (label.len == 0) null else label;
    }
};

pub const StandsFor = prim.StandsFor;

pub fn standsForClass(arrow_from: ArrowEnd, arrow_to: ArrowEnd) StandsFor {
    if (!prim.directional(arrow_from) and !prim.directional(arrow_to)) return .arrow_free;
    if (prim.directional(arrow_to) and !prim.directional(arrow_from)) return .forward_one_way;
    if (prim.directional(arrow_from) and !prim.directional(arrow_to)) return .backward_one_way;
    return .directed;
}

pub fn mergeStandsFor(a: StandsFor, b: StandsFor) StandsFor {
    return if (a == b) a else .directed;
}

pub fn arrowFree(e: Edge) bool {
    return prim.memberArrowFree(e.arrow_from, e.arrow_to, e.stands_for);
}

pub fn undecorated(e: Edge) bool {
    return e.arrow_from == .none and e.arrow_to == .none and e.stands_for == .arrow_free;
}

pub fn forwardOneWayHead(e: Edge) bool {
    if (e.stands_for != .arrow_free) return e.stands_for == .forward_one_way;
    return prim.directional(e.arrow_to) and !prim.directional(e.arrow_from);
}

pub const Cluster = struct {
    id: ClusterId,
    raw_id: []const u8,
    label: []const u8,
    parent: ?ClusterId,
    members: []const NodeId,
    sub_clusters: []const ClusterId,
    direction: ?Direction = null,
    synthetic: bool = false,
};

pub const ClassDef = struct {
    id: ClassId,
    name: []const u8,
    style: []const u8,
};

pub const SemGraph = struct {
    direction: Direction,
    nodes: []const Node,
    edges: []const Edge,
    clusters: []const Cluster,
    classes: []const ClassDef,
    skipped_lines: u32 = 0,
    arena: ?*std.heap.ArenaAllocator,

    pub fn nodeById(self: SemGraph, id: NodeId) ?Node {
        for (self.nodes) |node| if (node.id == id) return node;
        return null;
    }

    pub fn edgeById(self: SemGraph, id: EdgeId) ?Edge {
        for (self.edges) |edge| if (edge.id == id) return edge;
        return null;
    }

    pub fn clusterOf(self: SemGraph, id: NodeId) ?ClusterId {
        return if (self.nodeById(id)) |node| node.cluster else null;
    }

    pub fn deinit(self: *SemGraph, allocator: std.mem.Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
        self.* = undefined;
    }
};

test "stands-for classes: backward one-way blocks but is never a forward head" {
    try std.testing.expectEqual(StandsFor.backward_one_way, standsForClass(.filled, .none));
    try std.testing.expectEqual(StandsFor.forward_one_way, standsForClass(.none, .open));
    try std.testing.expectEqual(StandsFor.arrow_free, standsForClass(.circle, .cross));
    try std.testing.expectEqual(StandsFor.directed, standsForClass(.filled, .filled));
    try std.testing.expectEqual(StandsFor.directed, mergeStandsFor(.forward_one_way, .backward_one_way));

    try std.testing.expect(prim.memberBlocks(.none, .none, .backward_one_way));
    const proxy: Edge = .{
        .id = 0,
        .from = 0,
        .to = 1,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .stands_for = .backward_one_way,
    };
    try std.testing.expect(!forwardOneWayHead(proxy));
    try std.testing.expect(!arrowFree(proxy));
    try std.testing.expect(!undecorated(proxy));
}

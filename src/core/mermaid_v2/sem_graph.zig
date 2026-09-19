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
    asymmetric_left,
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
    /// @guarded-by: cluster/split_test.zig "a placement edge records the directedness of the crossings it stands for"
    stands_for: StandsFor = .arrow_free,
    crossings: u32 = 0,
    origin: EdgeId = SENTINEL,
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

/// @guarded-by: fan_lanes_test2.zig "a two-sided group whose heads are direction-invariant still separates"
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

    pub fn deinit(self: *SemGraph, allocator: std.mem.Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
        self.* = undefined;
    }
};

test "SemGraph manual construction round-trip" {
    const nodes = [_]Node{
        .{
            .id = 0,
            .raw_id = "A",
            .label = "Alpha",
            .shape = .rect,
            .classes = &.{},
            .cluster = null,
        },
        .{
            .id = 1,
            .raw_id = "B",
            .label = "Beta",
            .shape = .round,
            .classes = &.{},
            .cluster = 0,
        },
        .{
            .id = 2,
            .raw_id = "C",
            .label = "Gamma",
            .shape = .rhombus,
            .classes = &.{},
            .cluster = 0,
        },
    };

    const edges = [_]Edge{
        .{
            .id = 0,
            .from = 0,
            .to = 1,
            .kind = .solid,
            .arrow_from = .none,
            .arrow_to = .filled,
            .label = null,
        },
        .{
            .id = 1,
            .from = 1,
            .to = 2,
            .kind = .dotted,
            .arrow_from = .none,
            .arrow_to = .open,
            .label = "maybe",
        },
    };

    const members = [_]NodeId{ 1, 2 };
    const subs = [_]ClusterId{};
    const clusters = [_]Cluster{
        .{
            .id = 0,
            .raw_id = "inner",
            .label = "Inner",
            .parent = null,
            .members = &members,
            .sub_clusters = &subs,
        },
    };

    const classes = [_]ClassDef{};

    const g = SemGraph{
        .direction = .LR,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &clusters,
        .classes = &classes,
        .arena = null,
    };

    try std.testing.expectEqual(@as(usize, 3), g.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), g.edges.len);

    try std.testing.expectEqualStrings("A", g.nodes[0].raw_id);
    try std.testing.expectEqualStrings("B", g.nodes[1].raw_id);
    try std.testing.expectEqualStrings("C", g.nodes[2].raw_id);
    for (g.nodes, 0..) |n, i| try std.testing.expectEqual(@as(NodeId, @intCast(i)), n.id);

    try std.testing.expectEqualStrings("inner", g.clusters[0].raw_id);
    try std.testing.expectEqual(@as(ClusterId, 0), g.clusters[0].id);

    try std.testing.expectEqual(Direction.LR, g.direction);
    try std.testing.expectEqual(NodeShape.rhombus, g.nodes[2].shape);
    try std.testing.expectEqual(EdgeKind.dotted, g.edges[1].kind);
    try std.testing.expectEqual(ArrowEnd.open, g.edges[1].arrow_to);
    try std.testing.expect(g.edges[1].label != null);
    try std.testing.expectEqualStrings("maybe", g.edges[1].label.?);

    try std.testing.expectEqual(SENTINEL, std.math.maxInt(u32));
}

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

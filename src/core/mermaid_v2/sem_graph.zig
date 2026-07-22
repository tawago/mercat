//! SemGraph: post-syntax, pre-geometry IR for mermaid v2 flowcharts.
//! Produced by the parser, consumed by layout. Holds meaning only —
//! nodes, edges, clusters, direction, class definitions — no
//! coordinates, glyphs, or render options.
//!
//! Ownership: all slices are caller-owned; if `arena` is set, `deinit`
//! frees everything transitively via the arena, otherwise the caller
//! frees storage. Imports `std` and `prim` only (pure data module).

const std = @import("std");
// prim is a named build dependency (build.zig) so this file works both
// inside the mermaid_v2 module tree and standalone (tests/property/gen.zig).
const prim = @import("prim");

/// Stable handle for a node within a SemGraph.
pub const NodeId = prim.NodeId;
/// Stable handle for an edge within a SemGraph.
pub const EdgeId = prim.EdgeId;
/// Stable handle for a cluster (subgraph) within a SemGraph.
pub const ClusterId = prim.ClusterId;
/// Stable handle for a class definition within a SemGraph.
pub const ClassId = u32;

/// Sentinel value meaning "absent" for raw u32 id fields.
pub const SENTINEL: u32 = std.math.maxInt(u32);

/// Flowchart layout direction declared by the source.
pub const Direction = prim.Direction;

/// All flowchart node shapes mermaid supports. This is the *parse-level*
/// shape set (15 variants). Layout maps it to `prim.Shape` (12 variants)
/// by collapsing `double_circle → circle`, `parallelogram_alt →
/// parallelogram`, and `trapezoid_alt → trapezoid`.
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

/// Stroke style for an edge.
pub const EdgeKind = prim.EdgeKind;

/// Arrowhead glyph at one end of an edge.
pub const ArrowEnd = enum { none, open, filled, circle, cross };

/// A semantic node — an identifier, label, shape, and class membership.
pub const Node = struct {
    id: NodeId,
    /// User-given identifier like "A".
    raw_id: []const u8,
    /// Displayed text (equals raw_id when no label was supplied).
    label: []const u8,
    shape: NodeShape,
    /// Class ids attached via `:::` or `class` statements. Empty if none.
    classes: []const ClassId,
    /// Containing cluster, or null if top-level.
    cluster: ?ClusterId,
};

/// A semantic edge between two nodes.
pub const Edge = struct {
    id: EdgeId,
    from: NodeId,
    to: NodeId,
    kind: EdgeKind,
    arrow_from: ArrowEnd,
    arrow_to: ArrowEnd,
    /// Optional edge label text.
    label: ?[]const u8,
};

/// A subgraph grouping. Members are direct only; nested groups go in `sub_clusters`.
pub const Cluster = struct {
    id: ClusterId,
    raw_id: []const u8,
    label: []const u8,
    parent: ?ClusterId,
    /// Direct member nodes (not transitive through sub_clusters).
    members: []const NodeId,
    sub_clusters: []const ClusterId,
    /// Layout direction declared by an in-body `direction` line, or null
    /// to inherit from the parent cluster / top-level graph.
    direction: ?Direction = null,
    /// True for a layout-synthesized packing cluster (motif/pack.zig):
    /// pure grouping chrome-free containment — zero frame pad everywhere,
    /// no drawn border, no label. Never set by the parser.
    synthetic: bool = false,
};

/// A `classDef` statement: a named bag of raw mermaid style declarations.
pub const ClassDef = struct {
    id: ClassId,
    name: []const u8,
    /// Raw mermaid style string; layout/paint may inspect to extract css-like props.
    style: []const u8,
};

/// The semantic graph. This is what the parser returns and layout consumes.
pub const SemGraph = struct {
    direction: Direction,
    nodes: []const Node,
    edges: []const Edge,
    clusters: []const Cluster,
    classes: []const ClassDef,
    /// Number of source lines the parser dropped via line-level recovery
    /// (unparseable non-edge statements). Zero for a clean parse. Known
    /// directives (`click`, `style`, ...) are consumed silently and do
    /// NOT count here.
    skipped_lines: u32 = 0,
    /// Optional owning arena. If set, deinit() frees all SemGraph storage.
    arena: ?*std.heap.ArenaAllocator,

    /// Free all storage if this SemGraph owns an arena; otherwise just invalidate.
    pub fn deinit(self: *SemGraph, allocator: std.mem.Allocator) void {
        if (self.arena) |a| {
            a.deinit();
            allocator.destroy(a);
        }
        self.* = undefined;
    }

    /// Look up a node by raw_id (linear scan, fine for fixture-sized graphs).
    pub fn findNode(self: SemGraph, raw_id: []const u8) ?NodeId {
        for (self.nodes) |n| {
            if (std.mem.eql(u8, n.raw_id, raw_id)) return n.id;
        }
        return null;
    }

    /// Look up a cluster by raw_id (linear scan).
    pub fn findCluster(self: SemGraph, raw_id: []const u8) ?ClusterId {
        for (self.clusters) |c| {
            if (std.mem.eql(u8, c.raw_id, raw_id)) return c.id;
        }
        return null;
    }

    /// Number of nodes in the graph.
    pub fn nodeCount(self: SemGraph) usize {
        return self.nodes.len;
    }

    /// Number of edges in the graph.
    pub fn edgeCount(self: SemGraph) usize {
        return self.edges.len;
    }

    /// Allocate and return ids of all nodes whose `cluster` is null. Caller owns the slice.
    pub fn topLevelNodes(self: SemGraph, allocator: std.mem.Allocator) ![]const NodeId {
        var list = std.ArrayList(NodeId){};
        errdefer list.deinit(allocator);
        for (self.nodes) |n| {
            if (n.cluster == null) try list.append(allocator, n.id);
        }
        return try list.toOwnedSlice(allocator);
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

    try std.testing.expectEqual(@as(usize, 3), g.nodeCount());
    try std.testing.expectEqual(@as(usize, 2), g.edgeCount());

    try std.testing.expectEqual(@as(?NodeId, 0), g.findNode("A"));
    try std.testing.expectEqual(@as(?NodeId, 1), g.findNode("B"));
    try std.testing.expectEqual(@as(?NodeId, 2), g.findNode("C"));
    try std.testing.expectEqual(@as(?NodeId, null), g.findNode("Z"));

    try std.testing.expectEqual(@as(?ClusterId, 0), g.findCluster("inner"));
    try std.testing.expectEqual(@as(?ClusterId, null), g.findCluster("outer"));

    try std.testing.expectEqual(Direction.LR, g.direction);
    try std.testing.expectEqual(NodeShape.rhombus, g.nodes[2].shape);
    try std.testing.expectEqual(EdgeKind.dotted, g.edges[1].kind);
    try std.testing.expectEqual(ArrowEnd.open, g.edges[1].arrow_to);
    try std.testing.expect(g.edges[1].label != null);
    try std.testing.expectEqualStrings("maybe", g.edges[1].label.?);

    try std.testing.expectEqual(SENTINEL, std.math.maxInt(u32));
}

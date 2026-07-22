//! cluster/split.zig — cuts one SemGraph into independently-layoutable pieces:
//! the outer flowchart plus one inner flowchart per subgraph, glued back by
//! `cluster/stitch.zig`. Pure data work (SemGraph in, smaller SemGraphs out);
//! runs nothing itself — only `budget.zig` calls `layout()` on the pieces.
//! May import only std, prim, sem_graph, sketch, and cluster-internal files.
//!
//! Cuts single-level subgraphs whose edges never cross a border; anything
//! else falls back to the identity result (one flat outer piece), keyed
//! purely on graph shape.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const bridges = @import("bridges.zig");

pub const Crossing = bridges.Crossing;

/// One independently-layoutable flowchart carved out of the original graph.
///
/// `cluster_id` is null for the outermost piece (the top-level flowchart) and
/// set to the subgraph's id for a child piece. `orig_ids[new_id]` maps a
/// node's re-assigned id within this piece back to its original SemGraph id,
/// or `sg.SENTINEL` for synthetic nodes (super-nodes / future port-nodes).
pub const Piece = struct {
    graph: sg.SemGraph,
    cluster_id: ?sg.ClusterId,
    orig_ids: []const sg.NodeId,
};

/// A subgraph as seen from the outer flowchart: a single stand-in node whose
/// size is its child's finished bounding box.
pub const SuperNode = struct {
    /// Node id of the super-node within the OUTER piece (`pieces[0]`).
    outer_node: sg.NodeId,
    /// The original cluster this super-node stands in for.
    cluster_id: sg.ClusterId,
    /// Index into `SplitResult.pieces` of this cluster's child flowchart.
    child_piece: usize,
    /// Copied from `Cluster.synthetic`: a packing cluster whose frame is
    /// invisible — stitch/superSize/sub-budget all use ZERO frame pad.
    synthetic: bool = false,
};

/// The result of cutting a graph. `pieces[0]` is always the outer flowchart;
/// entries `1..` are child flowcharts (one per subgraph). `supers` ties each
/// outer super-node to its child piece so the driver can size it and `stitch`
/// can glue the child in.
pub const SplitResult = struct {
    pieces: []const Piece,
    supers: []const SuperNode,
    /// Cross-border edges, routed by `cluster/bridges.zig` after stitch using
    /// the final merged placements. Empty on the flat path.
    crossings: []const Crossing,
    /// Number of nodes in the ORIGINAL graph — sizes the orig→merged id map.
    orig_node_count: usize,

    /// True when there was nothing to cut — a flat flowchart (no subgraphs)
    /// or a structure not yet handled by the cut path. The driver then takes
    /// the fast path: lay out the single piece, return its Sketch unchanged.
    pub fn isFlat(self: SplitResult) bool {
        return self.pieces.len == 1 and self.supers.len == 0;
    }
};

/// Cut `graph` into independently-layoutable pieces.
pub fn split(arena: std.mem.Allocator, graph: sg.SemGraph) error{OutOfMemory}!SplitResult {
    if (cuttable(graph)) return cut(arena, graph);
    return identity(arena, graph);
}

/// Identity result: the whole graph as a single flat outer piece.
fn identity(arena: std.mem.Allocator, graph: sg.SemGraph) error{OutOfMemory}!SplitResult {
    const pieces = try arena.alloc(Piece, 1);
    pieces[0] = .{ .graph = graph, .cluster_id = null, .orig_ids = &.{} };
    return .{ .pieces = pieces, .supers = &.{}, .crossings = &.{}, .orig_node_count = graph.nodes.len };
}

/// Structural precondition for the cut path: the graph has at least one
/// top-level subgraph. Nested subgraphs are handled by recursion (each child
/// graph is itself cut). Keyed purely on graph shape, never on identity.
fn cuttable(graph: sg.SemGraph) bool {
    for (graph.clusters) |c| {
        if (c.parent == null) return true;
    }
    return false;
}

/// The direct cluster of node `id`, or null if top-level. Linear scan (graphs
/// are fixture-sized).
fn clusterOf(graph: sg.SemGraph, id: sg.NodeId) ?sg.ClusterId {
    for (graph.nodes) |n| {
        if (n.id == id) return n.cluster;
    }
    return null;
}

/// Parent of cluster `cid`, or null if top-level.
fn parentOf(graph: sg.SemGraph, cid: sg.ClusterId) ?sg.ClusterId {
    for (graph.clusters) |c| {
        if (c.id == cid) return c.parent;
    }
    return null;
}

/// The top-level (parent==null) ancestor of cluster `cid` — walks up the
/// parent chain.
fn topAncestor(graph: sg.SemGraph, cid: sg.ClusterId) sg.ClusterId {
    var cur = cid;
    while (parentOf(graph, cur)) |p| cur = p;
    return cur;
}

/// True iff cluster `d` is a proper descendant of cluster `anc`.
fn isDescendant(graph: sg.SemGraph, d: sg.ClusterId, anc: sg.ClusterId) bool {
    if (d == anc) return false;
    var cur: ?sg.ClusterId = d;
    while (cur) |c| : (cur = parentOf(graph, c)) {
        if (c == anc) return true;
    }
    return false;
}

/// True iff node `id` lies anywhere inside cluster `c`'s subtree (in `c`
/// directly or in a descendant cluster).
fn inSubtree(graph: sg.SemGraph, id: sg.NodeId, c: sg.ClusterId) bool {
    const nc = clusterOf(graph, id) orelse return false;
    return nc == c or isDescendant(graph, nc, c);
}

/// The top-level cluster containing node `id`, or null if `id` is top-level.
fn topClusterOf(graph: sg.SemGraph, id: sg.NodeId) ?sg.ClusterId {
    const nc = clusterOf(graph, id) orelse return null;
    return topAncestor(graph, nc);
}

/// Cut a graph into outer + one child per TOP-LEVEL subgraph. Each child holds
/// that subgraph's whole subtree (nested sub-clusters included), so laying it
/// out recurses through `split` again.
fn cut(arena: std.mem.Allocator, graph: sg.SemGraph) error{OutOfMemory}!SplitResult {
    var tops: std.ArrayListUnmanaged(usize) = .empty;
    for (graph.clusters, 0..) |c, ci| {
        if (c.parent == null) try tops.append(arena, ci);
    }
    const ntop = tops.items.len;

    const pieces = try arena.alloc(Piece, ntop + 1);
    const supers = try arena.alloc(SuperNode, ntop);

    for (tops.items, 0..) |ci, k| {
        pieces[k + 1] = try buildChild(arena, graph, graph.clusters[ci]);
        supers[k] = .{
            .outer_node = undefined,
            .cluster_id = graph.clusters[ci].id,
            .child_piece = k + 1,
            .synthetic = graph.clusters[ci].synthetic,
        };
    }

    // --- Outer piece + cross-border crossings (fills supers[].outer_node) ---
    const ob = try buildOuter(arena, graph, tops.items, supers);
    pieces[0] = ob.piece;

    return .{
        .pieces = pieces,
        .supers = supers,
        .crossings = ob.crossings,
        .orig_node_count = graph.nodes.len,
    };
}

const OuterBuild = struct { piece: Piece, crossings: []const Crossing };

/// Build the child flowchart for cluster `c`: its whole subtree re-id'd into a
/// self-contained SemGraph. Direct members come first (preserving member order
/// and ids, so a sub-cluster-free child is identical to the flat case), then
/// descendant nodes. `c`'s direct sub-clusters are re-parented to null so they
/// become the child's own top-level subgraphs for the recursive cut; deeper
/// clusters keep their (re-pointed) parents. Cluster ids are preserved; node
/// ids are re-assigned 0..k-1 and members/edges are remapped to them.
fn buildChild(arena: std.mem.Allocator, graph: sg.SemGraph, c: sg.Cluster) error{OutOfMemory}!Piece {
    // 1. Subtree node ids in child order: direct members first, then any node
    //    living in a descendant cluster (graph order).
    var ids: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    for (c.members) |mid| try ids.append(arena, mid);
    for (graph.nodes) |n| {
        const nc = n.cluster orelse continue;
        if (nc != c.id and isDescendant(graph, nc, c.id)) try ids.append(arena, n.id);
    }
    const k = ids.items.len;

    const nodes = try arena.alloc(sg.Node, k);
    const orig = try arena.alloc(sg.NodeId, k);
    for (ids.items, 0..) |oid, new_id| {
        const src = nodeById(graph, oid);
        orig[new_id] = oid;
        nodes[new_id] = .{
            .id = @intCast(new_id),
            .raw_id = src.raw_id,
            .label = src.label,
            .shape = src.shape,
            .classes = src.classes,
            // Directly in `c` → top-level in the child (null); otherwise keep
            // the (preserved-id) descendant cluster.
            .cluster = if (src.cluster) |sc| (if (sc == c.id) null else sc) else null,
        };
    }

    // 2. Descendant clusters, members/sub_clusters kept, direct subs reparented
    //    to null, members remapped to child-local node ids.
    var child_clusters: std.ArrayListUnmanaged(sg.Cluster) = .empty;
    for (graph.clusters) |d| {
        if (!isDescendant(graph, d.id, c.id)) continue;
        const new_members = try arena.alloc(sg.NodeId, d.members.len);
        for (d.members, 0..) |m, i| new_members[i] = localId(orig, m);
        try child_clusters.append(arena, .{
            .id = d.id,
            .raw_id = d.raw_id,
            .label = d.label,
            .parent = if (d.parent) |p| (if (p == c.id) null else p) else null,
            .members = new_members,
            .sub_clusters = d.sub_clusters,
            .direction = d.direction,
            .synthetic = d.synthetic,
        });
    }

    // 3. Edges with both endpoints in the subtree, remapped to child ids.
    var edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    for (graph.edges) |e| {
        if (inSubtree(graph, e.from, c.id) and inSubtree(graph, e.to, c.id)) {
            try edges.append(arena, .{
                .id = @intCast(edges.items.len),
                .from = localId(orig, e.from),
                .to = localId(orig, e.to),
                .kind = e.kind,
                .arrow_from = e.arrow_from,
                .arrow_to = e.arrow_to,
                .label = e.label,
            });
        }
    }

    const child_graph: sg.SemGraph = .{
        .direction = c.direction orelse graph.direction,
        .nodes = nodes,
        .edges = try edges.toOwnedSlice(arena),
        .clusters = try child_clusters.toOwnedSlice(arena),
        .classes = graph.classes,
        .arena = null,
    };
    return .{ .graph = child_graph, .cluster_id = c.id, .orig_ids = orig };
}

/// Build the outer flowchart: every top-level (cluster==null) node plus one
/// synthetic super-node per cluster, the top-level edges, a deduped super↔
/// super (or top-level↔super) "placement" edge per cross-border connection so
/// the outer layout stacks the boxes correctly, and the list of cross-border
/// crossings for `bridges` to route later.
fn buildOuter(arena: std.mem.Allocator, graph: sg.SemGraph, tops: []const usize, supers: []SuperNode) error{OutOfMemory}!OuterBuild {
    var nodes: std.ArrayListUnmanaged(sg.Node) = .empty;
    var orig: std.ArrayListUnmanaged(sg.NodeId) = .empty;

    for (graph.nodes) |n| {
        if (n.cluster != null) continue;
        try orig.append(arena, n.id);
        try nodes.append(arena, .{
            .id = @intCast(nodes.items.len),
            .raw_id = n.raw_id,
            .label = n.label,
            .shape = n.shape,
            .classes = n.classes,
            .cluster = null,
        });
    }

    for (tops, 0..) |ci, k| {
        const c = graph.clusters[ci];
        const super_id: sg.NodeId = @intCast(nodes.items.len);
        try orig.append(arena, sg.SENTINEL); // synthetic
        try nodes.append(arena, .{
            .id = super_id,
            .raw_id = c.raw_id,
            .label = c.label,
            .shape = .rect,
            .classes = &.{},
            .cluster = null,
        });
        supers[k].outer_node = super_id;
    }

    var edges: std.ArrayListUnmanaged(sg.Edge) = .empty;
    var crossings: std.ArrayListUnmanaged(Crossing) = .empty;
    // (from_outer, to_outer) pairs already given a placement edge.
    var seen: std.ArrayListUnmanaged([2]sg.NodeId) = .empty;

    for (graph.edges) |e| {
        // Classify by TOP-LEVEL containing subgraph (or null for top-level
        // nodes): an edge between two nodes in the same top-level subtree is
        // routed inside that child's recursion, not here.
        const fa = topClusterOf(graph, e.from);
        const ta = topClusterOf(graph, e.to);
        if (fa == null and ta == null) {
            try edges.append(arena, .{
                .id = @intCast(edges.items.len),
                .from = localIdList(orig.items, e.from),
                .to = localIdList(orig.items, e.to),
                .kind = e.kind,
                .arrow_from = e.arrow_from,
                .arrow_to = e.arrow_to,
                .label = e.label,
            });
        } else if (sameCluster(fa, ta)) {
            // Same top-level subtree: lives in the child piece, not here.
        } else {
            // Cross-border: record the real crossing + a deduped placement
            // edge between the two sides' outer representatives.
            try crossings.append(arena, .{
                .id = @intCast(crossings.items.len),
                .from = e.from,
                .to = e.to,
                .kind = e.kind,
                .arrow_from = mapArrow(e.arrow_from),
                .arrow_to = mapArrow(e.arrow_to),
                .label = e.label,
            });
            const rf = outerRepr(graph, supers, orig.items, e.from);
            const rt = outerRepr(graph, supers, orig.items, e.to);
            if (rf != rt and !pairSeen(seen.items, rf, rt)) {
                try seen.append(arena, .{ rf, rt });
                try edges.append(arena, .{
                    .id = @intCast(edges.items.len),
                    .from = rf,
                    .to = rt,
                    .kind = e.kind,
                    .arrow_from = .none,
                    .arrow_to = .none,
                    .label = null,
                });
            }
        }
    }

    const outer_graph: sg.SemGraph = .{
        .direction = graph.direction,
        .nodes = try nodes.toOwnedSlice(arena),
        .edges = try edges.toOwnedSlice(arena),
        .clusters = &.{},
        .classes = graph.classes,
        .arena = null,
    };
    return .{
        .piece = .{ .graph = outer_graph, .cluster_id = null, .orig_ids = try orig.toOwnedSlice(arena) },
        .crossings = try crossings.toOwnedSlice(arena),
    };
}

fn sameCluster(a: ?sg.ClusterId, b: ?sg.ClusterId) bool {
    return a != null and b != null and a.? == b.?;
}

fn pairSeen(seen: []const [2]sg.NodeId, f: sg.NodeId, t: sg.NodeId) bool {
    for (seen) |p| {
        if (p[0] == f and p[1] == t) return true;
    }
    return false;
}

/// The outer-graph node that stands in for an original node: the super-node of
/// its TOP-LEVEL containing subgraph, else its own outer-local real id.
fn outerRepr(graph: sg.SemGraph, supers: []const SuperNode, orig: []const sg.NodeId, id: sg.NodeId) sg.NodeId {
    if (topClusterOf(graph, id)) |cid| {
        for (supers) |s| {
            if (s.cluster_id == cid) return s.outer_node;
        }
    }
    return localIdList(orig, id);
}

fn mapArrow(e: sg.ArrowEnd) @import("../sketch.zig").ArrowKind {
    return switch (e) {
        .none => .none,
        .open => .open,
        .filled => .filled,
        .circle => .circle,
        .cross => .cross,
    };
}

fn nodeById(graph: sg.SemGraph, id: sg.NodeId) sg.Node {
    for (graph.nodes) |n| {
        if (n.id == id) return n;
    }
    return graph.nodes[0];
}

/// Map an original node id to its piece-local id via the piece's orig_ids.
fn localId(orig: []const sg.NodeId, original: sg.NodeId) sg.NodeId {
    for (orig, 0..) |o, i| {
        if (o == original) return @intCast(i);
    }
    return 0;
}

fn localIdList(orig: []const sg.NodeId, original: sg.NodeId) sg.NodeId {
    return localId(orig, original);
}

/// Resolve a child SKETCH node id to its id in the graph that produced a stitch
/// level: child sketch id -> child input-graph id (`child_input_of`) ->
/// this-graph id (`piece_orig_ids`). Either hop may be `SENTINEL` (synthetic
/// node). Shared by `stitch.zig` and `entry_inset.zig`.
pub fn pieceId(piece_orig_ids: []const sg.NodeId, child_input_of: []const sketch.NodeId, sketch_id: sketch.NodeId) sketch.NodeId {
    const child_graph_id = idAt(child_input_of, sketch_id);
    return idAt(piece_orig_ids, child_graph_id);
}

/// Index into a node-id map, returning `SENTINEL` for a sentinel/out-of-range
/// index (a synthetic node has no entry).
pub fn idAt(map: []const sketch.NodeId, i: sketch.NodeId) sketch.NodeId {
    if (i == sg.SENTINEL or i >= map.len) return sg.SENTINEL;
    return map[i];
}

// ====================================================================
// Tests
// ====================================================================

test "identity split for clusterless graph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g: sg.SemGraph = .{
        .direction = .TD,
        .nodes = &.{},
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
    const result = try split(a, g);
    try std.testing.expect(result.isFlat());
}

test "single-level disjoint subgraphs cut into outer + children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two clusters, two members each, intra-cluster edges only, plus one
    // top-level node outside any cluster.
    const nodes = [_]sg.Node{
        .{ .id = 0, .raw_id = "A", .label = "A", .shape = .rect, .classes = &.{}, .cluster = 0 },
        .{ .id = 1, .raw_id = "B", .label = "B", .shape = .rect, .classes = &.{}, .cluster = 0 },
        .{ .id = 2, .raw_id = "C", .label = "C", .shape = .rect, .classes = &.{}, .cluster = 1 },
        .{ .id = 3, .raw_id = "D", .label = "D", .shape = .rect, .classes = &.{}, .cluster = 1 },
        .{ .id = 4, .raw_id = "T", .label = "T", .shape = .rect, .classes = &.{}, .cluster = null },
    };
    const edges = [_]sg.Edge{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 2, .to = 3, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const m0 = [_]sg.NodeId{ 0, 1 };
    const m1 = [_]sg.NodeId{ 2, 3 };
    const clusters = [_]sg.Cluster{
        .{ .id = 0, .raw_id = "c0", .label = "C0", .parent = null, .members = &m0, .sub_clusters = &.{} },
        .{ .id = 1, .raw_id = "c1", .label = "C1", .parent = null, .members = &m1, .sub_clusters = &.{} },
    };
    const g: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &clusters, .classes = &.{}, .arena = null };

    const r = try split(a, g);
    try std.testing.expect(!r.isFlat());
    try std.testing.expectEqual(@as(usize, 3), r.pieces.len); // outer + 2 children
    try std.testing.expectEqual(@as(usize, 2), r.supers.len);

    // Each child has 2 nodes, 1 edge, flat.
    try std.testing.expectEqual(@as(usize, 2), r.pieces[1].graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), r.pieces[1].graph.edges.len);
    // Outer has 1 real (T) + 2 supers = 3 nodes, 0 edges.
    try std.testing.expectEqual(@as(usize, 3), r.pieces[0].graph.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), r.pieces[0].graph.edges.len);
    // Super-nodes point at the right child pieces.
    try std.testing.expectEqual(@as(usize, 1), r.supers[0].child_piece);
    try std.testing.expectEqual(@as(usize, 2), r.supers[1].child_piece);
}

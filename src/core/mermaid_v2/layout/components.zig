//! Lever A — component-packing for `layout.zig`.
//!
//! Detects weakly-connected components (union-find over `graph.edges`) in a
//! cluster-free graph and re-slots each as a tight, left-justified column
//! band, collapsing width to roughly the widest single component. Pure
//! x-translation: runs after crossing reduction + barycenter sweeps +
//! flush-left, before `applyDirection`; pressure-gated to rungs > `natural`
//! (flush_left / spacing_scale > 0), TD-only.
//!
//! Imports (layout/ zone): only `std`, `../sem_graph.zig`, `sugiyama.zig`,
//! and NodeGeom from `routing.zig`. Must not reach cluster/, recurse,
//! budget, raster/, lattice, or paint/.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");

pub const NodeGeom = routing.NodeGeom;

/// Horizontal gap, in cells, placed between adjacent packed components.
/// Wide enough that two independent chains read as visually separate columns
/// without wasting canvas. (Cluster-frame insets do not apply here — the
/// layout stage only ever sees cluster-free graphs.)
const COMPONENT_GAP: i32 = 4;

/// Re-slot each weakly-connected component into a tight, left-justified column
/// band, eliminating the inter-component whitespace the barycenter sweeps left
/// behind when they cross-aligned independent chains across a shared grid.
///
/// No-op (returns early) unless the graph actually has >1 component — a single
/// connected graph has nothing to pack and must stay byte-identical.
///
/// `geom` is parallel to `lg.nodes`. Virtual (long-edge waypoint) nodes are
/// assigned to a component via their owning edge and ride along by the same
/// per-component delta, so edge routing keeps its offset relative to the
/// component's real content.
pub fn packComponents(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    geom: []NodeGeom,
    lg: sugiyama.LayeredGraph,
) error{OutOfMemory}!void {
    const n = lg.nodes.len;
    if (n == 0) return;

    const parent = try a.alloc(u32, n);
    defer a.free(parent);
    for (parent, 0..) |*p, i| p.* = @intCast(i);

    for (graph.edges) |e| {
        const fi = lg.real_index.get(e.from) orelse continue;
        const ti = lg.real_index.get(e.to) orelse continue;
        unite(parent, fi, ti);
    }

    for (lg.nodes, 0..) |ln, i| {
        switch (ln) {
            .virtual => |v| {
                for (graph.edges) |e| {
                    if (e.id != v.edge) continue;
                    const fi = lg.real_index.get(e.from) orelse break;
                    unite(parent, @intCast(i), fi);
                    break;
                }
            },
            .real => {},
        }
    }

    // ---- Collect component roots and their current real-node x-span. -------
    // Only real nodes define a component's visible span; virtuals follow. guarded-by: components.zig "packComponents: virtual-node geometry cannot widen a component's span"
    var roots: std.ArrayListUnmanaged(u32) = .empty;
    const min_x = try a.alloc(i32, n);
    defer a.free(min_x);
    const max_x = try a.alloc(i32, n);
    defer a.free(max_x);
    for (min_x) |*m| m.* = std.math.maxInt(i32);
    for (max_x) |*m| m.* = std.math.minInt(i32);

    for (lg.nodes, 0..) |ln, i| {
        if (ln != .real) continue;
        const r = find(parent, @intCast(i));
        const left = geom[i].x;
        const right = geom[i].x + @as(i32, @intCast(geom[i].w));
        if (min_x[r] == std.math.maxInt(i32)) {
            try roots.append(a, r);
        }
        if (left < min_x[r]) min_x[r] = left;
        if (right > max_x[r]) max_x[r] = right;
    }
    defer roots.deinit(a);

    if (roots.items.len < 2) return; // single component → nothing to pack.

    // Stable horizontal reading order: leftmost x, then root index. guarded-by: components.zig "packComponents: equal-min_x components tiebreak by ascending root index"
    std.sort.pdq(u32, roots.items, SortCtx{ .min_x = min_x }, SortCtx.less);

    // ---- Compute a per-component left-justified delta and apply it. --------
    // Monotone cursor, gap exactly COMPONENT_GAP: contiguous, non-overlapping. guarded-by: components.zig "packComponents: packed components are contiguous with exactly COMPONENT_GAP between them"
    const delta = try a.alloc(i32, n);
    defer a.free(delta);
    for (delta) |*d| d.* = 0;
    var has_delta = false;

    var cursor: i32 = min_x[roots.items[0]];
    for (roots.items) |r| {
        const d = cursor - min_x[r];
        if (d != 0) {
            delta[r] = d;
            has_delta = true;
        }
        const width = max_x[r] - min_x[r];
        cursor += width + COMPONENT_GAP;
    }

    if (!has_delta) return;

    for (lg.nodes, 0..) |_, i| {
        const r = find(parent, @intCast(i));
        geom[i].x += delta[r];
    }
}

const SortCtx = struct {
    min_x: []const i32,
    fn less(ctx: SortCtx, lhs: u32, rhs: u32) bool {
        const lx = ctx.min_x[lhs];
        const rx = ctx.min_x[rhs];
        if (lx != rx) return lx < rx;
        return lhs < rhs;
    }
};

fn find(parent: []u32, x: u32) u32 {
    var root = x;
    while (parent[root] != root) root = parent[root];
    var cur = x;
    while (parent[cur] != root) {
        const next = parent[cur];
        parent[cur] = root;
        cur = next;
    }
    return root;
}

fn unite(parent: []u32, a_idx: u32, b_idx: u32) void {
    const ra = find(parent, a_idx);
    const rb = find(parent, b_idx);
    if (ra == rb) return;
    // Lower-index root wins for determinism. guarded-by: components.zig "unite: lower-index root always wins, regardless of call order"
    if (ra < rb) parent[rb] = ra else parent[ra] = rb;
}

const testing = std.testing;

fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}
fn mkEdge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

test "unite: lower-index root always wins, regardless of call order" {
    // Union-find must be deterministic across runs — the root of any
    // merged set is always the smallest original index, never whichever
    // side happened to be passed first.
    {
        var parent = [_]u32{ 0, 1, 2, 3 };
        unite(&parent, 3, 1); // higher index passed first
        try testing.expectEqual(@as(u32, 1), find(&parent, 3));
        try testing.expectEqual(@as(u32, 1), find(&parent, 1));
    }
    {
        var parent = [_]u32{ 0, 1, 2, 3 };
        unite(&parent, 1, 3); // lower index passed first — same result
        try testing.expectEqual(@as(u32, 1), find(&parent, 3));
        try testing.expectEqual(@as(u32, 1), find(&parent, 1));
    }
}

test "packComponents: virtual-node geometry cannot widen a component's span" {
    // Component 0: real nodes A,B (small span) plus a virtual waypoint
    // riding on their connecting edge, but positioned far to the right —
    // if the virtual's geometry ever leaked into the min/max span
    // computation, component 0 would appear far wider than its real
    // content and would shove component 1 much further right than
    // `COMPONENT_GAP` allows.
    const nodes = [_]sg.Node{
        mkNode(20, "PA"), // real_index 0 -> lg index 3
        mkNode(21, "PB"), // lg index 4
        mkNode(10, "QA"), // lg index 1
        mkNode(11, "QB"), // lg index 2
    };
    const edges = [_]sg.Edge{
        mkEdge(100, 20, 21), // A-B edge; virtual (edge=100) rides with it
    };
    const graph = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var real_index: std.AutoHashMapUnmanaged(sg.NodeId, u32) = .empty;
    defer real_index.deinit(testing.allocator);
    try real_index.put(testing.allocator, 20, 0);
    try real_index.put(testing.allocator, 21, 1);
    try real_index.put(testing.allocator, 10, 2);
    try real_index.put(testing.allocator, 11, 3);

    var lg_nodes = [_]sugiyama.LayerNode{
        .{ .real = 20 },
        .{ .real = 21 },
        .{ .virtual = .{ .edge = 100, .index = 0 } }, // huge geom below
        .{ .real = 10 },
        .{ .real = 11 },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &lg_nodes,
        .layers = &.{},
        .edges = &.{},
        .reversed_edges = &.{},
        .real_index = real_index,
        .arena = null,
    };

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 10, .h = 1, .layer = 0 }, // PA: [0,10]
        .{ .x = 5, .y = 0, .w = 5, .h = 1, .layer = 0 }, // PB: [5,10] (component span [0,10])
        .{ .x = 1000, .y = 0, .w = 900, .h = 1, .layer = 0 }, // virtual: [1000,1900] — must be ignored
        .{ .x = 20, .y = 0, .w = 5, .h = 1, .layer = 0 }, // QA: [20,25]
        .{ .x = 25, .y = 0, .w = 5, .h = 1, .layer = 0 }, // QB: [25,30] (component span [20,30])
    };

    try packComponents(testing.allocator, graph, &geom, lg);

    // Component P (PA/PB) has real span width 10; it packs first at
    // cursor 0. Component Q must land at exactly 10 + COMPONENT_GAP,
    // not at some position inflated by the virtual's [1000,1900] span.
    try testing.expectEqual(@as(i32, 0), geom[0].x); // PA unmoved
    try testing.expectEqual(@as(i32, 14), geom[3].x); // QA shifted to 10+4
    // The virtual rides along with its component's delta (0) — its own
    // huge span is untouched, proving it was never load-bearing.
    try testing.expectEqual(@as(i32, 1000), geom[2].x);
}

test "packComponents: equal-min_x components tiebreak by ascending root index" {
    // Build two single-node components that both start at x=0 so the
    // primary sort key (min_x) ties. Component P's *root* ends up as
    // the virtual node's own low index (0) via the edge it rides on;
    // component Q's root is a plain real node with a higher index (1).
    // The pre-sort collection order below is deliberately [Q-root=1,
    // P-root=0] (reverse of ascending) so this test would fail if the
    // comparator's tiebreak (`lhs < rhs`) were ever dropped.
    const nodes = [_]sg.Node{
        mkNode(10, "QA"), // lg index 1
        mkNode(11, "QB"), // lg index 2
        mkNode(20, "PA"), // lg index 3
        mkNode(21, "PB"), // lg index 4
    };
    const edges = [_]sg.Edge{
        mkEdge(200, 10, 11), // unions Q's two real nodes
        mkEdge(100, 20, 21), // unions P's two real nodes; virtual rides this
    };
    const graph = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var real_index: std.AutoHashMapUnmanaged(sg.NodeId, u32) = .empty;
    defer real_index.deinit(testing.allocator);
    try real_index.put(testing.allocator, 10, 1);
    try real_index.put(testing.allocator, 11, 2);
    try real_index.put(testing.allocator, 20, 3);
    try real_index.put(testing.allocator, 21, 4);

    var lg_nodes = [_]sugiyama.LayerNode{
        .{ .virtual = .{ .edge = 100, .index = 0 } }, // index 0: pulls P's root down to 0
        .{ .real = 10 },
        .{ .real = 11 },
        .{ .real = 20 },
        .{ .real = 21 },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &lg_nodes,
        .layers = &.{},
        .edges = &.{},
        .reversed_edges = &.{},
        .real_index = real_index,
        .arena = null,
    };

    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 1, .h = 1, .layer = 0 }, // virtual placeholder, irrelevant
        .{ .x = 0, .y = 0, .w = 6, .h = 1, .layer = 0 }, // QA: [0,6]
        .{ .x = 3, .y = 0, .w = 3, .h = 1, .layer = 0 }, // QB: [3,6]
        .{ .x = 0, .y = 0, .w = 4, .h = 1, .layer = 0 }, // PA: [0,4]
        .{ .x = 2, .y = 0, .w = 2, .h = 1, .layer = 0 }, // PB: [2,4]
    };

    try packComponents(testing.allocator, graph, &geom, lg);

    // Root 0 (P) must be treated as coming first despite Q's root (1)
    // being collected first — P stays put (delta 0) and Q gets pushed
    // out to P's width (4) + COMPONENT_GAP (4) = 8.
    try testing.expectEqual(@as(i32, 0), geom[3].x); // PA unmoved
    try testing.expectEqual(@as(i32, 8), geom[1].x); // QA shifted to 4+4
}

test "packComponents: packed components are contiguous with exactly COMPONENT_GAP between them" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "B"),
        mkNode(2, "C"),
    };
    const graph = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &.{}, // no edges: each node is its own component
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var real_index: std.AutoHashMapUnmanaged(sg.NodeId, u32) = .empty;
    defer real_index.deinit(testing.allocator);
    try real_index.put(testing.allocator, 0, 0);
    try real_index.put(testing.allocator, 1, 1);
    try real_index.put(testing.allocator, 2, 2);

    var lg_nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &lg_nodes,
        .layers = &.{},
        .edges = &.{},
        .reversed_edges = &.{},
        .real_index = real_index,
        .arena = null,
    };

    // Widely separated so packing must actually pull them together.
    var geom = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 1, .layer = 0 },
        .{ .x = 50, .y = 0, .w = 8, .h = 1, .layer = 0 },
        .{ .x = 200, .y = 0, .w = 4, .h = 1, .layer = 0 },
    };

    try packComponents(testing.allocator, graph, &geom, lg);

    // Sort by final x and check every adjacent pair is separated by
    // exactly COMPONENT_GAP, with no overlap and no slack.
    const Span = struct { left: i32, right: i32 };
    var spans: [3]Span = undefined;
    for (geom, 0..) |g, i| spans[i] = .{ .left = g.x, .right = g.x + @as(i32, @intCast(g.w)) };
    std.sort.pdq(Span, &spans, {}, struct {
        fn less(_: void, l: Span, r: Span) bool {
            return l.left < r.left;
        }
    }.less);

    try testing.expectEqual(spans[0].right + COMPONENT_GAP, spans[1].left);
    try testing.expectEqual(spans[1].right + COMPONENT_GAP, spans[2].left);
}

test "packComponents: idempotent across repeated calls on equivalent input" {
    const nodes = [_]sg.Node{
        mkNode(0, "A"),
        mkNode(1, "B"),
        mkNode(2, "C"),
    };
    const graph = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &.{},
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var real_index: std.AutoHashMapUnmanaged(sg.NodeId, u32) = .empty;
    defer real_index.deinit(testing.allocator);
    try real_index.put(testing.allocator, 0, 0);
    try real_index.put(testing.allocator, 1, 1);
    try real_index.put(testing.allocator, 2, 2);

    var lg_nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 },
        .{ .real = 1 },
        .{ .real = 2 },
    };
    const lg = sugiyama.LayeredGraph{
        .nodes = &lg_nodes,
        .layers = &.{},
        .edges = &.{},
        .reversed_edges = &.{},
        .real_index = real_index,
        .arena = null,
    };

    const original = [_]NodeGeom{
        .{ .x = 0, .y = 0, .w = 6, .h = 1, .layer = 0 },
        .{ .x = 50, .y = 0, .w = 8, .h = 1, .layer = 0 },
        .{ .x = 200, .y = 0, .w = 4, .h = 1, .layer = 0 },
    };

    var geom1 = original;
    var geom2 = original;
    try packComponents(testing.allocator, graph, &geom1, lg);
    try packComponents(testing.allocator, graph, &geom2, lg);

    for (geom1, geom2) |a1, a2| {
        try testing.expectEqual(a1.x, a2.x);
    }
}

test {
    _ = @import("components_test.zig");
}

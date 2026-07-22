//! Graph/placement lookup + perimeter-port + arrow-mapping helpers, split
//! from `routing.zig` to keep it under the 500-line mermaid_v2 cap. These are
//! pure lookups over the SemGraph, the placement slice, and the layered graph,
//! plus the perimeter-port geometry and SemGraph→Sketch arrow mapping — no
//! routing state of their own. `routing.zig` re-exports every symbol here so
//! both its own call sites and external importers (fan_busbar.zig,
//! back_edges.zig, ports_test.zig) address them exactly as before.
//!
//! Imports: only `std`, `../sem_graph.zig`, `../sketch.zig`, `sugiyama.zig`.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const sugiyama = @import("sugiyama.zig");
const rp = @import("routing_polyline.zig");

pub const PortDir = enum { out, in };

pub fn findGraphEdge(graph: sg.SemGraph, id: sg.EdgeId) ?sg.Edge {
    for (graph.edges) |e| {
        if (e.id == id) return e;
    }
    return null;
}

pub fn findPlacement(
    placements: []const sketch.NodePlacement,
    id: sg.NodeId,
) sketch.NodePlacement {
    for (placements) |p| {
        if (p.id == id) return p;
    }
    return placements[0];
}

/// Innermost cluster id of a node, or null if top-level.
fn nodeCluster(graph: sg.SemGraph, nid: sg.NodeId) ?sg.ClusterId {
    for (graph.nodes) |n| {
        if (n.id == nid) return n.cluster;
    }
    return null;
}

/// True iff cluster `anc` is `desc` or a (transitive) ancestor of it.
fn clusterAncestorOrSelf(graph: sg.SemGraph, anc: sg.ClusterId, desc: sg.ClusterId) bool {
    var cur: ?sg.ClusterId = desc;
    while (cur) |id| {
        if (id == anc) return true;
        var found: ?sg.Cluster = null;
        for (graph.clusters) |c| {
            if (c.id == id) {
                found = c;
                break;
            }
        }
        cur = if (found) |c| c.parent else null;
    }
    return false;
}

/// Rows of fan-rail lift for one fan member edge: 1 when it descends into a cluster, else 0. THE shared lift rule for both the bus-bar pre-pass and the per-peer path. // guarded-by: routing_test.zig "bus-bar pre-pass and forced per-peer path lift the same fan-OUT geometry to the same rail row"
pub fn fanRailLift(graph: sg.SemGraph, from: sg.NodeId, to: sg.NodeId) u32 {
    return if (crossesIntoCluster(graph, from, to)) 1 else 0;
}

/// True iff an edge from `from` to `to` descends into a cluster `from` is not a member/descendant of (ancestor-chain walk). // guarded-by: routing_test.zig "fan-OUT per-peer rail does not lift when the source is a member of (or ancestor of) the target's cluster"
fn crossesIntoCluster(graph: sg.SemGraph, from: sg.NodeId, to: sg.NodeId) bool {
    const dst_cluster = nodeCluster(graph, to) orelse return false;
    // If the source sits inside (or under) the destination's innermost
    // cluster, no leading border separates them — same frame interior.
    const src_cluster = nodeCluster(graph, from);
    if (src_cluster) |sc| {
        if (clusterAncestorOrSelf(graph, dst_cluster, sc)) return false;
    }
    return true;
}

pub fn isReversed(lg: sugiyama.LayeredGraph, eid: sg.EdgeId) bool {
    for (lg.reversed_edges) |r| {
        if (r == eid) return true;
    }
    return false;
}

pub fn collectVirtuals(
    a: std.mem.Allocator,
    lg: sugiyama.LayeredGraph,
    eid: sg.EdgeId,
) error{OutOfMemory}![]const u32 {
    var list: std.ArrayListUnmanaged(u32) = .empty;
    for (lg.nodes, 0..) |n, i| {
        switch (n) {
            .virtual => |v| {
                if (v.edge == eid) try list.append(a, @intCast(i));
            },
            .real => {},
        }
    }
    const Ctx = struct {
        nodes: []const sugiyama.LayerNode,
        fn lt(ctx: @This(), x: u32, y: u32) bool {
            const ix = switch (ctx.nodes[x]) {
                .virtual => |v| v.index,
                .real => 0,
            };
            const iy = switch (ctx.nodes[y]) {
                .virtual => |v| v.index,
                .real => 0,
            };
            return ix < iy;
        }
    };
    std.mem.sort(u32, list.items, Ctx{ .nodes = lg.nodes }, Ctx.lt);
    return try list.toOwnedSlice(a);
}

pub fn perimeterPort(
    p: sketch.NodePlacement,
    dir: sg.Direction,
    pd: PortDir,
) sketch.Port {
    const side: sketch.Dir4 = switch (dir) {
        .TD => if (pd == .out) .south else .north,
        .BT => if (pd == .out) .north else .south,
        .LR => if (pd == .out) .east else .west,
        .RL => if (pd == .out) .west else .east,
    };
    const offset: u32 = switch (side) {
        .north, .south => @divTrunc(p.rect.w, 2),
        .east, .west => @divTrunc(p.rect.h, 2),
    };
    return .{ .node = p.id, .side = side, .offset = offset };
}

pub fn mapArrow(e: sg.ArrowEnd) sketch.ArrowKind {
    return switch (e) {
        .none => .none,
        .open => .open,
        .filled => .filled,
        .circle => .circle,
        .cross => .cross,
    };
}

/// Base-approach LENGTHEN pass — the "corner-fed" companion to
/// routing_polyline.zig's `ensureBaseStub` (which handles the length-1
/// turn-at-tip by SHIFTING the descent leg in place). This targets the
/// case `ensureBaseStub` cannot: a perpendicular predecessor run turns at a
/// corner that sits DIRECTLY on the arrowhead's base cell. The rasterizer
/// stamps the arrowhead one cell inside the terminal port and skips the port
/// itself, so a final leg of length EXACTLY 2 renders `[corner][arrow]` — the
/// glyph behind the tip is a `┌┐└┘`, not a straight stroke. The owner
/// arrow-base rule (2026-07-18) requires a STRAIGHT collinear stroke on the
/// base side before any corner. This pulls the corner back one cell along the
/// base axis — carrying its perpendicular predecessor run with it, since the
/// corner's row/column is bound to that run — so the final leg grows to length
/// 3, rendering `[corner][straight][arrow]`: a formal base approach.
///
/// ZERO-HEIGHT / accept-fallback: fires only when a CLEAR collinear cell (the
/// reserved inter-rank row) already exists to grow into — the pulled-back
/// predecessor run must be touch-free (border-inclusive) of EVERY box
/// (`sketch.lineTouchesRect`, no from/to exemption: the run lives in the gap
/// and must not land on any node), AND the pulled-back corner must not become a
/// new extreme on the base axis (that would extend the bounding box — a
/// bare-gap loop turn at the margin). When either fails it returns the polyline
/// UNCHANGED (the report-only validator keeps counting the residual) rather
/// than fabricating overlap or adding a layout row. Requires an interior
/// predecessor vertex (not the source port, index 0) so the source attachment
/// never moves.
///
/// Grows onto a FRESH buffer (never mutates the input) so the caller retains
/// the ungrown polyline for a clearance-driven revert (a grown run can push
/// one cell into a neighbour). Returns the same slice when it does not fire.
/// The point count is preserved — the new straight cell is the vacated corner
/// position — but the slice is reallocated so callers uniformly rebind.
/// guarded-by: routing_terminal_test.zig "ensureBaseApproachLengthen grows a corner-fed len-2 final into a straight base approach"
pub fn ensureBaseApproachLengthen(
    a: std.mem.Allocator,
    poly: []sketch.Point,
    placements: []const sketch.NodePlacement,
) error{OutOfMemory}![]sketch.Point {
    const fed = rp.detectCornerFedTerminal(poly) orelse return poly;
    const bi = fed.bi;
    // Need an INTERIOR predecessor vertex (poly[bi-1]) that is not the source
    // port at index 0, so pulling the run back never detaches the source.
    if (bi < 2) return poly;
    const b = fed.b;
    const p = fed.p;
    const q = poly[bi - 2];
    // Final leg (b -> c): a single-axis run of length EXACTLY 2 — the
    // corner-on-base signature (corner at b, arrowhead at c-unit, base = b).
    // (The detector already confirmed p->b is a perpendicular orthogonal run.)
    const lx = fed.lx;
    const ly = fed.ly;
    if (lx != 0 and ly != 0) return poly; // not orthogonal
    if (@as(i32, @intCast(@abs(lx))) + @as(i32, @intCast(@abs(ly))) != 2) return poly;
    // Unit step along the base axis, from the corner toward the terminal.
    const ux: i32 = if (lx > 0) 1 else if (lx < 0) -1 else 0;
    const uy: i32 = if (ly > 0) 1 else if (ly < 0) -1 else 0;
    const base_horizontal = (ux != 0);
    // The leg q -> p must run along the base axis, so pulling p back one cell
    // keeps it a straight (non-reversing, non-degenerate) segment.
    const qp_perp: i32 = if (base_horizontal) (q.y - p.y) else (q.x - p.x);
    if (qp_perp != 0) return poly;
    const q_base: i32 = if (base_horizontal) q.x else q.y;
    const p_base: i32 = if (base_horizontal) p.x else p.y;
    const np_base: i32 = p_base - (if (base_horizontal) ux else uy);
    if (np_base == q_base or (p_base > q_base) != (np_base > q_base)) return poly;
    // Pull the corner (and its predecessor run) back one cell along -unit(base).
    const nb = sketch.Point{ .x = b.x - ux, .y = b.y - uy };
    const np = sketch.Point{ .x = p.x - ux, .y = p.y - uy };
    // Zero-DIMENSION gate: the pulled-back corner must not become a NEW extreme
    // on the base axis of this polyline. When the corner is already the
    // polyline's outermost point (e.g. a back-edge loop's turn at the canvas
    // margin), pulling it further out extends the diagram's bounding box — a
    // bare-gap case, not the reserved inter-rank slack this tranche grows into.
    // Accept-fallback so height AND width stay fixed.
    var lo_axis: i32 = if (base_horizontal) poly[0].x else poly[0].y;
    var hi_axis: i32 = lo_axis;
    for (poly) |pt| {
        const v = if (base_horizontal) pt.x else pt.y;
        lo_axis = @min(lo_axis, v);
        hi_axis = @max(hi_axis, v);
    }
    const nb_axis: i32 = if (base_horizontal) nb.x else nb.y;
    if (nb_axis < lo_axis or nb_axis > hi_axis) return poly;
    // Room gate: the pulled-back run lives in the inter-rank gap and must be
    // touch-free (touch semantics, border-inclusive) of EVERY box — including
    // from/to. Unlike a route body (which legitimately meets its endpoints at
    // the ports), this run must not land on any node; skipping from/to here
    // would let the grow pull the run onto the source/target border and pierce
    // it. No clear cell -> accept-fallback.
    const run_horizontal = (np.y == nb.y);
    const cross: i32 = if (run_horizontal) np.y else np.x;
    const lo: i32 = if (run_horizontal) @min(np.x, nb.x) else @min(np.y, nb.y);
    const hi: i32 = if (run_horizontal) @max(np.x, nb.x) else @max(np.y, nb.y);
    for (placements) |pl| {
        if (sketch.lineTouchesRect(run_horizontal, cross, lo, hi, pl.rect)) return poly;
    }
    var grown: std.ArrayListUnmanaged(sketch.Point) = .empty;
    try grown.appendSlice(a, poly);
    grown.items[bi] = nb;
    grown.items[bi - 1] = np;
    return try grown.toOwnedSlice(a);
}

/// Per-gap extra rows for OFFSET corner-fed forward terminals sitting in a
/// BARE inter-rank gap. The row-reservation companion to
/// `ensureBaseApproachLengthen`: that pass GROWS a corner-fed len-2 final into
/// a straight base only when a clear collinear cell already exists; in a bare
/// TD gap (v_spacing = 2 rows) none does, so it accept-falls-back. This pass
/// tells the caller which gaps to widen so the room appears.
///
/// Entry i is +1 when the gap between layer i and layer i+1 RECEIVES a terminal
/// whose final approach must TURN: an adjacent REAL→REAL forward edge whose
/// source-port column differs from its target-port column. A column-aligned
/// terminal descends straight (already a formal `│` base) and is left at 0.
///
/// Scope (matches the grow pass's own guards, so a reserved row is never
/// wasted on a case the pass declines):
///   - reversed segments are back edges (`growBaseApproach` skips them),
///   - bidirectional edges (`arrow_from != none`) are skipped by the grow pass,
///   - invisible links draw no arrowhead to formalize,
///   - virtual endpoints are skip corridors — `skipCorridorExtraRows` owns
///     those gaps; keying on REAL→REAL keeps the two passes disjoint.
///
/// Report-only, node-identity-free (placed columns + layered adjacency only).
/// The caller reads the ACCUMULATED gap width and tops up ONLY gaps still at
/// the bare width, so a fan/lane/skip-widened gap is never double-counted.
/// `geom` is parallel to `lg.nodes`.
/// guarded-by: routing_terminal_test.zig "terminalApproachExtraRows flags a bare gap with an offset adjacent forward terminal but not a column-aligned one"
pub fn terminalApproachExtraRows(
    comptime NodeGeom: type,
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    lg: sugiyama.LayeredGraph,
    geom: []const NodeGeom,
) error{OutOfMemory}![]u32 {
    if (lg.layers.len < 2) return try a.alloc(u32, 0);
    const out = try a.alloc(u32, lg.layers.len - 1);
    @memset(out, 0);

    var node_layer = try a.alloc(u32, lg.nodes.len);
    defer a.free(node_layer);
    @memset(node_layer, 0);
    for (lg.layers, 0..) |row, li| {
        for (row) |idx| node_layer[idx] = @intCast(li);
    }

    // Id -> Edge lookup built ONCE (first-match-wins, mirroring findGraphEdge)
    // so the per-edge resolve below is O(1) instead of a linear graph.edges scan.
    var edge_by_id = std.AutoHashMap(sg.EdgeId, sg.Edge).init(a);
    defer edge_by_id.deinit();
    for (graph.edges) |e| {
        const gop = try edge_by_id.getOrPut(e.id);
        if (!gop.found_existing) gop.value_ptr.* = e;
    }

    for (lg.edges) |le| {
        if (le.reversed) continue;
        const from_real = switch (lg.nodes[le.from]) {
            .real => true,
            .virtual => false,
        };
        const to_real = switch (lg.nodes[le.to]) {
            .real => true,
            .virtual => false,
        };
        if (!from_real or !to_real) continue;
        const lf = node_layer[le.from];
        const lt = node_layer[le.to];
        if (lt != lf + 1) continue; // only adjacent downward segments

        const oe = edge_by_id.get(le.edge) orelse continue;
        if (oe.arrow_to == .none or oe.arrow_from != .none) continue;
        if (oe.kind == .invisible) continue;

        // Offset test: source-port column != target-port column ⇒ the final
        // approach turns, so the terminal is corner-fed in a bare gap.
        const s = geom[le.from];
        const t = geom[le.to];
        const scx = s.x + @divTrunc(@as(i32, @intCast(s.w)), 2);
        const tcx = t.x + @divTrunc(@as(i32, @intCast(t.w)), 2);
        if (scx == tcx) continue;

        out[lf] = 1; // gap between layer lf and layer lf+1
    }
    return out;
}

test {
    _ = @import("routing_terminal_test.zig");
}

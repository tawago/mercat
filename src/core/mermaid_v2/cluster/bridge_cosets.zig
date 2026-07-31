//! cluster/bridge_cosets.zig — carry an outer co-set across the bridge swap.
//!
//! `stitch.zig` DROPS every outer edge that touches a super-node: those edges
//! only drove the outer layout, and `cluster/bridges.zig` re-routes the real
//! connection as a bridge EdgePath keyed by its Crossing id. An outer co-set
//! (e.g. a fan out of one top-level node into two sibling subgraphs) still
//! names the DROPPED placement ids, so without this remap its members resolve
//! to nothing and the ink those edges legally share loses its permission
//! record. Pure data: ids in, ids out; no geometry.
//!
//! JOIN KEY. `split.buildOuter` derives both records from the SAME
//! cross-border SemGraph edge: the Crossing keeps the real endpoints, the
//! placement edge their outer representatives (`outerRepr`). So a placement
//! edge corresponds to a crossing exactly when the crossing's endpoints
//! resolve to that edge's (from, to) outer nodes. Placement edges are DEDUPED
//! per (from, to) pair, so several crossings can answer to one placement edge;
//! that member is then left unmapped (see `bridgeFor`).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const ledger = @import("../base/ledger.zig");
const split_mod = @import("split.zig");

/// Copy an OUTER co-set into the merged id space: a member whose placement
/// edge survives shifts by `outer_base`, a member whose placement edge was
/// dropped for a bridge becomes that bridge's id (`bridge_base` + crossing
/// id). A member with neither is left shifted-but-dangling — a set names who
/// MAY share, and naming an absent edge authorizes nothing.
/// guarded-by: bridge_cosets.zig "a fan into two subgraphs keeps its members as bridge ids"
pub fn remapOuterSet(
    arena: std.mem.Allocator,
    sr: split_mod.SplitResult,
    outer: sketch.Sketch,
    cs: ledger.CoSet,
    outer_base: sketch.EdgeId,
    bridge_base: sketch.EdgeId,
) error{OutOfMemory}!ledger.CoSet {
    const members = try arena.alloc(sketch.EdgeId, cs.members.len);
    for (cs.members, 0..) |m, i| {
        members[i] = if (bridgeFor(sr, outer, m)) |cid| bridge_base + cid else m + outer_base;
    }
    return .{ .origin = cs.origin, .members = members };
}

/// The crossing id whose bridge REPLACES outer placement edge `id`, or null
/// when there is none — the edge survived the stitch, is unknown, or (the
/// conservative case) several crossings share the one deduped placement edge,
/// where naming any single bridge would be an arbitrary choice.
fn bridgeFor(sr: split_mod.SplitResult, outer: sketch.Sketch, id: sketch.EdgeId) ?sketch.EdgeId {
    const e = endpointsOf(outer, id) orelse return null;
    if (!isSuper(sr, e.from) and !isSuper(sr, e.to)) return null; // kept by stitch
    var found: ?sketch.EdgeId = null;
    for (sr.crossings) |c| {
        if (outerReprOf(sr, c.from) != e.from or outerReprOf(sr, c.to) != e.to) continue;
        if (found != null) return null; // many-to-one: name no bridge at all
        found = c.id;
    }
    return found;
}

const Endpoints = struct { from: sketch.NodeId, to: sketch.NodeId };

/// The outer nodes edge `id` connects. A fan's members are carried as bus-bar
/// TAPS rather than EdgePaths — the fan-into-subgraphs case this module
/// exists for — so both carriers answer here, oriented by the rail's role.
fn endpointsOf(s: sketch.Sketch, id: sketch.EdgeId) ?Endpoints {
    for (s.edges) |e| {
        if (e.id == id) return .{ .from = e.from, .to = e.to };
    }
    for (s.busbars) |b| {
        const into_pivot = b.role == .fan_in_dropper or b.role == .fan_in_rail;
        for (b.taps) |t| {
            if (t.edge != id) continue;
            return if (into_pivot) .{ .from = t.node, .to = b.pivot } else .{ .from = b.pivot, .to = t.node };
        }
    }
    return null;
}

fn isSuper(sr: split_mod.SplitResult, outer_node: sketch.NodeId) bool {
    for (sr.supers) |s| {
        if (s.outer_node == outer_node) return true;
    }
    return false;
}

/// The outer-piece node standing in for original node `orig_id`: the
/// super-node of the top-level subgraph holding it, else its own outer-local
/// id. Mirrors `split.outerRepr` over the SplitResult's id maps (the original
/// SemGraph is gone by stitch time).
fn outerReprOf(sr: split_mod.SplitResult, orig_id: sg.NodeId) sketch.NodeId {
    for (sr.supers) |s| {
        for (sr.pieces[s.child_piece].orig_ids) |o| {
            if (o == orig_id) return s.outer_node;
        }
    }
    for (sr.pieces[0].orig_ids, 0..) |o, i| {
        if (o == orig_id) return @intCast(i);
    }
    return sg.SENTINEL;
}

// ====================================================================
// Tests
// ====================================================================

const testing = std.testing;

/// Outer piece with node 0 = a real top-level node, nodes 1/2 = supers for
/// clusters 100/200 whose children hold original nodes 1 and 2.
fn fixture() split_mod.SplitResult {
    const S = struct {
        const outer_orig = [_]sg.NodeId{ 0, sg.SENTINEL, sg.SENTINEL };
        const child_a = [_]sg.NodeId{1};
        const child_b = [_]sg.NodeId{2};
        const empty: sg.SemGraph = .{
            .direction = .TD,
            .nodes = &.{},
            .edges = &.{},
            .clusters = &.{},
            .classes = &.{},
            .arena = null,
        };
        const pieces = [_]split_mod.Piece{
            .{ .graph = empty, .cluster_id = null, .orig_ids = &outer_orig },
            .{ .graph = empty, .cluster_id = 100, .orig_ids = &child_a },
            .{ .graph = empty, .cluster_id = 200, .orig_ids = &child_b },
        };
        const supers = [_]split_mod.SuperNode{
            .{ .outer_node = 1, .cluster_id = 100, .child_piece = 1 },
            .{ .outer_node = 2, .cluster_id = 200, .child_piece = 2 },
        };
        const crossings = [_]split_mod.Crossing{
            .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
            .{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        };
    };
    return .{ .pieces = &S.pieces, .supers = &S.supers, .crossings = &S.crossings, .orig_node_count = 3 };
}

fn placementEdge(id: sketch.EdgeId, from: sketch.NodeId, to: sketch.NodeId) sketch.EdgePath {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .polyline = &.{},
        .port_from = .{ .node = from, .side = .south, .offset = 0 },
        .port_to = .{ .node = to, .side = .north, .offset = 0 },
        .arrow_from = .none,
        .arrow_to = .none,
        .label = null,
        .kind = .solid,
    };
}

/// Minimal outer Sketch carrying only the placement edges under test.
fn outerWith(edges: []const sketch.EdgePath) sketch.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = edges,
        .diagnostics = &.{},
        .budget = .{ .max_width = 80, .rung = 0 },
    };
}

test "a fan into two subgraphs keeps its members as bridge ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const edges = [_]sketch.EdgePath{
        placementEdge(0, 0, 1), // dropped: replaced by crossing 0's bridge
        placementEdge(1, 0, 2), // dropped: replaced by crossing 1's bridge
    };
    const outer = outerWith(&edges);

    const set: ledger.CoSet = .{ .origin = .fan_rail, .members = &.{ 0, 1 } };
    const out = try remapOuterSet(a, fixture(), outer, set, 10, 100);
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 100, 101 }, out.members);
    try testing.expectEqual(ledger.CoOrigin.fan_rail, out.origin);
}

test "a surviving placement edge's member only shifts by the outer base" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const edges = [_]sketch.EdgePath{placementEdge(3, 0, 0)}; // real -> real
    const outer = outerWith(&edges);

    const set: ledger.CoSet = .{ .origin = .fan_rail, .members = &.{ 3, 9 } };
    const out = try remapOuterSet(a, fixture(), outer, set, 10, 100);
    // 3 survives (shift only); 9 names no outer edge and stays dangling.
    try testing.expectEqualSlices(sketch.EdgeId, &.{ 13, 19 }, out.members);
}

test "several crossings behind one deduped placement edge map to no bridge" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Both crossings of the fixture rewritten onto the SAME (0 -> 1) pair by
    // pointing the second one's target at child piece 1's node as well.
    var sr = fixture();
    const many = [_]split_mod.Crossing{
        .{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        .{ .id = 1, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    sr.crossings = &many;

    const edges = [_]sketch.EdgePath{placementEdge(0, 0, 1)};
    const outer = outerWith(&edges);

    const set: ledger.CoSet = .{ .origin = .fan_rail, .members = &.{0} };
    const out = try remapOuterSet(a, sr, outer, set, 10, 100);
    try testing.expectEqualSlices(sketch.EdgeId, &.{10}, out.members);
}

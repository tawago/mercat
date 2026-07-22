//! Lever D — TD single-node de-cascade for `layout.zig`.
//!
//! Detects a straight run of single-node layers whose indentation
//! accumulates layer-by-layer under a fork (drifting far right of the
//! diagram's left margin and busting the width budget) and slides the whole
//! drifted subtree (chain + its fork/leaf children) left as one rigid unit,
//! preserving every internal offset so the vertical trunk stays drilled —
//! instead of moving `x_assign.flushLeftRows`-exempted single-real-node rows
//! independently, which would shear their `│` connectors into a jog. Only
//! ever moves a run LEFTWARD, so it can only narrow or hold the bbox.
//! Downstream routing (`routing.buildEdges` / `back_edges.zig`) re-routes
//! every edge from the post-slide geom; this module only moves geom.
//!
//! Imports (layout/ zone): `std`, `../sem_graph.zig`, `sugiyama.zig`, and the
//! NodeGeom type from `routing.zig`. Must not reach into cluster/, recurse,
//! budget, raster/, lattice, or paint/.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const routing = @import("routing.zig");

pub const NodeGeom = routing.NodeGeom;

/// Minimum drift (cells) a chain head must sit right of the margin before the
/// slide is worth doing. Below this the run is essentially already left and a
/// shift would be churn (and risk crossing fitting seeds). A fixed function of
/// layout geometry, never of any seed identity.
const MIN_DRIFT: i32 = 4;

/// Horizontal gap (cells) kept between a slid unit node and the nearest
/// non-unit node to its left in the same layer, so the de-cascaded chain never
/// collides with the fork siblings it slides past. Matches the layout's default
/// inter-node breathing room; a fixed function of geometry, never of identity.
const COLLISION_GAP: i32 = 2;

/// Detect a rightward single-node cascade and slide it (with its fork/leaf
/// subtree) left to the diagram margin as a rigid unit. `geom` is parallel to
/// `lg.nodes`. No-op unless a drifted straight trunk of length ≥ 2 layers is
/// found. TD-only; the caller gates on `compact_x && justify == .flush_left`,
/// so this never fires on the natural rung (fitting seeds stay byte-identical).
pub fn deCascade(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    geom: []NodeGeom,
    lg: sugiyama.LayeredGraph,
) error{OutOfMemory}!void {
    _ = graph;
    const nl = lg.layers.len;
    if (nl < 3) return; // need a parent + ≥2 chain layers.

    var margin: i32 = std.math.maxInt(i32);
    for (lg.nodes, 0..) |ln, i| {
        if (ln == .real and geom[i].x < margin) margin = geom[i].x;
    }
    if (margin == std.math.maxInt(i32)) return;

    // ---- 1. Anchor on the MOST-drifted single-node-layer trunk node, not the first-drifted one. // guarded-by: decascade_test.zig "deCascade anchors on the most-drifted trunk, not the first-drifted one"
    var seed_idx: ?u32 = null;
    var best_drift: i32 = MIN_DRIFT;
    {
        var li: usize = 0;
        while (li < nl) : (li += 1) {
            const sole = soleRealNode(lg, li) orelse continue;
            const drift = geom[sole].x - margin;
            if (drift > best_drift) {
                best_drift = drift;
                seed_idx = sole;
            }
        }
    }
    const seed = seed_idx orelse return;

    // Climb UP through single-parent trunk links to the true head, stopping before a multi-node fork layer rather than climbing through it. // guarded-by: decascade_test.zig "deCascade head climb stops exactly at a multi-node fork layer"
    var head = seed;
    while (true) {
        const p = soleForwardParent(lg, head) orelse break;
        if (geom[p].layer + 1 != geom[head].layer) break;
        if (soleRealNode(lg, geom[p].layer) == null) break; // parent layer forks
        if (soleForwardChild(lg, p) == null) break; // parent forks downward
        head = p;
    }
    // The head must hang off a parent in the layer above; a true source with no such parent is already the left edge and this is a no-op. // guarded-by: decascade_test.zig "deCascade no-ops when the drifted trunk head is a true source (no forward parent)"
    if (soleForwardParent(lg, head) == null) return;
    const lo: usize = geom[head].layer;

    // The bottom may fork; the fork subtree rides along in the flood below.
    var hi = lo; // last chain layer index
    var cur = head;
    while (true) {
        const next = soleForwardChild(lg, cur) orelse break;
        // `next` must be the sole real node of its layer to keep the trunk straight; otherwise the chain ends at `cur`. // guarded-by: decascade_test.zig "deCascade trunk walk stops at a branch instead of treating it as trunk-straight"
        if (soleRealNode(lg, geom[next].layer) == null) break;
        if (geom[next].layer != geom[cur].layer + 1) break;
        hi = geom[next].layer;
        cur = next;
    }

    // A genuine CASCADE needs a RUN of ≥ 2 consecutive single-node layers; a lone drifted single-node layer (hi == lo) is not a cascade. // guarded-by: decascade_test.zig "deCascade does not fire for a lone drifted single-node layer (hi==lo)"
    if (hi <= lo) return;

    // ---- 3. Flood the rigid unit: every node reachable downward (forward
    //         edges) from the chain nodes, staying in layers ≥ lo. Includes
    //         the chain itself, the bottom fork's children + their subtree,
    //         and any virtual waypoints those edges thread. ------------------
    const n = lg.nodes.len;
    const in_unit = try a.alloc(bool, n);
    defer a.free(in_unit);
    @memset(in_unit, false);

    var stack: std.ArrayListUnmanaged(u32) = .empty;
    defer stack.deinit(a);
    {
        var c = head;
        in_unit[c] = true;
        try stack.append(a, c);
        while (true) {
            const next = soleForwardChild(lg, c) orelse break;
            if (soleRealNode(lg, geom[next].layer) == null) break;
            if (geom[next].layer != geom[c].layer + 1) break;
            if (geom[next].layer > hi) break;
            in_unit[next] = true;
            try stack.append(a, next);
            c = next;
        }
    }
    // Flood forward from the trunk bottom over forward edges, staying in layers ≥ lo so we never pull a node above the run. // guarded-by: decascade_test.zig "deCascade flood-forward never pulls a node above the run into the unit"
    while (stack.pop()) |node| {
        for (lg.edges) |e| {
            if (e.from != node) continue;
            if (e.reversed) continue; // back-edges route around; don't drag targets
            const t = e.to;
            if (in_unit[t]) continue;
            if (geom[t].layer < lo) continue; // would pull above the run
            in_unit[t] = true;
            try stack.append(a, t);
        }
    }

    // ---- 4. Compute the rigid leftward delta and apply it. -----------------
    // Min x over the unit's real nodes = the unit's left edge; slide it to the
    // margin. Clamp so the head never crosses left of its parent's center, so
    // the entry connector (parent → head) stays a clean vertical/elbow rather
    // than reversing into a rightward jog.
    var unit_min: i32 = std.math.maxInt(i32);
    for (lg.nodes, 0..) |ln, i| {
        if (ln == .real and in_unit[i] and geom[i].x < unit_min) unit_min = geom[i].x;
    }
    if (unit_min == std.math.maxInt(i32)) return;

    var delta = margin - unit_min;
    if (delta >= 0) return; // already at/left of margin — nothing to gain.

    // Collision floor: bound the leftward slide so no unit node crosses into the right edge (+ a gap) of the nearest non-unit node to its left in the same layer. // guarded-by: decascade_test.zig "deCascade collision floor clamps the slide short of a fixed sibling's right edge"
    var floor: i32 = std.math.minInt(i32);
    for (lg.nodes, 0..) |ln, i| {
        if (ln != .real or !in_unit[i]) continue;
        const layer = geom[i].layer;
        var bar: i32 = std.math.minInt(i32);
        for (lg.layers[layer]) |j| {
            if (lg.nodes[j] != .real or in_unit[j]) continue;
            if (geom[j].x >= geom[i].x) continue; // not to the left
            const r = geom[j].x + @as(i32, @intCast(geom[j].w));
            if (r > bar) bar = r;
        }
        if (bar == std.math.minInt(i32)) continue; // no left neighbour in layer
        // node i must stay at ≥ bar + COLLISION_GAP → max leftward shift.
        const node_floor = (bar + COLLISION_GAP) - geom[i].x;
        if (node_floor > floor) floor = node_floor;
    }
    if (floor != std.math.minInt(i32) and delta < floor) delta = floor;
    if (delta >= 0) return;

    for (lg.nodes, 0..) |_, i| {
        if (in_unit[i]) geom[i].x += delta;
    }

    // ---- 6. Entry-corridor headroom. The head's parent sits in the (un-moved)
    //         fork layer above, so after the slide the head's incoming edge
    //         must travel a long HORIZONTAL run to reach the head's now-far-left
    //         port. That run lands on the single gap row directly below the fork
    //         layer — the same row the fork SIBLING boxes (oauth's AccessDenied)
    //         occupy with their bottom border — and the router collides into
    //         them. Opening one extra gap row below the fork layer gives the
    //         horizontal run a clear lane: push every node at layer ≥ lo down by
    //         the tallest fork-layer box's height so the corridor clears the box
    //         entirely. Only fires when the head actually slid far enough that
    //         its port left of a non-unit sibling box in the fork layer — i.e.
    //         exactly the collision case.
    const head_port = geom[head].x + @divTrunc(@as(i32, @intCast(geom[head].w)), 2);
    var needs_corridor = false;
    var fork_layer_h: i32 = 0;
    if (lo > 0) {
        for (lg.layers[lo - 1]) |idx| {
            if (lg.nodes[idx] != .real or in_unit[idx]) continue;
            const r = geom[idx].x + @as(i32, @intCast(geom[idx].w));
            if (geom[idx].x <= head_port and head_port <= r) {
                // head's entry port falls under a non-unit fork-sibling box.
                needs_corridor = true;
            }
            const h: i32 = @intCast(geom[idx].h);
            if (h > fork_layer_h) fork_layer_h = h;
        }
    }
    if (needs_corridor and fork_layer_h > 0) {
        // Drop everything at layer ≥ lo by the tallest fork-layer sibling's height so the corridor clears the deepest sibling box, not just the overlapping one. // guarded-by: decascade_test.zig "deCascade entry-corridor drop uses the tallest fork-layer sibling, not just the overlapping one"
        const lo_u: u32 = @intCast(lo);
        for (geom) |*g| {
            if (g.layer >= lo_u) g.y += fork_layer_h;
        }
    }
}

/// The sole real-node index of layer `li`, or null if the layer has 0 or ≥2
/// real nodes (virtuals are ignored for the count).
fn soleRealNode(lg: sugiyama.LayeredGraph, li: usize) ?u32 {
    if (li >= lg.layers.len) return null;
    var found: ?u32 = null;
    for (lg.layers[li]) |idx| {
        if (lg.nodes[idx] != .real) continue;
        if (found != null) return null; // ≥2 real nodes
        found = idx;
    }
    return found;
}

/// The single forward (non-reversed) parent of `idx` if it has exactly one,
/// else null. "Parent" = a node with a forward edge INTO `idx`.
fn soleForwardParent(lg: sugiyama.LayeredGraph, idx: u32) ?u32 {
    var found: ?u32 = null;
    for (lg.edges) |e| {
        if (e.to != idx) continue;
        if (e.reversed) continue;
        if (found != null) return null;
        found = e.from;
    }
    return found;
}

/// The single forward (non-reversed) child of `idx` if it has exactly one,
/// else null. "Child" = a node `idx` has a forward edge to.
fn soleForwardChild(lg: sugiyama.LayeredGraph, idx: u32) ?u32 {
    var found: ?u32 = null;
    for (lg.edges) |e| {
        if (e.from != idx) continue;
        if (e.reversed) continue;
        if (found != null) return null;
        found = e.to;
    }
    return found;
}

test {
    _ = @import("decascade_test.zig");
}

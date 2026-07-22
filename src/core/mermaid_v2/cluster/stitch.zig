//! cluster/stitch.zig — glue the finished per-piece Sketches into one.
//!
//! Counterpart to `cluster/split.zig`: welds each piece's `layout/`-produced
//! Sketch into the outer one, translating child geometry into its super-
//! node's interior and drawing the box (ClusterFrame) around it.
//!
//! PURE DATA WORK: Sketches in, one Sketch out; the driver's arena owns all
//! slices for the whole cut → layout → stitch run (no deinit here).

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const split_mod = @import("split.zig");
const bridges = @import("bridges.zig");
const entry_inset = @import("entry_inset.zig");

pub const SplitResult = split_mod.SplitResult;
/// Re-exported so `recurse.stitchOuter` (which calls `entryInsetFor`) and the
/// translate sites below share one inset type.
pub const EntryInset = entry_inset.EntryInset;

/// THE single source of the per-super frame pad: full `prim` frame pad for a
/// real cluster, ZERO on every side for a SYNTHETIC packing cluster (no
/// border, no label, no inset). Used by `superSize` and BOTH child-translate
/// sites in `stitch`, so sizing and translation cannot desync.
fn superPad(scale: u32, synthetic: bool) struct { x: u32, y: u32 } {
    if (synthetic) return .{ .x = 0, .y = 0 };
    return .{ .x = prim.framePadX(scale), .y = prim.framePadY(scale) };
}

/// Size a super-node so its interior exactly holds `child_bbox` plus the frame
/// border+inset on every side, at the given `scale`. The driver feeds this into
/// `layout.LayoutOptions.fixed_sizes` for each super-node and MUST pass the same
/// `scale` it later hands `stitch` (the driver passes `opts.spacing_scale`).
pub fn superSize(child_bbox: sketch.Rect, scale: u32, synthetic: bool) struct { w: u32, h: u32 } {
    const pad = superPad(scale, synthetic);
    return .{ .w = child_bbox.w + 2 * pad.x, .h = child_bbox.h + 2 * pad.y };
}

/// Resolve `entry_inset.entryArrivalInset`'s inputs from a `SplitResult` + child
/// slice for a given super-node. THE single call site of the shared entry-side
/// inset predicate — used by both `stitch`'s two child-translate sites and
/// `recurse.stitchOuter`'s super-sizing site, so sizing and translation can
/// never disagree on which clusters grow a row. // guarded-by: entry_inset.zig "entryArrivalInset"
pub fn entryInsetFor(
    sr: SplitResult,
    children: []const Clustered,
    super: split_mod.SuperNode,
) EntryInset {
    const child = children[super.child_piece];
    return entry_inset.entryArrivalInset(
        sr.crossings,
        super,
        child.sketch,
        child.input_of,
        sr.pieces[super.child_piece].orig_ids,
        sr.pieces[0].graph.direction,
    );
}

pub const StitchError = error{
    OutOfMemory,
    PieceSketchMismatch,
};

/// Flatten a node's display rows back into one flat label string for a
/// single-line ClusterFrame label. The common case is one row (returned as
/// the borrowed sub-slice, zero alloc); multiple rows are joined with a
/// single space into the arena.
fn flattenLines(arena: std.mem.Allocator, lines: []const []const u8) error{OutOfMemory}![]const u8 {
    if (lines.len == 0) return "";
    if (lines.len == 1) return lines[0];
    return std.mem.join(arena, " ", lines);
}

/// A laid-out (possibly clustered) flowchart plus the map from each Sketch
/// node id back to the id it had in the graph that produced it. The map lets a
/// PARENT stitch resolve this piece's nodes to the parent graph's ids (and
/// thence to bridge endpoints), which is what makes nesting recurse.
pub const Clustered = struct {
    sketch: sketch.Sketch,
    /// `input_of[sketch_node_id]` = the node's id in this piece's input graph.
    /// Identity for a flat `layout()` result; rebuilt at each stitch level.
    input_of: []const sketch.NodeId,
};

/// Glue the outer Sketch + each super-node's child `Clustered` into one
/// `Clustered`. `children[i]` aligns with `split_result.pieces[i]`
/// (`children[0]` is unused; the outer is passed separately). A child may
/// itself be a nested stitch result — its own boxes/edges come along and are
/// translated into place.
pub fn stitch(
    arena: std.mem.Allocator,
    split_result: SplitResult,
    outer: sketch.Sketch,
    children: []const Clustered,
    /// LayoutOptions.spacing_scale for this pass: selects the frame pad used by
    /// BOTH translate sites below (via `superPad`, per super-node). MUST be the
    /// same scale the driver passed to `superSize` so sizing and translation
    /// never diverge.
    scale: u32,
) StitchError!Clustered {
    if (children.len != split_result.pieces.len) return error.PieceSketchMismatch;

    var nodes: std.ArrayListUnmanaged(sketch.NodePlacement) = .empty;
    var clusters: std.ArrayListUnmanaged(sketch.ClusterFrame) = .empty;
    var edges: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
    var busbars: std.ArrayListUnmanaged(sketch.BusBar) = .empty;

    // Per-piece map: piece SKETCH node id -> merged (global) node id.
    var global_of = try arena.alloc([]sketch.NodeId, split_result.pieces.len);
    global_of[0] = try arena.alloc(sketch.NodeId, outer.nodes.len);
    @memset(global_of[0], sg.SENTINEL);
    for (children, 0..) |c, pi| {
        if (pi == 0) continue;
        global_of[pi] = try arena.alloc(sketch.NodeId, c.sketch.nodes.len);
        @memset(global_of[pi], sg.SENTINEL);
    }
    // This-graph node id -> merged id, for routing cross-border edges.
    const orig_to_merged = try arena.alloc(sketch.NodeId, split_result.orig_node_count);
    @memset(orig_to_merged, sg.SENTINEL);
    // Merged id -> this-graph node id, returned for the parent level.
    var input_of: std.ArrayListUnmanaged(sketch.NodeId) = .empty;
    var next_global: sketch.NodeId = 0;

    // Entry-side inset per super, computed ONCE (entryInsetFor is an
    // O(crossings×nodes) scan) and shared by BOTH the node-translate loop and
    // the edge-translate loop, indexed by the super's position in `supers`.
    const insets = try arena.alloc(EntryInset, split_result.supers.len);
    for (split_result.supers, 0..) |super, si| {
        insets[si] = entryInsetFor(split_result, children, super);
    }

    // --- Walk outer placements. Real ones stay; super-nodes become a box +
    //     their translated child interior (which may itself be nested). ---
    for (outer.nodes) |p| {
        if (superIndexFor(split_result, p.id)) |si| {
            const super = split_result.supers[si];
            const child = children[super.child_piece];
            const piece = split_result.pieces[super.child_piece];
            const pad = superPad(scale, super.synthetic);
            // Entry-side inset (top-arrival terminal): pushes the child content
            // one cell off the frame so the arrowhead gets a straight approach
            // cell. MUST match the superSize sizing site and the edge-translate
            // site below, both via the same shared predicate. // guarded-by: entry_inset.zig "entryArrivalInset"
            const ei = insets[si];
            const dx = p.rect.x + @as(i32, @intCast(pad.x)) + ei.dxExtra();
            const dy = p.rect.y + @as(i32, @intCast(pad.y)) + ei.dyExtra();

            // Translate every child placement into the super interior.
            for (child.sketch.nodes) |cp| {
                const gid = next_global;
                next_global += 1;
                global_of[super.child_piece][cp.id] = gid;
                const this_id = split_mod.pieceId(piece.orig_ids, child.input_of, cp.id);
                try setAt(arena, &input_of, gid, this_id);
                if (this_id != sg.SENTINEL and this_id < orig_to_merged.len) orig_to_merged[this_id] = gid;
                try nodes.append(arena, .{
                    .id = gid,
                    .rect = .{ .x = cp.rect.x + dx, .y = cp.rect.y + dy, .w = cp.rect.w, .h = cp.rect.h },
                    .shape = cp.shape,
                    .lines = cp.lines,
                    // Preserve a deeper sub-cluster membership; only nodes
                    // sitting directly in this cluster (null) take its id.
                    .cluster_id = cp.cluster_id orelse super.cluster_id,
                });
            }

            // Nested boxes from the child come along: shift, deepen, reparent.
            for (child.sketch.clusters) |cf| {
                try clusters.append(arena, .{
                    .id = cf.id,
                    .rect = .{ .x = cf.rect.x + dx, .y = cf.rect.y + dy, .w = cf.rect.w, .h = cf.rect.h },
                    .parent_id = cf.parent_id orelse super.cluster_id,
                    .label = cf.label,
                    .depth = cf.depth + 1,
                    .direction = cf.direction,
                    .synthetic = cf.synthetic,
                });
            }

            // This cluster's own box (depth 0 here; a parent level deepens it).
            // The super-node's `lines` carry the cluster label; the frame label
            // is single-line so we flatten (sentinel/wrap rows joined by space).
            try clusters.append(arena, .{
                .id = super.cluster_id,
                .rect = p.rect,
                .parent_id = null,
                .label = try flattenLines(arena, p.lines),
                .depth = 0,
                .direction = child.sketch.direction,
                .synthetic = super.synthetic,
            });
        } else {
            // Real top-level node: keep geometry, assign a fresh merged id.
            const gid = next_global;
            next_global += 1;
            global_of[0][p.id] = gid;
            const this_id = split_mod.idAt(split_result.pieces[0].orig_ids, p.id);
            try setAt(arena, &input_of, gid, this_id);
            if (this_id != sg.SENTINEL and this_id < orig_to_merged.len) orig_to_merged[this_id] = gid;
            try nodes.append(arena, .{
                .id = gid,
                .rect = p.rect,
                .shape = p.shape,
                .lines = p.lines,
                .cluster_id = null,
            });
        }
    }

    // --- Child edges (intra + already-routed nested bridges), translated. ---
    for (split_result.supers, 0..) |super, si| {
        const child = children[super.child_piece];
        const sp = placementOf(outer.nodes, super.outer_node);
        const pad = superPad(scale, super.synthetic);
        // Same entry-side inset as the node-translate site, so child edges/
        // busbars stay aligned with their (offset) child nodes.
        const ei = insets[si];
        const dx = sp.rect.x + @as(i32, @intCast(pad.x)) + ei.dxExtra();
        const dy = sp.rect.y + @as(i32, @intCast(pad.y)) + ei.dyExtra();
        for (child.sketch.edges) |ce| {
            try edges.append(arena, try translateEdge(arena, ce, global_of[super.child_piece], dx, dy));
        }
        for (child.sketch.busbars) |cb| {
            if (try translateBusBar(arena, cb, global_of[super.child_piece], dx, dy)) |tb| {
                try busbars.append(arena, tb);
            }
        }
    }

    // --- Outer edges. Keep only edges between two real top-level nodes;
    //     edges touching a super-node are placement-only (they drove the
    //     outer layout) and are replaced by routed bridge lines below. ---
    for (outer.edges) |oe| {
        if (superFor(split_result, oe.from) != null or superFor(split_result, oe.to) != null) continue;
        try edges.append(arena, try translateEdge(arena, oe, global_of[0], 0, 0));
    }

    // --- Outer bus-bars. Same rule per member edge: a tap onto a
    //     super-node is placement-only (its edge re-routes as a bridge);
    //     a bus-bar whose pivot is a super-node drops entirely. Surviving
    //     taps keep the trunk; a trunk left with zero taps drops too. ---
    for (outer.busbars) |ob| {
        if (superFor(split_result, ob.pivot) != null) continue;
        var kept: std.ArrayListUnmanaged(sketch.Tap) = .empty;
        for (ob.taps) |tap| {
            if (superFor(split_result, tap.node) != null) continue;
            try kept.append(arena, tap);
        }
        if (kept.items.len == 0) continue;
        var filtered = ob;
        filtered.taps = try kept.toOwnedSlice(arena);
        // Re-clamp the rail to the surviving taps + junction. // guarded-by: recurse_test.zig "stitch re-clamps a surviving bus-bar's rail past a dropped super-node tap"
        const junction = ob.stem[ob.stem.len - 1];
        var min_x: i32 = junction.x;
        var max_x: i32 = junction.x;
        for (filtered.taps) |tap| {
            min_x = @min(min_x, tap.at.x);
            max_x = @max(max_x, tap.at.x);
        }
        filtered.rail = .{
            .{ .x = min_x, .y = ob.rail[0].y },
            .{ .x = max_x, .y = ob.rail[1].y },
        };
        if (try translateBusBar(arena, filtered, global_of[0], 0, 0)) |tb| {
            try busbars.append(arena, tb);
        }
    }

    // --- Cross-border edges, routed directly between merged placements,
    //     jogging in the gaps between the now-final boxes. ---
    const node_slice = try nodes.toOwnedSlice(arena);
    const cluster_slice = try clusters.toOwnedSlice(arena);
    const bridge_edges = try bridges.route(arena, split_result.crossings, node_slice, cluster_slice, outer.direction, orig_to_merged);
    for (bridge_edges) |be| try edges.append(arena, be);

    return .{
        .sketch = .{
            .bbox = outer.bbox, // child geometry fits inside super rects ⊂ outer bbox
            .direction = outer.direction,
            .nodes = node_slice,
            .clusters = cluster_slice,
            .edges = try edges.toOwnedSlice(arena),
            .busbars = try busbars.toOwnedSlice(arena),
            .diagnostics = outer.diagnostics,
            .budget = outer.budget,
        },
        .input_of = try input_of.toOwnedSlice(arena),
    };
}

/// Grow `list` to index `i` (filling with SENTINEL) and set `list[i] = val`.
fn setAt(arena: std.mem.Allocator, list: *std.ArrayListUnmanaged(sketch.NodeId), i: sketch.NodeId, val: sketch.NodeId) error{OutOfMemory}!void {
    while (list.items.len <= i) try list.append(arena, sg.SENTINEL);
    list.items[i] = val;
}

/// If `outer_node_id` is a super-node, return its SuperNode record.
fn superFor(sr: SplitResult, outer_node_id: sketch.NodeId) ?split_mod.SuperNode {
    for (sr.supers) |s| {
        if (s.outer_node == outer_node_id) return s;
    }
    return null;
}

/// If `outer_node_id` is a super-node, return its index in `sr.supers` (so a
/// caller can index arrays computed parallel to `supers`).
fn superIndexFor(sr: SplitResult, outer_node_id: sketch.NodeId) ?usize {
    for (sr.supers, 0..) |s, i| {
        if (s.outer_node == outer_node_id) return i;
    }
    return null;
}

fn placementOf(placements: []const sketch.NodePlacement, id: sketch.NodeId) sketch.NodePlacement {
    for (placements) |p| {
        if (p.id == id) return p;
    }
    return placements[0];
}

/// Copy an edge with its endpoints remapped through `gmap` and its polyline +
/// ports translated by (dx, dy).
fn translateEdge(
    arena: std.mem.Allocator,
    e: sketch.EdgePath,
    gmap: []const sketch.NodeId,
    dx: i32,
    dy: i32,
) error{OutOfMemory}!sketch.EdgePath {
    const poly = try arena.alloc(sketch.Point, e.polyline.len);
    for (e.polyline, 0..) |pt, i| poly[i] = .{ .x = pt.x + dx, .y = pt.y + dy };
    return .{
        .id = e.id,
        .from = gmap[e.from],
        .to = gmap[e.to],
        .polyline = poly,
        .port_from = e.port_from,
        .port_to = e.port_to,
        .arrow_from = e.arrow_from,
        .arrow_to = e.arrow_to,
        .label = e.label,
        .kind = e.kind,
        .role = e.role,
    };
}

/// Copy a bus-bar with node ids remapped through `gmap` and all geometry
/// translated by (dx, dy). Returns null when any referenced node maps to
/// SENTINEL (defensive; callers filter super-node members beforehand).
fn translateBusBar(
    arena: std.mem.Allocator,
    bb: sketch.BusBar,
    gmap: []const sketch.NodeId,
    dx: i32,
    dy: i32,
) error{OutOfMemory}!?sketch.BusBar {
    if (bb.pivot >= gmap.len or gmap[bb.pivot] == sg.SENTINEL) return null;
    const stem = try arena.alloc(sketch.Point, bb.stem.len);
    for (bb.stem, 0..) |pt, i| stem[i] = .{ .x = pt.x + dx, .y = pt.y + dy };
    const taps = try arena.alloc(sketch.Tap, bb.taps.len);
    for (bb.taps, 0..) |tap, i| {
        if (tap.node >= gmap.len or gmap[tap.node] == sg.SENTINEL) return null;
        taps[i] = tap;
        taps[i].node = gmap[tap.node];
        taps[i].at = .{ .x = tap.at.x + dx, .y = tap.at.y + dy };
        taps[i].landing = .{ .x = tap.landing.x + dx, .y = tap.landing.y + dy };
    }
    var out = bb;
    out.pivot = gmap[bb.pivot];
    out.stem = stem;
    out.taps = taps;
    out.rail = .{
        .{ .x = bb.rail[0].x + dx, .y = bb.rail[0].y + dy },
        .{ .x = bb.rail[1].x + dx, .y = bb.rail[1].y + dy },
    };
    return out;
}

// ====================================================================
// Tests
// ====================================================================

test "superSize wraps child bbox with frame padding (scale 0 = full inset)" {
    const sz = superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 0, false);
    try std.testing.expectEqual(@as(u32, 28), sz.w); // 20 + 2*4
    try std.testing.expectEqual(@as(u32, 12), sz.h); // 8 + 2*2
}

test "superSize shrinks x inset under pressure (scale > 0), y unchanged" {
    const sz = superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 1, false);
    try std.testing.expectEqual(@as(u32, 24), sz.w); // 20 + 2*2 (padX 4 -> 2)
    try std.testing.expectEqual(@as(u32, 12), sz.h); // 8 + 2*2 (padY unchanged)
}

test "superSize for a synthetic packing cluster is exactly the child bbox" {
    const sz = superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 0, true);
    try std.testing.expectEqual(@as(u32, 20), sz.w);
    try std.testing.expectEqual(@as(u32, 8), sz.h);
}

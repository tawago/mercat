//! cluster/stitch.zig — glue the finished per-piece Sketches into one.
//!
//! Counterpart to `cluster/split.zig`: glues each piece's `layout/`-produced
//! Sketch into the outer one, translating child geometry into its super-node's
//! interior and drawing the box (ClusterFrame) around it. PURE DATA WORK:
//! Sketches in, one Sketch out; the driver's arena owns all slices for the
//! whole cut → layout → stitch run (no deinit here).

const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const sketch_channels = @import("../sketch_channels.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const split_mod = @import("split.zig");
const bridges = @import("bridges.zig");
const entry_inset = @import("entry_inset.zig");
const stitch_cosets = @import("stitch_cosets.zig");
const stitch_rails = @import("stitch_rails.zig");

pub const SplitResult = split_mod.SplitResult;
/// Re-exported so `recurse.stitchOuter` and the translate sites share one type.
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

/// Per-field sum of the outer piece's closure counts and every child's.
fn closureSum(outer: sketch.Sketch, children: []const Clustered) ledger.ClosureCounts {
    var out = outer.closure;
    for (children) |child| {
        inline for (@typeInfo(ledger.ClosureCounts).@"struct".fields) |f| {
            @field(out, f.name) += @field(child.sketch.closure, f.name);
        }
    }
    return out;
}

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
    var busbars: std.ArrayListUnmanaged(sketch.Rail) = .empty;
    var co_sets: std.ArrayListUnmanaged(ledger.CoSet) = .empty;
    const claim_sources = try arena.alloc(stitch_rails.ChildSource, split_result.supers.len);

    // INVARIANT: edge ids are globally unique inside the merged Sketch.
    // Every piece renumbers its edges from 0 (`split.zig`), so each piece gets
    // a disjoint contiguous id window here — children in append order, then the
    // outer piece, then the routed bridges — and EVERY id-bearing field copied
    // out of a piece (`EdgePath.id`, `Tap.edge`, `CoSet.members`) is rewritten
    // with that piece's offset. Without it, `ledger.coMembers` and the identity
    // comparisons in `raster/` alias two unrelated edges that both numbered
    // themselves 0. The scheme composes under nesting: an inner merged Sketch
    // already satisfies the invariant, and the outer stitch only slides its
    // whole (already-disjoint) window by one more offset.
    // guarded-by: recurse_test.zig "stitched sibling clusters share one edge-id space"
    var id_base: sketch.EdgeId = 0;

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
        const base = id_base;
        id_base += idSpan(child.sketch);
        claim_sources[si] = .{ .sketch = child.sketch, .node_map = global_of[super.child_piece], .edge_base = base };
        for (child.sketch.edges) |ce| {
            try edges.append(arena, try translateEdge(arena, ce, global_of[super.child_piece], dx, dy, base));
        }
        for (child.sketch.busbars) |cb| {
            if (try translateRail(arena, cb, global_of[super.child_piece], dx, dy, base)) |tb| {
                try busbars.append(arena, tb);
            }
        }
        for (child.sketch.co_sets) |cs| {
            if (cs.origin != .port_share) try co_sets.append(arena, try stitch_cosets.shiftSet(arena, cs, base, dx, dy));
        }
    }

    // --- Outer edges. Keep only edges between two real top-level nodes;
    //     edges touching a super-node are placement-only (they drove the
    //     outer layout) and are replaced by routed bridge lines below. ---
    const outer_base = id_base;
    id_base += idSpan(outer);
    for (outer.edges) |oe| {
        if (superFor(split_result, oe.from) != null or superFor(split_result, oe.to) != null) continue;
        try edges.append(arena, try translateEdge(arena, oe, global_of[0], 0, 0, outer_base));
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
        filtered.crossbar = .{
            .{ .x = min_x, .y = ob.crossbar[0].y },
            .{ .x = max_x, .y = ob.crossbar[1].y },
        };
        if (try translateRail(arena, filtered, global_of[0], 0, 0, outer_base)) |tb| {
            try busbars.append(arena, tb);
        }
    }

    // --- Cross-border edges, routed directly between merged placements,
    //     jogging in the gaps between the now-final boxes. ---
    const node_slice = try nodes.toOwnedSlice(arena);
    const cluster_slice = try clusters.toOwnedSlice(arena);
    const bridge_base = id_base;
    const bridge_start = edges.items.len;
    const bridge_edges = try bridges.route(arena, split_result.crossings, node_slice, cluster_slice, outer.direction, orig_to_merged);
    // Bridges carry crossing ids, themselves renumbered from 0 by `split.zig`:
    // they take the last id window.
    for (bridge_edges) |be| {
        var b = be;
        b.id = be.id + bridge_base;
        try edges.append(arena, b);
    }

    // Reconstruct authority only after bridge routing made every final image,
    // endpoint, port, and id available. Structural outer groups require exact
    // pivot evidence; port shares are one fresh population from final paths.
    // guarded-by: recurse_test2.zig "two bridges into one port declare a port-share co-set"
    const edge_slice = try edges.toOwnedSlice(arena);
    const final_bridges = edge_slice[bridge_start..];
    const bar_slice = try busbars.toOwnedSlice(arena);
    const authority = try stitch_cosets.finalizeAuthority(
        arena,
        split_result,
        outer,
        claim_sources,
        global_of[0],
        outer_base,
        bridge_base,
        edge_slice,
        final_bridges,
        bar_slice,
        node_slice,
        try co_sets.toOwnedSlice(arena),
    );

    var merged: sketch.Sketch = .{
        .bbox = outer.bbox, // child geometry fits inside super rects ⊂ outer bbox
        .direction = outer.direction,
        .nodes = node_slice,
        .clusters = cluster_slice,
        .edges = edge_slice,
        .busbars = bar_slice,
        .rail_claims = authority.claims,
        .co_sets = authority.sets,
        // Deliberately empty, not forgotten: piece-local plans speak in
        // piece-local edge ids that do not survive the merge, so no piece's
        // joins may be carried across. The merged candidate's plan is written
        // by the post-stitch realization pass or stays empty.
        .joins = .{},
        // Report-only counts are per-PIECE facts about one merged picture,
        // so the merged Sketch carries their sum; keeping only the outer's
        // would silently drop every refusal a child's fans decided.
        // guarded-by: recurse_test2.zig "the merged sketch sums its pieces' closure counts"
        .closure = closureSum(outer, children),
        .diagnostics = outer.diagnostics,
        .budget = outer.budget,
        // The candidate's label policy is a property of the CANDIDATE, not
        // of any one piece: it must survive the cut/glue or the raster (and
        // the scorer's audit re-raster) would silently read the struct
        // default instead of the policy the layout was built for.
        // guarded-by: select_test3.zig "stitching preserves the outer sketch's label policy"
        .label_policy = outer.label_policy,
    };
    // Each piece numbered from one, so the merged roster is re-numbered here.
    // guarded-by: sketch_channels_test.zig "a merged roster names every channel once"
    sketch_channels.stamp(arena, &merged);
    return .{
        .sketch = merged,
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

/// One past the largest edge id a piece can name in geometry or metadata.
fn idSpan(s: sketch.Sketch) sketch.EdgeId {
    var max_id: ?sketch.EdgeId = null;
    const bump = struct {
        fn f(cur: *?sketch.EdgeId, id: sketch.EdgeId) void {
            if (cur.* == null or id > cur.*.?) cur.* = id;
        }
    }.f;
    for (s.edges) |e| bump(&max_id, e.id);
    for (s.busbars) |b| for (b.taps) |t| bump(&max_id, t.edge);
    for (s.co_sets) |cs| for (cs.members) |m| bump(&max_id, m);
    for (s.rail_claims) |claim| for (claim.members) |m| bump(&max_id, m.edge);
    return if (max_id) |m| m + 1 else 0;
}

/// Copy an edge with its endpoints remapped through `gmap`, its polyline +
/// ports translated by (dx, dy) and its id shifted into the piece's window.
fn translateEdge(
    arena: std.mem.Allocator,
    e: sketch.EdgePath,
    gmap: []const sketch.NodeId,
    dx: i32,
    dy: i32,
    id_base: sketch.EdgeId,
) error{OutOfMemory}!sketch.EdgePath {
    const poly = try arena.alloc(sketch.Point, e.polyline.len);
    for (e.polyline, 0..) |pt, i| poly[i] = .{ .x = pt.x + dx, .y = pt.y + dy };
    return .{
        .id = e.id + id_base,
        .from = gmap[e.from],
        .to = gmap[e.to],
        .polyline = poly,
        .port_from = .{ .node = gmap[e.from], .side = e.port_from.side, .offset = e.port_from.offset },
        .port_to = .{ .node = gmap[e.to], .side = e.port_to.side, .offset = e.port_to.offset },
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
fn translateRail(
    arena: std.mem.Allocator,
    bb: sketch.Rail,
    gmap: []const sketch.NodeId,
    dx: i32,
    dy: i32,
    id_base: sketch.EdgeId,
) error{OutOfMemory}!?sketch.Rail {
    if (bb.pivot >= gmap.len or gmap[bb.pivot] == sg.SENTINEL) return null;
    const stem = try arena.alloc(sketch.Point, bb.stem.len);
    for (bb.stem, 0..) |pt, i| stem[i] = .{ .x = pt.x + dx, .y = pt.y + dy };
    const taps = try arena.alloc(sketch.Tap, bb.taps.len);
    for (bb.taps, 0..) |tap, i| {
        if (tap.node >= gmap.len or gmap[tap.node] == sg.SENTINEL) return null;
        taps[i] = tap;
        taps[i].node = gmap[tap.node];
        taps[i].edge = tap.edge + id_base;
        taps[i].at = .{ .x = tap.at.x + dx, .y = tap.at.y + dy };
        taps[i].landing = .{ .x = tap.landing.x + dx, .y = tap.landing.y + dy };
    }
    var out = bb;
    out.pivot = gmap[bb.pivot];
    out.stem = stem;
    out.taps = taps;
    out.crossbar = .{
        .{ .x = bb.crossbar[0].x + dx, .y = bb.crossbar[0].y + dy },
        .{ .x = bb.crossbar[1].x + dx, .y = bb.crossbar[1].y + dy },
    };
    return out;
}

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

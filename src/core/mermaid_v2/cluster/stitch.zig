const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const sketch_bundles = @import("../sketch_bundles.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const split_mod = @import("split.zig");
const bridges = @import("bridges.zig");
const bridge_plan = @import("bridge_plan.zig");
const entry_inset = @import("entry_inset.zig");
const stitch_bundle_sets = @import("stitch_bundle_sets.zig");
const stitch_bundles = @import("stitch_bundles.zig");
const stitch_rails = @import("stitch_rails.zig");
const stitch_gaps = @import("stitch_gaps.zig");

pub const SplitResult = split_mod.SplitResult;
pub const EntryInset = entry_inset.EntryInset;

fn superPad(scale: u32, synthetic: bool) struct { x: u32, y: u32 } {
    if (synthetic) return .{ .x = 0, .y = 0 };
    return .{ .x = prim.framePadX(scale), .y = prim.framePadY(scale) };
}

pub fn superSize(child_bbox: sketch.Rect, scale: u32, synthetic: bool) struct { w: u32, h: u32 } {
    const pad = superPad(scale, synthetic);
    return .{ .w = child_bbox.w + 2 * pad.x, .h = child_bbox.h + 2 * pad.y };
}

/// @guarded-by: entry_inset.zig "entryArrivalInset"
pub fn entryInsetFor(
    sr: SplitResult,
    children: []const Clustered,
    super: split_mod.SuperNode,
) EntryInset {
    const child = children[super.child_piece];
    return entry_inset.entryArrivalInset(
        sr.arrivals,
        super,
        child.sketch,
        child.input_of,
        sr.pieces[super.child_piece].orig_ids,
    );
}

pub const StitchError = error{
    OutOfMemory,
    PieceSketchMismatch,
};

fn flattenLines(arena: std.mem.Allocator, lines: []const []const u8) error{OutOfMemory}![]const u8 {
    if (lines.len == 0) return "";
    if (lines.len == 1) return lines[0];
    return std.mem.join(arena, " ", lines);
}

pub const Clustered = struct {
    sketch: sketch.Sketch,
    input_of: []const sketch.NodeId,
};

fn withTrackExpiry(
    arena: std.mem.Allocator,
    base: []const sketch.Diagnostic,
    expired: u32,
) error{OutOfMemory}![]const sketch.Diagnostic {
    if (expired == 0) return base;
    const out = try arena.alloc(sketch.Diagnostic, base.len + 1);
    @memcpy(out[0..base.len], base);
    out[base.len] = .{ .track_clearance_expired = expired };
    return out;
}

fn closureSum(outer: sketch.Sketch, children: []const Clustered) ledger.ClosureCounts {
    var out = outer.closure;
    for (children) |child| {
        inline for (@typeInfo(ledger.ClosureCounts).@"struct".fields) |f| {
            @field(out, f.name) += @field(child.sketch.closure, f.name);
        }
    }
    return out;
}

pub fn stitch(
    arena: std.mem.Allocator,
    split_result: SplitResult,
    outer: sketch.Sketch,
    children: []const Clustered,
    scale: u32,
    merge_joins: bool,
    bridge_build: prim.BridgeBuild,
) StitchError!Clustered {
    if (children.len != split_result.pieces.len) return error.PieceSketchMismatch;

    var nodes: std.ArrayListUnmanaged(sketch.NodePlacement) = .empty;
    var clusters: std.ArrayListUnmanaged(sketch.ClusterFrame) = .empty;
    var edges: std.ArrayListUnmanaged(sketch.EdgePath) = .empty;
    var rails: std.ArrayListUnmanaged(sketch.Rail) = .empty;
    var bundle_sets: std.ArrayListUnmanaged(ledger.Bundle) = .empty;
    var gap_records: std.ArrayListUnmanaged(ledger.GapRows) = .empty;
    var piece_joins: std.ArrayListUnmanaged(stitch_bundles.PieceBundles) = .empty;
    const claim_sources = try arena.alloc(stitch_rails.ChildSource, split_result.supers.len);

    // @guarded-by: recurse_test.zig "stitched sibling clusters share one edge-id space"
    var id_base: sketch.EdgeId = 0;

    var global_of = try arena.alloc([]sketch.NodeId, split_result.pieces.len);
    global_of[0] = try arena.alloc(sketch.NodeId, outer.nodes.len);
    @memset(global_of[0], sg.SENTINEL);
    for (children, 0..) |c, pi| {
        if (pi == 0) continue;
        global_of[pi] = try arena.alloc(sketch.NodeId, c.sketch.nodes.len);
        @memset(global_of[pi], sg.SENTINEL);
    }
    const orig_to_merged = try arena.alloc(sketch.NodeId, split_result.orig_node_count);
    @memset(orig_to_merged, sg.SENTINEL);
    var input_of: std.ArrayListUnmanaged(sketch.NodeId) = .empty;
    var next_global: sketch.NodeId = 0;

    const insets = try arena.alloc(EntryInset, split_result.supers.len);
    for (split_result.supers, 0..) |super, si| {
        insets[si] = entryInsetFor(split_result, children, super);
    }

    for (outer.nodes) |p| {
        if (superIndexFor(split_result, p.id)) |si| {
            const super = split_result.supers[si];
            const child = children[super.child_piece];
            const piece = split_result.pieces[super.child_piece];
            const pad = superPad(scale, super.synthetic);
            // @guarded-by: entry_inset.zig "entryArrivalInset"
            const ei = insets[si];
            const dx = p.rect.x + @as(i32, @intCast(pad.x)) + ei.dxExtra();
            const dy = p.rect.y + @as(i32, @intCast(pad.y)) + ei.dyExtra();

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
                    .cluster_id = cp.cluster_id orelse super.cluster_id,
                });
            }

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

    for (split_result.supers, 0..) |super, si| {
        const child = children[super.child_piece];
        const sp = placementOf(outer.nodes, super.outer_node);
        const pad = superPad(scale, super.synthetic);
        const ei = insets[si];
        const dx = sp.rect.x + @as(i32, @intCast(pad.x)) + ei.dxExtra();
        const dy = sp.rect.y + @as(i32, @intCast(pad.y)) + ei.dyExtra();
        const base = id_base;
        id_base += idSpan(child.sketch);
        claim_sources[si] = .{ .sketch = child.sketch, .node_map = global_of[super.child_piece], .edge_base = base };
        try piece_joins.append(arena, .{ .bundles = child.sketch.bundles, .edge_base = base, .node_map = global_of[super.child_piece] });
        for (child.sketch.edges) |ce| {
            try edges.append(arena, try translateEdge(arena, ce, global_of[super.child_piece], dx, dy, base));
        }
        for (child.sketch.rails) |cb| {
            if (try translateRail(arena, cb, global_of[super.child_piece], dx, dy, base)) |tb| {
                try rails.append(arena, tb);
            }
        }
        for (child.sketch.bundle_sets) |cs| {
            if (cs.origin != .port_share) try bundle_sets.append(arena, try stitch_bundle_sets.shiftSet(arena, cs, base, dx, dy));
        }
        for (child.sketch.gap_rows) |g| try gap_records.append(arena, try stitch_gaps.translateGap(arena, g, global_of[super.child_piece], dx, dy, base, child.sketch.direction, &.{}));
    }

    const outer_base = id_base;
    id_base += idSpan(outer);
    const bridge_base = id_base;
    var proxy_span: usize = 0;
    for (split_result.crossings) |c| if (c.proxy != sg.SENTINEL) {
        proxy_span = @max(proxy_span, @as(usize, c.proxy) + 1);
    };
    const bridges_of = try arena.alloc([]const sketch.EdgeId, proxy_span);
    {
        var lists = try arena.alloc(std.ArrayListUnmanaged(sketch.EdgeId), bridges_of.len);
        @memset(lists, .empty);
        for (split_result.crossings) |c| if (c.proxy != sg.SENTINEL and c.proxy < lists.len) try lists[c.proxy].append(arena, c.id + bridge_base);
        for (lists, bridges_of) |*l, *b| b.* = try l.toOwnedSlice(arena);
    }
    for (outer.gap_rows) |g| try gap_records.append(arena, try stitch_gaps.translateGap(arena, g, global_of[0], 0, 0, outer_base, outer.direction, bridges_of));
    try piece_joins.append(arena, .{ .bundles = outer.bundles, .edge_base = outer_base, .node_map = global_of[0] });
    for (outer.edges) |oe| {
        if (superFor(split_result, oe.from) != null or superFor(split_result, oe.to) != null) continue;
        try edges.append(arena, try translateEdge(arena, oe, global_of[0], 0, 0, outer_base));
    }
    for (outer.rails) |ob| {
        if (superFor(split_result, ob.pivot) != null) continue;
        var kept: std.ArrayListUnmanaged(sketch.Tap) = .empty;
        for (ob.taps) |tap| {
            if (superFor(split_result, tap.node) != null) continue;
            try kept.append(arena, tap);
        }
        if (kept.items.len == 0) continue;
        var filtered = ob;
        filtered.taps = try kept.toOwnedSlice(arena);
        // @guarded-by: recurse_test.zig "stitch re-clamps a surviving rail's crossbar past a dropped super-node tap"
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
            try rails.append(arena, tb);
        }
    }

    const node_slice = try nodes.toOwnedSlice(arena);
    const cluster_slice = try clusters.toOwnedSlice(arena);
    const bridge_start = edges.items.len;
    var track_expired: u32 = 0;
    const bridge_edges = try bridges.route(arena, split_result.crossings, node_slice, cluster_slice, rails.items, edges.items, outer.direction, orig_to_merged, &track_expired, bridge_build);
    for (bridge_edges) |be| {
        var b = be;
        b.id = be.id + bridge_base;
        try edges.append(arena, b);
    }
    try stitch_gaps.adoptBridgeInk(arena, gap_records.items, edges.items[bridge_start..], outer.direction);

    // @guarded-by: recurse_test2.zig "two bridges into one port declare a port-share bundle"
    const edge_slice = try edges.toOwnedSlice(arena);
    const final_bridges = edge_slice[bridge_start..];
    const bridge_joins = if (merge_joins)
        try bridge_plan.plan(arena, split_result.crossings, final_bridges, bridge_base)
    else
        ledger.RealizedBundles{};
    for (try ledger.bundlesFromPlan(arena, bridge_joins)) |cs| try bundle_sets.append(arena, cs);
    const bar_slice = try rails.toOwnedSlice(arena);
    const authority = try stitch_bundle_sets.finalizeAuthority(
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
        try bundle_sets.toOwnedSlice(arena),
    );

    var merged: sketch.Sketch = .{
        .bbox = outer.bbox,
        .direction = outer.direction,
        .nodes = node_slice,
        .clusters = cluster_slice,
        .edges = edge_slice,
        .rails = bar_slice,
        .rail_claims = authority.claims,
        .bundle_sets = authority.sets,
        .bundles = if (merge_joins) try stitch_bundles.merge(arena, piece_joins.items, bridge_joins) else .{},
        // @guarded-by: recurse_test2.zig "the merged sketch sums its pieces' closure counts"
        .closure = closureSum(outer, children),
        .gap_rows = try gap_records.toOwnedSlice(arena),
        .diagnostics = try withTrackExpiry(arena, outer.diagnostics, track_expired),
        .budget = outer.budget,
    };
    // @guarded-by: sketch_bundles_test.zig "merged bundle sets name every bundle once"
    sketch_bundles.stamp(arena, &merged);
    return .{
        .sketch = merged,
        .input_of = try input_of.toOwnedSlice(arena),
    };
}

fn setAt(arena: std.mem.Allocator, list: *std.ArrayListUnmanaged(sketch.NodeId), i: sketch.NodeId, val: sketch.NodeId) error{OutOfMemory}!void {
    while (list.items.len <= i) try list.append(arena, sg.SENTINEL);
    list.items[i] = val;
}

fn superFor(sr: SplitResult, outer_node_id: sketch.NodeId) ?split_mod.SuperNode {
    for (sr.supers) |s| {
        if (s.outer_node == outer_node_id) return s;
    }
    return null;
}

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

fn idSpan(s: sketch.Sketch) sketch.EdgeId {
    var max_id: ?sketch.EdgeId = null;
    const bump = struct {
        fn f(cur: *?sketch.EdgeId, id: sketch.EdgeId) void {
            if (cur.* == null or id > cur.*.?) cur.* = id;
        }
    }.f;
    for (s.edges) |e| bump(&max_id, e.id);
    for (s.rails) |b| for (b.taps) |t| bump(&max_id, t.edge);
    for (s.bundle_sets) |cs| for (cs.members) |m| bump(&max_id, m);
    for (s.rail_claims) |claim| for (claim.members) |m| bump(&max_id, m.edge);
    return if (max_id) |m| m + 1 else 0;
}

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

fn translateRail(
    arena: std.mem.Allocator,
    rail: sketch.Rail,
    gmap: []const sketch.NodeId,
    dx: i32,
    dy: i32,
    id_base: sketch.EdgeId,
) error{OutOfMemory}!?sketch.Rail {
    if (rail.pivot >= gmap.len or gmap[rail.pivot] == sg.SENTINEL) return null;
    const stem = try arena.alloc(sketch.Point, rail.stem.len);
    for (rail.stem, 0..) |pt, i| stem[i] = .{ .x = pt.x + dx, .y = pt.y + dy };
    const taps = try arena.alloc(sketch.Tap, rail.taps.len);
    for (rail.taps, 0..) |tap, i| {
        if (tap.node >= gmap.len or gmap[tap.node] == sg.SENTINEL) return null;
        taps[i] = tap;
        taps[i].node = gmap[tap.node];
        taps[i].edge = tap.edge + id_base;
        taps[i].at = .{ .x = tap.at.x + dx, .y = tap.at.y + dy };
        taps[i].landing = .{ .x = tap.landing.x + dx, .y = tap.landing.y + dy };
    }
    var out = rail;
    out.pivot = gmap[rail.pivot];
    out.stem = stem;
    out.taps = taps;
    out.crossbar = .{
        .{ .x = rail.crossbar[0].x + dx, .y = rail.crossbar[0].y + dy },
        .{ .x = rail.crossbar[1].x + dx, .y = rail.crossbar[1].y + dy },
    };
    return out;
}

test "superSize wraps child bbox with frame padding (scale 0 = full inset)" {
    const sz = superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 0, false);
    try std.testing.expectEqual(@as(u32, 28), sz.w);
    try std.testing.expectEqual(@as(u32, 12), sz.h);
}

test "superSize shrinks x inset under pressure (scale > 0), y unchanged" {
    const sz = superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 1, false);
    try std.testing.expectEqual(@as(u32, 24), sz.w);
    try std.testing.expectEqual(@as(u32, 12), sz.h);
}

test "superSize for a synthetic packing cluster is exactly the child bbox" {
    const sz = superSize(.{ .x = 0, .y = 0, .w = 20, .h = 8 }, 0, true);
    try std.testing.expectEqual(@as(u32, 20), sz.w);
    try std.testing.expectEqual(@as(u32, 8), sz.h);
}

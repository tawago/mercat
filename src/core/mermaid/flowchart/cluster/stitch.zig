const std = @import("std");
const prim = @import("prim");
const sketch = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const ledger = @import("../base/ledger.zig");
const bundle_mod = @import("../base/bundle.zig");
const bundle_plan = @import("../base/bundle_plan.zig");
const split_mod = @import("split.zig");
const bridges = @import("bridges.zig");
const bridge_plan = @import("bridge_plan.zig");
const entry_inset = @import("entry_inset.zig");
const stitch_bundle_sets = @import("stitch_bundle_sets.zig");
const stitch_bundles = @import("stitch_bundles.zig");
const stitch_rails = @import("stitch_rails.zig");

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

const Offset = struct {
    dx: i32 = 0,
    dy: i32 = 0,

    fn rect(self: Offset, r: sketch.Rect) sketch.Rect {
        return .{ .x = r.x + self.dx, .y = r.y + self.dy, .w = r.w, .h = r.h };
    }

    fn point(self: Offset, p: sketch.Point) sketch.Point {
        return .{ .x = p.x + self.dx, .y = p.y + self.dy };
    }
};

const Place = struct {
    gmap: []const sketch.NodeId,
    off: Offset = .{},
    base: sketch.EdgeId,
};

const Stitcher = struct {
    arena: std.mem.Allocator,
    sr: SplitResult,
    outer: sketch.Sketch,
    children: []const Clustered,
    offsets: []Offset,
    global_of: [][]sketch.NodeId,
    orig_to_merged: []sketch.NodeId,
    input_of: std.ArrayListUnmanaged(sketch.NodeId) = .empty,
    nodes: std.ArrayListUnmanaged(sketch.NodePlacement) = .empty,
    clusters: std.ArrayListUnmanaged(sketch.ClusterFrame) = .empty,
    edges: std.ArrayListUnmanaged(sketch.EdgePath) = .empty,
    rails: std.ArrayListUnmanaged(sketch.Rail) = .empty,
    bundle_sets: std.ArrayListUnmanaged(bundle_mod.Bundle) = .empty,
    piece_joins: std.ArrayListUnmanaged(stitch_bundles.PieceBundles) = .empty,
    claim_sources: []stitch_rails.ChildSource,
    outer_base: sketch.EdgeId = 0,
    bridge_base: sketch.EdgeId = 0,

    fn init(
        arena: std.mem.Allocator,
        sr: SplitResult,
        outer: sketch.Sketch,
        children: []const Clustered,
        scale: u32,
    ) error{OutOfMemory}!Stitcher {
        const global_of = try arena.alloc([]sketch.NodeId, sr.pieces.len);
        global_of[0] = try arena.alloc(sketch.NodeId, outer.nodes.len);
        for (children[1..], global_of[1..]) |c, *map| map.* = try arena.alloc(sketch.NodeId, c.sketch.nodes.len);
        for (global_of) |map| @memset(map, sg.SENTINEL);
        const orig_to_merged = try arena.alloc(sketch.NodeId, sr.orig_node_count);
        @memset(orig_to_merged, sg.SENTINEL);

        const offsets = try arena.alloc(Offset, sr.supers.len);
        for (sr.supers, offsets) |super, *off| {
            const pad = superPad(scale, super.synthetic);
            const inset = entryInsetFor(sr, children, super);
            const at = placementOf(outer.nodes, super.outer_node).rect;
            off.* = .{
                .dx = at.x + @as(i32, @intCast(pad.x)) + inset.dxExtra(),
                .dy = at.y + @as(i32, @intCast(pad.y)) + inset.dyExtra(),
            };
        }
        return .{
            .arena = arena,
            .sr = sr,
            .outer = outer,
            .children = children,
            .offsets = offsets,
            .global_of = global_of,
            .orig_to_merged = orig_to_merged,
            .claim_sources = try arena.alloc(stitch_rails.ChildSource, sr.supers.len),
        };
    }

    fn placeNodes(self: *Stitcher) error{OutOfMemory}!void {
        for (self.outer.nodes) |p| {
            if (self.sr.superIndex(p.id)) |si| {
                try self.placeChild(si, p);
            } else {
                var plain = p;
                plain.cluster_id = null;
                try self.addNode(0, split_mod.idAt(self.sr.pieces[0].orig_ids, p.id), plain);
            }
        }
    }

    fn placeChild(self: *Stitcher, si: usize, stand_in: sketch.NodePlacement) error{OutOfMemory}!void {
        const arena = self.arena;
        const super = self.sr.supers[si];
        const child = self.children[super.child_piece];
        const piece = self.sr.pieces[super.child_piece];
        const off = self.offsets[si];

        for (child.sketch.nodes) |cp| {
            var moved = cp;
            moved.rect = off.rect(cp.rect);
            moved.cluster_id = cp.cluster_id orelse super.cluster_id;
            try self.addNode(super.child_piece, split_mod.pieceId(piece.orig_ids, child.input_of, cp.id), moved);
        }
        for (child.sketch.clusters) |cf| {
            try self.clusters.append(arena, .{
                .id = cf.id,
                .rect = off.rect(cf.rect),
                .parent_id = cf.parent_id orelse super.cluster_id,
                .label = cf.label,
                .depth = cf.depth + 1,
                .direction = cf.direction,
                .synthetic = cf.synthetic,
            });
        }
        try self.clusters.append(arena, .{
            .id = super.cluster_id,
            .rect = stand_in.rect,
            .parent_id = null,
            .label = try flattenLines(arena, stand_in.lines),
            .depth = 0,
            .direction = child.sketch.direction,
            .synthetic = super.synthetic,
        });
    }

    fn addNode(self: *Stitcher, piece: usize, orig: sketch.NodeId, local: sketch.NodePlacement) error{OutOfMemory}!void {
        const gid: sketch.NodeId = @intCast(self.nodes.items.len);
        self.global_of[piece][local.id] = gid;
        try self.input_of.append(self.arena, orig);
        if (orig != sg.SENTINEL and orig < self.orig_to_merged.len) self.orig_to_merged[orig] = gid;
        var placed = local;
        placed.id = gid;
        try self.nodes.append(self.arena, placed);
    }

    fn copyChildren(self: *Stitcher) error{OutOfMemory}!void {
        const arena = self.arena;
        var id_base: sketch.EdgeId = 0;
        for (self.sr.supers, self.offsets, self.claim_sources) |super, off, *claims| {
            const child = self.children[super.child_piece];
            const at: Place = .{ .gmap = self.global_of[super.child_piece], .off = off, .base = id_base };
            id_base += idSpan(child.sketch);
            claims.* = .{ .sketch = child.sketch, .node_map = at.gmap, .edge_base = at.base };
            try self.piece_joins.append(arena, .{ .bundles = child.sketch.bundles, .edge_base = at.base });
            for (child.sketch.edges) |ce| try self.edges.append(arena, try translateEdge(arena, ce, at));
            for (child.sketch.rails) |cr| {
                if (try translateRail(arena, cr, at)) |tr| try self.rails.append(arena, tr);
            }
            for (child.sketch.bundle_sets) |cs| {
                if (cs.origin != .port_share) try self.bundle_sets.append(arena, try stitch_bundle_sets.shiftSet(arena, cs, at.base, off.dx, off.dy));
            }
        }
        self.outer_base = id_base;
        self.bridge_base = id_base + idSpan(self.outer);
    }

    fn copyOuter(self: *Stitcher) error{OutOfMemory}!void {
        const arena = self.arena;
        const at: Place = .{ .gmap = self.global_of[0], .base = self.outer_base };
        try self.piece_joins.append(arena, .{ .bundles = self.outer.bundles, .edge_base = at.base });
        for (self.outer.edges) |oe| {
            if (self.sr.isSuper(oe.from) or self.sr.isSuper(oe.to)) continue;
            try self.edges.append(arena, try translateEdge(arena, oe, at));
        }
        for (self.outer.rails) |orail| {
            const kept = try self.survivingRail(orail) orelse continue;
            if (try translateRail(arena, kept, at)) |tr| try self.rails.append(arena, tr);
        }
    }

    fn survivingRail(self: *Stitcher, rail: sketch.Rail) error{OutOfMemory}!?sketch.Rail {
        if (self.sr.isSuper(rail.pivot)) return null;
        var taps: std.ArrayListUnmanaged(sketch.Tap) = .empty;
        for (rail.taps) |tap| {
            if (!self.sr.isSuper(tap.node)) try taps.append(self.arena, tap);
        }
        if (taps.items.len == 0) return null;
        var out = rail;
        out.taps = try taps.toOwnedSlice(self.arena);
        const junction = rail.stem[rail.stem.len - 1];
        var min_x: i32 = junction.x;
        var max_x: i32 = junction.x;
        for (out.taps) |tap| {
            min_x = @min(min_x, tap.at.x);
            max_x = @max(max_x, tap.at.x);
        }
        out.crossbar = .{
            .{ .x = min_x, .y = rail.crossbar[0].y },
            .{ .x = max_x, .y = rail.crossbar[1].y },
        };
        return out;
    }

    fn finish(self: *Stitcher, merge_joins: bool, bridge_build: prim.BridgeBuild) error{OutOfMemory}!Clustered {
        const arena = self.arena;
        const node_slice = try self.nodes.toOwnedSlice(arena);
        const cluster_slice = try self.clusters.toOwnedSlice(arena);
        const bridge_start = self.edges.items.len;
        const bridge_edges = try bridges.route(arena, self.sr.crossings, node_slice, cluster_slice, self.rails.items, self.edges.items, self.outer.direction, self.orig_to_merged, bridge_build);
        for (bridge_edges) |be| {
            var b = be;
            b.id = be.id + self.bridge_base;
            try self.edges.append(arena, b);
        }

        const edge_slice = try self.edges.toOwnedSlice(arena);
        const final_bridges = edge_slice[bridge_start..];
        const bridge_joins = if (merge_joins)
            try bridge_plan.plan(arena, self.sr.crossings, final_bridges, self.bridge_base)
        else
            ledger.RealizedBundles{};
        for (try bundle_plan.bundlesFromPlan(arena, bridge_joins)) |cs| try self.bundle_sets.append(arena, cs);
        const bar_slice = try self.rails.toOwnedSlice(arena);
        const authority = try stitch_bundle_sets.finalizeAuthority(
            arena,
            self.sr,
            self.outer,
            self.claim_sources,
            self.global_of[0],
            self.outer_base,
            self.bridge_base,
            edge_slice,
            final_bridges,
            bar_slice,
            node_slice,
            try self.bundle_sets.toOwnedSlice(arena),
        );

        const merged: sketch.Sketch = .{
            .bbox = self.outer.bbox,
            .direction = self.outer.direction,
            .nodes = node_slice,
            .clusters = cluster_slice,
            .edges = edge_slice,
            .rails = bar_slice,
            .rail_claims = authority.claims,
            .bundle_sets = authority.sets,
            .bundles = if (merge_joins) try stitch_bundles.merge(arena, self.piece_joins.items, bridge_joins) else .{},
            .diagnostics = self.outer.diagnostics,
            .budget = self.outer.budget,
        };
        return .{
            .sketch = merged,
            .input_of = try self.input_of.toOwnedSlice(arena),
        };
    }
};

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
    var st = try Stitcher.init(arena, split_result, outer, children, scale);
    try st.placeNodes();
    try st.copyChildren();
    try st.copyOuter();
    return st.finish(merge_joins, bridge_build);
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

fn translateEdge(arena: std.mem.Allocator, e: sketch.EdgePath, at: Place) error{OutOfMemory}!sketch.EdgePath {
    const poly = try arena.alloc(sketch.Point, e.polyline.len);
    for (e.polyline, poly) |pt, *out| out.* = at.off.point(pt);
    return .{
        .id = e.id + at.base,
        .from = at.gmap[e.from],
        .to = at.gmap[e.to],
        .polyline = poly,
        .port_from = .{ .node = at.gmap[e.from], .side = e.port_from.side, .offset = e.port_from.offset },
        .port_to = .{ .node = at.gmap[e.to], .side = e.port_to.side, .offset = e.port_to.offset },
        .arrow_from = e.arrow_from,
        .arrow_to = e.arrow_to,
        .label = e.label,
        .kind = e.kind,
        .role = e.role,
    };
}

fn translateRail(arena: std.mem.Allocator, rail: sketch.Rail, at: Place) error{OutOfMemory}!?sketch.Rail {
    const gmap = at.gmap;
    if (rail.pivot >= gmap.len or gmap[rail.pivot] == sg.SENTINEL) return null;
    const stem = try arena.alloc(sketch.Point, rail.stem.len);
    for (rail.stem, stem) |pt, *out| out.* = at.off.point(pt);
    const taps = try arena.alloc(sketch.Tap, rail.taps.len);
    for (rail.taps, taps) |tap, *out| {
        if (tap.node >= gmap.len or gmap[tap.node] == sg.SENTINEL) return null;
        out.* = tap;
        out.node = gmap[tap.node];
        out.edge = tap.edge + at.base;
        out.at = at.off.point(tap.at);
        out.landing = at.off.point(tap.landing);
    }
    var out = rail;
    out.pivot = gmap[rail.pivot];
    out.stem = stem;
    out.taps = taps;
    out.crossbar = .{ at.off.point(rail.crossbar[0]), at.off.point(rail.crossbar[1]) };
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

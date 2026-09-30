const std = @import("std");
const prim = @import("prim");
const ledger = @import("base/ledger.zig");
const sem_graph = @import("sem_graph.zig");
const sketch_mod = @import("sketch.zig");
const ladder = @import("budget.zig");
const score_mod = @import("score.zig");
const audit_mod = @import("audit.zig");
const motif_mod = @import("motif.zig");

const Candidate = ladder.Candidate;

/// The lowest-scored candidate among those that route every visible edge,
/// or the first raw rung that fits when none does.
pub fn choose(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
    subgraph_edges: prim.SubgraphEdges,
) !Candidate {
    const candidates = try enumerateAll(aa, graph, bundle_permits, max_width);
    return candidates[try chooseIndex(aa, candidates, graph.direction, subgraph_edges)];
}

/// Where `choose` finds its candidate in the list.
pub fn chooseIndex(
    aa: std.mem.Allocator,
    candidates: []const Candidate,
    source_direction: sem_graph.Direction,
    subgraph_edges: prim.SubgraphEdges,
) !usize {
    const positions = try routedPositions(aa, candidates);
    if (positions.len == 0) return ladder.firstFitIndex(candidates);
    const routed = try aa.alloc(Candidate, positions.len);
    for (positions, routed) |p, *r| r.* = candidates[p];
    return positions[try argmin(aa, routed, source_direction, subgraph_edges)];
}

pub fn isUnrouted(e: sketch_mod.EdgePath) bool {
    return e.polyline.len < 2 and e.kind != .invisible;
}

pub fn unroutedEdges(s: sketch_mod.Sketch) u32 {
    var n: u32 = 0;
    for (s.edges) |e| {
        if (isUnrouted(e)) n += 1;
    }
    return n;
}

/// Positions, in list order, of the candidates that route every visible edge.
pub fn routedPositions(aa: std.mem.Allocator, candidates: []const Candidate) ![]const usize {
    var kept: std.ArrayListUnmanaged(usize) = .empty;
    for (candidates, 0..) |cand, i| {
        if (unroutedEdges(cand.sketch) == 0) try kept.append(aa, i);
    }
    return kept.toOwnedSlice(aa);
}

/// Raw rungs in rung order, then motif-packed rungs, then bridge variants.
pub fn enumerateAll(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) ![]const Candidate {
    var list: std.ArrayListUnmanaged(Candidate) = .empty;
    try list.appendSlice(aa, try ladder.enumerate(aa, graph, bundle_permits, max_width));
    try list.appendSlice(aa, try packedCandidates(aa, graph, bundle_permits, max_width));
    try appendBridgeVariants(aa, &list, graph, bundle_permits, max_width);
    return list.toOwnedSlice(aa);
}

fn appendBridgeVariants(
    aa: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Candidate),
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) !void {
    if (graph.clusters.len == 0) return;
    const fit = ladder.firstFit(list.items).rung;
    const rungs: []const ladder.Rung = if (fit == .natural) &.{.natural} else &.{ .natural, fit };
    for (rungs) |rung| {
        const base = rawAt(list.items, rung);
        for ([2]ladder.Transform{ .bridge_dodged, .bridge_railed }) |transform| {
            const variant = try ladder.run(aa, graph, bundle_permits, max_width, rung, transform);
            if (sameEdgeGeometry(base, variant.sketch)) continue;
            try list.append(aa, variant);
        }
    }
}

fn rawAt(candidates: []const Candidate, rung: ladder.Rung) sketch_mod.Sketch {
    for (candidates) |c| if (c.transform == .raw and c.rung == rung) return c.sketch;
    unreachable;
}

fn sameEdgeGeometry(a: sketch_mod.Sketch, b: sketch_mod.Sketch) bool {
    if (a.edges.len != b.edges.len) return false;
    for (a.edges, b.edges) |ea, eb| {
        if (ea.id != eb.id or ea.polyline.len != eb.polyline.len) return false;
        for (ea.polyline, eb.polyline) |pa, pb| {
            if (pa.x != pb.x or pa.y != pb.y) return false;
        }
    }
    return true;
}

/// The graph's motif-packed layouts at the packing rungs; empty when the graph has nothing to pack.
pub fn packedCandidates(
    aa: std.mem.Allocator,
    graph: sem_graph.SemGraph,
    bundle_permits: *const ledger.BundlePermits,
    max_width: u32,
) ![]const Candidate {
    if (!ladder.Transform.motif_pack.appliesTo(graph.direction)) return &.{};
    const tree = try motif_mod.decompose(aa, graph);
    const packed_graph = (try motif_mod.pack.transform(aa, graph, tree)) orelse return &.{};

    const rungs = ladder.Transform.motif_pack.rungs();
    const out = try aa.alloc(Candidate, rungs.len);
    for (rungs, out) |rung, *c| c.* = try ladder.run(aa, packed_graph, bundle_permits, max_width, rung, .motif_pack);
    return out;
}

/// Index of the lowest score, the earlier candidate winning a tie. Truncate may win only
/// when raw natural overflows or breaks integrity, and a challenger must beat raw natural
/// by the natural-preference margin.
pub fn argmin(
    aa: std.mem.Allocator,
    candidates: []const Candidate,
    source_direction: sem_graph.Direction,
    subgraph_edges: prim.SubgraphEdges,
) !usize {
    if (candidates.len == 1) return 0;
    const scores = try aa.alloc(score_mod.Score, candidates.len);
    for (candidates, scores, 0..) |cand, *s, i| {
        const raster = try audit_mod.collect(aa, cand.sketch, subgraph_edges);
        s.* = try score_mod.eval(aa, cand.sketch, source_direction, @intCast(i), raster);
    }
    const natural: ?usize = for (candidates, 0..) |c, i| {
        if (c.rung == .natural and c.transform == .raw) break i;
    } else null;
    const truncate_allowed = if (natural) |n| scores[n].t0_fit > 0 or scores[n].t1_integrity > 0 else true;

    var best: ?usize = null;
    for (candidates, scores, 0..) |c, s, i| {
        if (c.rung == .truncate and !truncate_allowed) continue;
        if (best == null or s.lessThan(scores[best.?])) best = i;
    }
    const n = natural orelse return best.?;
    return if (score_mod.displacesNatural(scores[best.?], scores[n])) best.? else n;
}

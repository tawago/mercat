//! motif.zig — MotifTree (IR 1.5) decomposition of a SemGraph: a pure-data
//! motif tree. select.zig packs it into the motif-packed candidate; no other
//! layout decision reads it.
//!
//! Pipeline per cluster scope (motif/): scope.zig builds the scope digraph,
//! dominator.zig removes cycles and computes the dominator tree, classify.zig
//! coarsens it into typed motifs. This file drives cluster-scope recursion
//! (motifs never span a cluster border) and fills covered/ext_in/ext_out
//! metrics.

const std = @import("std");
const prim = @import("prim");
const sg = @import("sem_graph.zig");
const types = @import("motif/types.zig");
const scope_mod = @import("motif/scope.zig");
const dom_mod = @import("motif/dominator.zig");
const classify = @import("motif/classify.zig");

pub const MotifKind = types.MotifKind;
pub const Motif = types.Motif;
pub const MotifTree = types.MotifTree;

/// Namespace re-export of the synthetic-cluster packer so callers outside
/// the motif zone (select.zig) reach it through this root file.
pub const pack = @import("motif/pack.zig");

/// Decompose `graph` into a MotifTree. All storage comes from `a`; pass an
/// arena (repo IR convention) — there is no deinit.
pub fn decompose(a: std.mem.Allocator, graph: sg.SemGraph) error{OutOfMemory}!MotifTree {
    var motifs: std.ArrayListUnmanaged(Motif) = .empty;
    const roots = try decomposeScope(a, graph, null, &motifs);
    const ms = try motifs.toOwnedSlice(a);
    try computeMetrics(a, graph, ms);
    return .{ .motifs = ms, .roots = roots, .node_count = graph.nodes.len };
}

/// Decompose one cluster scope (null = top level) and recurse into every
/// cluster motif it produced, filling the placeholder children.
fn decomposeScope(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    parent: ?sg.ClusterId,
    out: *std.ArrayListUnmanaged(Motif),
) error{OutOfMemory}![]const usize {
    const sc = try scope_mod.build(a, graph, parent);
    if (sc.verts.len == 0) return &.{};
    const dom = try dom_mod.compute(a, sc.verts.len, sc.edges);
    const start = out.items.len;
    const roots = try classify.coarsenScope(a, sc, dom, out);
    const end = out.items.len;
    var i = start;
    while (i < end) : (i += 1) {
        if (out.items[i].kind == .cluster) {
            const cid = out.items[i].cluster_id.?;
            const kids = try decomposeScope(a, graph, cid, out);
            out.items[i].children = kids;
        }
    }
    return roots;
}

/// Fill `covered`, `ext_in`, `ext_out` for every motif: covered = real
/// nodes owned by the motif's subtree; ext counts scan the ORIGINAL edge
/// list against the covered set (O(motifs × edges), corpus-sized).
fn computeMetrics(a: std.mem.Allocator, graph: sg.SemGraph, motifs: []Motif) error{OutOfMemory}!void {
    var node_idx = std.AutoHashMapUnmanaged(sg.NodeId, usize).empty;
    for (graph.nodes, 0..) |n, i| try node_idx.put(a, n.id, i);

    const in_set = try a.alloc(bool, graph.nodes.len);
    var stack: std.ArrayListUnmanaged(usize) = .empty;

    for (motifs, 0..) |*m, mi| {
        @memset(in_set, false);
        var covered: u32 = 0;
        stack.clearRetainingCapacity();
        try stack.append(a, mi);
        while (stack.pop()) |cur| {
            for (motifs[cur].members) |nid| {
                const idx = node_idx.get(nid) orelse continue;
                if (!in_set[idx]) {
                    in_set[idx] = true;
                    covered += 1;
                }
            }
            for (motifs[cur].children) |c| try stack.append(a, c);
        }
        var ext_in: u32 = 0;
        var ext_out: u32 = 0;
        for (graph.edges) |e| {
            const fi = node_idx.get(e.from) orelse continue;
            const ti = node_idx.get(e.to) orelse continue;
            if (!in_set[fi] and in_set[ti]) ext_in += 1;
            if (in_set[fi] and !in_set[ti]) ext_out += 1;
        }
        m.covered = covered;
        m.ext_in = ext_in;
        m.ext_out = ext_out;
    }
}

test {
    _ = @import("motif/motif_test.zig");
    _ = @import("motif/pack.zig");
}

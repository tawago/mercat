//! motif.zig — MotifTree (IR 1.5) decomposition of a SemGraph: a pure-data
//! motif tree, inert to rendering. entry.zig computes it only under
//! `MERCAT_DUMP_MOTIFS=1`; no layout decision reads it.
//!
//! Pipeline per cluster scope (motif/): scope.zig builds the scope digraph,
//! dominator.zig removes cycles and computes the dominator tree, classify.zig
//! coarsens it into typed motifs. This file drives cluster-scope recursion
//! (motifs never span a cluster border), fills covered/ext_in/ext_out
//! metrics, and renders the human-readable dump.

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
    // Only the motifs THIS scope appended are scanned; deeper cluster
    // motifs are filled by their own recursion level.
    var i = start;
    while (i < end) : (i += 1) {
        if (out.items[i].kind == .cluster) {
            const cid = out.items[i].cluster_id.?;
            // NOTE: recurse BEFORE touching out.items[i] — the recursion
            // appends to `out` and may reallocate its buffer, so a combined
            // `out.items[i].children = try decomposeScope(...)` would write
            // through a stale pointer.
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

/// Render the human-readable dump: one `mercat-motifs:`-prefixed line per
/// motif (indented tree) between begin/end marker lines. The end line
/// carries the per-seed aggregates the coverage report consumes.
pub fn dump(a: std.mem.Allocator, graph: sg.SemGraph, tree: MotifTree) error{OutOfMemory}![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try appendf(a, &buf, "mercat-motifs: begin nodes={d} edges={d} clusters={d} direction={s}\n", .{
        graph.nodes.len, graph.edges.len, graph.clusters.len, @tagName(graph.direction),
    });
    for (tree.roots) |r| try dumpMotif(a, &buf, graph, tree, r, 0);

    var kind_counts = std.enums.EnumArray(MotifKind, u32).initFill(0);
    var largest: u32 = 0;
    var nonprime: u32 = 0;
    var structured: u32 = 0;
    for (tree.motifs) |m| {
        kind_counts.getPtr(m.kind).* += 1;
        const owned: u32 = @intCast(m.members.len);
        largest = @max(largest, owned);
        if (m.kind != .prime) nonprime += owned;
        switch (m.kind) {
            .spine, .fan, .parallel => structured += owned,
            else => {},
        }
    }
    try appendf(
        a,
        &buf,
        "mercat-motifs: end motifs={d} atom={d} spine={d} fan={d} parallel={d} cluster={d} prime={d} largest={d} nonprime={d}/{d} structured={d}/{d}\n",
        .{
            tree.motifs.len,
            kind_counts.get(.atom),
            kind_counts.get(.spine),
            kind_counts.get(.fan),
            kind_counts.get(.parallel),
            kind_counts.get(.cluster),
            kind_counts.get(.prime),
            largest,
            nonprime,
            tree.node_count,
            structured,
            tree.node_count,
        },
    );
    return buf.toOwnedSlice(a);
}

fn dumpMotif(
    a: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    graph: sg.SemGraph,
    tree: MotifTree,
    mi: usize,
    depth: u32,
) error{OutOfMemory}!void {
    const m = tree.motifs[mi];
    try buf.appendSlice(a, "mercat-motifs: ");
    var d: u32 = 0;
    while (d < depth) : (d += 1) try buf.appendSlice(a, "  ");
    try appendf(a, buf, "- {s} size={d} members={d}", .{ @tagName(m.kind), m.covered, m.members.len });
    if (m.entry) |eid| {
        try appendf(a, buf, " entry=\"{s}\"", .{prim.truncateToWidth(nodeLabel(graph, eid), 24)});
    }
    if (m.cluster_id) |cid| {
        try appendf(a, buf, " cluster=\"{s}\"", .{prim.truncateToWidth(clusterLabel(graph, cid), 24)});
    }
    try appendf(a, buf, " ext={d}/{d} children={d}\n", .{ m.ext_in, m.ext_out, m.children.len });
    for (m.children) |c| try dumpMotif(a, buf, graph, tree, c, depth + 1);
}

fn nodeLabel(graph: sg.SemGraph, id: sg.NodeId) []const u8 {
    for (graph.nodes) |n| {
        if (n.id == id) return n.label;
    }
    return "?";
}

fn clusterLabel(graph: sg.SemGraph, cid: sg.ClusterId) []const u8 {
    for (graph.clusters) |c| {
        if (c.id == cid) return c.label;
    }
    return "?";
}

/// Decompose + dump to stderr. Called by entry.zig under MERCAT_DUMP_MOTIFS=1
/// only (the env decision stays at the composition root). Purely
/// observational: failures are logged and swallowed, the render proceeds
/// unchanged either way.
pub fn dumpToStderr(a: std.mem.Allocator, graph: sg.SemGraph) void {
    const tree = decompose(a, graph) catch |err| {
        std.log.warn("mermaid_v2/motif: decompose failed: {s}", .{@errorName(err)});
        return;
    };
    const text = dump(a, graph, tree) catch |err| {
        std.log.warn("mermaid_v2/motif: dump failed: {s}", .{@errorName(err)});
        return;
    };
    std.debug.print("{s}", .{text});
}

fn appendf(
    a: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    comptime fmt: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    const s = try std.fmt.allocPrint(a, fmt, args);
    try buf.appendSlice(a, s);
}

test {
    _ = @import("motif/motif_test.zig");
    _ = @import("motif/pack.zig");
}

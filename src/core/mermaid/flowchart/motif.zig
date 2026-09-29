const std = @import("std");
const sg = @import("sem_graph.zig");
const types = @import("motif/types.zig");
const scope_mod = @import("motif/scope.zig");
const dom_mod = @import("motif/dominator.zig");
const classify = @import("motif/classify.zig");

pub const MotifKind = types.MotifKind;
pub const Motif = types.Motif;
pub const MotifTree = types.MotifTree;

pub const pack = @import("motif/pack.zig");

pub fn decompose(a: std.mem.Allocator, graph: sg.SemGraph) error{OutOfMemory}!MotifTree {
    var motifs: std.ArrayListUnmanaged(Motif) = .empty;
    const roots = try decomposeScope(a, graph, null, &motifs);
    return .{ .motifs = try motifs.toOwnedSlice(a), .roots = roots };
}

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

test {
    _ = @import("motif/motif_test.zig");
    _ = @import("motif/pack_test.zig");
}

//! motif/classify.zig — coarsen one scope's dominator forest into typed
//! motifs (full kind vocabulary documented on `types.MotifKind`).
//!
//! Classification precedence: chain walk → fan → parallel → atom/prime.
//! Each rule's exact conditions are documented as a doc comment on the
//! function that implements it (coarsenSubtree for chain walk, pivotMotif
//! for fan/atom, groupSiblings/parallelMotif for sibling fusion).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const types = @import("types.zig");
const scope_mod = @import("scope.zig");
const dom_mod = @import("dominator.zig");

const Ctx = struct {
    a: std.mem.Allocator,
    sc: scope_mod.Scope,
    dom: dom_mod.DomTree,
    out: *std.ArrayListUnmanaged(types.Motif),
    /// Dominator-subtree vertex counts, indexed by scope vertex.
    size: []u32,
    /// Dominator-shape signatures, indexed by scope vertex.
    sig: []u64,
};

const Error = error{OutOfMemory};

/// Coarsen the scope's dominator forest, appending motifs to `out`
/// (children always appended before their parent, except cluster interiors
/// which the driver fills in later). Returns the scope-root motif indices.
/// Cluster motifs are emitted as placeholders with empty children; the
/// driver (motif.zig) recurses into each cluster's own scope.
pub fn coarsenScope(
    a: std.mem.Allocator,
    sc: scope_mod.Scope,
    dom: dom_mod.DomTree,
    out: *std.ArrayListUnmanaged(types.Motif),
) Error![]const usize {
    const n = sc.verts.len;
    var ctx: Ctx = .{
        .a = a,
        .sc = sc,
        .dom = dom,
        .out = out,
        .size = try a.alloc(u32, n),
        .sig = try a.alloc(u64, n),
    };
    for (dom.roots) |v| computeMeta(&ctx, v);
    return groupSiblings(&ctx, dom.roots);
}

/// Post-order subtree size + shape signature. Signature hashes the vertex
/// kind tag and the SORTED child signatures, so two subtrees compare equal
/// iff their dominator trees are isomorphic (modulo hash collision).
fn computeMeta(ctx: *Ctx, v: u32) void {
    var size: u32 = 1;
    var child_sigs: [64]u64 = undefined;
    const kids = ctx.dom.children[v];
    for (kids, 0..) |c, i| {
        computeMeta(ctx, c);
        size += ctx.size[c];
        if (i < child_sigs.len) child_sigs[i] = ctx.sig[c];
    }
    const m = @min(kids.len, child_sigs.len);
    std.mem.sort(u64, child_sigs[0..m], {}, std.sort.asc(u64));
    var h = std.hash.Wyhash.init(0x6d6f7469); // "moti"
    const tag: u8 = switch (ctx.sc.verts[v]) {
        .node => 1,
        .cluster => 2,
    };
    h.update(std.mem.asBytes(&tag));
    h.update(std.mem.sliceAsBytes(child_sigs[0..m]));
    ctx.size[v] = size;
    ctx.sig[v] = h.final();
}

/// Group a sibling set: subtrees sharing a signature (size >= 2) fuse into
/// one `parallel` motif; the rest coarsen individually. First-occurrence
/// order is preserved.
fn groupSiblings(ctx: *Ctx, kids: []const u32) Error![]const usize {
    var result: std.ArrayListUnmanaged(usize) = .empty;
    const used = try ctx.a.alloc(bool, kids.len);
    @memset(used, false);

    for (kids, 0..) |k, i| {
        if (used[i]) continue;
        used[i] = true;
        var group: std.ArrayListUnmanaged(u32) = .empty;
        try group.append(ctx.a, k);
        if (ctx.size[k] >= 2) {
            for (kids[i + 1 ..], i + 1..) |k2, j| {
                if (!used[j] and ctx.sig[k2] == ctx.sig[k]) {
                    used[j] = true;
                    try group.append(ctx.a, k2);
                }
            }
        }
        if (group.items.len >= 2) {
            try result.append(ctx.a, try parallelMotif(ctx, group.items));
        } else {
            try result.append(ctx.a, try coarsenSubtree(ctx, k));
        }
    }
    return result.toOwnedSlice(ctx.a);
}

/// Fuse >= 2 isomorphic-ish sibling subtrees into one `parallel` motif.
/// Simple-path branches (all plain nodes, linear) are absorbed as direct
/// members; anything richer keeps per-branch child motifs.
fn parallelMotif(ctx: *Ctx, branches: []const u32) Error!usize {
    var all_simple = true;
    for (branches) |b| {
        if (!isSimplePath(ctx, b)) {
            all_simple = false;
            break;
        }
    }
    if (all_simple) {
        // Record per-branch spans while flattening. // guarded-by: pack.zig "parallel TD graph: one synthetic cluster per branch, members reassigned"
        var members: std.ArrayListUnmanaged(sg.NodeId) = .empty;
        var spans: std.ArrayListUnmanaged([2]usize) = .empty;
        for (branches) |b| {
            const start = members.items.len;
            var cur = b;
            while (true) {
                try members.append(ctx.a, ctx.sc.verts[cur].node);
                const kids = ctx.dom.children[cur];
                if (kids.len == 0) break;
                cur = kids[0];
            }
            try spans.append(ctx.a, .{ start, members.items.len });
        }
        const owned = try members.toOwnedSlice(ctx.a);
        const branch_runs = try ctx.a.alloc([]const sg.NodeId, spans.items.len);
        for (spans.items, 0..) |sp, i| branch_runs[i] = owned[sp[0]..sp[1]];
        return appendMotif(ctx, .{
            .kind = .parallel,
            .members = owned,
            .entry = null,
            .cluster_id = null,
            .ext_in = 0,
            .ext_out = 0,
            .covered = 0,
            .children = &.{},
            .branches = branch_runs,
        });
    }
    var children: std.ArrayListUnmanaged(usize) = .empty;
    for (branches) |b| try children.append(ctx.a, try coarsenSubtree(ctx, b));
    return appendMotif(ctx, .{
        .kind = .parallel,
        .members = &.{},
        .entry = null,
        .cluster_id = null,
        .ext_in = 0,
        .ext_out = 0,
        .covered = 0,
        .children = try children.toOwnedSlice(ctx.a),
    });
}

/// A subtree is a simple path when every vertex is a plain node with at
/// most one dominator child.
fn isSimplePath(ctx: *Ctx, v: u32) bool {
    var cur = v;
    while (true) {
        switch (ctx.sc.verts[cur]) {
            .cluster => return false,
            .node => {},
        }
        const kids = ctx.dom.children[cur];
        if (kids.len == 0) return true;
        if (kids.len > 1) return false;
        cur = kids[0];
    }
}

/// Coarsen the whole dominator subtree rooted at `v` into one motif
/// (recursively), returning its index.
fn coarsenSubtree(ctx: *Ctx, v: u32) Error!usize {
    var chain: std.ArrayListUnmanaged(u32) = .empty;
    var tail: ?u32 = null;
    var cur = v;
    while (true) {
        const kids = ctx.dom.children[cur];
        if (kids.len == 0) {
            try chain.append(ctx.a, cur);
            break;
        }
        if (kids.len == 1) {
            try chain.append(ctx.a, cur);
            cur = kids[0];
            continue;
        }
        tail = cur;
        break;
    }
    const pm: ?usize = if (tail) |t| try pivotMotif(ctx, t) else null;
    if (chain.items.len == 0) return pm.?; // v itself branches

    var members: std.ArrayListUnmanaged(sg.NodeId) = .empty;
    var children: std.ArrayListUnmanaged(usize) = .empty;
    for (chain.items) |cv| {
        switch (ctx.sc.verts[cv]) {
            .node => |nid| try members.append(ctx.a, nid),
            .cluster => |cid| try children.append(ctx.a, try clusterMotif(ctx, cid)),
        }
    }
    if (pm) |p| try children.append(ctx.a, p);

    // A lone cluster vertex with nothing downstream IS its cluster motif. // guarded-by: motif_test.zig "lone cluster vertex classifies as the cluster motif directly (not wrapped)"
    if (chain.items.len == 1 and members.items.len == 0 and pm == null)
        return children.items[0];

    const kind: types.MotifKind = if (chain.items.len >= 3)
        .spine
    else if (chain.items.len == 1 and members.items.len == 1)
        .atom
    else
        .prime; // 2-chains and node→cluster stubs: below the spine minimum
    const entry: ?sg.NodeId = switch (ctx.sc.verts[chain.items[0]]) {
        .node => |nid| nid,
        .cluster => null,
    };
    return appendMotif(ctx, .{
        .kind = kind,
        .members = try members.toOwnedSlice(ctx.a),
        .entry = entry,
        .cluster_id = null,
        .ext_in = 0,
        .ext_out = 0,
        .covered = 0,
        .children = try children.toOwnedSlice(ctx.a),
    });
}

/// Classify a branching pivot (>= 2 dominator children).
fn pivotMotif(ctx: *Ctx, p: u32) Error!usize {
    const kids = ctx.dom.children[p];
    const p_node: ?sg.NodeId = switch (ctx.sc.verts[p]) {
        .node => |nid| nid,
        .cluster => null,
    };
    var singles: u32 = 0;
    for (kids) |k| {
        if (ctx.size[k] == 1) singles += 1;
    }

    if (p_node != null and kids.len >= 3 and singles >= 3) {
        var members: std.ArrayListUnmanaged(sg.NodeId) = .empty;
        try members.append(ctx.a, p_node.?);
        var children: std.ArrayListUnmanaged(usize) = .empty;
        var deep: std.ArrayListUnmanaged(u32) = .empty;
        for (kids) |k| {
            if (ctx.size[k] == 1) {
                switch (ctx.sc.verts[k]) {
                    .node => |nid| try members.append(ctx.a, nid),
                    .cluster => |cid| try children.append(ctx.a, try clusterMotif(ctx, cid)),
                }
            } else {
                try deep.append(ctx.a, k);
            }
        }
        for (try groupSiblings(ctx, deep.items)) |mi| try children.append(ctx.a, mi);
        return appendMotif(ctx, .{
            .kind = .fan,
            .members = try members.toOwnedSlice(ctx.a),
            .entry = p_node,
            .cluster_id = null,
            .ext_in = 0,
            .ext_out = 0,
            .covered = 0,
            .children = try children.toOwnedSlice(ctx.a),
        });
    }

    const grouped = try groupSiblings(ctx, kids);
    if (p_node) |nid| {
        const members = try ctx.a.alloc(sg.NodeId, 1);
        members[0] = nid;
        return appendMotif(ctx, .{
            .kind = .atom,
            .members = members,
            .entry = nid,
            .cluster_id = null,
            .ext_in = 0,
            .ext_out = 0,
            .covered = 0,
            .children = grouped,
        });
    }
    // Branching cluster vertex: wrap in a prime so cluster motifs stay pure. // guarded-by: motif_test.zig "branching cluster vertex wraps in prime; the cluster motif stays pure"
    var children: std.ArrayListUnmanaged(usize) = .empty;
    try children.append(ctx.a, try clusterMotif(ctx, ctx.sc.verts[p].cluster));
    for (grouped) |mi| try children.append(ctx.a, mi);
    return appendMotif(ctx, .{
        .kind = .prime,
        .members = &.{},
        .entry = null,
        .cluster_id = null,
        .ext_in = 0,
        .ext_out = 0,
        .covered = 0,
        .children = try children.toOwnedSlice(ctx.a),
    });
}

/// Placeholder cluster motif; the driver fills `children` by recursing
/// into the cluster's own scope.
fn clusterMotif(ctx: *Ctx, cid: sg.ClusterId) Error!usize {
    return appendMotif(ctx, .{
        .kind = .cluster,
        .members = &.{},
        .entry = null,
        .cluster_id = cid,
        .ext_in = 0,
        .ext_out = 0,
        .covered = 0,
        .children = &.{},
    });
}

fn appendMotif(ctx: *Ctx, m: types.Motif) Error!usize {
    const idx = ctx.out.items.len;
    try ctx.out.append(ctx.a, m);
    return idx;
}

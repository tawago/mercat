//! motif/types.zig — pure data types for the MotifTree (IR 1.5).
//!
//! Sits between SemGraph and Sketch: the dominator tree of the
//! cycle-removed digraph, coarsened into typed motifs. Consumed live by
//! motif/pack.zig (via select.zig's motif-packed candidates) and by
//! entry.zig's `MERCAT_DUMP_MOTIFS=1` diagnostic dump.
//!
//! Lint zone: motif.zig + motif/* may import only std, prim, sem_graph,
//! and motif-internal files (tools/lint_imports.zig).

const std = @import("std");
const sg = @import("../sem_graph.zig");

/// The typed motif vocabulary. Classification rules (motif/classify.zig):
///
/// - `atom`     — a single node, possibly with child motifs hanging off it
///                (a branching pivot that is neither fan nor spine keeps its
///                children as child motifs).
/// - `spine`    — a linear dominator chain of >= 3 vertices. Cluster
///                vertices may sit ON the chain; they are recorded as child
///                motifs (a spine of subgraphs), never absorbed as members.
/// - `fan`      — a pivot node with >= 3 single-vertex dominator children
///                (leaf-ish spokes); a diamond's merge sink is one such
///                child, so diamonds classify as `fan`, not `prime` —
///                guarded-by: motif/motif_test.zig "diamond classifies as fan (documented choice)"
/// - `parallel` — >= 2 isomorphic-ish independent sibling dominator subtrees
///                under one parent (same dominator-shape signature, subtree
///                size >= 2). When every branch is a simple path of plain
///                nodes the branch nodes are absorbed as direct members;
///                otherwise each branch becomes a child motif.
/// - `cluster`  — a subgraph boundary. Clusters cut the tree: a motif never
///                spans a cluster border. The cluster motif's children are
///                the motifs of the cluster's own inner decomposition.
/// - `prime`    — anything unclassified (notably 2-chains, which fall below
///                the spine minimum of 3).
pub const MotifKind = enum { atom, spine, fan, parallel, cluster, prime };

/// One motif. Every real node of the SemGraph belongs to exactly one
/// motif's `members` (the partition invariant); motifs nest via `children`.
pub const Motif = struct {
    kind: MotifKind,
    /// Real node ids DIRECTLY owned by this motif — never nodes owned by a
    /// descendant motif. Empty for `cluster` motifs (their nodes are owned
    /// by the inner decomposition) and for non-absorbing `parallel` motifs.
    members: []const sg.NodeId,
    /// The single real entry node (the dominator-subtree root), when one
    /// exists. Null for `cluster` and `parallel` motifs (no single entry)
    /// and for chains that start at a cluster vertex.
    entry: ?sg.NodeId,
    /// Set iff kind == .cluster.
    cluster_id: ?sg.ClusterId,
    /// Original-graph edges crossing this motif's covered-node boundary
    /// (covered = members plus everything covered by descendants).
    ext_in: u32,
    ext_out: u32,
    /// Total real nodes covered by this motif's subtree.
    covered: u32,
    /// Indices into `MotifTree.motifs`.
    children: []const usize,
    /// For an ABSORBED `parallel` motif (every branch a simple path of
    /// plain nodes): the per-branch member runs, in branch order —
    /// `members` is exactly their concatenation. Empty for every other
    /// kind (a non-absorbing parallel keeps its branches as `children`).
    /// Consumed by motif/pack.zig to inject one synthetic cluster per
    /// branch.
    branches: []const []const sg.NodeId = &.{},
};

/// The decomposition of one SemGraph. All slices are allocated from the
/// allocator passed to `motif.decompose`; callers are expected to pass an
/// arena (the repo-wide IR convention) — there is no deinit.
pub const MotifTree = struct {
    motifs: []const Motif,
    /// Indices of the top-level (scope-root) motifs, in scope order.
    roots: []const usize,
    /// Real node count of the source graph (denominator for coverage).
    node_count: usize,
};

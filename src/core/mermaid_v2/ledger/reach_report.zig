//! reach_report.zig — result types, canonical ordering, and
//! component-table construction for the pre-raster D-REACH
//! vector oracle (P2v Step 6). Split sibling of `reach_vector.zig`
//! for the 500-line cap; the traversal/oracle logic lives there.
//!
//! Determinism (D-REACH item 12): terminal keys order by (canonical node
//! semantic key = source raw_id bytes, endpoint_side, port row, port
//! col); component ids by smallest member terminal key; every report list
//! sorts by these keys. Numeric NodeId/EdgeId never appear in keys.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! sketch, reach_geometry.

const std = @import("std");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const geom = @import("reach_geometry.zig");

pub const Error = error{OutOfMemory};

/// Per-candidate counts for every D-REACH diagnostic tag. Field names are
/// the registry tags minus the `reach_` prefix (pinned by test) — except
/// `skipped_packed_candidate`, deliberately a NON-tag field (post-review
/// F2): the D-DISPOSITION registry is closed and must not grow for
/// a report-only skip split, so the packed-candidate skip is counted
/// distinctly without ever becoming a `reach_*` tag.
/// `cross_connected` / `one_sided_adjacency` / `mixed_stroke_junction`
/// are PAINTED-half events (D-REACH clauses 4/7) and
/// `vector_raster_mismatch` is cross-half (Step 9): all structurally zero
/// in the vector-half oracle, carried so the report shape is complete.
pub const Counts = struct {
    undeclared_pair: u32 = 0,
    missing_declared: u32 = 0,
    split_trace: u32 = 0,
    duplicate_trace: u32 = 0,
    bundle_split: u32 = 0,
    independent_joined: u32 = 0,
    cross_connected: u32 = 0,
    one_sided_adjacency: u32 = 0,
    mixed_stroke_junction: u32 = 0,
    unknown_continuation: u32 = 0,
    vector_raster_mismatch: u32 = 0,
    skipped_clustered: u32 = 0,
    /// Flat input, cluster-framed candidate (synthetic packed frames):
    /// the oracle skipped a candidate that D-REACH item 1 has no carve-out
    /// for (OPEN-8). Non-tag; excluded from `ciTotal` like the RO skip.
    skipped_packed_candidate: u32 = 0,

    /// Sum of the 11 non-skip (CI-class) tag counts (D-DISPOSITION
    /// item 6 row 4; `reach_skipped_clustered` is the RO skip and
    /// `skipped_packed_candidate` the non-tag packed skip).
    pub fn ciTotal(self: Counts) u32 {
        var total: u32 = 0;
        inline for (@typeInfo(Counts).@"struct".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "skipped_clustered")) continue;
            if (comptime std.mem.eql(u8, f.name, "skipped_packed_candidate")) continue;
            total += @field(self, f.name);
        }
        return total;
    }

    /// P2v Step 8 safety-filter verdict (D-JOIN-SELECT item 6):
    /// the candidate carries NO CI-class reach event, so it survives the
    /// pre-raster filter. A skip (clustered/packed) is CI-clean by this
    /// predicate — `ciTotal` excludes both skip counts (OPEN-8), yet the
    /// report still records the skip so telemetry reports it as SKIPPED,
    /// never as validated. Consumes EVENTS only — never a score or magnitude.
    pub fn ciClean(self: Counts) bool {
        return self.ciTotal() == 0;
    }
};

/// One illegal cross-owner sharing event (`reach_unknown_continuation`):
/// the first offending cell (row/col scan order) of one cross-bundle
/// unit pair. Owning declared edges are null for a realized whole-rail
/// participant. Canonical after `canonicalizeSharing` (D-REACH item 12):
/// within an event the smaller owner key is `a_edge`, and the list sorts
/// by (cell, owner keys) — never by writer/unit index.
pub const SharingEvent = struct {
    x: i32,
    y: i32,
    a_edge: ?pb.EdgeId,
    b_edge: ?pb.EdgeId,
};

/// One declared edge as read from the candidate's own geometry
/// (EdgePath.id/from/to + rail taps — D-IR item 9).
pub const DeclaredEdge = struct { id: pb.EdgeId, from: sk.NodeId, to: sk.NodeId };

pub const Report = struct {
    components: pb.ComponentTable = &.{},
    counts: Counts = .{},
    /// Declared relation the oracle checked against (geometry-derived).
    declared: []const DeclaredEdge = &.{},
    /// Declared edges with no conductive ink and no terminals at all
    /// (`reach_missing_declared`), as canonical `bundles.memberships` ranks.
    missing_declared: []const u32 = &.{},
    sharing: []const SharingEvent = &.{},
    skipped_clustered: bool = false,
    /// Flat input skipped because the candidate carries synthetic packed
    /// cluster frames (post-review F2; see Counts.skipped_packed_candidate).
    skipped_packed: bool = false,
};

/// One typed terminal occurrence: a geometry attachment matched to its
/// `bundles.terminal_ports` record, placed in a connectivity component.
/// `opposite` is the owning edge's other endpoint — the deterministic
/// tie-break for equal-(node, side, cell) rail-pivot terminals, keeping
/// numeric ids out of every ordering decision.
pub const Occurrence = struct {
    edge: pb.EdgeId,
    node: sk.NodeId,
    endpoint_side: pb.EndpointSide,
    opposite: sk.NodeId,
    cell: geom.Cell,
    port: u32,
};

/// One connectivity component under assembly (a bundle sub-component).
pub const Comp = struct {
    chan: usize,
    first_cell: geom.Cell,
    cells: std.ArrayListUnmanaged(geom.Cell) = .empty,
    occ: std.ArrayListUnmanaged(Occurrence) = .empty,
    missing: std.ArrayListUnmanaged(pb.NodePair) = .empty,
    bundles: std.ArrayListUnmanaged(pb.SelectedBundleId) = .empty,
    /// (source node, target node) pairs an admissible walk joins
    /// (reach_walk.zig) — the trace model's reading of the component.
    reachable: []const pb.NodePair = &.{},
};

pub fn nodeKey(node_keys: []const []const u8, id: sk.NodeId) []const u8 {
    if (id < node_keys.len) return node_keys[id];
    return "";
}

pub fn declaredById(declared: []const DeclaredEdge, id: pb.EdgeId) ?DeclaredEdge {
    for (declared) |d| if (d.id == id) return d;
    return null;
}

pub fn compHasSide(comp: *const Comp, edge: pb.EdgeId, side: pb.EndpointSide) bool {
    for (comp.occ.items) |o| {
        if (o.edge == edge and o.endpoint_side == side) return true;
    }
    return false;
}

const KeyCtx = struct { keys: []const []const u8 };

fn occLess(ctx: KeyCtx, a: Occurrence, b: Occurrence) bool {
    const nk = pb.nodeKeyOrder(nodeKey(ctx.keys, a.node), nodeKey(ctx.keys, b.node));
    if (nk != .eq) return nk == .lt;
    const side = std.math.order(@intFromEnum(a.endpoint_side), @intFromEnum(b.endpoint_side));
    if (side != .eq) return side == .lt;
    if (a.cell.y != b.cell.y) return a.cell.y < b.cell.y;
    if (a.cell.x != b.cell.x) return a.cell.x < b.cell.x;
    return pb.nodeKeyOrder(nodeKey(ctx.keys, a.opposite), nodeKey(ctx.keys, b.opposite)) == .lt;
}

fn pairLess(ctx: KeyCtx, a: pb.NodePair, b: pb.NodePair) bool {
    const s = pb.nodeKeyOrder(nodeKey(ctx.keys, a.source), nodeKey(ctx.keys, b.source));
    if (s != .eq) return s == .lt;
    return pb.nodeKeyOrder(nodeKey(ctx.keys, a.target), nodeKey(ctx.keys, b.target)) == .lt;
}

/// Component order: smallest member terminal key first (item 12);
/// terminal-less components after every terminal-bearing one, by first
/// cell in row/col order.
const CompOrder = struct {
    keys: []const []const u8,
    comps: []const Comp,

    fn less(self: @This(), a: usize, b: usize) bool {
        const ca = &self.comps[a];
        const cb = &self.comps[b];
        const a_has = ca.occ.items.len > 0;
        const b_has = cb.occ.items.len > 0;
        if (a_has != b_has) return a_has;
        if (a_has) {
            const oa = minOcc(self.keys, ca);
            const ob = minOcc(self.keys, cb);
            if (occLess(.{ .keys = self.keys }, oa, ob)) return true;
            if (occLess(.{ .keys = self.keys }, ob, oa)) return false;
        }
        return geom.cellLess({}, ca.first_cell, cb.first_cell);
    }

    fn minOcc(keys: []const []const u8, comp: *const Comp) Occurrence {
        var best = comp.occ.items[0];
        for (comp.occ.items[1..]) |o| {
            if (occLess(.{ .keys = keys }, o, best)) best = o;
        }
        return best;
    }
};

/// An owner's canonical key: the declared edge's endpoint node keys. A
/// whole-rail participant (null edge) keys as the empty pair and sorts
/// first, mirroring `labelOrder`'s null-first rule; every edge-owned unit
/// is in `declared` by construction (units and declared edges are built
/// from the same s.edges/s.rails).
const OwnerKey = struct { from: []const u8, to: []const u8 };

fn ownerKey(declared: []const DeclaredEdge, keys: []const []const u8, edge: ?pb.EdgeId) OwnerKey {
    const id = edge orelse return .{ .from = "", .to = "" };
    const d = declaredById(declared, id) orelse return .{ .from = "", .to = "" };
    return .{ .from = nodeKey(keys, d.from), .to = nodeKey(keys, d.to) };
}

fn ownerOrder(a: OwnerKey, b: OwnerKey) std.math.Order {
    const from = pb.nodeKeyOrder(a.from, b.from);
    if (from != .eq) return from;
    return pb.nodeKeyOrder(a.to, b.to);
}

const SharingCtx = struct { declared: []const DeclaredEdge, keys: []const []const u8 };

fn sharingLess(ctx: SharingCtx, a: SharingEvent, b: SharingEvent) bool {
    if (a.y != b.y) return a.y < b.y;
    if (a.x != b.x) return a.x < b.x;
    const a_first = ownerOrder(
        ownerKey(ctx.declared, ctx.keys, a.a_edge),
        ownerKey(ctx.declared, ctx.keys, b.a_edge),
    );
    if (a_first != .eq) return a_first == .lt;
    return ownerOrder(
        ownerKey(ctx.declared, ctx.keys, a.b_edge),
        ownerKey(ctx.declared, ctx.keys, b.b_edge),
    ) == .lt;
}

/// Canonicalize the sharing list in place: order each event's two owners
/// by canonical owner key (smaller first), then sort the list by (cell in
/// row/col order, a-owner key, b-owner key). The result is byte-stable
/// under any writer permutation of s.edges — unit indices never leak into
/// the emitted order.
pub fn canonicalizeSharing(events: []SharingEvent, declared: []const DeclaredEdge, keys: []const []const u8) void {
    for (events) |*ev| {
        const ka = ownerKey(declared, keys, ev.a_edge);
        const kb = ownerKey(declared, keys, ev.b_edge);
        if (ownerOrder(kb, ka) == .lt) std.mem.swap(?pb.EdgeId, &ev.a_edge, &ev.b_edge);
    }
    std.mem.sort(SharingEvent, events, SharingCtx{ .declared = declared, .keys = keys }, sharingLess);
}

fn dedupPairs(alloc: std.mem.Allocator, keys: []const []const u8, pairs: []const pb.NodePair) Error![]pb.NodePair {
    var out: std.ArrayListUnmanaged(pb.NodePair) = .empty;
    outer: for (pairs) |p| {
        for (out.items) |q| {
            if (q.source == p.source and q.target == p.target) continue :outer;
        }
        try out.append(alloc, p);
    }
    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(pb.NodePair, slice, KeyCtx{ .keys = keys }, pairLess);
    return slice;
}

/// Assemble the ordered component table: per component the typed source/
/// target terminals, the pairs an admissible walk joins, the declared pairs it
/// represents, the missing/extra defect lists, and its selected-bundle ids.
/// `bridge_ids` stays empty in the no-bridge P1a slice. Also charges
/// `counts.undeclared_pair` for every extra pair (clause 10 bullet 1).
pub fn buildTable(
    alloc: std.mem.Allocator,
    node_keys: []const []const u8,
    declared: []const DeclaredEdge,
    comps: []Comp,
    counts: *Counts,
) Error!pb.ComponentTable {
    const order = try alloc.alloc(usize, comps.len);
    for (order, 0..) |*o, i| o.* = i;
    std.mem.sort(usize, order, CompOrder{ .keys = node_keys, .comps = comps }, CompOrder.less);

    const entries = try alloc.alloc(pb.ComponentEntry, comps.len);
    for (order, 0..) |ci, rank| {
        const comp = &comps[ci];
        std.mem.sort(Occurrence, comp.occ.items, KeyCtx{ .keys = node_keys }, occLess);

        var sources: std.ArrayListUnmanaged(pb.TerminalPort) = .empty;
        var targets: std.ArrayListUnmanaged(pb.TerminalPort) = .empty;
        for (comp.occ.items) |o| {
            const term: pb.TerminalPort = .{ .node = o.node, .edge = o.edge, .endpoint_side = o.endpoint_side, .port = o.port };
            switch (o.endpoint_side) {
                .source_exit => try sources.append(alloc, term),
                .target_entry => try targets.append(alloc, term),
            }
        }

        var declared_pairs: std.ArrayListUnmanaged(pb.NodePair) = .empty;
        for (declared) |d| {
            if (compHasSide(comp, d.id, .source_exit) and compHasSide(comp, d.id, .target_entry))
                try declared_pairs.append(alloc, .{ .source = d.from, .target = d.to });
        }
        const declared_sorted = try dedupPairs(alloc, node_keys, declared_pairs.items);

        const reachable_sorted = try dedupPairs(alloc, node_keys, comp.reachable);

        var extra: std.ArrayListUnmanaged(pb.NodePair) = .empty;
        outer: for (reachable_sorted) |p| {
            for (declared_sorted) |q| {
                if (q.source == p.source and q.target == p.target) continue :outer;
            }
            try extra.append(alloc, p);
        }
        counts.undeclared_pair += @intCast(extra.items.len);

        const bundle_ids = try alloc.dupe(pb.SelectedBundleId, comp.bundles.items);
        std.mem.sort(pb.SelectedBundleId, bundle_ids, {}, std.sort.asc(pb.SelectedBundleId));

        entries[rank] = .{
            .id = @intCast(rank),
            .source_terminals = try sources.toOwnedSlice(alloc),
            .target_terminals = try targets.toOwnedSlice(alloc),
            .declared_pairs_in_component = declared_sorted,
            .reachable_pairs = reachable_sorted,
            .missing_declared_pairs = try dedupPairs(alloc, node_keys, comp.missing.items),
            .extra_undeclared_pairs = try extra.toOwnedSlice(alloc),
            .selected_bundle_ids = bundle_ids,
            .bridge_ids = &.{},
        };
    }
    return entries;
}

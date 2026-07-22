//! reach_vector.zig — pre-raster VECTOR-half D-REACH reachability
//! oracle (P2v Step 6; TSD §12.4 / §17 step 15 first half; D-REACH items
//! 5, 9, 10, 12–13; SDD §12.4 component table), modeled on score_geom.zig.
//!
//! PURE REPORT-ONLY in this step: `validate` computes and records — it
//! feeds no CI filter, rejects no candidate, updates no disposition,
//! constructs no terminal candidate, and is never score input.
//! Enforcement lands in Step 8, after the output-changing Step 7.
//!
//! Model (D-REACH item 9): conductive channels are (a) edge-owned
//! `EdgePath` polylines, (b) realized trunks (BusBars backing
//! `joins.selected_joins`, complete member provenance), (c) labeled
//! exempt mesh unions (`joins.mesh_unions` provenance elements — recorded
//! provenance, never geometric inference). Terminals are typed from
//! `joins.terminal_ports`; a node is a terminal — traversal never
//! continues through it (item 5), so equal-NodeId terminals add no link.
//! Cross-owner cell sharing links nothing: a strict orthogonal
//! transversal is legal (clause 7), any other sharing fires
//! `reach_unknown_continuation`. Report ordering is canonical (item 12).
//!
//! Flat gate (D-REACH item 13; D-EDGE-ID): a Sketch carrying cluster
//! frames is skipped — no traversal, byte-identity untouched. The skip
//! records WHY (post-review F2): a clustered ORIGINAL input fires the
//! report-only `reach_skipped_clustered` marker; a flat input whose
//! candidate carries (synthetic) packed frames fires the distinct
//! non-tag `skipped_packed_candidate` count (OPEN-8: the packed-winner
//! validation gap must stay visible, and the 43-tag registry is pinned).
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! sketch, reach_geometry, reach_report (split
//! siblings for the 500-line cap, mirroring realized/invariants).

const std = @import("std");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const geom = @import("reach_geometry.zig");
const rep = @import("reach_report.zig");

pub const Error = error{OutOfMemory};

// Public result surface (types + serializer live in the report sibling).
pub const Counts = rep.Counts;
pub const Report = rep.Report;
pub const SharingEvent = rep.SharingEvent;
pub const DeclaredEdge = rep.DeclaredEdge;
pub const serialize = rep.serialize;

const Occurrence = rep.Occurrence;
const Comp = rep.Comp;

const ChanCell = struct { chan: u32, x: i32, y: i32 };

fn containsEdge(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |e| if (e == edge) return true;
    return false;
}

fn tapSetEquals(bb: sk.BusBar, members: []const pb.EdgeId) bool {
    if (bb.taps.len != members.len) return false;
    for (bb.taps) |tap| if (!containsEdge(members, tap.edge)) return false;
    for (members) |m| {
        var found = false;
        for (bb.taps) |tap| {
            if (tap.edge == m) found = true;
        }
        if (!found) return false;
    }
    return true;
}

// -- Union-find over units (co-ownership channels) -------------------------

fn find(parent: []usize, i: usize) usize {
    var root = i;
    while (parent[root] != root) root = parent[root];
    var cur = i;
    while (parent[cur] != root) {
        const next = parent[cur];
        parent[cur] = root;
        cur = next;
    }
    return root;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra != rb) parent[@max(ra, rb)] = @min(ra, rb);
}

/// Whether the caller's ORIGINAL parsed input was flat or clustered.
/// Only the caller knows: a flat input's motif-PACKED candidate carries
/// synthetic cluster frames the sketch alone cannot tell apart from real
/// authored subgraphs.
pub const InputKind = enum { flat, clustered };

/// Run the vector-half oracle over one candidate Sketch + its `joins`
/// envelope. `node_keys` maps NodeId → source raw_id bytes (the canonical
/// node semantic key, D-REACH item 12); ids beyond the table order as the
/// empty key. `input` is the ORIGINAL-input fact (see `InputKind`) — it
/// only selects which skip marker a cluster-framed sketch records. Pure
/// and deterministic; callers degrade errors to the empty report (the
/// render never fails on validation).
pub fn validate(alloc: std.mem.Allocator, s: sk.Sketch, node_keys: []const []const u8, input: InputKind) Error!Report {
    if (s.clusters.len != 0) return switch (input) {
        .clustered => .{
            .skipped_clustered = true,
            .counts = .{ .skipped_clustered = 1 },
        },
        // Flat input, framed candidate: the frames are synthetic packing
        // chrome (motif pack). Recorded distinctly so the packed-winner
        // validation gap (OPEN-8) is visible, never conflated with the
        // clustered-input scope gate.
        .flat => .{
            .skipped_packed = true,
            .counts = .{ .skipped_packed_candidate = 1 },
        },
    };
    const joins = s.joins;
    const declared = try declaredEdges(alloc, s);

    // 1. Units. A BusBar realizing a selected join is ONE trunk channel;
    // any other BusBar decomposes into per-tap member shares (an
    // unrealized fusion is a channel of NO class — D-REACH clause 9 —
    // so sibling shares are cross-owner and report, never link).
    var units: std.ArrayListUnmanaged(geom.Unit) = .empty;
    const bb_join = try alloc.alloc(?pb.RealizedJoinId, s.busbars.len);
    @memset(bb_join, null);
    for (joins.selected_joins) |join| {
        for (s.busbars, 0..) |bb, bi| {
            if (bb_join[bi] == null and tapSetEquals(bb, join.members)) {
                bb_join[bi] = join.id;
                break;
            }
        }
    }
    for (s.busbars, 0..) |bb, bi| {
        if (bb_join[bi]) |jid| {
            try units.append(alloc, try geom.trunkUnit(alloc, bb, jid));
        } else {
            for (bb.taps) |tap| try units.append(alloc, try geom.tapShareUnit(alloc, bb, tap));
        }
    }
    for (s.edges) |e| try units.append(alloc, try geom.edgeUnit(alloc, e));

    // 2. Channels: co-ownership union-find. Links exist only inside a
    // channel + trunk arms: a selected join co-owns its trunk and its
    // members' continuations; a labeled mesh union co-owns ALL member
    // geometry as one conductive channel (clause 9(c)).
    const parent = try alloc.alloc(usize, units.items.len);
    for (parent, 0..) |*p, i| p.* = i;
    for (joins.selected_joins) |join| {
        var anchor: ?usize = null;
        for (units.items, 0..) |u, i| {
            const owns = (u.join != null and u.join.? == join.id) or
                (u.edge != null and containsEdge(join.members, u.edge.?));
            if (!owns) continue;
            if (anchor) |a| unite(parent, a, i) else anchor = i;
        }
    }
    for (joins.mesh_unions) |mu| {
        var anchor: ?usize = null;
        for (units.items, 0..) |u, i| {
            if (u.edge == null or !containsEdge(mu.members, u.edge.?)) continue;
            if (anchor) |a| unite(parent, a, i) else anchor = i;
        }
    }

    // 3. Cross-channel sharing (clauses 7/9): a strict orthogonal
    // transversal is legal and links nothing; ANY other cross-owner
    // sharing fires reach_unknown_continuation once per offending pair.
    var counts: Counts = .{};
    var sharing: std.ArrayListUnmanaged(SharingEvent) = .empty;
    var all_cells: std.AutoArrayHashMapUnmanaged(geom.Cell, void) = .empty;
    for (units.items) |u| {
        for (u.cells.keys()) |c| try all_cells.put(alloc, c, {});
    }
    const sorted_cells = try alloc.dupe(geom.Cell, all_cells.keys());
    std.mem.sort(geom.Cell, sorted_cells, {}, geom.cellLess);
    var flagged: std.AutoArrayHashMapUnmanaged([2]usize, void) = .empty;
    for (sorted_cells) |c| {
        for (units.items, 0..) |ua, i| {
            const pa = ua.cells.get(c) orelse continue;
            for (units.items[i + 1 ..], i + 1..) |ub, j| {
                const b_info = ub.cells.get(c) orelse continue;
                if (find(parent, i) == find(parent, j)) continue;
                if (geom.transversal(pa, b_info)) continue;
                const key: [2]usize = .{ i, j };
                if (flagged.contains(key)) continue;
                try flagged.put(alloc, key, {});
                counts.unknown_continuation += 1;
                try sharing.append(alloc, .{ .x = c.x, .y = c.y, .a_edge = ua.edge, .b_edge = ub.edge });
            }
        }
    }

    // 4. Connectivity sub-components per channel: a channel whose cells
    // do not all connect splits (the V-D-REACH-18 broken-trunk surface).
    var comps: std.ArrayListUnmanaged(Comp) = .empty;
    var cell_comp: std.AutoArrayHashMapUnmanaged(ChanCell, usize) = .empty;
    var chan_seen: std.AutoArrayHashMapUnmanaged(usize, void) = .empty;
    for (units.items, 0..) |_, i| try chan_seen.put(alloc, find(parent, i), {});
    for (chan_seen.keys()) |chan| {
        var chan_cells: std.AutoArrayHashMapUnmanaged(geom.Cell, void) = .empty;
        for (units.items, 0..) |u, i| {
            if (find(parent, i) != chan) continue;
            for (u.cells.keys()) |c| try chan_cells.put(alloc, c, {});
        }
        const cells = try alloc.dupe(geom.Cell, chan_cells.keys());
        std.mem.sort(geom.Cell, cells, {}, geom.cellLess);
        const labels = try geom.componentLabels(alloc, cells);
        var label_comp: std.AutoArrayHashMapUnmanaged(u32, usize) = .empty;
        for (cells, labels) |c, label| {
            const gop = try label_comp.getOrPut(alloc, label);
            if (!gop.found_existing) {
                gop.value_ptr.* = comps.items.len;
                try comps.append(alloc, .{ .chan = chan, .first_cell = c });
            }
            try cell_comp.put(alloc, .{ .chan = @intCast(chan), .x = c.x, .y = c.y }, gop.value_ptr.*);
        }
    }

    // 5. Terminals: typed records only, never inferred by geometry scan
    // (clause 2). A geometry attachment becomes a terminal occurrence iff
    // a matching (edge, endpoint_side, node) record exists in
    // joins.terminal_ports; its border-cell location is the attachment
    // cell, derived from the owning Sketch at consumption time.
    for (units.items, 0..) |u, i| {
        const chan: u32 = @intCast(find(parent, i));
        for (u.attachments) |att| {
            const port = matchRecord(joins.terminal_ports, att) orelse continue;
            const ci = cell_comp.get(.{ .chan = chan, .x = att.cell.x, .y = att.cell.y }) orelse continue;
            const comp = &comps.items[ci];
            if (rep.compHasSide(comp, att.edge, att.endpoint_side)) continue;
            const d = rep.declaredById(declared, att.edge);
            try comp.occ.append(alloc, .{
                .edge = att.edge,
                .node = att.node,
                .endpoint_side = att.endpoint_side,
                .opposite = oppositeNode(d, att),
                .cell = .{ .x = att.cell.x, .y = att.cell.y },
                .port = port,
            });
        }
    }

    try oracle(alloc, s, declared, comps.items, &counts);
    const missing = try missingDeclared(alloc, s, declared, comps.items, &counts);
    const table = try rep.buildTable(alloc, node_keys, declared, comps.items, &counts);
    // Canonical sharing order (D-REACH item 12, post-review F1): owners
    // within each event and the event list itself are keyed, so the
    // emitted report is byte-identical under s.edges writer permutation.
    const sharing_events = try sharing.toOwnedSlice(alloc);
    rep.canonicalizeSharing(sharing_events, declared, node_keys);
    return .{
        .components = table,
        .counts = counts,
        .declared = declared,
        .missing_declared = missing,
        .sharing = sharing_events,
    };
}

fn oppositeNode(d: ?DeclaredEdge, att: geom.Attachment) sk.NodeId {
    const de = d orelse return att.node;
    return switch (att.endpoint_side) {
        .source_exit => de.to,
        .target_entry => de.from,
    };
}

fn matchRecord(records: []const pb.TerminalPort, att: geom.Attachment) ?u32 {
    for (records) |r| {
        if (r.edge == att.edge and r.endpoint_side == att.endpoint_side and r.node == att.node)
            return r.port;
    }
    return null;
}

/// Declared edge relation, read from the candidate's own geometry
/// (EdgePath.id/from/to + trunk taps — D-IR item 9), first occurrence per
/// id wins (a second instance of one id is the V-D-REACH-17 duplicate).
fn declaredEdges(alloc: std.mem.Allocator, s: sk.Sketch) Error![]const DeclaredEdge {
    var list: std.ArrayListUnmanaged(DeclaredEdge) = .empty;
    for (s.edges) |e| try addDeclared(alloc, &list, e.id, e.from, e.to);
    for (s.busbars) |bb| {
        const out_dir = geom.busBarDirection(bb) == .out;
        for (bb.taps) |tap| {
            const from = if (out_dir) bb.pivot else tap.node;
            const to = if (out_dir) tap.node else bb.pivot;
            try addDeclared(alloc, &list, tap.edge, from, to);
        }
    }
    return list.toOwnedSlice(alloc);
}

fn addDeclared(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(DeclaredEdge), id: pb.EdgeId, from: sk.NodeId, to: sk.NodeId) Error!void {
    for (list.items) |d| if (d.id == id) return;
    try list.append(alloc, .{ .id = id, .from = from, .to = to });
}

/// Clause-10 per-edge placement + clause-6 join/union provenance checks.
fn oracle(
    alloc: std.mem.Allocator,
    s: sk.Sketch,
    declared: []const DeclaredEdge,
    comps: []Comp,
    counts: *Counts,
) Error!void {
    // Every declared edge MUST have its source and target terminals in
    // exactly one component (TSD §12.4, cross-gap condition vacuous).
    for (declared) |d| {
        var n_both: u32 = 0;
        var n_src: u32 = 0;
        var n_tgt: u32 = 0;
        var src_comp: ?usize = null;
        var tgt_comp: ?usize = null;
        for (comps, 0..) |*comp, ci| {
            const has_src = rep.compHasSide(comp, d.id, .source_exit);
            const has_tgt = rep.compHasSide(comp, d.id, .target_entry);
            if (has_src) {
                n_src += 1;
                if (src_comp == null) src_comp = ci;
            }
            if (has_tgt) {
                n_tgt += 1;
                if (tgt_comp == null) tgt_comp = ci;
            }
            if (has_src and has_tgt) n_both += 1;
        }
        if (n_src == 0 and n_tgt == 0) continue; // absence half → missingDeclared
        if (n_both >= 2 or (n_both == 1 and (n_src > 1 or n_tgt > 1))) {
            counts.duplicate_trace += 1; // bullet 3: multi-component edge
        } else if (n_both == 0) {
            counts.split_trace += 1; // bullet 2: ink present across >1 fragment
            const home = src_comp orelse tgt_comp.?;
            try comps[home].missing.append(alloc, .{ .source = d.from, .target = d.to });
        }
    }
    // Bullet 4: a selected trunk MUST form one component containing the
    // pivot terminal and exactly its member terminals.
    for (s.joins.selected_joins) |join| {
        var member_comps: u32 = 0;
        for (comps) |*comp| {
            var has_member = false;
            for (comp.occ.items) |o| {
                if (containsEdge(join.members, o.edge)) has_member = true;
            }
            if (has_member) member_comps += 1;
        }
        if (member_comps != 1) counts.join_split += 1;
        try foreignCheck(alloc, join.id, true, join.members, comps, counts);
    }
    // A labeled mesh union's channel must likewise carry members only;
    // within the union, member sharing is intra-channel and bullet 5
    // never fires among members (clause 9(c)).
    for (s.joins.mesh_unions) |mu| {
        try foreignCheck(alloc, null, false, mu.members, comps, counts);
    }
}

/// Bullet 5: a component carrying a join's/union's members that also
/// carries any non-member terminal joins independent memberships.
fn foreignCheck(
    alloc: std.mem.Allocator,
    join_id: ?pb.RealizedJoinId,
    record_join: bool,
    members: []const pb.EdgeId,
    comps: []Comp,
    counts: *Counts,
) Error!void {
    for (comps) |*comp| {
        var has_member = false;
        for (comp.occ.items) |o| {
            if (containsEdge(members, o.edge)) has_member = true;
        }
        if (!has_member) continue;
        if (record_join) try comp.joins.append(alloc, join_id.?);
        var foreign: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        defer foreign.deinit(alloc);
        for (comp.occ.items) |o| {
            if (!containsEdge(members, o.edge) and !containsEdge(foreign.items, o.edge))
                try foreign.append(alloc, o.edge);
        }
        counts.independent_joined += @intCast(foreign.items.len);
    }
}

/// Bullet 2 absence half (clause 8): a declared edge with no conductive
/// ink and no terminals at all. Surfaces via `joins.memberships` entries
/// whose edge has neither geometry nor a terminal occurrence.
fn missingDeclared(
    alloc: std.mem.Allocator,
    s: sk.Sketch,
    declared: []const DeclaredEdge,
    comps: []const Comp,
    counts: *Counts,
) Error![]const u32 {
    var missing: std.ArrayListUnmanaged(u32) = .empty;
    for (s.joins.memberships, 0..) |m, rank| {
        const has_geometry = rep.declaredById(declared, m.edge) != null;
        if (has_geometry and edgeHasOccurrence(comps, m.edge)) continue;
        counts.missing_declared += 1;
        try missing.append(alloc, @intCast(rank));
    }
    return missing.toOwnedSlice(alloc);
}

fn edgeHasOccurrence(comps: []const Comp, edge: pb.EdgeId) bool {
    for (comps) |comp| {
        for (comp.occ.items) |o| if (o.edge == edge) return true;
    }
    return false;
}

//! reach_vector.zig — pre-raster VECTOR-half D-REACH reachability
//! oracle (P2v Step 6; D-REACH items 5, 9, 10, 12–13), modeled on
//! score_geom.zig and emitting the shared component-table shape.
//!
//! PURE REPORT-ONLY in this step: `validate` computes and records — it
//! feeds no CI filter, rejects no candidate, updates no disposition,
//! constructs no terminal candidate, and is never score input.
//! Enforcement lands in Step 8, after the output-changing Step 7.
//!
//! Model (D-REACH item 9): conductive bundles are (a) edge-owned
//! `EdgePath` polylines and (b) realized rails (Rails backing
//! `bundles.selected_bundles`, complete member provenance). Terminals are typed from
//! `bundles.terminal_ports`; a node is a terminal — traversal never
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
//! validation gap must stay visible, and the tag registry is closed).
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, the base/ no-deps
//! tier (here ../base/ledger.zig and ../base/rail_closure.zig), sketch,
//! reach_geometry, reach_report, reach_walk (split
//! siblings for the 500-line cap, mirroring realized/invariants).

const std = @import("std");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const rc = @import("../base/rail_closure.zig");
const geom = @import("reach_geometry.zig");
const rep = @import("reach_report.zig");
const walk = @import("reach_walk.zig");

pub const Error = error{OutOfMemory};

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

fn tapSetEquals(rail: sk.Rail, members: []const pb.EdgeId) bool {
    if (rail.taps.len != members.len) return false;
    for (rail.taps) |tap| if (!containsEdge(members, tap.edge)) return false;
    for (members) |m| {
        var found = false;
        for (rail.taps) |tap| {
            if (tap.edge == m) found = true;
        }
        if (!found) return false;
    }
    return true;
}

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

/// Run the vector-half oracle over one candidate Sketch + its `bundles`
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
        .flat => .{
            .skipped_packed = true,
            .counts = .{ .skipped_packed_candidate = 1 },
        },
    };
    const bundles = s.bundles;
    const declared = try declaredEdges(alloc, s);

    var units: std.ArrayListUnmanaged(geom.Unit) = .empty;
    const rail_bundle = try alloc.alloc(?pb.SelectedBundleId, s.rails.len);
    @memset(rail_bundle, null);
    for (bundles.selected_bundles) |sel| {
        for (s.rails, 0..) |rail, bi| {
            if (rail_bundle[bi] == null and tapSetEquals(rail, sel.members)) {
                rail_bundle[bi] = sel.id;
                break;
            }
        }
    }
    for (s.rails, 0..) |rail, bi| {
        if (rail_bundle[bi]) |jid| {
            try units.append(alloc, try geom.railUnit(alloc, rail, jid));
        } else {
            for (rail.taps) |tap| try units.append(alloc, try geom.tapShareUnit(alloc, rail, tap));
        }
    }
    for (s.edges) |e| try units.append(alloc, try geom.edgeUnit(alloc, e));

    const parent = try alloc.alloc(usize, units.items.len);
    for (parent, 0..) |*p, i| p.* = i;
    for (bundles.selected_bundles) |sel| {
        var anchor: ?usize = null;
        for (units.items, 0..) |u, i| {
            const owns = (u.bundle != null and u.bundle.? == sel.id) or
                (u.edge != null and containsEdge(sel.members, u.edge.?));
            if (!owns) continue;
            if (anchor) |a| unite(parent, a, i) else anchor = i;
        }
    }
    for (bundles.fused) |u| {
        var anchor: ?usize = null;
        for (units.items, 0..) |unit, i| {
            const owns = (unit.edge != null and containsEdge(u, unit.edge.?)) or
                (unit.bundle != null and bundleInUnion(bundles, unit.bundle.?, u));
            if (!owns) continue;
            if (anchor) |a| unite(parent, a, i) else anchor = i;
        }
    }

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
            try comps.items[gop.value_ptr.*].cells.append(alloc, c);
            try cell_comp.put(alloc, .{ .chan = @intCast(chan), .x = c.x, .y = c.y }, gop.value_ptr.*);
        }
    }

    for (units.items, 0..) |u, i| {
        const chan: u32 = @intCast(find(parent, i));
        for (u.attachments) |att| {
            const port = matchRecord(bundles.terminal_ports, att) orelse continue;
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

    try walkComponents(alloc, units.items, parent, comps.items);
    try oracle(alloc, s, declared, comps.items, &counts);
    const missing = try missingDeclared(alloc, s, declared, comps.items, &counts);
    const table = try rep.buildTable(alloc, node_keys, declared, comps.items, &counts);
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

/// Read each component under the trace model: its reachable pairs are the
/// ones an admissible walk over its channel's units joins.
fn walkComponents(alloc: std.mem.Allocator, units: []const geom.Unit, parent: []usize, comps: []Comp) Error!void {
    for (comps) |*comp| {
        var chan_units: std.ArrayListUnmanaged(geom.Unit) = .empty;
        for (units, 0..) |u, i| if (find(parent, i) == comp.chan) try chan_units.append(alloc, u);
        var sources: std.ArrayListUnmanaged(walk.Terminal) = .empty;
        var targets: std.ArrayListUnmanaged(walk.Terminal) = .empty;
        for (comp.occ.items) |o| {
            const term: walk.Terminal = .{ .node = o.node, .cell = o.cell };
            switch (o.endpoint_side) {
                .source_exit => try sources.append(alloc, term),
                .target_entry => try targets.append(alloc, term),
            }
        }
        comp.reachable = try walk.reachablePairs(alloc, chan_units.items, comp.cells.items, sources.items, targets.items);
    }
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
/// (EdgePath.id/from/to + rail taps — D-IR item 9), first occurrence per
/// id wins (a second instance of one id is the V-D-REACH-17 duplicate).
fn declaredEdges(alloc: std.mem.Allocator, s: sk.Sketch) Error![]const DeclaredEdge {
    var list: std.ArrayListUnmanaged(DeclaredEdge) = .empty;
    for (s.edges) |e| try addDeclared(alloc, &list, e.id, e.from, e.to);
    for (s.rails) |rail| {
        const out_dir = geom.railDirection(rail) == .out;
        for (rail.taps) |tap| {
            const from = if (out_dir) rail.pivot else tap.node;
            const to = if (out_dir) tap.node else rail.pivot;
            try addDeclared(alloc, &list, tap.edge, from, to);
        }
    }
    return list.toOwnedSlice(alloc);
}

fn addDeclared(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(DeclaredEdge), id: pb.EdgeId, from: sk.NodeId, to: sk.NodeId) Error!void {
    for (list.items) |d| if (d.id == id) return;
    try list.append(alloc, .{ .id = id, .from = from, .to = to });
}

/// Clause-10 per-edge placement + clause-6 bundle/union provenance checks.
fn oracle(
    alloc: std.mem.Allocator,
    s: sk.Sketch,
    declared: []const DeclaredEdge,
    comps: []Comp,
    counts: *Counts,
) Error!void {
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
        if (n_src == 0 and n_tgt == 0) continue;
        if (n_both >= 2 or (n_both == 1 and (n_src > 1 or n_tgt > 1))) {
            counts.duplicate_trace += 1;
        } else if (n_both == 0) {
            counts.split_trace += 1;
            const home = src_comp orelse tgt_comp.?;
            try comps[home].missing.append(alloc, .{ .source = d.from, .target = d.to });
        }
    }
    for (s.bundles.selected_bundles) |sel| {
        var member_comps: u32 = 0;
        for (comps) |*comp| {
            var has_member = false;
            for (comp.occ.items) |o| {
                if (containsEdge(sel.members, o.edge)) has_member = true;
            }
            if (!has_member) continue;
            member_comps += 1;
            try comp.bundles.append(alloc, sel.id);
        }
        if (member_comps != 1) counts.bundle_split += 1;
    }
    try foreignCheck(alloc, s.bundles, comps, counts);
}

fn bundleInUnion(bundles: pb.RealizedBundles, id: pb.SelectedBundleId, u: []const pb.EdgeId) bool {
    for (bundles.selected_bundles) |j| {
        if (j.id != id) continue;
        for (j.members) |m| if (containsEdge(u, m)) return true;
        return false;
    }
    return false;
}

fn fusedUnionOf(bundles: pb.RealizedBundles, sel: pb.SelectedBundle) ?[]const pb.EdgeId {
    for (bundles.fused) |u| {
        var all = true;
        for (sel.members) |m| {
            if (!containsEdge(u, m)) all = false;
        }
        if (all and sel.members.len > 0) return u;
    }
    return null;
}

/// Bullet 5: a component carrying realized bundles' members that also
/// carries a terminal no bundle of the component licenses — an
/// independent membership joined to shared ink. A component may hold
/// several bundles (an edge that is a member at both ends joins its two
/// rails), so "foreign" is measured against the union of every bundle
/// present, each read through its fused union when it has one.
fn foreignCheck(alloc: std.mem.Allocator, bundles: pb.RealizedBundles, comps: []Comp, counts: *Counts) Error!void {
    for (comps) |*comp| {
        if (comp.bundles.items.len == 0) continue;
        var covered: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        defer covered.deinit(alloc);
        for (comp.bundles.items) |id| {
            for (bundles.selected_bundles) |sel| {
                if (sel.id != id) continue;
                try covered.appendSlice(alloc, fusedUnionOf(bundles, sel) orelse sel.members);
            }
        }
        var foreign: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        defer foreign.deinit(alloc);
        for (comp.occ.items) |o| {
            if (!containsEdge(covered.items, o.edge) and !containsEdge(foreign.items, o.edge))
                try foreign.append(alloc, o.edge);
        }
        counts.independent_joined += @intCast(foreign.items.len);
    }
}

/// Bullet 2 absence half (clause 8): a declared edge with no conductive
/// ink and no terminals at all. Surfaces via `bundles.memberships` entries
/// whose edge has neither geometry nor a terminal occurrence.
fn missingDeclared(
    alloc: std.mem.Allocator,
    s: sk.Sketch,
    declared: []const DeclaredEdge,
    comps: []const Comp,
    counts: *Counts,
) Error![]const u32 {
    var missing: std.ArrayListUnmanaged(u32) = .empty;
    for (s.bundles.memberships, 0..) |m, rank| {
        // A CO-REALIZED edge is present, not absent: an all-arrow-free rail
        // discharged it, so the crossbar ink between its two taps IS its
        // rendering. It owns no geometry of its own by construction, and
        // charging it here would report the licence's success as a lost edge.
        // @guarded-by: reach_vector_test.zig "a discharged edge is not charged as a missing declared edge"
        if (rc.contains(s.bundles.discharged, m.edge)) continue;
        const has_geometry = rep.declaredById(declared, m.edge) != null;
        if (has_geometry and edgeHasOccurrence(comps, m.edge)) continue;
        counts.missing_declared += 1;
        try missing.append(alloc, @intCast(rank));
    }
    // A visible edge the router laid no ink for (an empty polyline) is a
    // declared pair with no trace whatever its plan; one with no membership
    // was not visited above and is charged here (count only — it has no
    // membership rank to name).
    // @guarded-by: select_test.zig "an unrouted edge is a missing declared pair on a candidate the oracle skipped"
    for (s.edges) |e| {
        if (e.polyline.len >= 2 or e.kind == .invisible) continue;
        if (rc.contains(s.bundles.discharged, e.id)) continue;
        var member = false;
        for (s.bundles.memberships) |m| if (m.edge == e.id) {
            member = true;
        };
        if (!member) counts.missing_declared += 1;
    }
    return missing.toOwnedSlice(alloc);
}

fn edgeHasOccurrence(comps: []const Comp, edge: pb.EdgeId) bool {
    for (comps) |comp| {
        for (comp.occ.items) |o| if (o.edge == edge) return true;
    }
    return false;
}

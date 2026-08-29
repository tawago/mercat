//! Pre-sizing realization commitment for the flat layout path.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const rc = @import("../base/rail_closure.zig");
const sg = @import("../sem_graph.zig");
const permit_mod = @import("../ledger/permits.zig");

/// The closure law's report-only inventory (base/ledger.zig). One type for
/// every producer — the flat commitment here and the clustered lane pass —
/// so the shipped Sketch carries a single set of counts.
pub const Report = pb.ClosureCounts;

/// The plan THIS graph's layout realizes against: the root plan when it is
/// flat, a fresh piece-scoped plan (piece-local edge ids) for a cluster-free
/// piece of a clustered original, and null when no plan applies (no permits,
/// clusters present — authored or motif-pack synthetic — or invalid piece).
pub fn effectivePlan(a: std.mem.Allocator, graph: sg.SemGraph, root: ?*const pb.JoinPermits) error{OutOfMemory}!?pb.JoinPermits {
    const rp = root orelse return null;
    if (graph.clusters.len != 0) return null;
    if (rp.isFlat()) return rp.*;
    const piece = permit_mod.buildPiece(a, graph) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSemGraph => return null,
    };
    return piece.plan;
}

pub fn buildReported(a: std.mem.Allocator, graph: sg.SemGraph, permits: ?*const pb.JoinPermits, reversed_edges: []const pb.EdgeId, disable: bool, report: ?*Report) error{OutOfMemory}!pb.RealizedJoins {
    // Commit only when laying out a cluster-free graph: synthetic motif-pack
    // clusters are outside the flat edge-id identity path just like authored
    // clusters, so no original-input permit may affect their geometry before
    // post-layout realization applies the same gate. A piece-scoped plan
    // (from `effectivePlan`) realizes exactly like a flat one — it speaks the
    // piece's own edge ids; only a skipped_clustered root plan commits nothing.
    const plan_ptr = permits orelse return .{};
    if (graph.clusters.len != 0) return .{};
    if (plan_ptr.scope == .skipped_clustered) return .{};
    const plan = plan_ptr.*;
    // P2v Step 8 (D-DISPOSITION item 9(b)): the forced all-independent terminal
    // layout. Every grouped endpoint takes an independent(not_selected)
    // disposition, so no trunk is realized — fan_rail.resolve then declines (memberships present, none selected),
    // leaving per-edge D-PORT ports. The always-expressible conservative
    // baseline, materialized as layout geometry.
    if (disable) {
        const memberships = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
        for (plan.memberships, memberships) |m, *out| out.* = .{
            .edge = m.edge,
            .source = independentOf(m.source_group),
            .target = independentOf(m.target_group),
        };
        return .{ .memberships = memberships };
    }
    // Phase 1 — provisional eligibility under the frozen gates. `eff_of[gi]`
    // is the member set the group would commit as a trunk, or null when a
    // gate refuses it.
    const eff_of = try a.alloc(?[]const pb.EdgeId, plan.groups.len);
    for (plan.groups, 0..) |group, gi| {
        // A fan-IN group whose arrival is a legal pure fan-in stays eligible
        // despite an overlap (arrival re-merge preference); the shared
        // conflict is still retained by the memberships pass below. Fan-OUT
        // groups keep the strict overlap exclusion.
        const overlap = overlaps(plan.groups, gi);
        const remerge = overlap and pb.fanInReMergeEligible(plan.groups, gi);
        // Forward-subset composition (owner ruling 2026-07-18): a fan-IN group
        // blocked ONLY by a layout-reversed member composes its FORWARD subset
        // (>=2 members) as one merged trunk; the reversed member(s) take
        // independent side entries. `eff` drops the reversed members so every
        // gate below (style, duplicate, floor) judges exactly the trunk
        // members — keeping join_commit and realized.realize in agreement (N6).
        // Fan-out and non-reversed groups keep the whole member set unchanged.
        const reversed = containsReversed(group, reversed_edges);
        const forward = if (reversed and group.direction == .in)
            try forwardSubset(a, group.members, reversed_edges)
        else
            group.members;
        const eff = (try permit_mod.prepareRailMembers(a, graph, group.direction, group.pivot, forward)).members;
        const eff_group: pb.JoinGroup = .{ .id = group.id, .direction = group.direction, .pivot = group.pivot, .members = eff };
        const blocked = (overlap and !remerge) or !styleCompatible(graph, eff_group) or hasDuplicateKey(graph, eff_group) or
            containsReversed(eff_group, reversed_edges) or eff.len < 2;
        eff_of[gi] = if (blocked) null else eff;
    }

    // Phase 2 — the all-arrow-free shared-rail closure law. A rail whose every
    // member is arrow-free asserts each unordered LEAF PAIR too, so it may fuse
    // only over pairs the graph declares. Each rail is judged on its own here;
    // `reserve` below then applies the plan-wide clause.
    const closure_refused = try a.alloc(bool, plan.groups.len);
    @memset(closure_refused, false);
    const verdicts = try a.alloc(?rc.Verdict, plan.groups.len);
    @memset(verdicts, null);
    for (plan.groups, 0..) |group, gi| {
        const eff = eff_of[gi] orelse continue;
        const verdict = try closureVerdict(a, graph, group, eff, plan.scope == .piece);
        if (report) |r| {
            if (verdict.outcome == .refuse or verdict.outcome == .salvage) r.rail_closure_undeclared += 1;
            r.co_undeclared += verdict.undeclared_pairs;
        }
        switch (verdict.outcome) {
            // A directed or mixed rail asserts no leaf pair at all, so it never
            // enters the reservation.
            .untouched => continue,
            .keep => {},
            // A salvaged rail keeps a strict subset; the dropped members fall
            // to independent lanes exactly like a member the style gate
            // excluded, and keep their own ink.
            .salvage => eff_of[gi] = verdict.members,
            .refuse => {
                eff_of[gi] = null;
                closure_refused[gi] = true;
                continue;
            },
        }
        verdicts[gi] = verdict;
    }
    try reserve(a, eff_of, verdicts, closure_refused, report);

    // Phase 2b — discharge. `drawn` is the union of the SURVIVING rails' own
    // members: such a declaration already carries ink, so it LICENSES the pair
    // (the crossbar states nothing the page does not) without handing over its
    // rendering a second time. Every other backing declaration is discharged —
    // the crossbar between its two taps IS its rendering — and, being spent,
    // backs nothing else plan-wide.
    // guarded-by: join_commit_test.zig "a clique whose pair edges are other rails' members keeps a rail"
    var discharged: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    var drawn: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (eff_of) |maybe| {
        if (maybe) |eff| try drawn.appendSlice(a, eff);
    }
    for (verdicts, 0..) |maybe, gi| {
        const verdict = maybe orelse continue;
        if (eff_of[gi] == null) continue;
        for (verdict.discharges) |d| {
            if (containsEdge(drawn.items, d.backer)) continue;
            try discharged.append(a, d.backer);
            try drawn.append(a, d.backer);
        }
    }

    // Phase 3 — commitment. Ids ascend with group rank, unchanged.
    const selected_group = try a.alloc(?pb.RealizedJoinId, plan.groups.len);
    @memset(selected_group, null);
    var selected: std.ArrayListUnmanaged(pb.SelectedJoin) = .empty;
    for (plan.groups, 0..) |group, gi| {
        const eff = eff_of[gi] orelse continue;
        const jid: pb.RealizedJoinId = @intCast(selected.items.len);
        selected_group[gi] = jid;
        try selected.append(a, .{
            .id = jid,
            .proposal = @intCast(gi),
            .permission_group = group.id,
            .members = try a.dupe(pb.EdgeId, eff),
        });
    }

    const memberships = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
    for (plan.memberships, memberships) |m, *out| {
        out.* = .{
            .edge = m.edge,
            .source = disposition(graph, plan.groups, selected_group, closure_refused, selected.items, m.source_group, reversed_edges, m.edge),
            .target = disposition(graph, plan.groups, selected_group, closure_refused, selected.items, m.target_group, reversed_edges, m.edge),
        };
    }
    const selected_slice = try selected.toOwnedSlice(a);
    return .{
        .selected_joins = selected_slice,
        .memberships = memberships,
        .co_realized = try discharged.toOwnedSlice(a),
        .fused = try fusionLicence(a, graph, plan.groups, selected_slice),
    };
}

/// Phase 4 — the two-sided fusion licence. Selected SAME-direction trunks
/// over ONE AND THE SAME leaf set form a candidate union (a mere shared leaf
/// would chain two disjoint complete unions into one that refuses); the union
/// is licensed iff every member edge carries its one-way head at the union's
/// TARGET side (a head at the source stops a trace only in the direction a
/// fused rail reads backwards), all members agree on stroke kind and head
/// glyphs, and the distinct declared pairs are EXACTLY srcs x tgts with both
/// sides plural — then the trunks' shared rail asserts only cross pairs the
/// source declares, and its ink is one channel. Keyed on the plan and the
/// declared edges only.
/// guarded-by: join_commit_test.zig "a complete bipartite of selected arrivals licenses one fused union"
fn fusionLicence(a: std.mem.Allocator, graph: sg.SemGraph, groups: []const pb.JoinGroup, selected: []const pb.SelectedJoin) error{OutOfMemory}![]const []const pb.EdgeId {
    const n = selected.len;
    if (n < 2) return &.{};
    const parent = try a.alloc(usize, n);
    for (parent, 0..) |*p, i| p.* = i;
    for (selected, 0..) |x, i| {
        const dx = directionOf(groups, x.permission_group) orelse continue;
        for (selected[i + 1 ..], i + 1..) |y, j| {
            if (directionOf(groups, y.permission_group) != dx) continue;
            if (leafSetEqual(graph, dx, x.members, y.members)) uniteJoin(parent, i, j);
        }
    }
    var out: std.ArrayListUnmanaged([]const pb.EdgeId) = .empty;
    for (0..n) |root| {
        if (findJoin(parent, root) != root) continue;
        var member_joins: u32 = 0;
        var edges: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
        for (selected, 0..) |j, ji| {
            if (findJoin(parent, ji) != root) continue;
            member_joins += 1;
            try edges.appendSlice(a, j.members);
        }
        if (member_joins < 2) continue;
        if (try unionComplete(a, graph, edges.items)) {
            std.mem.sort(pb.EdgeId, edges.items, {}, std.sort.asc(pb.EdgeId));
            try out.append(a, try edges.toOwnedSlice(a));
        } else edges.deinit(a);
    }
    return out.toOwnedSlice(a);
}

fn directionOf(groups: []const pb.JoinGroup, id: pb.JoinGroupId) ?pb.JoinDirection {
    for (groups) |g| if (g.id == id) return g.direction;
    return null;
}

fn leafSetEqual(graph: sg.SemGraph, dir: pb.JoinDirection, xs: []const pb.EdgeId, ys: []const pb.EdgeId) bool {
    return leafSubset(graph, dir, xs, ys) and leafSubset(graph, dir, ys, xs);
}

fn leafSubset(graph: sg.SemGraph, dir: pb.JoinDirection, xs: []const pb.EdgeId, ys: []const pb.EdgeId) bool {
    for (xs) |xi| {
        const x = edgeById(graph, xi) orelse return false;
        const lx = if (dir == .in) x.from else x.to;
        const held = for (ys) |yi| {
            const y = edgeById(graph, yi) orelse return false;
            if ((if (dir == .in) y.from else y.to) == lx) break true;
        } else false;
        if (!held) return false;
    }
    return true;
}

fn unionComplete(a: std.mem.Allocator, graph: sg.SemGraph, members: []const pb.EdgeId) error{OutOfMemory}!bool {
    var srcs: std.ArrayListUnmanaged(pb.NodeId) = .empty;
    defer srcs.deinit(a);
    var tgts: std.ArrayListUnmanaged(pb.NodeId) = .empty;
    defer tgts.deinit(a);
    var pairs: std.ArrayListUnmanaged([2]pb.NodeId) = .empty;
    defer pairs.deinit(a);
    var style: ?u48 = null;
    for (members) |id| {
        const e = edgeById(graph, id) orelse return false;
        if (e.kind == .invisible or !sg.forwardOneWayHead(e)) return false;
        // Mixed stroke kind or head glyphs would restate a member's
        // declaration in a foreign style (mirrors realized's per-group gate).
        const key: u48 = (@as(u48, pb.edgeKindOrdinal(e.kind)) << 8) |
            (@as(u48, @intFromEnum(e.arrow_from)) << 4) | @intFromEnum(e.arrow_to);
        if (style) |st| {
            if (st != key) return false;
        } else style = key;
        try addUniqueNode(a, &srcs, e.from);
        try addUniqueNode(a, &tgts, e.to);
        var seen = false;
        for (pairs.items) |p| if (p[0] == e.from and p[1] == e.to) {
            seen = true;
        };
        if (!seen) try pairs.append(a, .{ e.from, e.to });
    }
    if (srcs.items.len <= 1 or tgts.items.len <= 1) return false;
    return pairs.items.len == srcs.items.len * tgts.items.len;
}

fn addUniqueNode(a: std.mem.Allocator, list: *std.ArrayListUnmanaged(pb.NodeId), v: pb.NodeId) error{OutOfMemory}!void {
    for (list.items) |x| if (x == v) return;
    try list.append(a, v);
}

fn findJoin(parent: []usize, i: usize) usize {
    var r = i;
    while (parent[r] != r) r = parent[r];
    return r;
}

fn uniteJoin(parent: []usize, i: usize, j: usize) void {
    const ri = findJoin(parent, i);
    const rj = findJoin(parent, j);
    if (ri != rj) parent[@max(ri, rj)] = @min(ri, rj);
}

/// The plan-wide clause of the closure law: an implied leaf pair may be
/// claimed by AT MOST ONE rail. Mutates `eff_of`/`closure_refused` in place.
///
/// Two rails may each assert a pair the graph declares and still fabricate
/// TOGETHER. `A---Z; B---Z` and `A---W; B---W` with `A---B` declared put two
/// crossbars over the SAME leaf columns, so a reader traces Z up A's column,
/// along crossbar one, down to... W — a Z—W relation no declaration covers.
/// The pair is what is spendable, so a second rail implying an already-claimed
/// pair refuses, and so does the first: neither may keep ink the other's
/// existence turned into a lie.
///
/// The over-refusal that ruling guards against is a fully declared clique,
/// where the clique edges are themselves stars. It is answered by realizing
/// the discharge instead of licensing it: a kept rail's backers become
/// co-realized, drawing no private ink, and an edge with no ink can carry no
/// trunk — so a candidate whose every member is another rail's discharge is
/// not a competing rail at all. The WIDER rail claims first (ties by group
/// rank), which is the reading that leaves the clique fused.
///
/// A refusal never revives a candidate an earlier claim subordinated: the
/// answer stays the one fewer rails would give, which can only under-fuse.
/// guarded-by: join_commit_test.zig "two rails asserting one declared pair both refuse"
fn reserve(
    a: std.mem.Allocator,
    eff_of: []?[]const pb.EdgeId,
    verdicts: []const ?rc.Verdict,
    closure_refused: []bool,
    report: ?*Report,
) error{OutOfMemory}!void {
    var order: std.ArrayListUnmanaged(usize) = .empty;
    for (verdicts, 0..) |verdict, gi| {
        if (verdict != null and eff_of[gi] != null) try order.append(a, gi);
    }
    std.mem.sort(usize, order.items, eff_of, widestFirst);

    for (order.items, 0..) |ri, rank| {
        if (eff_of[ri] == null) continue;
        for (order.items[rank + 1 ..]) |gi| {
            const eff = eff_of[gi] orelse continue;
            if (!allDischargedBy(verdicts[ri].?, eff)) continue;
            eff_of[gi] = null;
            closure_refused[gi] = true;
        }
    }

    const conflicted = try a.alloc(bool, eff_of.len);
    @memset(conflicted, false);
    for (order.items, 0..) |x, rank| {
        if (eff_of[x] == null) continue;
        for (order.items[rank + 1 ..]) |y| {
            if (eff_of[y] == null or !sharesPair(verdicts[x].?, verdicts[y].?)) continue;
            conflicted[x] = true;
            conflicted[y] = true;
        }
    }
    for (conflicted, 0..) |hit, gi| {
        if (!hit) continue;
        eff_of[gi] = null;
        closure_refused[gi] = true;
        // One group, one count. A SALVAGE was already counted by the per-rail
        // pass above (it refused part of its own rail); counting it again here
        // reports one more rail refused than the plan holds groups.
        // guarded-by: join_commit_test.zig "a salvaged rail that then loses its pair is one refusal, not two"
        const counted = if (verdicts[gi]) |v| v.outcome == .salvage else false;
        if (!counted) {
            if (report) |r| r.rail_closure_undeclared += 1;
        }
    }
}

/// Wider rails first, then by group rank — the deterministic claim order.
fn widestFirst(eff_of: []?[]const pb.EdgeId, x: usize, y: usize) bool {
    const nx = (eff_of[x] orelse &.{}).len;
    const ny = (eff_of[y] orelse &.{}).len;
    return if (nx == ny) x < y else nx > ny;
}

/// Every one of `members` is a declaration the verdict's rail discharges —
/// so all of them are co-realized by that rail's crossbar and none of them
/// can carry a trunk of its own.
fn allDischargedBy(verdict: rc.Verdict, members: []const pb.EdgeId) bool {
    for (members) |member| {
        var found = false;
        for (verdict.discharges) |d| {
            if (d.backer == member) found = true;
        }
        if (!found) return false;
    }
    return true;
}

/// The two rails assert one and the same unordered leaf pair. `pair` is
/// already normalized low-id first by the closure law.
fn sharesPair(x: rc.Verdict, y: rc.Verdict) bool {
    for (x.discharges) |dx| {
        for (y.discharges) |dy| {
            if (dx.pair[0] == dy.pair[0] and dx.pair[1] == dy.pair[1]) return true;
        }
    }
    return false;
}

/// Project one provisionally eligible group into the closure law's own
/// vocabulary and ask it. Members carry the LEAF endpoint (the one that is
/// not the pivot); every other declared non-self edge is a candidate backer.
fn closureVerdict(
    a: std.mem.Allocator,
    graph: sg.SemGraph,
    group: pb.JoinGroup,
    eff: []const pb.EdgeId,
    piece_scope: bool,
) error{OutOfMemory}!rc.Verdict {
    const members = try a.alloc(rc.Member, eff.len);
    for (eff, members) |id, *m| {
        const edge = edgeById(graph, id) orelse return .{ .outcome = .untouched, .members = eff };
        m.* = .{
            .edge = id,
            .leaf = if (group.direction == .out) edge.to else edge.from,
            .kind = pb.edgeKindOrdinal(edge.kind),
            .arrow_free = undecorated(edge),
        };
    }
    var backers: std.ArrayListUnmanaged(rc.Backer) = .empty;
    for (graph.edges) |edge| {
        if (edge.from == edge.to or containsEdge(eff, edge.id)) continue;
        // In a piece, a born-synthetic edge (placement stand-in for a
        // cross-border relation) is not a declaration and may back nothing.
        if (piece_scope and edge.origin == sg.SENTINEL) continue;
        try backers.append(a, .{
            .edge = edge.id,
            .a = edge.from,
            .b = edge.to,
            .kind = pb.edgeKindOrdinal(edge.kind),
            .arrow_free = undecorated(edge),
            .unlabeled = edge.label == null or edge.label.?.len == 0,
        });
    }
    return rc.decide(a, members, backers.items);
}

fn undecorated(edge: sg.Edge) bool {
    return sg.undecorated(edge);
}

fn containsEdge(edges: []const pb.EdgeId, edge: pb.EdgeId) bool {
    for (edges) |e| if (e == edge) return true;
    return false;
}

/// An all-independent(not_selected) disposition for a grouped endpoint (null
/// when the endpoint has no ≥2-member group). The terminal-layout builder.
fn independentOf(group: ?pb.JoinGroupId) ?pb.MembershipDisposition {
    const gid = group orelse return null;
    return .{ .independent = .{ .permission_group = gid, .reason = .not_selected } };
}

fn containsReversed(group: pb.JoinGroup, reversed_edges: []const pb.EdgeId) bool {
    for (group.members) |member| for (reversed_edges) |reversed| {
        if (member == reversed) return true;
    };
    return false;
}

/// The group's forward (non-layout-reversed) members, in canonical member
/// order (deterministic under edge-array permutation because `members` is
/// already canonical). Used as the trunk-eligible subset for a fan-IN group.
fn forwardSubset(a: std.mem.Allocator, members: []const pb.EdgeId, reversed_edges: []const pb.EdgeId) error{OutOfMemory}![]const pb.EdgeId {
    var out: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
    for (members) |m| {
        var rev = false;
        for (reversed_edges) |r| if (r == m) {
            rev = true;
        };
        if (!rev) try out.append(a, m);
    }
    return out.toOwnedSlice(a);
}

fn disposition(graph: sg.SemGraph, groups: []const pb.JoinGroup, selected_group: []const ?pb.RealizedJoinId, closure_refused: []const bool, selected_joins: []const pb.SelectedJoin, id: ?pb.JoinGroupId, reversed_edges: []const pb.EdgeId, edge: pb.EdgeId) ?pb.MembershipDisposition {
    const gid = id orelse return null;
    for (groups, 0..) |g, i| if (g.id == gid) {
        if (selected_group[i]) |jid| {
            // A committed trunk may carry only the forward subset; a reversed
            // member excluded from it takes an independent side entry.
            for (selected_joins) |sj| if (sj.id == jid) {
                for (sj.members) |mem| if (mem == edge) return .{ .selected = jid };
            };
            return .{ .independent = .{ .permission_group = gid, .reason = .not_selected } };
        }
        // A closure refusal must reach the member as `independent`: that
        // disposition is what unfuses it (per-member fan lanes in TD, a port of
        // its own in LR/RL). The null-disposition escape below is for a group
        // the reversal rule left ungrouped, never for a refused rail.
        // guarded-by: join_commit_test.zig "a reversed member does not hide a closure refusal behind a null disposition"
        if (!closure_refused[i] and containsReversed(g, reversed_edges) and !overlaps(groups, i) and styleCompatible(graph, g) and !hasDuplicateKey(graph, g)) return null;
        return .{ .independent = .{ .permission_group = gid, .reason = if (overlaps(groups, i)) .overlap_conflict else .not_selected } };
    };
    return null;
}

fn overlaps(groups: []const pb.JoinGroup, idx: usize) bool {
    for (groups, 0..) |other, oi| {
        if (oi == idx) continue;
        for (groups[idx].members) |edge| for (other.members) |candidate| {
            if (edge == candidate) return true;
        };
    }
    return false;
}

fn styleCompatible(graph: sg.SemGraph, group: pb.JoinGroup) bool {
    var first: ?sg.Edge = null;
    for (group.members) |id| {
        const edge = edgeById(graph, id) orelse return false;
        if (edge.kind == .invisible) return false;
        if (first) |f| {
            if (edge.kind != f.kind) return false;
            const arrow = if (group.direction == .out) edge.arrow_from else edge.arrow_to;
            const first_arrow = if (group.direction == .out) f.arrow_from else f.arrow_to;
            if (arrow != first_arrow) return false;
        } else first = edge;
    }
    return first != null;
}

fn hasDuplicateKey(graph: sg.SemGraph, group: pb.JoinGroup) bool {
    for (group.members, 0..) |id, i| {
        const edge = edgeById(graph, id) orelse return true;
        for (group.members[0..i]) |prev_id| {
            const prev = edgeById(graph, prev_id) orelse return true;
            if (edge.from == prev.from and edge.to == prev.to and edge.kind == prev.kind and
                edge.arrow_from == prev.arrow_from and edge.arrow_to == prev.arrow_to and labelsEqual(edge.label, prev.label)) return true;
        }
    }
    return false;
}

fn edgeById(graph: sg.SemGraph, id: pb.EdgeId) ?sg.Edge {
    for (graph.edges) |edge| if (edge.id == id) return edge;
    return null;
}

fn labelsEqual(a: ?[]const u8, b: ?[]const u8) bool {
    const av = a orelse return b == null;
    return b != null and std.mem.eql(u8, av, b.?);
}

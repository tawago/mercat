//! Planner-side unit tests for realized.zig (P2v Step 4 vectors:
//! V-D-JOIN-SELECT, V-D-TRUNK predicate/plan halves, V-D-DUAL plan level,
//! V-D-IR-01/02/04). Aggregated into the test build from entry.zig's
//! `test {}` block. The §6.7 validator vectors and controlled hand-built
//! plans live in realized_test2.zig.
const std = @import("std");
const parse_mod = @import("../parse.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const planner = @import("permits.zig");
const jp = @import("realized.zig");
const select = @import("../select.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
// -- Hand-built graph/sketch helpers ----------------------------------------
const test_nodes = [_]sg.Node{
    node(0, "A"), node(1, "B"),   node(2, "C"), node(3, "D"),
    node(4, "E"), node(5, "Hub"), node(6, "X"),
};
fn node(id: sg.NodeId, raw_id: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw_id, .label = raw_id, .shape = .rect, .classes = &.{}, .cluster = null };
}
fn edge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return styled(id, from, to, .solid, .none, .filled, null);
}
fn styled(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId, kind: sg.EdgeKind, af: sg.ArrowEnd, at: sg.ArrowEnd, label: ?[]const u8) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = kind, .arrow_from = af, .arrow_to = at, .label = label };
}

fn graph(edges: []const sg.Edge) sg.SemGraph {
    return .{ .direction = .TD, .nodes = &test_nodes, .edges = edges, .clusters = &.{}, .classes = &.{}, .arena = null };
}

fn mapArrow(e: sg.ArrowEnd) sk.ArrowKind {
    return std.meta.stringToEnum(sk.ArrowKind, @tagName(e)).?;
}

const poly = [_]sk.Point{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 } };

fn pathFor(e: sg.Edge) sk.EdgePath {
    return .{
        .id = e.id,
        .from = e.from,
        .to = e.to,
        .polyline = &poly,
        .port_from = .{ .node = e.from, .side = .south, .offset = 0 },
        .port_to = .{ .node = e.to, .side = .north, .offset = 0 },
        .arrow_from = mapArrow(e.arrow_from),
        .arrow_to = mapArrow(e.arrow_to),
        .label = e.label,
        .kind = e.kind,
    };
}

fn tapFor(e: sg.Edge) sk.Tap {
    return .{ .edge = e.id, .node = e.to, .at = poly[0], .landing = poly[1], .label = e.label, .arrow = mapArrow(e.arrow_to) };
}

fn busbarFor(pivot: sg.NodeId, kind: sg.EdgeKind, role: sk.EdgeRole, taps: []const sk.Tap) sk.BusBar {
    return .{ .pivot = pivot, .stem = &poly, .rail = .{ poly[0], poly[1] }, .taps = taps, .kind = kind, .role = role };
}

fn sketchOf(edges: []const sk.EdgePath, busbars: []const sk.BusBar) sk.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
        .direction = .TD,
        .nodes = &.{},
        .clusters = &.{},
        .edges = edges,
        .busbars = busbars,
        .diagnostics = &.{},
        .budget = .{ .max_width = 120, .rung = 0 },
    };
}

fn paths(a: std.mem.Allocator, edges: []const sg.Edge) ![]sk.EdgePath {
    const out = try a.alloc(sk.EdgePath, edges.len);
    for (edges, out) |e, *p| p.* = pathFor(e);
    return out;
}

fn buildPlan(a: std.mem.Allocator, g: sg.SemGraph) !pb.JoinPermits {
    return (try planner.build(a, g, .joined)).plan;
}

/// The raw natural-rung candidate's realized plan for a parsed graph —
/// the production shape most vectors exercise.
fn realizeNatural(a: std.mem.Allocator, g: sg.SemGraph, plan: pb.JoinPermits, width: u32) !jp.Result {
    const set = try select.enumerateAll(a, g, &plan, true, width);
    for (set.merged) |cand| {
        if (cand.rung == .natural and cand.transform == .raw)
            return jp.realize(a, plan, cand.sketch, &.{});
    }
    return error.MissingNaturalCandidate;
}

fn realizeNaturalWithoutCommit(a: std.mem.Allocator, g: sg.SemGraph, plan: pb.JoinPermits, width: u32) !jp.Result {
    const set = try select.enumerateAll(a, g, &plan, true, width);
    for (set.merged) |cand| if (cand.rung == .natural and cand.transform == .raw) {
        var s = cand.sketch;
        s.joins = .{};
        return jp.realize(a, plan, s, &.{});
    };
    return error.MissingNaturalCandidate;
}

fn edgeIdByEnds(g: sg.SemGraph, from: []const u8, to: []const u8) sg.EdgeId {
    for (g.edges) |e| {
        if (std.mem.eql(u8, rawOf(g, e.from), from) and std.mem.eql(u8, rawOf(g, e.to), to)) return e.id;
    }
    unreachable;
}

fn rawOf(g: sg.SemGraph, id: sg.NodeId) []const u8 {
    for (g.nodes) |n| if (n.id == id) return n.raw_id;
    unreachable;
}

fn verdictOf(res: jp.Result, plan: pb.JoinPermits, dir: pb.JoinDirection, pivot: sg.NodeId) jp.GroupVerdict {
    for (plan.groups, res.report.verdicts) |g, v| {
        if (g.direction == dir and g.pivot == pivot) return v;
    }
    unreachable;
}

/// Canonical serialization: numeric ids mapped to canonical ranks (edges:
/// position in plan.memberships; groups: array rank) and node raw_id
/// bytes, so two writer orders of one graph serialize identically.
fn planBytes(a: std.mem.Allocator, g: sg.SemGraph, plan: pb.JoinPermits, res: jp.Result) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (plan.groups, res.report.verdicts, 0..) |grp, v, rank| {
        try appendf(a, &out, "v:{d}:{s}:{s}:{s}:{s}:{s}:{}:{d}\n", .{
            rank,                @tagName(grp.direction),
            rawOf(g, grp.pivot), @tagName(v.clause),
            pb.tagName(v.tag),   if (v.trunk_detail) |t| pb.tagName(t) else "-",
            v.duplicate_pair,    v.proposal_count,
        });
    }
    for (res.report.proposals, res.report.multiplicity) |p, mult| {
        try appendf(a, &out, "p:{d}:{d}:{d}:", .{ p.id, groupRank(plan, p.permission_group), mult });
        for (p.members) |e| try appendf(a, &out, "{d},", .{edgeRankOf(plan, e)});
        try out.append(a, '\n');
    }
    for (res.plan.selected_joins) |join| {
        try appendf(a, &out, "s:{d}:{d}:{d}:", .{ join.id, groupRank(plan, join.permission_group), join.proposal });
        for (join.members) |e| try appendf(a, &out, "{d},", .{edgeRankOf(plan, e)});
        try out.append(a, '\n');
    }
    for (res.plan.rejected_proposals) |pid| try appendf(a, &out, "r:{d}\n", .{pid});
    for (res.plan.memberships, 0..) |rm, rank| {
        try appendf(a, &out, "m:{d}:", .{rank});
        try dispBytes(a, &out, plan, rm.source);
        try out.append(a, ':');
        try dispBytes(a, &out, plan, rm.target);
        try out.append(a, '\n');
    }
    for (res.plan.conflicts) |c| {
        try appendf(a, &out, "c:{d}:{d}:", .{ groupRank(plan, c.groups[0]), groupRank(plan, c.groups[1]) });
        for (c.shared_edges) |e| try appendf(a, &out, "{d},", .{edgeRankOf(plan, e)});
        try out.append(a, ':');
        for (c.proposals) |pid| try appendf(a, &out, "{d},", .{pid});
        try appendf(a, &out, ":{s}\n", .{@tagName(c.reason)});
    }
    for (res.plan.terminal_ports) |tp| {
        try appendf(a, &out, "t:{s}:{d}:{s}:{d}\n", .{ rawOf(g, tp.node), edgeRankOf(plan, tp.edge), @tagName(tp.endpoint_side), tp.port });
    }
    return out.toOwnedSlice(a);
}

fn appendf(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
    try out.appendSlice(a, try std.fmt.allocPrint(a, fmt, args));
}

fn dispBytes(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), plan: pb.JoinPermits, disp: ?pb.MembershipDisposition) !void {
    const d = disp orelse return out.append(a, '-');
    switch (d) {
        .selected => |jid| try appendf(a, out, "sel{d}", .{jid}),
        .independent => |ind| try appendf(a, out, "ind{d}.{s}", .{ groupRank(plan, ind.permission_group), @tagName(ind.reason) }),
    }
}

fn groupRank(plan: pb.JoinPermits, id: pb.JoinGroupId) usize {
    return jp.groupIndexById(plan.groups, id).?;
}

fn edgeRankOf(plan: pb.JoinPermits, e: pb.EdgeId) usize {
    return jp.edgeRank(plan.memberships, e).?;
}

// -- Production-path vectors -------------------------------------------------

test "V-D-JOIN-SELECT-01: complete fan-out busbar realizes one selected join with full provenance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parse_mod.parse(a, "flowchart TD\n  Hub --> A\n  Hub --> B\n  Hub --> C\n");
    const plan = try buildPlan(a, g);

    const res = try realizeNatural(a, g, plan, 80);
    try expect(!res.report.skipped_clustered);
    try expectEqual(@as(usize, 1), res.plan.selected_joins.len);
    try expectEqual(@as(usize, 3), res.plan.selected_joins[0].members.len);
    try expectEqual(jp.GroupClause.selected, res.report.verdicts[0].clause);
    try expectEqual(pb.DiagnosticTag.join_select_selected, res.report.verdicts[0].tag);
    try expectEqual(@as(usize, 3), res.plan.memberships.len);
    for (res.plan.memberships) |rm| {
        try expect(rm.source != null and rm.source.? == .selected);
        try expect(rm.target == null);
    }
    try expectEqual(@as(usize, 6), res.plan.terminal_ports.len);
    for (res.plan.terminal_ports) |tp| try expectEqual(@as(u32, 0), tp.port);
}

test "V-D-JOIN-SELECT-02: no trunk proposal leaves every member independent(not_selected)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // V-D-POLICY-06: permission alone is not a proposal obligation.
    const g = try parse_mod.parse(a, "flowchart LR\n  Hub --> A\n  Hub --> B\n");
    const plan = try buildPlan(a, g);

    const res = try realizeNaturalWithoutCommit(a, g, plan, 80);
    try expectEqual(@as(usize, 0), res.plan.selected_joins.len);
    try expectEqual(jp.GroupClause.no_proposal, res.report.verdicts[0].clause);
    try expectEqual(pb.DiagnosticTag.join_select_independent_not_selected, res.report.verdicts[0].tag);
    for (res.plan.memberships) |rm| {
        try expect(rm.source != null);
        try expectEqual(pb.IndependentReason.not_selected, rm.source.?.independent.reason);
    }
}

test "V-D-DUAL-05: a dual edge's two permission groups are distinct records with distinct directions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parse_mod.parse(a, "flowchart TD\n  S --> X\n  S --> A\n  B --> X\n");
    const plan = try buildPlan(a, g);
    for (plan.memberships) |m| {
        if (m.source_group != null and m.target_group != null) {
            try expect(m.source_group.? != m.target_group.?);
            const sgrp = plan.groups[groupRank(plan, m.source_group.?)];
            const tgrp = plan.groups[groupRank(plan, m.target_group.?)];
            try expect(sgrp.direction == .out and tgrp.direction == .in);
        }
    }
}

test "V-D-JOIN-SELECT-07: partial proposal fails clause (c) first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Hub -> {A..E}; the candidate proposes a trunk for {A,B,C} only.
    const edges = [_]sg.Edge{ edge(0, 5, 0), edge(1, 5, 1), edge(2, 5, 2), edge(3, 5, 3), edge(4, 5, 4) };
    const g = graph(&edges);
    const plan = try buildPlan(a, g);
    const taps = [_]sk.Tap{ tapFor(edges[0]), tapFor(edges[1]), tapFor(edges[2]) };
    const bbs = [_]sk.BusBar{busbarFor(5, .solid, .fan_out_rail, &taps)};
    const s = sketchOf(try paths(a, edges[3..]), &bbs);

    const res = try jp.realize(a, plan, s, &.{});
    try expectEqual(jp.GroupClause.incomplete, res.report.verdicts[0].clause);
    try expectEqual(@as(usize, 0), res.plan.selected_joins.len);
    try expectEqual(@as(usize, 1), res.plan.rejected_proposals.len);
    try expectEqual(@as(usize, 1), res.report.proposals.len);
    for (res.plan.memberships) |rm| {
        try expectEqual(pb.IndependentReason.not_selected, rm.source.?.independent.reason);
    }
}

test "V-D-JOIN-SELECT-08: plan serialization is byte-identical under edge and sketch permutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // V-03's topology hand-built in two array orders (ids preserved).
    const ordered = [_]sg.Edge{ edge(10, 0, 2), edge(11, 0, 3), edge(12, 1, 3) };
    const shuffled = [_]sg.Edge{ ordered[2], ordered[0], ordered[1] };
    const g1 = graph(&ordered);
    const g2 = graph(&shuffled);
    const p1 = try buildPlan(a, g1);
    const p2 = try buildPlan(a, g2);
    const paths2 = try paths(a, &shuffled);
    const r1 = try jp.realize(a, p1, sketchOf(try paths(a, &ordered), &.{}), &.{});
    const r2 = try jp.realize(a, p2, sketchOf(paths2, &.{}), &.{});

    try std.testing.expectEqualStrings(
        try planBytes(a, g1, p1, r1),
        try planBytes(a, g2, p2, r2),
    );
}

test "V-D-JOIN-SELECT-09: mixed member kinds fail clause (e) deterministically under member permutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src1 = "flowchart TD\n  Hub\n  A\n  B\n  Hub --> A\n  Hub -.-> B\n";
    const src2 = "flowchart TD\n  Hub\n  A\n  B\n  Hub -.-> B\n  Hub --> A\n";
    var bytes: [2][]const u8 = undefined;
    for ([2][]const u8{ src1, src2 }, 0..) |src, i| {
        const g = try parse_mod.parse(a, src);
        const plan = try buildPlan(a, g);
        const res = try realizeNatural(a, g, plan, 80);
        const v = res.report.verdicts[0];
        try expectEqual(jp.GroupClause.style, v.clause);
        try expectEqual(pb.DiagnosticTag.join_select_independent_not_selected, v.tag);
        try expectEqual(pb.DiagnosticTag.trunk_member_style_mixed, v.trunk_detail.?);
        try expectEqual(@as(usize, 0), res.plan.selected_joins.len);
        bytes[i] = try planBytes(a, g, plan, res);
    }
    try std.testing.expectEqualStrings(bytes[0], bytes[1]);
}

test "V-D-JOIN-SELECT-13: proposal multiplicity blocks realization, byte-identical under enumeration swap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(0, 5, 0), edge(1, 5, 1), edge(2, 5, 2) };
    const g = graph(&edges);
    const plan = try buildPlan(a, g);
    const taps = [_]sk.Tap{ tapFor(edges[0]), tapFor(edges[1]), tapFor(edges[2]) };
    const bb = busbarFor(5, .solid, .fan_out_rail, &taps);
    // TWO complete trunk proposals for FO-Hub (distinct busbar entries,
    // identical member-set key → one multiplicity-counted entry).
    const two = [_]sk.BusBar{ bb, bb };
    const res = try jp.realize(a, plan, sketchOf(&.{}, &two), &.{});
    try expectEqual(jp.GroupClause.multiplicity, res.report.verdicts[0].clause);
    try expectEqual(pb.DiagnosticTag.join_select_proposal_multiplicity_blocked, res.report.verdicts[0].tag);
    try expectEqual(@as(u32, 2), res.report.verdicts[0].proposal_count);
    try expectEqual(@as(usize, 1), res.report.proposals.len);
    try expectEqual(@as(u32, 2), res.report.multiplicity[0]);
    try expectEqual(@as(usize, 0), res.plan.selected_joins.len);
    try expectEqual(@as(usize, 1), res.plan.rejected_proposals.len);
    for (res.plan.memberships) |rm| {
        try expectEqual(pb.IndependentReason.not_selected, rm.source.?.independent.reason);
    }
    // Proposal-enumeration swap (busbar array order) → byte-identical.
    const swapped = [_]sk.BusBar{ two[1], two[0] };
    const res2 = try jp.realize(a, plan, sketchOf(&.{}, &swapped), &.{});
    try std.testing.expectEqualStrings(
        try planBytes(a, g, plan, res),
        try planBytes(a, g, plan, res2),
    );
}

// -- V-D-TRUNK predicate/plan halves ------------------------------------------

test "V-D-TRUNK-01/02/03/04: clause (e) sub-clauses fire first-fail in frozen order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 01: all-solid arrowless-pivot fan-out is style-compatible: with no
    // proposal the first failure is clause (f), never (e).
    const ok = [_]sg.Edge{ edge(0, 5, 0), edge(1, 5, 1), edge(2, 5, 2), edge(3, 5, 3), edge(4, 5, 4) };
    var g = graph(&ok);
    var res = try jp.realize(a, try buildPlan(a, g), sketchOf(try paths(a, &ok), &.{}), &.{});
    try expectEqual(jp.GroupClause.no_proposal, res.report.verdicts[0].clause);
    try expect(res.report.verdicts[0].trunk_detail == null);

    // 02: two solid + one dotted → (e)(b) trunk_member_style_mixed.
    const mixed = [_]sg.Edge{ edge(0, 5, 0), edge(1, 5, 1), styled(2, 5, 2, .dotted, .none, .filled, null) };
    g = graph(&mixed);
    res = try jp.realize(a, try buildPlan(a, g), sketchOf(try paths(a, &mixed), &.{}), &.{});
    try expectEqual(pb.DiagnosticTag.trunk_member_style_mixed, res.report.verdicts[0].trunk_detail.?);

    // 03: fan-in with one invisible member, visible members ARROWLESS so
    // sub-clause (a) is isolated → exactly trunk_member_invisible.
    const invis = [_]sg.Edge{
        styled(0, 0, 6, .solid, .none, .none, null),
        styled(1, 1, 6, .solid, .none, .none, null),
        styled(2, 2, 6, .invisible, .none, .none, null),
    };
    g = graph(&invis);
    res = try jp.realize(a, try buildPlan(a, g), sketchOf(try paths(a, &invis), &.{}), &.{});
    try expectEqual(pb.DiagnosticTag.trunk_member_invisible, res.report.verdicts[0].trunk_detail.?);

    // 04: all solid, MIXED pivot-side arrow_from → (e)(c).
    const pivot_arrow = [_]sg.Edge{ edge(0, 5, 0), edge(1, 5, 1), styled(2, 5, 2, .solid, .filled, .filled, null) };
    g = graph(&pivot_arrow);
    res = try jp.realize(a, try buildPlan(a, g), sketchOf(try paths(a, &pivot_arrow), &.{}), &.{});
    try expectEqual(jp.GroupClause.style, res.report.verdicts[0].clause);
    try expectEqual(pb.DiagnosticTag.trunk_pivot_side_arrow, res.report.verdicts[0].trunk_detail.?);
}

// V-D-TRUNK-06/08/10 live in realized_test2.zig (500-line cap balance).

// -- V-D-IR vectors -----------------------------------------------------------

test "V-D-IR-01: winner joins artifact survives selection to the entry boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parse_mod.parse(a, "flowchart TD\n  Hub --> A\n  Hub --> B\n  Hub --> C\n");
    const built = try planner.build(a, g, .joined);

    // The production call path: choose() returns the envelope entry.zig
    // keeps; its joins must arrive populated, not recomputed after.
    const result = try select.choose(a, g, &built.plan, true, 80, false, false);
    try expectEqual(@as(usize, 3), result.sketch.joins.memberships.len);
    try expectEqual(@as(usize, 1), result.sketch.joins.selected_joins.len);
    try expectEqual(@as(usize, 6), result.sketch.joins.terminal_ports.len);
}

test "V-D-IR-02: motif_pack candidate is off the identity path and keeps an empty plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parse_mod.parse(a, "flowchart TD\n  A --> B1 --> C1\n  A --> B2 --> C2\n");
    const plan = try buildPlan(a, g);
    const set = try select.enumerateAll(a, g, &plan, true, 80);

    var saw_raw = false;
    var saw_packed = false;
    for (set.merged) |cand| {
        const res = try jp.realize(a, plan, cand.sketch, &.{});
        if (cand.transform == .raw) {
            try expect(!res.report.skipped_clustered);
            try expectEqual(@as(usize, 4), res.plan.memberships.len);
            for (res.report.proposals) |p| {
                switch (p.candidate_geometry) {
                    .busbar => |idx| try expect(idx < cand.sketch.busbars.len),
                    .edge_path => |idx| try expect(idx < cand.sketch.edges.len),
                }
            }
            saw_raw = true;
        } else if (cand.transform == .motif_pack) {
            // Packed sketches remain outside the flat identity path.
            try expect(cand.sketch.clusters.len > 0);
            try expect(res.report.skipped_clustered);
            try expectEqual(@as(usize, 0), res.plan.memberships.len);
            try expectEqual(@as(usize, 0), res.plan.selected_joins.len);
            saw_packed = true;
        }
    }
    try expect(saw_raw and saw_packed);
}

test "V-D-IR-04: JoinPermits and RealizedJoins byte-identical across edge orders and writer orders" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sources = [_][]const u8{
        "flowchart TD\n  H --> A\n  H --> B\n  H --> C\n  H --> D\n",
        "flowchart TD\n  H --> D\n  H --> C\n  H --> B\n  H --> A\n",
        "flowchart TD\n  A[A]\n  B[B]\n  C[C]\n  D[D]\n  H --> A\n  H --> B\n  H --> C\n  H --> D\n",
        "flowchart TD\n  D[D]\n  C[C]\n  B[B]\n  A[A]\n  H --> A\n  H --> B\n  H --> C\n  H --> D\n",
    };
    var first: ?[]const u8 = null;
    for (sources) |src| {
        const g = try parse_mod.parse(a, src);
        const plan = try buildPlan(a, g);
        const res = try realizeNatural(a, g, plan, 100);
        const bytes = try planBytes(a, g, plan, res);
        if (first) |f| {
            try std.testing.expectEqualStrings(f, bytes);
        } else first = bytes;
    }
}

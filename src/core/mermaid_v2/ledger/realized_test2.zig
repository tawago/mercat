//! §6.7 validator vectors + controlled hand-built plans for realized_
//! validate.zig (P2v Step 4: V-D-JOIN-SELECT-04/06/12, V-D-DUAL-01/02 and
//! the never-both reject, the N5 mesh-legality pin, per-bullet corruption
//! rejection, and the planner-output-validates-clean property). Split
//! from realized_test.zig for the 500-line cap; aggregated into the test
//! build from entry.zig's `test {}` block.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const planner = @import("permits.zig");
const jp = @import("realized.zig");
const jpv = @import("invariants.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const test_nodes = [_]sg.Node{
    node(0, "S1"), node(1, "S2"), node(2, "T1"), node(3, "T2"),
    node(4, "S"),  node(5, "X"),  node(6, "A"),  node(7, "B"),
    node(8, "Hub"), node(9, "C"), node(10, "D"), node(11, "E"),
};

pub fn node(id: sg.NodeId, raw_id: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw_id, .label = raw_id, .shape = .rect, .classes = &.{}, .cluster = null };
}

pub fn edge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

pub fn graph(edges: []const sg.Edge) sg.SemGraph {
    return .{ .direction = .TD, .nodes = &test_nodes, .edges = edges, .clusters = &.{}, .classes = &.{}, .arena = null };
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
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = e.label,
        .kind = e.kind,
    };
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

pub fn buildPlan(a: std.mem.Allocator, g: sg.SemGraph) !pb.JoinPermits {
    return (try planner.build(a, g, .joined)).plan;
}

pub fn groupIdOf(plan: pb.JoinPermits, dir: pb.JoinDirection, pivot: sg.NodeId) pb.JoinGroupId {
    for (plan.groups) |g| if (g.direction == dir and g.pivot == pivot) return g.id;
    unreachable;
}

pub fn hasFinding(report: jpv.ValidationReport, tag: jpv.ValidationTag) bool {
    for (report.findings) |f| if (f.tag == tag) return true;
    return false;
}

/// Build a CONTROLLED one-side (or partial-member) plan: `sel_members` of
/// `sel_group` are selected into one join; every other membership is
/// independent(not_selected). Conflicts are recomputed complete per §6.5.
pub fn controlledPlan(
    a: std.mem.Allocator,
    plan: pb.JoinPermits,
    sel_group: pb.JoinGroupId,
    sel_members: []const pb.EdgeId,
) !struct { plan: pb.RealizedJoins, proposals: []const pb.JoinProposal } {
    const gi = jp.groupIndexById(plan.groups, sel_group).?;
    const dir = plan.groups[gi].direction;
    const proposals = try a.alloc(pb.JoinProposal, 1);
    proposals[0] = .{ .id = 0, .permission_group = sel_group, .members = sel_members, .candidate_geometry = .{ .busbar = 0 } };
    const joins = try a.alloc(pb.SelectedJoin, 1);
    joins[0] = .{ .id = 0, .proposal = 0, .permission_group = sel_group, .members = sel_members };

    const rms = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
    for (plan.memberships, rms) |m, *rm| {
        rm.* = .{ .edge = m.edge, .source = disp(m.edge, m.source_group, sel_group, .out, dir, sel_members), .target = disp(m.edge, m.target_group, sel_group, .in, dir, sel_members) };
    }

    var conflicts: std.ArrayListUnmanaged(pb.JoinConflict) = .empty;
    for (plan.groups, 0..) |ga, i| {
        for (plan.groups[i + 1 ..]) |gb| {
            var shared: std.ArrayListUnmanaged(pb.EdgeId) = .empty;
            for (ga.members) |e| {
                for (gb.members) |o| if (o == e) try shared.append(a, e);
            }
            if (shared.items.len == 0) continue;
            try conflicts.append(a, .{
                .groups = .{ ga.id, gb.id },
                .shared_edges = try shared.toOwnedSlice(a),
                .proposals = &.{},
                .reason = .overlapping_permissions,
            });
        }
    }
    return .{
        .plan = .{
            .selected_joins = joins,
            .memberships = rms,
            .conflicts = try conflicts.toOwnedSlice(a),
        },
        .proposals = proposals,
    };
}

fn disp(
    e: pb.EdgeId,
    group: ?pb.JoinGroupId,
    sel_group: pb.JoinGroupId,
    end: pb.JoinDirection,
    sel_dir: pb.JoinDirection,
    sel_members: []const pb.EdgeId,
) ?pb.MembershipDisposition {
    const gid = group orelse return null;
    if (gid == sel_group and end == sel_dir and jp.containsEdge(sel_members, e))
        return .{ .selected = 0 };
    return .{ .independent = .{ .permission_group = gid, .reason = .not_selected } };
}

// -- Controlled one-side and partial plans through the §6.7 validator ---------

// Shared topologies.
pub const twox2 = [_]sg.Edge{ edge(0, 0, 2), edge(1, 0, 3), edge(2, 1, 3) }; // S1→T1, S1→T2, S2→T2
pub const dual = [_]sg.Edge{ edge(0, 4, 5), edge(1, 4, 6), edge(2, 7, 5) }; // S→X, S→A, B→X
pub const fan5 = [_]sg.Edge{ edge(0, 8, 6), edge(1, 8, 7), edge(2, 8, 9), edge(3, 8, 10), edge(4, 8, 11) };

test "V-D-JOIN-SELECT-04 / V-D-DUAL-01: controlled one-side incomplete-2x2 plans pass §6.6 step 3 validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = graph(&twox2);
    const plan = try buildPlan(a, g);
    const fo = groupIdOf(plan, .out, 0);
    const fi = groupIdOf(plan, .in, 3);

    // (i) source-side FO-S1 selected; (ii) target-side FI-T2 selected.
    // Both are CONTROLLED vectors only — the production result for this
    // topology is NEITHER (V-D-JOIN-SELECT-03) — but each must validate
    // clean at plan level (no both-sides selection, dispositions total).
    for ([2]pb.JoinGroupId{ fo, fi }) |sel| {
        const members = plan.groups[jp.groupIndexById(plan.groups, sel).?].members;
        const built = try controlledPlan(a, plan, sel, members);
        const report = try jpv.validate(a, plan, built.plan, built.proposals);
        try expect(report.valid());
    }
}

test "V-D-JOIN-SELECT-06 / V-D-DUAL-02: controlled one-side dual-chain plans validate clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = graph(&dual);
    const plan = try buildPlan(a, g);
    for ([2]pb.JoinGroupId{ groupIdOf(plan, .out, 4), groupIdOf(plan, .in, 5) }) |sel| {
        const members = plan.groups[jp.groupIndexById(plan.groups, sel).?].members;
        const built = try controlledPlan(a, plan, sel, members);
        const report = try jpv.validate(a, plan, built.plan, built.proposals);
        try expect(report.valid());
    }
}

test "V-D-JOIN-SELECT-12: controlled partial-member subset plan validates clean, never a production result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = graph(&fan5);
    const plan = try buildPlan(a, g);
    const fo = groupIdOf(plan, .out, 8);
    // Subset {A,B,C} selected; D/E independent with their own Hub ports.
    const subset = plan.groups[jp.groupIndexById(plan.groups, fo).?].members[0..3];
    const built = try controlledPlan(a, plan, fo, subset);
    const report = try jpv.validate(a, plan, built.plan, built.proposals);
    try expect(report.valid());
    // The production planner never emits this subset automatically: with
    // the same subset proposed as a busbar, clause (c) rejects it whole.
    // guarded-by: realized_test.zig "V-D-JOIN-SELECT-07: partial proposal fails clause (c) first"
}

test "V-D-DUAL-04 analogue: selecting one dual edge at both endpoint sides is rejected by the validator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = graph(&dual);
    const plan = try buildPlan(a, g);
    const fo = groupIdOf(plan, .out, 4);
    const fi = groupIdOf(plan, .in, 5);
    const fo_members = plan.groups[jp.groupIndexById(plan.groups, fo).?].members;
    const fi_members = plan.groups[jp.groupIndexById(plan.groups, fi).?].members;

    const proposals = try a.alloc(pb.JoinProposal, 2);
    proposals[0] = .{ .id = 0, .permission_group = fo, .members = fo_members, .candidate_geometry = .{ .busbar = 0 } };
    proposals[1] = .{ .id = 1, .permission_group = fi, .members = fi_members, .candidate_geometry = .{ .busbar = 1 } };
    const joins = try a.alloc(pb.SelectedJoin, 2);
    joins[0] = .{ .id = 0, .proposal = 0, .permission_group = fo, .members = fo_members };
    joins[1] = .{ .id = 1, .proposal = 1, .permission_group = fi, .members = fi_members };
    const rms = try a.alloc(pb.RealizedEdgeMembership, plan.memberships.len);
    for (plan.memberships, rms) |m, *rm| rm.* = .{
        .edge = m.edge,
        .source = if (m.source_group) |gid| .{ .selected = if (gid == fo) 0 else 1 } else null,
        .target = if (m.target_group) |gid| .{ .selected = if (gid == fi) 1 else 0 } else null,
    };
    const bad: pb.RealizedJoins = .{ .selected_joins = joins, .memberships = rms };
    const report = try jpv.validate(a, plan, bad, proposals);
    try expect(hasFinding(report, .selected_both_sides));
}

// -- V-D-TRUNK hand-built plan halves (moved from realized_test.zig) ----------

test "V-D-TRUNK-06: duplicate (from,to) pair is blocked by the item-1 duplicate-key rule with the pair inventory tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dup = [_]sg.Edge{ edge(0, 8, 6), edge(1, 8, 6), edge(2, 8, 7) };
    const g = graph(&dup);
    const plan = try buildPlan(a, g);
    const res = try jp.realize(a, plan, sketchOf(try paths(a, &dup), &.{}), &.{});
    // Both containing groups (FO-Hub and FI-A) blocked pre-clause; the
    // overlap conflict between them is still retained per §6.5.
    for (res.report.verdicts) |v| {
        try expectEqual(jp.GroupClause.duplicate_key, v.clause);
        try expectEqual(pb.DiagnosticTag.join_select_duplicate_key_blocked, v.tag);
        try expect(v.duplicate_pair);
    }
    try expectEqual(@as(usize, 1), res.plan.conflicts.len);
    try expectEqual(@as(usize, 2), res.plan.conflicts[0].shared_edges.len);
    try expectEqual(@as(usize, 0), res.plan.selected_joins.len);
    for (res.plan.memberships) |rm| {
        if (rm.source) |d| try expectEqual(pb.IndependentReason.not_selected, d.independent.reason);
    }
    try expect((try jpv.validate(a, plan, res.plan, res.report.proposals)).valid());
}

test "V-D-TRUNK-08: no automatic partial trunk — a subset proposal is rejected whole via clause (c)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const four = [_]sg.Edge{
        edge(0, 8, 6), edge(1, 8, 7), edge(2, 8, 9),
        .{ .id = 3, .from = 8, .to = 10, .kind = .dotted, .arrow_from = .none, .arrow_to = .filled, .label = null },
    };
    const g = graph(&four);
    const plan = try buildPlan(a, g);
    // A candidate proposing only the 3 style-compatible members: clause
    // (c) COMPLETE fails first — the whole group routes independently.
    var taps: [3]sk.Tap = undefined;
    for (four[0..3], &taps) |e, *t| {
        t.* = .{ .edge = e.id, .node = e.to, .at = poly[0], .landing = poly[1], .arrow = .filled };
    }
    const bbs = [_]sk.BusBar{.{ .pivot = 8, .stem = &poly, .rail = .{ poly[0], poly[1] }, .taps = &taps, .kind = .solid, .role = .fan_out_rail }};
    const res = try jp.realize(a, plan, sketchOf(try paths(a, four[3..]), &bbs), &.{});
    try expectEqual(jp.GroupClause.incomplete, res.report.verdicts[0].clause);
    try expectEqual(@as(usize, 0), res.plan.selected_joins.len);
    try expectEqual(@as(usize, 1), res.plan.rejected_proposals.len);
}

test "V-D-TRUNK-10: uniform directed fan-in busbar proposal realizes one group-owned join" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fanin = [_]sg.Edge{ edge(0, 0, 5), edge(1, 1, 5), edge(2, 6, 5), edge(3, 7, 5) };
    const g = graph(&fanin);
    const plan = try buildPlan(a, g);
    var taps: [4]sk.Tap = undefined;
    for (fanin, &taps) |e, *t| {
        t.* = .{ .edge = e.id, .node = e.from, .at = poly[0], .landing = poly[1], .arrow = .none };
    }
    const bbs = [_]sk.BusBar{.{ .pivot = 5, .stem = &poly, .rail = .{ poly[0], poly[1] }, .taps = &taps, .kind = .solid, .role = .fan_in_rail }};
    const res = try jp.realize(a, plan, sketchOf(&.{}, &bbs), &.{});
    try expectEqual(@as(usize, 1), res.plan.selected_joins.len);
    try expectEqual(@as(usize, 4), res.plan.selected_joins[0].members.len);
    for (res.plan.memberships) |rm| {
        try expect(rm.target != null and rm.target.? == .selected);
        try expect(rm.source == null);
    }
    try expect((try jpv.validate(a, plan, res.plan, res.report.proposals)).valid());
}

// -- Planner output always validates clean -------------------------------------

test "6.7: every planner output validates clean across the step-4 vector shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dup = [_]sg.Edge{ edge(0, 8, 6), edge(1, 8, 6), edge(2, 8, 7) };
    const cases = [_][]const sg.Edge{ &twox2, &dual, &fan5, &dup };
    for (cases) |edges| {
        const g = graph(edges);
        const plan = try buildPlan(a, g);
        const res = try jp.realize(a, plan, sketchOf(try paths(a, edges), &.{}), &.{});
        const report = try jpv.validate(a, plan, res.plan, res.report.proposals);
        try expect(report.valid());
    }

    // Busbar-realized fan and partial/multiplicity proposal shapes.
    var taps: [3]sk.Tap = undefined;
    for (fan5[0..3], &taps) |e, *t| {
        t.* = .{ .edge = e.id, .node = e.to, .at = poly[0], .landing = poly[1], .arrow = .filled };
    }
    const partial_bb = [_]sk.BusBar{.{ .pivot = 8, .stem = &poly, .rail = .{ poly[0], poly[1] }, .taps = &taps, .kind = .solid, .role = .fan_out_rail }};
    const g5 = graph(&fan5);
    const plan5 = try buildPlan(a, g5);
    const partial = try jp.realize(a, plan5, sketchOf(try paths(a, fan5[3..]), &partial_bb), &.{});
    try expect((try jpv.validate(a, plan5, partial.plan, partial.report.proposals)).valid());

    const fan3 = fan5[0..3];
    const g3 = graph(fan3);
    const plan3 = try buildPlan(a, g3);
    const complete_bb = [_]sk.BusBar{ partial_bb[0], partial_bb[0] };
    const multi = try jp.realize(a, plan3, sketchOf(&.{}, &complete_bb), &.{});
    try expect((try jpv.validate(a, plan3, multi.plan, multi.report.proposals)).valid());
    const realized = try jp.realize(a, plan3, sketchOf(&.{}, complete_bb[0..1]), &.{});
    try expectEqual(@as(usize, 1), realized.plan.selected_joins.len);
    try expect((try jpv.validate(a, plan3, realized.plan, realized.report.proposals)).valid());
}

// -- Corruption rejection per §6.7 bullet ---------------------------------------

test "6.7: corrupted plans are rejected bullet by bullet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = graph(&twox2);
    const plan = try buildPlan(a, g);
    const res = try jp.realize(a, plan, sketchOf(try paths(a, &twox2), &.{}), &.{});

    // Bullet 1/7: a dropped membership record.
    var p = res.plan;
    p.memberships = res.plan.memberships[0 .. res.plan.memberships.len - 1];
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .membership_set_mismatch));

    // Bullet 1: canonical order violated.
    const swapped = try a.dupe(pb.RealizedEdgeMembership, res.plan.memberships);
    std.mem.swap(pb.RealizedEdgeMembership, &swapped[0], &swapped[1]);
    p = res.plan;
    p.memberships = swapped;
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .membership_set_mismatch));

    // Bullet 1: a group-owned endpoint with no disposition.
    const nulled = try a.dupe(pb.RealizedEdgeMembership, res.plan.memberships);
    nulled[0].source = null;
    nulled[0].target = null;
    p = res.plan;
    p.memberships = nulled;
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .disposition_missing));

    // A disposition where no permission membership exists.
    const extra = try a.dupe(pb.RealizedEdgeMembership, res.plan.memberships);
    for (plan.memberships, extra) |m, *rm| {
        if (m.source_group == null) rm.source = .{ .independent = .{ .permission_group = 0, .reason = .not_selected } };
        if (m.target_group == null) rm.target = .{ .independent = .{ .permission_group = 0, .reason = .not_selected } };
    }
    p = res.plan;
    p.memberships = extra;
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .disposition_unexpected));

    // §6.5: erased or truncated conflicts.
    p = res.plan;
    p.conflicts = &.{};
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .conflict_missing));
    const short = try a.dupe(pb.JoinConflict, res.plan.conflicts);
    short[0].shared_edges = &.{};
    p = res.plan;
    p.conflicts = short;
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .conflict_shared_edges_wrong));

    // Proposal accounting: unknown rejected id / unaccounted proposal.
    p = res.plan;
    p.rejected_proposals = &.{99};
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .rejected_proposal_unknown));

    const g3 = graph(fan5[0..3]);
    const plan3 = try buildPlan(a, g3);
    var taps: [3]sk.Tap = undefined;
    for (fan5[0..3], &taps) |e, *t| {
        t.* = .{ .edge = e.id, .node = e.to, .at = poly[0], .landing = poly[1], .arrow = .filled };
    }
    const bbs = [_]sk.BusBar{ .{ .pivot = 8, .stem = &poly, .rail = .{ poly[0], poly[1] }, .taps = taps[0..2], .kind = .solid, .role = .fan_out_rail } };
    const rejected = try jp.realize(a, plan3, sketchOf(try paths(a, fan5[2..3]), &bbs), &.{});
    try expectEqual(@as(usize, 1), rejected.plan.rejected_proposals.len);
    p = rejected.plan;
    p.rejected_proposals = &.{};
    try expect(hasFinding(try jpv.validate(a, plan3, p, rejected.report.proposals), .proposal_unaccounted));

    // Bullets 2/3/4: a selected join re-pointed at the wrong group.
    const realized = try jp.realize(a, plan3, sketchOf(&.{}, &.{.{ .pivot = 8, .stem = &poly, .rail = .{ poly[0], poly[1] }, .taps = &taps, .kind = .solid, .role = .fan_out_rail }}), &.{});
    try expectEqual(@as(usize, 1), realized.plan.selected_joins.len);
    const rejoined = try a.dupe(pb.SelectedJoin, realized.plan.selected_joins);
    const foreign = try a.dupe(pb.EdgeId, realized.plan.selected_joins[0].members);
    foreign[0] = 99;
    rejoined[0].members = foreign;
    p = realized.plan;
    p.selected_joins = rejoined;
    const rj = try jpv.validate(a, plan3, p, realized.report.proposals);
    try expect(hasFinding(rj, .selected_join_foreign_member));

    // Terminal ports out of canonical order.
    const ports = try a.dupe(pb.TerminalPort, res.plan.terminal_ports);
    std.mem.swap(pb.TerminalPort, &ports[0], &ports[1]);
    p = res.plan;
    p.terminal_ports = ports;
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .terminal_ports_not_canonical));
}

// -- Mesh-union legality (D-IR item 16; plan N5) --------------------------------

const k22 = [_]sg.Edge{ edge(0, 0, 2), edge(1, 0, 3), edge(2, 1, 2), edge(3, 1, 3) };

test "mesh legality: exactly-complete exactly-declared K2,2 union is legal and passes through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = graph(&k22);
    const plan = try buildPlan(a, g);
    const members = [_]pb.EdgeId{ 0, 1, 2, 3 };
    try expect(jp.meshUnionLegal(plan, &members));

    const element = [_]pb.MeshUnion{.{
        .id = 0,
        .members = &members,
        .source_keys = &.{ "S1", "S2" },
        .target_keys = &.{ "T1", "T2" },
    }};
    const res = try jp.realize(a, plan, sketchOf(try paths(a, &k22), &.{}), &element);
    try expectEqual(@as(usize, 1), res.plan.mesh_unions.len);
    try expectEqual(@as(u32, 0), res.report.mesh_unions_rejected);
    try expect((try jpv.validate(a, plan, res.plan, res.report.proposals)).valid());
}

test "N5: duplicate-containing complete pair set fails mesh legality (D = declared edge count)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // K2,2 plus a DUPLICATE declared S1→T1 edge: the unique-pair relation
    // is complete (fan_lanes.isIncomplete would keep it fused) but D = 5
    // declared member edges != N*M = 4 → NOT a legal exempt union.
    const dup5 = k22 ++ [_]sg.Edge{edge(4, 0, 2)};
    const g = graph(&dup5);
    const plan = try buildPlan(a, g);
    const members = [_]pb.EdgeId{ 0, 1, 2, 3, 4 };
    try expect(!jp.meshUnionLegal(plan, &members));

    const element = [_]pb.MeshUnion{.{ .id = 0, .members = &members, .source_keys = &.{ "S1", "S2" }, .target_keys = &.{ "T1", "T2" } }};
    const res = try jp.realize(a, plan, sketchOf(try paths(a, &dup5), &.{}), &element);
    try expectEqual(@as(usize, 0), res.plan.mesh_unions.len);
    try expectEqual(@as(u32, 1), res.report.mesh_unions_rejected);

    // A hand-landed illegal element is rejected by the §6.7 validator.
    var p = res.plan;
    p.mesh_unions = &element;
    try expect(hasFinding(try jpv.validate(a, plan, p, res.report.proposals), .mesh_union_illegal));
}

test "mesh legality: incomplete unions and single-pivot fans are never legal unions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // K2,2 minus one edge: T2's fan-in group vanishes → not exactly complete.
    const incomplete = [_]sg.Edge{ edge(0, 0, 2), edge(1, 0, 3), edge(2, 1, 2) };
    const gi = graph(&incomplete);
    const pi = try buildPlan(a, gi);
    const mi = [_]pb.EdgeId{ 0, 1, 2 };
    try expect(!jp.meshUnionLegal(pi, &mi));

    // A 1×3 fan is single-pivot: carve-out territory, never a mesh union.
    const g3 = graph(fan5[0..3]);
    const p3 = try buildPlan(a, g3);
    const m3 = [_]pb.EdgeId{ 0, 1, 2 };
    try expect(!jp.meshUnionLegal(p3, &m3));
}

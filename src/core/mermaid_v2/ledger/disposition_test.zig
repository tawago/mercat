//! disposition_test.zig — P2v Step 8 integration vectors driving the
//! CI safety filter + terminal candidate through REAL reach geometry (fusing
//! vs complete unions), `disposeUnsafe`, and end-to-end render. A dedicated
//! integration file (broad TEST allowlist) rather than spreading across
//! siblings. Reuses reach_vector_test's pub sketch helpers.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, base/ledger,
//! sem_graph, sketch, parse, permits, realized, invariants, reach_vector,
//! reach_vector_test, select, raster, paint.

const std = @import("std");
const pb = @import("../base/ledger.zig");
const sk = @import("../sketch.zig");
const sg = @import("../sem_graph.zig");
const parse = @import("../parse.zig").parse;
const permits = @import("permits.zig");
const jp = @import("realized.zig");
const jpv = @import("invariants.zig");
const vc = @import("reach_vector.zig");
const rvt = @import("reach_vector_test.zig");
const ladder = @import("../budget.zig");
const select = @import("../select.zig");
const raster = @import("../raster.zig");
const paint = @import("../paint.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// incomplete-2×2 topology (S1→T1, S1→T2, S2→T2): FO-S1 and FI-T2 overlap on
// the dual edge S1→T2. Three straight, SEPARATE per-edge polylines.
const twox2_nodes = [_]sg.Node{ rvt.node(0, "S1"), rvt.node(1, "S2"), rvt.node(2, "T1"), rvt.node(3, "T2") };
const twox2_edges = [_]sg.Edge{ rvt.edge(0, 0, 2), rvt.edge(1, 0, 3), rvt.edge(2, 1, 3) };
/// SEPARATE per-edge polylines: each edge its own column, no shared ink.
fn twox2Paths() [3]sk.EdgePath {
    return .{
        rvt.path(0, 0, 2, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 } }),
        rvt.path(1, 0, 3, &.{ .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 6 } }),
        rvt.path(2, 1, 3, &.{ .{ .x = 10, .y = 2 }, .{ .x = 10, .y = 6 } }),
    };
}

/// FUSED-rail polylines: all three edges meet a shared rail row (y=4), so the
/// both-sides union's members form ONE connected component — the oracle then
/// reports S2→T1 as an extra (undeclared) reachable pair. (S1 col 2, S2 col 6,
/// T1 col 2, T2 col 10.)
fn twox2FusedPaths() [3]sk.EdgePath {
    return .{
        rvt.path(0, 0, 2, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 } }),
        rvt.path(1, 0, 3, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 6 } }),
        rvt.path(2, 1, 3, &.{ .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 6 } }),
    };
}

fn groupId(plan: pb.JoinPermits, dir: pb.JoinDirection, pivot: sg.NodeId) pb.JoinGroupId {
    for (plan.groups) |g| if (g.direction == dir and g.pivot == pivot) return g.id;
    unreachable;
}

/// The "preserved fusing-geometry constructor": take the real all-independent
/// plan (terminal ports + §6.5 conflicts) and OVERRIDE its selected joins to a
/// fabricating both-sides union of FO(`fo_pivot`) and FI(`fi_pivot`) — the
/// incomplete union whose Cartesian product exceeds its declared pairs. The
/// vector oracle then unites the members and reports the extra pair.
const Fused = struct { sketch: sk.Sketch, proposals: []const pb.JoinProposal };

fn fusedBothSides(a: std.mem.Allocator, plan: pb.JoinPermits, s: sk.Sketch, fo_pivot: sg.NodeId, fi_pivot: sg.NodeId) !Fused {
    const base = (try jp.realize(a, plan, s, &.{})).plan;
    const fo = groupId(plan, .out, fo_pivot);
    const fi = groupId(plan, .in, fi_pivot);
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
        .source = if (m.source_group) |gid| (if (gid == fo) pb.MembershipDisposition{ .selected = 0 } else null) else null,
        .target = if (m.target_group) |gid| (if (gid == fi) pb.MembershipDisposition{ .selected = 1 } else null) else null,
    };
    var out = s;
    out.joins = .{ .selected_joins = joins, .memberships = rms, .conflicts = base.conflicts, .terminal_ports = base.terminal_ports };
    return .{ .sketch = out, .proposals = proposals };
}

test "V-D-DISPOSITION-04: fusing incomplete-union candidate is CI-excluded, independent survivor routes; complete union fires nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const g = rvt.graphOf(&twox2_nodes, &twox2_edges);
    const plan = (try permits.build(a, g, .joined)).plan;
    const keys = try rvt.nodeKeys(a, &twox2_nodes);

    // Clean survivor: separate per-edge routing, all-independent → reach clean.
    var clean_paths = twox2Paths();
    const clean = try rvt.realized(a, g, rvt.sketchOf(&clean_paths, &.{}), &.{});
    const clean_report = try vc.validate(a, clean, keys, .flat);
    try expect(clean_report.counts.ciClean());
    try expectEqual(@as(usize, 0), clean.joins.selected_joins.len);

    // Fusing candidate: the same edges FUSED as an incomplete union → the REAL
    // oracle reports the extra (undeclared) S2→T1 pair (no forged counts).
    var fused_paths = twox2FusedPaths();
    const fused = (try fusedBothSides(a, plan, rvt.sketchOf(&fused_paths, &.{}), 0, 3)).sketch;
    const fused_report = try vc.validate(a, fused, keys, .flat);
    try expect(!fused_report.counts.ciClean());
    try expect(fused_report.counts.undeclared_pair > 0);

    // Filter: excludes the fusing candidate, keeps the clean survivor.
    const cands = [_]ladder.Candidate{
        .{ .rung = .natural, .sketch = fused, .accepted = false },
        .{ .rung = .tight, .sketch = clean, .accepted = false },
    };
    const reports = [_]vc.Report{ fused_report, clean_report };
    const filtered = select.ciFilter(a, &cands, &reports);
    try expect(filtered.excluded_any);
    try expectEqual(@as(usize, 1), filtered.survivors.len);
    try expectEqual(@as(usize, 1), filtered.excluded.len);
    // The survivor routes independently (every membership independent).
    for (filtered.survivors[0].sketch.joins.memberships) |rm| {
        if (rm.source) |d| try expect(d == .independent);
        if (rm.target) |d| try expect(d == .independent);
    }
    // The excluded candidate's re-disposed plan (via the `excluded` surface) is
    // all-independent — clause-(g)-pre withdrawal.
    try expectEqual(@as(usize, 0), filtered.excluded[0].sketch.joins.selected_joins.len);

    // Complete exact union (N*M == D): K3,3 real geometry fires NOTHING; every
    // candidate is CI-clean and the filter is the identity.
    const k33 = try parse(a,
        \\flowchart TD
        \\  S1 --> T1
        \\  S1 --> T2
        \\  S1 --> T3
        \\  S2 --> T1
        \\  S2 --> T2
        \\  S2 --> T3
        \\  S3 --> T1
        \\  S3 --> T2
        \\  S3 --> T3
        \\
    );
    const k33_plan = (try permits.build(a, k33, .joined)).plan;
    const k33_set = try select.enumerateAll(a, k33, &k33_plan, true, 120);
    const k33_reports = select.reachReports(a, k33, true, k33_set.merged);
    for (k33_reports) |r| try expect(r.counts.ciClean());
    const k33_filtered = select.ciFilter(a, k33_set.merged, k33_reports);
    try expect(!k33_filtered.excluded_any);
    try expectEqual(k33_set.merged.len, k33_filtered.survivors.len);
}

test "V-D-DUAL-04: a both-sides proposal set is CI-excluded by the filter and re-disposed to all-independent" {
    // Dual topology S→X, S→A, B→X. Selecting the dual edge S→X at BOTH ends
    // (§6.6 step 3 illegal) fuses FO-S and FI-X → the REAL oracle reports the
    // undeclared B→A pair. The filter excludes it and clause-(g)-pre withdrawal
    // falls the emitted plan back to all-independent; the §6.5 conflict is kept.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ rvt.node(0, "S"), rvt.node(1, "X"), rvt.node(2, "A"), rvt.node(3, "B") };
    const edges = [_]sg.Edge{ rvt.edge(0, 0, 1), rvt.edge(1, 0, 2), rvt.edge(2, 3, 1) };
    const g = rvt.graphOf(&nodes, &edges);
    const plan = (try permits.build(a, g, .joined)).plan;
    const keys = try rvt.nodeKeys(a, &nodes);

    // Fused-rail geometry (shared row y=4): S col 2, B col 6, X col 10, A col 14.
    var paths = [_]sk.EdgePath{
        rvt.path(0, 0, 1, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 6 } }),
        rvt.path(1, 0, 2, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 4 }, .{ .x = 14, .y = 4 }, .{ .x = 14, .y = 6 } }),
        rvt.path(2, 3, 1, &.{ .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 4 }, .{ .x = 10, .y = 4 }, .{ .x = 10, .y = 6 } }),
    };
    const fused = try fusedBothSides(a, plan, rvt.sketchOf(&paths, &.{}), 0, 1);
    const report = try vc.validate(a, fused.sketch, keys, .flat);
    try expect(!report.counts.ciClean());
    try expect(report.counts.undeclared_pair > 0); // B reaches A

    const cands = [_]ladder.Candidate{.{ .rung = .natural, .sketch = fused.sketch, .accepted = false }};
    const reports = [_]vc.Report{report};
    const filtered = select.ciFilter(a, &cands, &reports);
    try expectEqual(@as(usize, 0), filtered.survivors.len);
    try expectEqual(@as(usize, 1), filtered.excluded.len);

    const disposed = filtered.excluded[0].sketch.joins;
    try expectEqual(@as(usize, 0), disposed.selected_joins.len);
    for (disposed.memberships) |rm| {
        if (rm.source) |d| try expect(d == .independent);
        if (rm.target) |d| try expect(d == .independent);
    }
    try expectEqual(@as(usize, 1), disposed.conflicts.len); // §6.5 conflict retained
    try expect((try jpv.validate(a, plan, disposed, fused.proposals)).valid());
    try expectEqual(pb.DispositionClass.report_only, pb.classOf(.dual_membership_selected_both_sides));
}

test "V-D-DISPOSITION-01: incomplete-2x2 conflicts survive disposeUnsafe, all-independent withdrawal, render succeeds" {
    // Record input: incomplete-2x2. The production winner retains the §6.5
    // overlap conflict (permission_overlap_conflicts=1); clause-(g)-pre
    // withdrawal keeps that conflict while dropping every selected join; the
    // candidate renders end-to-end (RO — never fatal).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, true, 94, false, false);
    const joins = winner.sketch.joins;

    try expectEqual(@as(usize, 1), joins.conflicts.len); // permission_overlap_conflicts = 1

    const disposed = try jp.disposeUnsafe(a, joins);
    try expectEqual(@as(usize, 1), disposed.conflicts.len); // conflict survives the withdrawal
    try expectEqual(@as(usize, 0), disposed.selected_joins.len);
    for (disposed.memberships) |rm| {
        if (rm.source) |d| try expect(d == .independent);
        if (rm.target) |d| try expect(d == .independent);
    }
    try expectEqual(pb.DispositionClass.report_only, pb.classOf(.join_select_independent_unsafe_component));

    // Render succeeds (RO disposition, no fatal).
    const rendered = try raster.rasterize(a, winner.sketch, .bridge);
    const bytes = try paint.paint(a, rendered.lattice, winner.sketch.budget.max_width);
    try expect(bytes.len > 0);
}

test "V-D-DISPOSITION-06: terminal fallback is built by the selection tail, marks terminal_fallback, validates, and renders" {
    // Fault injection: ALL candidates report a CI event, so the selection tail
    // (`selectWinner`) empties the scored set and BUILDS the terminal
    // all-independent candidate (D-DISPOSITION item 9(b)); `terminal_fallback`
    // is the "=1" engagement signal (9(e)); the plan validates and it renders.
    for ([_]u32{ 94, 118 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
        const plan = (try permits.build(a, graph, .joined)).plan;
        const set = try select.enumerateAll(a, graph, &plan, true, width);

        const reports = try a.alloc(vc.Report, set.merged.len);
        for (reports) |*r| r.* = .{ .counts = .{ .undeclared_pair = 1 } }; // ALL RED

        const result = try select.selectWinner(a, graph, &plan, true, width, set.merged, reports, set.incumbent, false, false);
        try expect(result.terminal_fallback); // engagement observable (=1)

        // All-independent, §6.7-valid against the REAL permits, and renders.
        try expectEqual(@as(usize, 0), result.sketch.joins.selected_joins.len);
        try expectEqual(@as(usize, 0), result.sketch.busbars.len);
        try expect(result.sketch.joins.memberships.len > 0);
        try expect((try jpv.validate(a, plan, result.sketch.joins, &.{})).valid());
        const rendered = try raster.rasterize(a, result.sketch, .bridge);
        const bytes = try paint.paint(a, rendered.lattice, result.sketch.budget.max_width);
        try expect(bytes.len > 0);
    }
}

test "finding-2: survivors present ⇒ selection tail never engages the terminal candidate" {
    // The frenzy-at-94 shape: the CI-excluded candidate IS the ladder incumbent,
    // but clean survivors remain. selectWinner must ship a survivor (argmin
    // fallback), NEVER the terminal candidate while survivors exist.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const set = try select.enumerateAll(a, graph, &plan, true, 96);

    const reports = try a.dupe(vc.Report, select.reachReports(a, graph, true, set.merged));
    var inc: ?usize = null;
    for (set.merged, 0..) |cand, i| if (cand.transform == .raw and cand.rung == set.incumbent.final_rung) {
        inc = i;
        break;
    };
    try expect(inc != null);
    reports[inc.?].counts.unknown_continuation = 1; // the incumbent fabricates

    const result = try select.selectWinner(a, graph, &plan, true, 96, set.merged, reports, set.incumbent, false, false);
    try expect(!result.terminal_fallback); // a survivor shipped, not the terminal candidate
}

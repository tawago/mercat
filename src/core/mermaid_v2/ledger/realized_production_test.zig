//! Step 7 production-path structural vectors for the §14.6 mixing cases.

const std = @import("std");
const parse = @import("../parse.zig").parse;
const permits = @import("permits.zig");
const reach = @import("reach_vector.zig");
const select = @import("../select.zig");
const raster = @import("../raster.zig");
const paint = @import("../paint.zig");
const pb = @import("../base/ledger.zig");

fn nodeId(graph: anytype, raw: []const u8) u32 {
    for (graph.nodes) |n| if (std.mem.eql(u8, n.raw_id, raw)) return n.id;
    unreachable;
}

fn edgeId(graph: anytype, from: []const u8, to: []const u8) u32 {
    const f = nodeId(graph, from);
    const t = nodeId(graph, to);
    for (graph.edges) |e| if (e.from == f and e.to == t) return e.id;
    unreachable;
}

fn groupIdx(groups: []const pb.JoinGroup, id: pb.JoinGroupId) usize {
    for (groups, 0..) |g, i| if (g.id == id) return i;
    unreachable;
}

fn rmByEdge(plan: pb.RealizedJoins, e: u32) pb.RealizedEdgeMembership {
    for (plan.memberships) |rm| if (rm.edge == e) return rm;
    unreachable;
}

test "Step 7 §14.6 mixing cases have exact reach and no fused edge junction" {
    const sources = [_][]const u8{
        "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n",
        "flowchart TD\n  S --> X\n  S --> A\n  B --> X\n",
    };
    for (sources) |source| for ([_]u32{ 94, 118 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const winner = try select.choose(a, graph, &plan, true, width, false, false);
        const keys = try select.nodeKeyTable(a, graph);
        const report = try reach.validate(a, winner.sketch, keys, .flat);

        try std.testing.expectEqual(@as(u32, 0), report.counts.ciTotal());
        try std.testing.expectEqual(graph.edges.len, report.declared.len);
        // Arrival re-merge (D-PORT.md 2026-07-18): the shared-target pure
        // fan-in (T2 / X) is now composed as ONE merged trunk entry; the
        // departure side stays dissolved so reach stays exact.
        try std.testing.expectEqual(@as(usize, 1), winner.sketch.busbars.len);

        // No fused PLAIN-edge junction: independent forward/back-edge cells
        // stay 2-neighbour paths. The one merged fan-in rail legitimately
        // carries a ┬ junction (its taps meet the drop), so busbar trunk/
        // rail roles are exempt — that junction IS the truthful merged ink.
        const rendered = try raster.rasterize(a, winner.sketch, .bridge);
        for (rendered.lattice.cells) |cell| switch (cell.occupant) {
            .edge_segment => |seg| switch (seg.role) {
                .forward, .back_edge => try std.testing.expect(@popCount(cell.neighbours.toMask()) <= 2),
                else => {},
            },
            else => {},
        };
    };
}

test "forward-subset composition: reversed fan-in member independent, forward pair merges" {
    // D has forward arrivals B->D, C->D plus a layout-reversed back-edge F->D
    // (cycle D->E->F->D). Owner ruling 2026-07-18: the forward subset
    // {B->D, C->D} composes ONE merged fan-in trunk; F->D keeps its own
    // independent east back-edge entry (never fused into the trunk).
    const source = "flowchart TD\n  A --> B\n  A --> C\n  B --> D\n  C --> D\n  D --> E\n  E --> F\n  F --> D\n";
    for ([_]u32{ 94, 118 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const winner = try select.choose(a, graph, &plan, true, width, false, false);
        const joins = winner.sketch.joins;

        // The fan-IN trunk at D carries EXACTLY the two forward arrivals.
        var fi: ?pb.SelectedJoin = null;
        for (joins.selected_joins) |sj| {
            const gi = groupIdx(plan.groups, sj.permission_group);
            if (plan.groups[gi].direction == .in and plan.groups[gi].pivot == nodeId(graph, "D")) fi = sj;
        }
        try std.testing.expect(fi != null);
        try std.testing.expectEqual(@as(usize, 2), fi.?.members.len);
        var saw_bd = false;
        var saw_cd = false;
        for (fi.?.members) |m| {
            if (m == edgeId(graph, "B", "D")) saw_bd = true;
            if (m == edgeId(graph, "C", "D")) saw_cd = true;
        }
        try std.testing.expect(saw_bd and saw_cd);

        // F->D never joins the trunk: independent at target, no source group.
        const fd = rmByEdge(joins, edgeId(graph, "F", "D"));
        try std.testing.expect(fd.target.? == .independent);
        try std.testing.expect(fd.source == null);
        try std.testing.expect(rmByEdge(joins, edgeId(graph, "B", "D")).target.? == .selected);
        try std.testing.expect(rmByEdge(joins, edgeId(graph, "C", "D")).target.? == .selected);

        // never-both, and the merged trunk + independent back-edge read back
        // exactly (census zero).
        for (joins.memberships) |rm| {
            const s_sel = rm.source != null and rm.source.? == .selected;
            const t_sel = rm.target != null and rm.target.? == .selected;
            try std.testing.expect(!(s_sel and t_sel));
        }
        const report = try reach.validate(a, winner.sketch, try select.nodeKeyTable(a, graph), .flat);
        try std.testing.expectEqual(@as(u32, 0), report.counts.ciTotal());

        // A first-class fan-in busbar exists at D — the ONE merged entry.
        var has_d_trunk = false;
        for (winner.sketch.busbars) |bb| {
            if (bb.pivot == nodeId(graph, "D")) has_d_trunk = true;
        }
        try std.testing.expect(has_d_trunk);
    }
}

test "V-D-PORT-01: mixed-kind 1x3 renders as three pitch-2 independent components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S --> A\n  S -.-> B\n  S ==> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, true, 94, false, false);
    try std.testing.expectEqual(@as(usize, 0), winner.sketch.busbars.len);

    var offsets: [3]u32 = undefined;
    var count: usize = 0;
    for (winner.sketch.edges) |edge| if (edge.from == 0) {
        offsets[count] = edge.port_from.offset;
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), count);
    std.mem.sort(u32, &offsets, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 5 }, &offsets);

    const report = try reach.validate(a, winner.sketch, try select.nodeKeyTable(a, graph), .flat);
    try std.testing.expectEqual(@as(usize, 3), report.components.len);
    try std.testing.expectEqual(@as(u32, 0), report.counts.ciTotal());
    try std.testing.expectEqual(@as(u32, 0), (try raster.rasterize(a, winner.sketch, .bridge)).edge_cells_lost);
}

test "V-D-PORT-14: inline K1,3 realized BusBar keeps midpoint stem and pre-Step-7 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S --> A\n  S --> B\n  S --> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const realized_winner = try select.choose(a, graph, &plan, true, 94, false, false);
    const inert: @import("../base/ledger.zig").JoinPermits = .{ .policy = .joined };
    const before = try select.choose(a, graph, &inert, true, 94, false, false);

    try std.testing.expectEqual(@as(usize, 1), realized_winner.sketch.busbars.len);
    try std.testing.expectEqual(@as(usize, 1), realized_winner.sketch.joins.selected_joins.len);
    const bb = realized_winner.sketch.busbars[0];
    var pivot = realized_winner.sketch.nodes[0];
    for (realized_winner.sketch.nodes) |node| if (node.id == bb.pivot) {
        pivot = node;
        break;
    };
    try std.testing.expectEqual(pivot.rect.x + @as(i32, @intCast(pivot.rect.w / 2)), bb.stem[0].x);
    try std.testing.expectEqual(pivot.rect.bottom() - 1, bb.stem[0].y);

    const realized_raster = try raster.rasterize(a, realized_winner.sketch, .bridge);
    const before_raster = try raster.rasterize(a, before.sketch, .bridge);
    const realized_bytes = try paint.paint(a, realized_raster.lattice, realized_winner.sketch.budget.max_width);
    const before_bytes = try paint.paint(a, before_raster.lattice, before.sketch.budget.max_width);
    try std.testing.expectEqualStrings(before_bytes, realized_bytes);
}

test "V-D-PORT-16: incomplete 2x2 arrival re-merges the pure fan-in, overlap conflict retained, never-both holds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T2\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, true, 94, false, false);
    const joins = winner.sketch.joins;

    // Both selection sites agree: join_commit built the merged fan-in trunk
    // (one busbar) and realized (via select's plan) selected the same group.
    try std.testing.expectEqual(@as(usize, 1), winner.sketch.busbars.len);
    try std.testing.expectEqual(@as(usize, 1), joins.selected_joins.len);

    // The selected group is the pure fan-in at T2; the fan-out FO-S1 stays
    // overlap → NEITHER (mixing prohibition intact).
    const sel_gi = groupIdx(plan.groups, joins.selected_joins[0].permission_group);
    try std.testing.expectEqual(pb.JoinDirection.in, plan.groups[sel_gi].direction);
    try std.testing.expectEqual(nodeId(graph, "T2"), plan.groups[sel_gi].pivot);

    // §6.5 completeness: the shared dual edge S1->T2 is STILL a retained
    // conflict beside the preference.
    try std.testing.expectEqual(@as(usize, 1), joins.conflicts.len);
    try std.testing.expectEqual(edgeId(graph, "S1", "T2"), joins.conflicts[0].shared_edges[0]);

    // S1->T2: selected at TARGET, independent at SOURCE (departure dissolved).
    const dual = rmByEdge(joins, edgeId(graph, "S1", "T2"));
    try std.testing.expect(dual.target.? == .selected);
    try std.testing.expect(dual.source.? == .independent);
    try std.testing.expect(rmByEdge(joins, edgeId(graph, "S2", "T2")).target.? == .selected);
    try std.testing.expect(rmByEdge(joins, edgeId(graph, "S1", "T1")).source.? == .independent);
    for (joins.memberships) |rm| {
        const s_sel = rm.source != null and rm.source.? == .selected;
        const t_sel = rm.target != null and rm.target.? == .selected;
        try std.testing.expect(!(s_sel and t_sel)); // never-both
    }
}

test "V-D-PORT-16 corrected: a fan-out-pivot target DOES re-merge its pure fan-in arrival (OPEN-1 class-1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // FI-T = {A->T, B->T} overlaps FO-A = {A->T, A->Z} on the dual edge A->T.
    // T is ALSO the pivot of the fan-out FO-T = {T->X, T->Y}. OPEN-1 class-1
    // (D-PORT 2026-07-17 four-way): purity is the ARRIVAL SHAPE alone, so the
    // fan-out at the same pivot does NOT block the re-merge — the arrival
    // trunk enters T's entry side while departures exit other sides (no ink
    // fusion). FI-T re-merges; FO-T's own dispositions are untouched.
    const graph = try parse(a, "flowchart TD\n  A --> T\n  A --> Z\n  B --> T\n  T --> X\n  T --> Y\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, true, 94, false, false);
    const joins = winner.sketch.joins;

    // FI-T IS selected now: the fan-in at pivot T, direction .in.
    var fi_sel: ?pb.SelectedJoin = null;
    for (joins.selected_joins) |sj| {
        const gi = groupIdx(plan.groups, sj.permission_group);
        if (plan.groups[gi].direction == .in and plan.groups[gi].pivot == nodeId(graph, "T")) fi_sel = sj;
    }
    try std.testing.expect(fi_sel != null);

    // The trunk members are EXACTLY the arrival edges A->T and B->T.
    try std.testing.expectEqual(@as(usize, 2), fi_sel.?.members.len);
    var saw_at = false;
    var saw_bt = false;
    for (fi_sel.?.members) |m| {
        if (m == edgeId(graph, "A", "T")) saw_at = true;
        if (m == edgeId(graph, "B", "T")) saw_bt = true;
    }
    try std.testing.expect(saw_at and saw_bt);

    // The shared dual edge A->T: selected at TARGET (arrival), independent at
    // SOURCE — FO-A stays overlap → its departure dissolved, conflict retained.
    const dual = rmByEdge(joins, edgeId(graph, "A", "T"));
    try std.testing.expect(dual.target.? == .selected);
    try std.testing.expect(dual.source.? == .independent);
    try std.testing.expect(rmByEdge(joins, edgeId(graph, "B", "T")).target.? == .selected);

    // FO-T (T->X, T->Y) is unchanged by the arrival re-merge: its departures
    // keep identical source dispositions (they do not share the arrival trunk).
    const dx = rmByEdge(joins, edgeId(graph, "T", "X")).source;
    const dy = rmByEdge(joins, edgeId(graph, "T", "Y")).source;
    try std.testing.expect(dx != null and dy != null);
    try std.testing.expectEqual(std.meta.activeTag(dx.?), std.meta.activeTag(dy.?));

    for (joins.memberships) |rm| {
        const s_sel = rm.source != null and rm.source.? == .selected;
        const t_sel = rm.target != null and rm.target.? == .selected;
        try std.testing.expect(!(s_sel and t_sel)); // never-both
    }
}

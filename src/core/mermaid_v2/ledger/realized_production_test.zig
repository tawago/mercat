//! Step 7 production-path structural vectors for mixed fan-in/fan-out cases.

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

test "Step 7 mixing cases have exact reach and no fused edge junction" {
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
        const winner = try select.choose(a, graph, &plan, width, false, false);
        const keys = try select.nodeKeyTable(a, graph);
        const report = try reach.validate(a, winner.sketch, keys, .flat);

        try std.testing.expectEqual(@as(u32, 0), report.counts.ciTotal());
        try std.testing.expectEqual(graph.edges.len, report.declared.len);
        // Arrival re-merge (D-PORT 2026-07-18): the shared-target pure
        // fan-in (T2 / X) is now composed as ONE merged trunk entry; the
        // departure side stays dissolved so reach stays exact.
        try std.testing.expectEqual(@as(usize, 1), winner.sketch.rails.len);

        // No fused PLAIN-edge junction: independent forward/back-edge cells
        // stay 2-neighbour paths. The one merged fan-in rail legitimately
        // carries a ┬ junction (its taps meet the drop), so rail trunk/
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
        const winner = try select.choose(a, graph, &plan, width, false, false);
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

        // A first-class fan-in rail exists at D — the ONE merged entry.
        var has_d_trunk = false;
        for (winner.sketch.rails) |bb| {
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
    const winner = try select.choose(a, graph, &plan, 94, false, false);
    try std.testing.expectEqual(@as(usize, 0), winner.sketch.rails.len);

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

test "V-D-PORT-14: inline K1,3 realized Rail keeps midpoint stem and pre-Step-7 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S --> A\n  S --> B\n  S --> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const realized_winner = try select.choose(a, graph, &plan, 94, false, false);
    const inert: @import("../base/ledger.zig").JoinPermits = .{ .policy = .joined };
    const before = try select.choose(a, graph, &inert, 94, false, false);

    try std.testing.expectEqual(@as(usize, 1), realized_winner.sketch.rails.len);
    try std.testing.expectEqual(@as(usize, 1), realized_winner.sketch.joins.selected_joins.len);
    const bb = realized_winner.sketch.rails[0];
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
    const winner = try select.choose(a, graph, &plan, 94, false, false);
    const joins = winner.sketch.joins;

    // Both selection sites agree: join_commit built the merged fan-in trunk
    // (one rail) and realized (via select's plan) selected the same group.
    try std.testing.expectEqual(@as(usize, 1), winner.sketch.rails.len);
    try std.testing.expectEqual(@as(usize, 1), joins.selected_joins.len);

    // The selected group is the pure fan-in at T2; the fan-out FO-S1 stays
    // overlap → NEITHER (mixing prohibition intact).
    const sel_gi = groupIdx(plan.groups, joins.selected_joins[0].permission_group);
    try std.testing.expectEqual(pb.JoinDirection.in, plan.groups[sel_gi].direction);
    try std.testing.expectEqual(nodeId(graph, "T2"), plan.groups[sel_gi].pivot);

    // Conflict completeness: the shared dual edge S1->T2 is STILL a retained
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
    const winner = try select.choose(a, graph, &plan, 94, false, false);
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

test "dominance pin: a complete K2,2 decomposes into star trunks, never one union" {
    // Shared trunking exists only where members share ONE exact endpoint. A
    // complete K2,2 has no such endpoint, so no single element may speak for
    // all four edges: what selection lands is the star decomposition — a trunk
    // per shared pivot — and every landed trunk's members share its pivot.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T1\n  S2 --> T2\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, 94, false, false);

    for (winner.sketch.joins.selected_joins) |sj| {
        try std.testing.expect(sj.members.len < graph.edges.len);
        for (plan.groups) |g| if (g.id == sj.permission_group) {
            for (sj.members) |m| for (graph.edges) |e| if (e.id == m) {
                const shared = if (g.direction == .out) e.from else e.to;
                try std.testing.expectEqual(g.pivot, shared);
            };
        };
    }
}

/// Render a source end-to-end (select → raster → paint) and return the plain
/// grid plus the winning candidate's plan.
fn renderPlain(a: std.mem.Allocator, source: []const u8, width: u32) !struct { grid: []const u8, joins: pb.RealizedJoins, routed: []const u32 } {
    const graph = try parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, width, false, false);
    const rendered = try raster.rasterize(a, winner.sketch, .bridge);
    const routed = try a.alloc(u32, winner.sketch.edges.len);
    for (winner.sketch.edges, routed) |e, *slot| slot.* = e.id;
    return .{
        .grid = try paint.paint(a, rendered.lattice, winner.sketch.budget.max_width),
        .joins = winner.sketch.joins,
        .routed = routed,
    };
}

/// Count how many of `grid`'s rows carry at least one horizontal run glyph —
/// a shared crossbar occupies ONE such row, unfused private lanes occupy one
/// each.
fn rowsWithInk(grid: []const u8, glyph: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, grid, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, glyph) != null) n += 1;
    }
    return n;
}

test "an undeclared all-arrow-free fan unfuses; a declared clique keeps the rail and withholds its pair edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // (1) REFUSAL. Three arrow-free arrivals at Z with no declared leaf pair:
    // the old single crossbar `└────────┼────────┘` asserted A—B, A—C and B—C.
    // Every member now descends on its own, so the picture states only the
    // three declared relations.
    const refused = try renderPlain(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n", 70);
    try std.testing.expectEqual(@as(usize, 0), refused.joins.selected_joins.len);
    try std.testing.expectEqual(@as(usize, 0), refused.joins.co_realized.len);
    try std.testing.expectEqual(@as(usize, 3), refused.routed.len);
    // No row carries a run spanning A's column through C's: the leaves never
    // meet each other's ink.
    try std.testing.expect(std.mem.indexOf(u8, refused.grid, "┼") == null);

    // (2) CO-REALIZED EMISSION. A---B declared, so the two arrivals may share
    // one run: the ink between the taps IS A---B's rendering, and A---B keeps
    // no polyline of its own — three declared edges, two drawn.
    const kept = try renderPlain(a, "flowchart LR\n  A --- Z\n  B --- Z\n  A --- B\n", 70);
    try std.testing.expectEqual(@as(usize, 1), kept.joins.co_realized.len);
    try std.testing.expectEqual(@as(usize, 2), kept.routed.len);
    // No double discharge: the withheld edge owns no private geometry.
    for (kept.joins.co_realized) |co| {
        for (kept.routed) |id| try std.testing.expect(id != co);
    }
    // The shared arrival survives: exactly one western entry at Z.
    try std.testing.expectEqual(@as(usize, 1), rowsWithInk(kept.grid, "├──┤ Z"));
}

test "a salvaged trunk is complete against the commitment the layout drew" {
    // A---Z, B---Z, C---Z with A---B and B---C declared: the closure law
    // refuses the three-member rail (A—C is undeclared) and salvages a
    // two-member one. The layout draws that trunk — so the planner must not
    // then call it `incomplete` against the whole permission group, withdraw
    // it, and leave its fused ink with no co-set. That disagreement made every
    // candidate CI-dirty and shipped the forced all-independent fallback, which
    // dead-ends C---B's stroke on B's border.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n  A --- B\n  B --- C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const set = try select.enumerateAll(a, graph, &plan, 60);
    const merged = set.merged;
    const reports = select.reachReports(a, graph, true, merged);
    try std.testing.expectEqual(merged.len, reports.len);
    for (reports) |r| try std.testing.expect(r.counts.ciClean());

    // The winner keeps the salvaged trunk and loses no edge cell.
    const winner = try select.choose(a, graph, &plan, 60, false, false);
    var trunk_members: usize = 0;
    for (winner.sketch.joins.selected_joins) |sj| trunk_members = @max(trunk_members, sj.members.len);
    try std.testing.expectEqual(@as(usize, 2), trunk_members);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
}

test "a complete all-to-all draws one rail per shared endpoint, and the fused run spends one stub per source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // DIRECTED K2,2. The star decomposition stands: one arrival trunk at X
    // and one at Y, each carrying only the members that share ITS pivot. The
    // declared set is EXACTLY srcs x tgts with every head one-way at the
    // target, so the fusion licence lets the two trunks share one rail row —
    // and each SOURCE spends ONE stub for its whole member set (discharge:
    // the crossbar asserts every pair, so a second stub adds nothing).
    const directed = try renderPlain(a, "flowchart TD\n  A --> X\n  A --> Y\n  B --> X\n  B --> Y\n", 70);
    try std.testing.expectEqual(@as(usize, 2), directed.joins.selected_joins.len);
    for (directed.joins.selected_joins) |sj| try std.testing.expectEqual(@as(usize, 2), sj.members.len);
    // Every declared edge is drawn, by exactly one of those two trunks.
    for (0..4) |edge| {
        var owners: usize = 0;
        for (directed.joins.selected_joins) |sj| {
            for (sj.members) |m| {
                if (m == edge) owners += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), owners);
    }
    // The licence is on record, and the ink honours it: one source-border
    // junction per source node — two `┬` in the whole grid, not one per edge.
    try std.testing.expectEqual(@as(usize, 1), directed.joins.fused.len);
    try std.testing.expectEqual(@as(usize, 4), directed.joins.fused[0].len);
    var stubs: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, directed.grid, i, "┬")) |at| : (i = at + 1) stubs += 1;
    try std.testing.expectEqual(@as(usize, 2), stubs);

    // UNDIRECTED K2,2. Arrow-free ink reads both ways, so a shared run also
    // states A—B. Neither arrival's pair is declared and both arrivals assert
    // it, so the closure law refuses both rails outright: no trunk, no
    // crossbar, nothing co-realized, and all four edges route privately.
    const undirected = try renderPlain(a, "flowchart TD\n  A --- X\n  A --- Y\n  B --- X\n  B --- Y\n", 70);
    try std.testing.expectEqual(@as(usize, 0), undirected.joins.selected_joins.len);
    try std.testing.expectEqual(@as(usize, 0), undirected.joins.co_realized.len);
    try std.testing.expectEqual(@as(usize, 4), undirected.routed.len);
}

test "a directed complete bipartite keeps its TD star decomposition on clearing rows" {
    // The all-to-all's star decomposition is one arrival trunk per target —
    // and because every member carries a one-way head and the declared set is
    // EXACTLY srcs x tgts, the plan's two-sided fusion licence
    // (`RealizedJoins.fused`) lets the three trunks share ONE rail row: the
    // fused run asserts only cross pairs the source declares, its ink is one
    // channel, and the reach oracle fires nothing.
    const source =
        \\flowchart TD
        \\    S1[Order Received] --> M1[Validate Payment]
        \\    S1 --> M2[Check Inventory]
        \\    S1 --> M3[Apply Discount]
        \\    S2[Webhook Triggered] --> M1
        \\    S2 --> M2
        \\    S2 --> M3
        \\    S3[Manual Entry] --> M1
        \\    S3 --> M2
        \\    S3 --> M3
        \\
    ;
    for ([_]u32{ 60, 90, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const winner = try select.choose(a, graph, &plan, width, false, false);

        // The TD shape survives: three arrival trunks of three taps each,
        // FUSED onto one shared rail row, and the source's direction is kept.
        try std.testing.expectEqual(graph.direction, winner.sketch.direction);
        try std.testing.expectEqual(@as(usize, 3), winner.sketch.rails.len);
        for (winner.sketch.rails) |bar| {
            try std.testing.expectEqual(@as(usize, 3), bar.taps.len);
            try std.testing.expectEqual(winner.sketch.rails[0].crossbar[0].y, bar.crossbar[0].y);
        }

        // THE licence: the plan records one fused union of all nine members,
        // so the shared row is one channel of record, not a coincidence.
        try std.testing.expectEqual(@as(usize, 1), winner.sketch.joins.fused.len);
        try std.testing.expectEqual(@as(usize, 9), winner.sketch.joins.fused[0].len);

        // And the licence is spent honestly: every trunk's tap at one source
        // rides the SAME column, so each source drops ONE stub for its three
        // member edges — the crossbar's completeness recovers the pairs.
        for (winner.sketch.rails) |bar| for (bar.taps) |tap| {
            for (winner.sketch.rails) |other| for (other.taps) |t2| {
                if (t2.node == tap.node) try std.testing.expectEqual(tap.at.x, t2.at.x);
            };
        };

        // No reach event, no lost ink, and the render fits the budget it was
        // asked for (the defect shipped a clipped render at width 60).
        const keys = try select.nodeKeyTable(a, graph);
        const report = try reach.validate(a, winner.sketch, keys, .flat);
        try std.testing.expectEqual(@as(u32, 0), report.counts.ciTotal());
        try std.testing.expect(winner.sketch.bbox.w <= width);
    }
}

test "on the licence's lapse path a trunk's junction still clears foreign taps" {
    // The licence lapses where the declared set falls short (here S3 --> M3
    // is absent), so rows separate again — and THE row-order invariant of the
    // separated regime must still hold: a trunk's stem junction never sits on
    // a row a foreign trunk's tap still occupies, or the junction becomes a
    // four-armed glyph two trunks claim (the reach oracle's
    // `unknown_continuation`) and the whole family is filtered out.
    const source =
        \\flowchart TD
        \\    S1[Order Received] --> M1[Validate Payment]
        \\    S1 --> M2[Check Inventory]
        \\    S1 --> M3[Apply Discount]
        \\    S2[Webhook Triggered] --> M1
        \\    S2 --> M2
        \\    S2 --> M3
        \\    S3[Manual Entry] --> M1
        \\    S3 --> M2
        \\
    ;
    for ([_]u32{ 90, 120 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const winner = try select.choose(a, graph, &plan, width, false, false);

        // Non-vacuous: the lapse actually split the rails onto >= 2 rows.
        try std.testing.expect(winner.sketch.rails.len >= 2);
        var rows_differ = false;
        for (winner.sketch.rails) |bar| {
            if (bar.crossbar[0].y != winner.sketch.rails[0].crossbar[0].y) rows_differ = true;
        }
        try std.testing.expect(rows_differ);

        // THE invariant, unchanged from the separated regime: a foreign
        // trunk's tap crossing my stem column keeps its rail nearer the
        // sources than my junction.
        for (winner.sketch.rails) |bar| {
            const stem_x = bar.stem[0].x;
            const junction_y = bar.crossbar[0].y;
            for (winner.sketch.rails) |other| {
                if (other.crossbar[0].y == junction_y) continue;
                for (other.taps) |tap| {
                    if (tap.at.x != stem_x) continue;
                    try std.testing.expect(other.crossbar[0].y < junction_y);
                }
            }
        }

        const keys = try select.nodeKeyTable(a, graph);
        const report = try reach.validate(a, winner.sketch, keys, .flat);
        try std.testing.expectEqual(@as(u32, 0), report.counts.ciTotal());
    }
}

//! Step 7 production-path structural vectors for mixed fan-in/fan-out cases.

const std = @import("std");
const parse = @import("../parse.zig").parse;
const permits = @import("permits.zig");
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

fn groupIdx(groups: []const pb.CandidateBundle, id: pb.CandidateBundleId) usize {
    for (groups, 0..) |g, i| if (g.id == id) return i;
    unreachable;
}

fn rmByEdge(plan: pb.RealizedBundles, e: u32) pb.RealizedEdgeMembership {
    for (plan.memberships) |rm| if (rm.edge == e) return rm;
    unreachable;
}

test "Step 7 mixing cases realize one rail and no fused edge junction" {
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
        const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);

        try std.testing.expectEqual(@as(usize, 1), winner.sketch.rails.len);

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
    const source = "flowchart TD\n  A --> B\n  A --> C\n  B --> D\n  C --> D\n  D --> E\n  E --> F\n  F --> D\n";
    for ([_]u32{ 94, 118 }) |width| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);
        const bundles = winner.sketch.bundles;

        var fi: ?pb.SelectedBundle = null;
        for (bundles.selected_bundles) |sj| {
            const gi = groupIdx(plan.groups, sj.candidate_bundle);
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

        const fd = rmByEdge(bundles, edgeId(graph, "F", "D"));
        try std.testing.expect(fd.target.? == .independent);
        try std.testing.expect(fd.source == null);
        try std.testing.expect(rmByEdge(bundles, edgeId(graph, "B", "D")).target.? == .selected);
        try std.testing.expect(rmByEdge(bundles, edgeId(graph, "C", "D")).target.? == .selected);

        for (bundles.memberships) |rm| {
            const s_sel = rm.source != null and rm.source.? == .selected;
            const t_sel = rm.target != null and rm.target.? == .selected;
            try std.testing.expect(!(s_sel and t_sel));
        }
        var has_d_rail = false;
        for (winner.sketch.rails) |rail| {
            if (rail.pivot == nodeId(graph, "D")) has_d_rail = true;
        }
        try std.testing.expect(has_d_rail);
    }
}

test "V-D-PORT-01: mixed-kind 1x3 renders as three pitch-2 independent components" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S --> A\n  S -.-> B\n  S ==> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, 94, false, false, .bridge);
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

    try std.testing.expectEqual(@as(u32, 0), (try raster.rasterize(a, winner.sketch, .bridge)).edge_cells_lost);
}

test "V-D-PORT-14: inline K1,3 realized Rail keeps midpoint stem and pre-Step-7 bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S --> A\n  S --> B\n  S --> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const realized_winner = try select.choose(a, graph, &plan, 94, false, false, .bridge);
    const inert: @import("../base/ledger.zig").BundlePermits = .{ .policy = .joined };
    const before = try select.choose(a, graph, &inert, 94, false, false, .bridge);

    try std.testing.expectEqual(@as(usize, 1), realized_winner.sketch.rails.len);
    try std.testing.expectEqual(@as(usize, 1), realized_winner.sketch.bundles.selected_bundles.len);
    const rail = realized_winner.sketch.rails[0];
    var pivot = realized_winner.sketch.nodes[0];
    for (realized_winner.sketch.nodes) |node| if (node.id == rail.pivot) {
        pivot = node;
        break;
    };
    try std.testing.expectEqual(pivot.rect.x + @as(i32, @intCast(pivot.rect.w / 2)), rail.stem[0].x);
    try std.testing.expectEqual(pivot.rect.bottom() - 1, rail.stem[0].y);

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
    const winner = try select.choose(a, graph, &plan, 94, false, false, .bridge);
    const bundles = winner.sketch.bundles;

    try std.testing.expectEqual(@as(usize, 1), winner.sketch.rails.len);
    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);

    const sel_gi = groupIdx(plan.groups, bundles.selected_bundles[0].candidate_bundle);
    try std.testing.expectEqual(pb.BundleDirection.in, plan.groups[sel_gi].direction);
    try std.testing.expectEqual(nodeId(graph, "T2"), plan.groups[sel_gi].pivot);


    const dual = rmByEdge(bundles, edgeId(graph, "S1", "T2"));
    try std.testing.expect(dual.target.? == .selected);
    try std.testing.expect(dual.source.? == .independent);
    try std.testing.expect(rmByEdge(bundles, edgeId(graph, "S2", "T2")).target.? == .selected);
    try std.testing.expect(rmByEdge(bundles, edgeId(graph, "S1", "T1")).source.? == .independent);
    for (bundles.memberships) |rm| {
        const s_sel = rm.source != null and rm.source.? == .selected;
        const t_sel = rm.target != null and rm.target.? == .selected;
        try std.testing.expect(!(s_sel and t_sel));
    }
}

test "V-D-PORT-16 corrected: a fan-out-pivot target DOES re-merge its pure fan-in arrival (OPEN-1 class-1)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> T\n  A --> Z\n  B --> T\n  T --> X\n  T --> Y\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, 94, false, false, .bridge);
    const bundles = winner.sketch.bundles;

    var fi_sel: ?pb.SelectedBundle = null;
    for (bundles.selected_bundles) |sj| {
        const gi = groupIdx(plan.groups, sj.candidate_bundle);
        if (plan.groups[gi].direction == .in and plan.groups[gi].pivot == nodeId(graph, "T")) fi_sel = sj;
    }
    try std.testing.expect(fi_sel != null);

    try std.testing.expectEqual(@as(usize, 2), fi_sel.?.members.len);
    var saw_at = false;
    var saw_bt = false;
    for (fi_sel.?.members) |m| {
        if (m == edgeId(graph, "A", "T")) saw_at = true;
        if (m == edgeId(graph, "B", "T")) saw_bt = true;
    }
    try std.testing.expect(saw_at and saw_bt);

    const dual = rmByEdge(bundles, edgeId(graph, "A", "T"));
    try std.testing.expect(dual.target.? == .selected);
    try std.testing.expect(dual.source.? == .independent);
    try std.testing.expect(rmByEdge(bundles, edgeId(graph, "B", "T")).target.? == .selected);

    const dx = rmByEdge(bundles, edgeId(graph, "T", "X")).source;
    const dy = rmByEdge(bundles, edgeId(graph, "T", "Y")).source;
    try std.testing.expect(dx != null and dy != null);
    try std.testing.expectEqual(std.meta.activeTag(dx.?), std.meta.activeTag(dy.?));

    for (bundles.memberships) |rm| {
        const s_sel = rm.source != null and rm.source.? == .selected;
        const t_sel = rm.target != null and rm.target.? == .selected;
        try std.testing.expect(!(s_sel and t_sel));
    }
}

test "dominance pin: a complete K2,2 decomposes into star rails, never one union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S1 --> T1\n  S1 --> T2\n  S2 --> T1\n  S2 --> T2\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, 94, false, false, .bridge);

    for (winner.sketch.bundles.selected_bundles) |sj| {
        try std.testing.expect(sj.members.len < graph.edges.len);
        for (plan.groups) |g| if (g.id == sj.candidate_bundle) {
            for (sj.members) |m| for (graph.edges) |e| if (e.id == m) {
                const shared = if (g.direction == .out) e.from else e.to;
                try std.testing.expectEqual(g.pivot, shared);
            };
        };
    }
}

const Plain = struct { grid: []const u8, bundles: pb.RealizedBundles, routed: []const u32 };

fn finishPlain(a: std.mem.Allocator, s: anytype) !Plain {
    const rendered = try raster.rasterize(a, s, .bridge);
    const routed = try a.alloc(u32, s.edges.len);
    for (s.edges, routed) |e, *slot| slot.* = e.id;
    return .{
        .grid = try paint.paint(a, rendered.lattice, s.budget.max_width),
        .bundles = s.bundles,
        .routed = routed,
    };
}

/// Render a source end-to-end (select → raster → paint) and return the plain
/// grid plus the winning candidate's plan.
fn renderPlain(a: std.mem.Allocator, source: []const u8, width: u32) !Plain {
    const graph = try parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);
    return finishPlain(a, winner.sketch);
}

/// Render ONE candidate of the live set — the first on the source's
/// `switch_direction` rung, carrying the plan its layout committed — so a
/// test can pin what a layout produces on that candidate without pinning
/// the score's choice.
fn renderRotated(a: std.mem.Allocator, source: []const u8, width: u32) !Plain {
    const graph = try parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const set = try select.enumerateAll(a, graph, &plan, width);
    for (set.merged) |cand| {
        if (cand.rung != .switch_direction) continue;
        return finishPlain(a, cand.sketch);
    }
    return error.NoRotatedCandidate;
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

    const refused = try renderPlain(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n", 70);
    try std.testing.expectEqual(@as(usize, 0), refused.bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), refused.bundles.discharged.len);
    try std.testing.expectEqual(@as(usize, 3), refused.routed.len);
    try std.testing.expect(std.mem.indexOf(u8, refused.grid, "┼") == null);

    // Both candidates are judged: A's departure {A—Z, A—B} (Z is a long
    // member of it) claims first by rank and discharges B—Z; Z's arrival,
    // left with one member, subordinates. A's rail ships with A—B tapped
    // and A—Z as the member stroke, so one edge is routed. Pinned on the
    // rotated (TD) candidate of the LR source: which candidate the score
    // picks is not this test's subject, and the row ledger made the natural
    // LR candidate narrow enough to win at this width.
    const kept = try renderRotated(a, "flowchart LR\n  A --- Z\n  B --- Z\n  A --- B\n", 70);
    try std.testing.expectEqual(@as(usize, 1), kept.bundles.discharged.len);
    try std.testing.expectEqual(@as(usize, 1), kept.routed.len);
    for (kept.bundles.discharged) |co| {
        for (kept.routed) |id| try std.testing.expect(id != co);
    }
    try std.testing.expectEqual(@as(usize, 1), rowsWithInk(kept.grid, "├────┐"));
}

test "a salvaged rail is complete against the commitment the layout drew" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n  A --- B\n  B --- C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, 60, false, false, .bridge);
    var rail_members: usize = 0;
    for (winner.sketch.bundles.selected_bundles) |sj| rail_members = @max(rail_members, sj.members.len);
    try std.testing.expectEqual(@as(usize, 2), rail_members);
    const report = try raster.rasterize(a, winner.sketch, .bridge);
    try std.testing.expectEqual(@as(u32, 0), report.edge_cells_lost);
}

test "a complete all-to-all draws one rail per shared endpoint, and the fused run spends one stub per source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const directed = try renderPlain(a, "flowchart TD\n  A --> X\n  A --> Y\n  B --> X\n  B --> Y\n", 70);
    try std.testing.expectEqual(@as(usize, 2), directed.bundles.selected_bundles.len);
    for (directed.bundles.selected_bundles) |sj| try std.testing.expectEqual(@as(usize, 2), sj.members.len);
    for (0..4) |edge| {
        var owners: usize = 0;
        for (directed.bundles.selected_bundles) |sj| {
            for (sj.members) |m| {
                if (m == edge) owners += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), owners);
    }
    try std.testing.expectEqual(@as(usize, 1), directed.bundles.fused.len);
    try std.testing.expectEqual(@as(usize, 4), directed.bundles.fused[0].len);
    var stubs: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, directed.grid, i, "┬")) |at| : (i = at + 1) stubs += 1;
    try std.testing.expectEqual(@as(usize, 2), stubs);

    const undirected = try renderPlain(a, "flowchart TD\n  A --- X\n  A --- Y\n  B --- X\n  B --- Y\n", 70);
    try std.testing.expectEqual(@as(usize, 0), undirected.bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), undirected.bundles.discharged.len);
    try std.testing.expectEqual(@as(usize, 4), undirected.routed.len);
}

test "a directed complete bipartite keeps its TD star decomposition on clearing rows" {
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
        const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);

        try std.testing.expectEqual(graph.direction, winner.sketch.direction);
        try std.testing.expectEqual(@as(usize, 3), winner.sketch.rails.len);
        for (winner.sketch.rails) |rail| {
            try std.testing.expectEqual(@as(usize, 3), rail.taps.len);
            try std.testing.expectEqual(winner.sketch.rails[0].crossbar[0].y, rail.crossbar[0].y);
        }

        try std.testing.expectEqual(@as(usize, 1), winner.sketch.bundles.fused.len);
        try std.testing.expectEqual(@as(usize, 9), winner.sketch.bundles.fused[0].len);

        for (winner.sketch.rails) |rail| for (rail.taps) |tap| {
            for (winner.sketch.rails) |other| for (other.taps) |t2| {
                if (t2.node == tap.node) try std.testing.expectEqual(tap.at.x, t2.at.x);
            };
        };

        try std.testing.expect(winner.sketch.bbox.w <= width);
    }
}

test "on the licence's lapse path a rail's junction still clears foreign taps" {
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
        const winner = try select.choose(a, graph, &plan, width, false, false, .bridge);

        try std.testing.expect(winner.sketch.rails.len >= 2);
        var rows_differ = false;
        for (winner.sketch.rails) |rail| {
            if (rail.crossbar[0].y != winner.sketch.rails[0].crossbar[0].y) rows_differ = true;
        }
        try std.testing.expect(rows_differ);

        for (winner.sketch.rails) |rail| {
            const stem_x = rail.stem[0].x;
            const junction_y = rail.crossbar[0].y;
            for (winner.sketch.rails) |other| {
                if (other.crossbar[0].y == junction_y) continue;
                for (other.taps) |tap| {
                    if (tap.at.x != stem_x) continue;
                    try std.testing.expect(other.crossbar[0].y < junction_y);
                }
            }
        }
    }
}

test "membership at both ends in production: the skip-layer repro traces only its declared pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> B\n  B --> C\n  A --> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, 94, false, false, .bridge);
    try std.testing.expectEqual(@as(usize, 2), winner.sketch.rails.len);
    try std.testing.expectEqual(@as(usize, 2), winner.sketch.bundles.selected_bundles.len);
    const ac = rmByEdge(winner.sketch.bundles, edgeId(graph, "A", "C"));
    try std.testing.expect(ac.source.? == .selected);
    try std.testing.expect(ac.target.? == .selected);
    var strokes: usize = 0;
    for (winner.sketch.edges) |e| if (e.role == .member_stroke) {
        strokes += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), strokes);
}

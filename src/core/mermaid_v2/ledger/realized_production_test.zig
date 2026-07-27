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

// == #29 class property, asserted on the RASTER (not on permissions) ========
//
// The rework of 63ceb32 exists because nothing in this tree asserted on the
// RENDER: a permission-tier carve-out silently deleted plain edges, blew a
// 53-column canvas out to 261, and fused orphan glyphs onto node borders,
// and every unit test stayed green. These three properties are the standing
// guard for that whole class. They are deliberately stated over a SWEPT
// family (direction x peer count x source-end connector) and never mention a
// node name, a fixture, or an expected glyph.

/// True iff cell (cx, cy) is orthogonally adjacent to `rect`'s perimeter —
/// the "halo" ring where an edge's ink meets the box it attaches to.
/// Diagonal contact does not count: that is not an attachment.
fn haloTouches(rect: anytype, cx: u32, cy: u32) bool {
    const x: i64 = @intCast(cx);
    const y: i64 = @intCast(cy);
    const l: i64 = rect.x;
    const r: i64 = rect.right(); // exclusive
    const t: i64 = rect.y;
    const b: i64 = rect.bottom(); // exclusive
    if (x >= l and x < r and (y == t - 1 or y == b)) return true;
    if (y >= t and y < b and (x == l - 1 or x == r)) return true;
    return false;
}

/// The ink ids that legitimately stand for `edge` on the grid.
///
/// A grid cell records ONE owner id, but mercat's grammar deliberately shares
/// ink: a bus-bar trunk carries `taps[0].edge` for cells all its members use,
/// and two independent polylines that converge on the same terminal cell
/// leave that cell to whichever wrote first. Crediting only the member id
/// would read those legitimate merges as deleted edges, so this returns:
///   - the edge's own id,
///   - the trunk-owner id of any bus-bar it taps,
///   - the id of any edge that shares its exact departure or arrival cell.
fn inkIdsOf(a: std.mem.Allocator, s: anytype, edge: u32) ![]const u32 {
    var ids: std.ArrayListUnmanaged(u32) = .empty;
    try ids.append(a, edge);
    for (s.busbars) |bb| {
        for (bb.taps) |tap| {
            if (tap.edge == edge) try ids.append(a, bb.taps[0].edge);
        }
    }
    for (s.edges) |mine| {
        if (mine.id != edge or mine.polyline.len == 0) continue;
        const head = mine.polyline[0];
        const tail = mine.polyline[mine.polyline.len - 1];
        for (s.edges) |other| {
            if (other.id == edge or other.polyline.len == 0) continue;
            const o_head = other.polyline[0];
            const o_tail = other.polyline[other.polyline.len - 1];
            const shares_arrival = other.to == mine.to and o_tail.x == tail.x and o_tail.y == tail.y;
            const shares_departure = other.from == mine.from and o_head.x == head.x and o_head.y == head.y;
            if (shares_arrival or shares_departure) try ids.append(a, other.id);
        }
    }
    return ids.items;
}

fn rectOf(s: anytype, node: u32) @TypeOf(s.nodes[0].rect) {
    for (s.nodes) |n| if (n.id == node) return n.rect;
    unreachable;
}

/// Sweep body: one (direction, peer count, connector) case. `conn` decorates
/// the FIRST peer's edge only; the remaining peers stay plain `-->`.
fn checkSourceHeadedFamily(
    a: std.mem.Allocator,
    dir: []const u8,
    peers: usize,
    conn: []const u8,
) !void {
    var src: std.ArrayListUnmanaged(u8) = .empty;
    var twin: std.ArrayListUnmanaged(u8) = .empty;
    try src.writer(a).print("flowchart {s}\n", .{dir});
    try twin.writer(a).print("flowchart {s}\n", .{dir});
    for (0..peers) |i| {
        const c = if (i == 0) conn else "-->";
        try src.writer(a).print("  P{d} {s} Z\n", .{ i, c });
        try twin.writer(a).print("  P{d} --> Z\n", .{i});
    }

    const graph = try parse(a, src.items);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, true, 200, false, false);
    const grid = (try raster.rasterize(a, winner.sketch, .bridge)).lattice;

    // (1) No deleted edges: EVERY edge keeps ink at BOTH of its endpoints.
    for (graph.edges) |e| {
        const ids = try inkIdsOf(a, winner.sketch, e.id);
        const from_rect = rectOf(winner.sketch, e.from);
        const to_rect = rectOf(winner.sketch, e.to);
        var at_source = false;
        var at_target = false;
        for (0..grid.height) |yy| for (0..grid.width) |xx| {
            const cx: u32 = @intCast(xx);
            const cy: u32 = @intCast(yy);
            const owner: ?u32 = switch (grid.atConst(cx, cy).occupant) {
                .edge_segment => |seg| seg.edge,
                .arrowhead => |ah| ah.edge,
                else => null,
            };
            const id = owner orelse continue;
            var mine = false;
            for (ids) |candidate| if (candidate == id) {
                mine = true;
            };
            if (!mine) continue;
            if (haloTouches(from_rect, cx, cy)) at_source = true;
            if (haloTouches(to_rect, cx, cy)) at_target = true;
        };
        try std.testing.expect(at_source);
        try std.testing.expect(at_target);
    }

    // (2) No canvas blow-up: the decorated family stays within 1.5x the width
    // of its all-forward twin. (The 2026-07-27 permits carve-out took a
    // 53-column render to 261 — this is the tripwire for that class.) 1.5x,
    // not 2x: a bound of exactly 2 admits a clean DOUBLING, and the live
    // corpus lands cases right on that boundary. Integer form, no rounding.
    const tg = try parse(a, twin.items);
    const tplan = (try permits.build(a, tg, .joined)).plan;
    const twin_w = (try select.choose(a, tg, &tplan, true, 200, false, false)).sketch.bbox.w;
    try std.testing.expect(2 * winner.sketch.bbox.w <= 3 * twin_w);

    // (3) The decorated member's SOURCE-end arrowhead survives, adjacent to
    // its own source node — the #29 defect itself, read off the grid.
    const decorated = graph.edges[0];
    try std.testing.expect(decorated.arrow_from != .none);
    const dids = try inkIdsOf(a, winner.sketch, decorated.id);
    const dsrc = rectOf(winner.sketch, decorated.from);
    const ddst = rectOf(winner.sketch, decorated.to);
    var saw_reverse_head = false;
    var saw_forward_head = false;
    for (0..grid.height) |yy| for (0..grid.width) |xx| {
        const cx: u32 = @intCast(xx);
        const cy: u32 = @intCast(yy);
        switch (grid.atConst(cx, cy).occupant) {
            .arrowhead => |ah| {
                var mine = false;
                for (dids) |candidate| if (candidate == ah.edge) {
                    mine = true;
                };
                if (!mine) continue;
                if (haloTouches(dsrc, cx, cy)) saw_reverse_head = true;
                if (haloTouches(ddst, cx, cy)) saw_forward_head = true;
                // (4) ARROW-BASE LAW, both ends. The cell BEHIND the tip (the
                // one the ink arrives from — opposite `ah.dir`) must not be
                // background: a head fed by blank space reads as arriving from
                // nowhere. Asserted for EVERY head of the decorated edge, so
                // the target end is guarded on the same terms as the source end
                // (the two ends run through different passes — the terminal
                // stub/lengthen vs. `ensureSourceBaseApproach` — and only the
                // source end used to be covered here).
                const dx: i64 = switch (ah.dir) {
                    .east => 1,
                    .west => -1,
                    .north, .south => 0,
                };
                const dy: i64 = switch (ah.dir) {
                    .south => 1,
                    .north => -1,
                    .east, .west => 0,
                };
                const bx: i64 = @as(i64, cx) - dx;
                const by: i64 = @as(i64, cy) - dy;
                try std.testing.expect(bx >= 0 and by >= 0);
                try std.testing.expect(bx < grid.width and by < grid.height);
                const base = grid.atConst(@intCast(bx), @intCast(by)).occupant;
                try std.testing.expect(base != .empty);
            },
            else => {},
        }
    };
    try std.testing.expect(saw_reverse_head);
    try std.testing.expect(saw_forward_head);
}

test "#29 class: a source-end-decorated member keeps both endpoints, its reverse head, and a sane canvas" {
    const dirs = [_][]const u8{ "TD", "BT", "LR", "RL" };
    const conns = [_][]const u8{ "<-->", "o--o", "x--x" };
    for (dirs) |dir| for ([_]usize{ 2, 3, 4, 5 }) |peers| for (conns) |conn| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        checkSourceHeadedFamily(arena.allocator(), dir, peers, conn) catch |err| {
            std.debug.print("[#29 class] FAILED dir={s} peers={d} conn={s}\n", .{ dir, peers, conn });
            return err;
        };
    };
}

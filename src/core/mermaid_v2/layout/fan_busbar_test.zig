//! Tests for `fan_busbar.zig`. Discovered via fan_busbar.zig's top-level
//! `test { _ = @import("fan_busbar_test.zig"); }` block.
//!
//! "busbar taps stay in sync..." moved from `fan_test.zig` (which built
//! this fixture but was really exercising fan_busbar's `Built.taps`
//! aliasing contract through the full `coords.layout` pipeline); its
//! `mkNode`/`mkEdge2`/`findById2`/`deinitSketch2` helpers are duplicated
//! here (rather than moved) since fan_test.zig's OWN remaining
//! "5-source fan-IN sink recenters..." test still uses them.
//!
//! "fan_busbar.blocked rejects..." moved from `routing_test.zig` (which
//! tested `fan_busbar.blocked` directly, unlike the rest of that file's
//! `coords.layout`-driven fan-rail-lift tests).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sketch = @import("../sketch.zig");
const coords = @import("../layout.zig");
const fan_busbar = @import("fan_busbar.zig");

const testing = std.testing;

fn mkNode(id: sg.NodeId, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}
fn mkEdge2(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

fn findById2(nodes: []const sketch.NodePlacement, id: sketch.NodeId) sketch.NodePlacement {
    for (nodes) |n| if (n.id == id) return n;
    @panic("missing node");
}

// coords.layout's Sketch is arena-owned with no public deinit reachable
// from here; testing.allocator would flag a leak if we tried to free it
// piecemeal, so (like layout_test.zig) we simply leak within the test's
// own arena, which the test's `defer arena.deinit()` reclaims.
fn deinitSketch2(s: *sketch.Sketch, allocator: std.mem.Allocator) void {
    _ = s;
    _ = allocator;
}

// -- bus-bar freeze happens AFTER the bbox coordinate-shift pass -------------

test "busbar taps stay in sync with their target node's post-shift position" {
    // P has a fan-out busbar to C1/C2 AND a self-loop. The self-loop's
    // classic "over the top" detour runs above P's north border — since P
    // sits in the topmost layer (y=0), that detour has negative y, forcing
    // computeBbox's shift pass to translate every coordinate down (dy>0).
    // If layout.zig ever copied `.busbar` into the Sketch BEFORE that
    // shift (instead of after), every tap would freeze at its stale
    // pre-shift y while `s.nodes` reports the shifted (correct) position,
    // desyncing the busbar from the very node it's supposed to land on.
    const nodes = [_]sg.Node{ mkNode(0, "P"), mkNode(1, "C1"), mkNode(2, "C2") };
    const edges = [_]sg.Edge{
        mkEdge2(0, 0, 1),
        mkEdge2(1, 0, 2),
        mkEdge2(2, 0, 0), // self-loop on P
    };
    const g = sg.SemGraph{
        .direction = .TD,
        .nodes = &nodes,
        .edges = &edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var s = try coords.layout(arena.allocator(), g, .{});
    defer deinitSketch2(&s, arena.allocator());

    // The self-loop's detour must have actually forced a real shift: P's
    // y must be > 0 (it would be 0, the topmost layer, if no shift fired).
    const p = findById2(s.nodes, 0);
    try testing.expect(p.rect.y > 0);

    // Exactly one busbar, with 2 taps (C1, C2).
    try testing.expectEqual(@as(usize, 1), s.busbars.len);
    const bb = s.busbars[0];
    try testing.expectEqual(@as(usize, 2), bb.taps.len);

    // Every tap must land exactly on its target's final (post-shift) north
    // border — the same shift that moved `s.nodes` must have moved the
    // busbar by the same amount.
    for (bb.taps) |tap| {
        const child = findById2(s.nodes, tap.node);
        const want_x = child.rect.x + @as(i32, @intCast(child.rect.w / 2));
        try testing.expectEqual(want_x, tap.landing.x);
        try testing.expectEqual(child.rect.y, tap.landing.y);
    }
}

// -- claim: fan_busbar.blocked (integrity gate) ------------------------------

test "fan_busbar.blocked rejects a built bus-bar whose tap drop touches a foreign node's box" {
    // Pivot P fans out to two peers Q, R on distinct columns from P's own
    // (so the stem and rail spans stay clear); a foreign box sits exactly
    // on Q's tap-drop column, in the one row between the rail and Q's top
    // (a foreign node's owned cells, border included). `blocked` must
    // reject this artifact rather than let raster amputate the trunk.
    const p = sketch.NodePlacement{ .id = 0, .rect = .{ .x = 20, .y = 0, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null }; // mid x = 25
    const q = sketch.NodePlacement{ .id = 1, .rect = .{ .x = 30, .y = 12, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null }; // mid x = 35
    const other = sketch.NodePlacement{ .id = 2, .rect = .{ .x = 60, .y = 12, .w = 10, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null }; // mid x = 65
    // Foreign box on Q's tap column (x=35) at row 11 only — strictly
    // between the rail (row 10) and Q's top (row 12), off both the stem
    // column (25) and the rail span.
    const foreign = sketch.NodePlacement{ .id = 3, .rect = .{ .x = 33, .y = 11, .w = 4, .h = 1 }, .shape = .rect, .lines = &.{}, .cluster_id = null };
    const placements = [_]sketch.NodePlacement{ p, q, other, foreign };

    const e_pq = sg.Edge{ .id = 0, .from = 0, .to = 1, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
    const e_po = sg.Edge{ .id = 1, .from = 0, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };

    var peers = [_]fan_busbar.Peer{
        .{ .edge = e_pq, .placement = q },
        .{ .edge = e_po, .placement = other },
    };
    const resolved = fan_busbar.Resolved{ .pivot = p, .peers = &peers };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const built = try fan_busbar.build(arena.allocator(), resolved, 0, 0);

    try testing.expect(fan_busbar.blocked(built, p.id, &placements));

    // Control: the same fixture minus the foreign box must NOT be blocked.
    const clean_placements = [_]sketch.NodePlacement{ p, q, other };
    try testing.expect(!fan_busbar.blocked(built, p.id, &clean_placements));
}

// -- claim: formal base approach (rail lift for a straight base cell) --------

fn mkPlace(id: sketch.NodeId, x: i32, y: i32, w: u16, h: u16) sketch.NodePlacement {
    return .{ .id = id, .rect = .{ .x = x, .y = y, .w = w, .h = h }, .shape = .rect, .lines = &.{}, .cluster_id = null };
}

test "formal base approach: rail lifts one row when the gap admits it, holds at a gap of 2" {
    // LAW (owner ruling): every terminal arrowhead must have >= 1 straight
    // collinear stroke cell on its base side before any junction. The bus-bar
    // tap-drop (fan-OUT) / stem (fan-IN) must therefore leave a straight `│`
    // between the rail junction and the `▼` when the gap admits it (off=3),
    // but must hold at the old off=2 geometry when lifting the rail would land
    // it on the pivot border (fan-OUT) / a source border (fan-IN) — the tight
    // rung halves v_spacing, so the gap can be as small as 2. Geometry-generic:
    // the guard reads only the rects, never a seed name.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // -- fan-OUT, gap = 4 (natural fan headroom) -> rail lifts (off=3) --------
    // pivot bottom border row = 2; peer top row = 6 (gap 4). off=3 puts the
    // rail at row 3 (one clear row below the pivot border), so the tap drops
    // rail(3) -> `│`(4) -> `▼`(5) -> peer top(6): a straight base cell exists.
    {
        const pivot = mkPlace(0, 20, 0, 10, 3); // bottom()-1 = 2
        const q = mkPlace(1, 10, 6, 6, 3); // top = 6
        const r = mkPlace(2, 30, 6, 6, 3); // top = 6
        var peers = [_]fan_busbar.Peer{
            .{ .edge = mkEdge2(0, 0, 1), .placement = q },
            .{ .edge = mkEdge2(1, 0, 2), .placement = r },
        };
        const resolved = fan_busbar.Resolved{ .pivot = pivot, .direction = .out, .peers = &peers };
        const built = try fan_busbar.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 3), built.busbar.rail[0].y); // off=3
        // >= 1 straight base cell: arrowhead sits at landing-1, base at landing-2,
        // and the base must be strictly below the rail junction.
        for (built.taps) |tap| {
            try testing.expect(built.busbar.rail[0].y <= tap.landing.y - 3);
        }
        // Rail stays strictly below the pivot's bottom border row (no overlap).
        try testing.expect(built.busbar.rail[0].y > pivot.rect.bottom() - 1);
    }

    // -- fan-OUT, gap = 3 -> guard HOLDS at off=2 (a blind -3 would touch) -----
    // peer top row = 5; a blind off=3 would put the rail on row 2 == the pivot
    // border. The guard declines and keeps off=2 (rail row 3), still clear.
    {
        const pivot = mkPlace(0, 20, 0, 10, 3); // bottom()-1 = 2
        const q = mkPlace(1, 10, 5, 6, 3); // top = 5
        const r = mkPlace(2, 30, 5, 6, 3); // top = 5
        var peers = [_]fan_busbar.Peer{
            .{ .edge = mkEdge2(0, 0, 1), .placement = q },
            .{ .edge = mkEdge2(1, 0, 2), .placement = r },
        };
        const resolved = fan_busbar.Resolved{ .pivot = pivot, .direction = .out, .peers = &peers };
        const built = try fan_busbar.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 3), built.busbar.rail[0].y); // off=2 held
        try testing.expect(built.busbar.rail[0].y > pivot.rect.bottom() - 1); // no overlap
    }

    // -- fan-OUT, gap = 2 (tight rung) -> off=2 held, byte-identical to today --
    // peer top row = 4; off=2 -> rail row 2 (== pivot border, blocked() then
    // falls back to the polyline path, exactly as today). off=3 must NOT fire.
    {
        const pivot = mkPlace(0, 20, 0, 10, 3); // bottom()-1 = 2
        const q = mkPlace(1, 10, 4, 6, 3); // top = 4
        const r = mkPlace(2, 30, 4, 6, 3); // top = 4
        var peers = [_]fan_busbar.Peer{
            .{ .edge = mkEdge2(0, 0, 1), .placement = q },
            .{ .edge = mkEdge2(1, 0, 2), .placement = r },
        };
        const resolved = fan_busbar.Resolved{ .pivot = pivot, .direction = .out, .peers = &peers };
        const built = try fan_busbar.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 2), built.busbar.rail[0].y); // off=2, unchanged
    }

    // -- fan-IN, gap = 8 -> stem lifts (off=3), sink arrowhead gains a base ----
    // sink top row = 10; sources' bottom border row = 2. off=3 puts the rail at
    // row 7, so the stem runs rail(7) -> `│`(8) -> `▼`(9) -> sink top(10): the
    // terminal (sink) arrowhead now has a straight base cell above it.
    {
        const sink = mkPlace(0, 20, 10, 10, 3); // top = 10
        const s1 = mkPlace(1, 10, 0, 6, 3); // bottom()-1 = 2
        const s2 = mkPlace(2, 30, 0, 6, 3); // bottom()-1 = 2
        var peers = [_]fan_busbar.Peer{
            .{ .edge = mkEdge2(0, 1, 0), .placement = s1 },
            .{ .edge = mkEdge2(1, 2, 0), .placement = s2 },
        };
        const resolved = fan_busbar.Resolved{ .pivot = sink, .direction = .in, .peers = &peers };
        const built = try fan_busbar.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 7), built.busbar.rail[0].y); // off=3
        // Stem base cell: sink top - rail >= 3 (arrowhead at top-1, base at top-2).
        try testing.expect(built.busbar.rail[0].y <= sink.rect.y - 3);
        // Rail stays above the sink and below every source bottom (no overlap).
        try testing.expect(built.busbar.rail[0].y < sink.rect.y);
        for (peers) |pr| try testing.expect(built.busbar.rail[0].y > pr.placement.rect.bottom() - 1);
    }

    // -- fan-IN, gap = 3 -> guard HOLDS at off=2 (a blind -3 would touch) ------
    // sink top row = 5; sources' bottom = 2. A blind off=3 would put the rail on
    // row 2 == a source border. The guard declines and keeps off=2 (rail row 3).
    {
        const sink = mkPlace(0, 20, 5, 10, 3); // top = 5
        const s1 = mkPlace(1, 10, 0, 6, 3); // bottom()-1 = 2
        const s2 = mkPlace(2, 30, 0, 6, 3); // bottom()-1 = 2
        var peers = [_]fan_busbar.Peer{
            .{ .edge = mkEdge2(0, 1, 0), .placement = s1 },
            .{ .edge = mkEdge2(1, 2, 0), .placement = s2 },
        };
        const resolved = fan_busbar.Resolved{ .pivot = sink, .direction = .in, .peers = &peers };
        const built = try fan_busbar.build(a, resolved, 0, 0);
        try testing.expectEqual(@as(i32, 3), built.busbar.rail[0].y); // off=2 held
        for (peers) |pr| try testing.expect(built.busbar.rail[0].y > pr.placement.rect.bottom() - 1); // no overlap
    }
}

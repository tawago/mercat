//! fan_lanes_test2.zig — continuation of fan_lanes_test.zig, split at the
//! mermaid_v2 500-line cap. Same zone privileges; the shared graph/geometry
//! builders are imported from fan_lanes_test.zig.
//!
//! These pin the closure test `fusionForbidden` asks of a fused group: what a
//! run ASSERTS depends on its arrowheads, and a group keeps one shared row
//! only when the source DECLARES all of it.

const std = @import("std");
const testing = std.testing;
const sg = @import("../sem_graph.zig");
const sugiyama = @import("sugiyama.zig");
const fan = @import("fan.zig");
const fan_lanes = @import("fan_lanes.zig");
const pb = @import("../base/ledger.zig");
const flt = @import("fan_lanes_test.zig");
const Geom = flt.Geom;
const mkLg = flt.mkLg;
const mkGraph = flt.mkGraph;
const mkBareGraph = flt.mkBareGraph;
const laneOfPivot = flt.laneOfPivot;

/// A,B on one stage, X,Y on the next, every cross pair declared — the shape
/// whose declared set is complete. Callers supply the arrowheads.
fn twoByTwo() struct { nodes: [4]sugiyama.LayerNode, edges: [4]sugiyama.LayerEdge } {
    return .{
        .nodes = .{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 } },
        .edges = .{
            .{ .from = 0, .to = 2, .reversed = false, .edge = 0 }, // A—X
            .{ .from = 0, .to = 3, .reversed = false, .edge = 1 }, // A—Y
            .{ .from = 1, .to = 2, .reversed = false, .edge = 2 }, // B—X
            .{ .from = 1, .to = 3, .reversed = false, .edge = 3 }, // B—Y
        },
    };
}

test "an arrow-free group whose declared set is complete still separates" {
    // Arrow-free, so the fused run would assert every UNORDERED pair among its
    // endpoints — including A—B and X—Y, which a two-sided source never
    // declares. Completeness of the cross pairs buys nothing here.
    const a = testing.allocator;
    var fixture = twoByTwo();
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 } };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkBareGraph(aa, &fixture.edges, &.{});
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
    try testing.expect(laneOfPivot(fans, .out, 0) != laneOfPivot(fans, .out, 1));
}

test "a directed group whose declared set is complete keeps one shared row" {
    // Every member carries an arrowhead, so the run asserts only the CROSS
    // pairs — the stage separation removes the within-side reading. The source
    // declares all four of them, so nothing undeclared is asserted and no
    // rail needs a row of its own.
    const a = testing.allocator;
    var fixture = twoByTwo();
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 }, .{ .x = 0, .w = 3 }, .{ .x = 9, .w = 3 } };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &fixture.edges); // every edge arrow_to = filled
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
    for (fans) |f| try testing.expectEqual(@as(u32, 0), f.lane);
}

test "a directed group whose declared set is short of complete still separates" {
    // A->X, A->Y, A->Z, B->X, B->Y. Two sources, three targets: the fused run
    // would assert all six cross pairs, but B—Z is not declared, so the run
    // speaks for a pivot nothing declares and the rails separate.
    //
    // Built so a naive `edges.len` sum WOULD wrongly admit it. B's departure
    // has every peer selected into an arrival rail, so it keeps its own rail
    // yet stays out of `fanout_edges`; B->X is therefore modelled twice, once
    // by B's departure and once by X's arrival. Rail lengths then sum to
    // 3 + 2 + 1 = 6 == 2 * 3, an exact false match, while the DISTINCT declared
    // pairs number 5. Y's arrival draws no rail at all (its only undeferred
    // peer B sits on Y's own column).
    const a = testing.allocator;
    var nodes = [_]sugiyama.LayerNode{
        .{ .real = 0 }, .{ .real = 1 }, // A B
        .{ .real = 2 }, .{ .real = 3 }, .{ .real = 4 }, // X Y Z
    };
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3, 4 };
    var layers = [_][]u32{ &row0, &row1 };
    var edges = [_]sugiyama.LayerEdge{
        .{ .from = 0, .to = 2, .reversed = false, .edge = 0 }, // A->X
        .{ .from = 0, .to = 3, .reversed = false, .edge = 1 }, // A->Y
        .{ .from = 0, .to = 4, .reversed = false, .edge = 2 }, // A->Z
        .{ .from = 1, .to = 2, .reversed = false, .edge = 3 }, // B->X
        .{ .from = 1, .to = 3, .reversed = false, .edge = 4 }, // B->Y
    };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&nodes, &layers, &edges, &reversed);
    // Centres: A 1, B 21; X 11, Y 21 (B's own column), Z 41.
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 },  .{ .x = 20, .w = 3 },
        .{ .x = 10, .w = 3 }, .{ .x = 20, .w = 3 },
        .{ .x = 40, .w = 3 },
    };

    var x_members = [_]pb.EdgeId{3};
    var y_members = [_]pb.EdgeId{4};
    var selected = [_]pb.SelectedBundle{
        .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &x_members },
        .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &y_members },
    };
    // A's departure keeps its own run (A->Z bundles nothing); B's does not.
    var memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .overlap_conflict } }, .target = null },
        .{ .edge = 1, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .overlap_conflict } }, .target = null },
        .{ .edge = 2, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .overlap_conflict } }, .target = null },
        .{ .edge = 3, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .overlap_conflict } }, .target = .{ .selected = 0 } },
        .{ .edge = 4, .source = .{ .independent = .{ .candidate_bundle = 2, .reason = .overlap_conflict } }, .target = .{ .selected = 1 } },
    };
    const bundles: pb.RealizedBundles = .{ .selected_bundles = &selected, .memberships = &memberships };

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, bundles, null);
    try testing.expect(laneOfPivot(fans, .out, 0) != laneOfPivot(fans, .out, 1));
}

/// A,B,C on one stage, X,Y on the next. A and B declare both cross pairs; C
/// declares only C->X, so the union is 5 of 6 and must never fuse.
fn fiveOfSix() struct { nodes: [5]sugiyama.LayerNode, edges: [5]sugiyama.LayerEdge } {
    return .{
        .nodes = .{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 }, .{ .real = 3 }, .{ .real = 4 } },
        .edges = .{
            .{ .from = 0, .to = 3, .reversed = false, .edge = 0 }, // A->X
            .{ .from = 0, .to = 4, .reversed = false, .edge = 1 }, // A->Y
            .{ .from = 1, .to = 3, .reversed = false, .edge = 2 }, // B->X
            .{ .from = 1, .to = 4, .reversed = false, .edge = 3 }, // B->Y
            .{ .from = 2, .to = 3, .reversed = false, .edge = 4 }, // C->X
        },
    };
}

/// Run `fiveOfSix` with C placed at centre `cx_c` and the given plan.
fn runFiveOfSix(cx_c: i32, bundles: pb.RealizedBundles) !bool {
    const a = testing.allocator;
    var fixture = fiveOfSix();
    var row0 = [_]u32{ 0, 2, 1 };
    var row1 = [_]u32{ 3, 4 };
    var layers = [_][]u32{ &row0, &row1 };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
    // Centres: A 1, B 41; X 21, Y 41. C's centre is the caller's.
    const geom = [_]Geom{
        .{ .x = 0, .w = 3 },  .{ .x = 40, .w = 3 }, .{ .x = cx_c - 1, .w = 3 },
        .{ .x = 20, .w = 3 }, .{ .x = 40, .w = 3 },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const graph = try mkGraph(aa, &fixture.edges);
    const fans = try fan.detect(aa, graph, lg);
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, bundles, null);
    return laneOfPivot(fans, .out, 0) != laneOfPivot(fans, .out, 1);
}

test "a peer on its pivot's own column never shrinks a group into looking complete" {
    // C->X draws no horizontal run when C sits on X's column, so X's arrival
    // models nothing and C leaves srcs — leaving {A,B} x {X,Y}, four pairs of
    // four, an exact false "complete". C's vertical still descends onto the
    // fused crossbar, so a reader traces C to Y, a pair nothing declares.
    // Placed geometry must not decide legality: both placements separate.
    try testing.expect(try runFiveOfSix(21, .{})); // C's centre == X's
    try testing.expect(try runFiveOfSix(31, .{})); // C's centre free
}

test "a discharged edge never shrinks a group into looking complete" {
    // Same 5-of-6 union, C placed clear of X. Co-realizing C->X removes it
    // from every rail model — its ink IS the crossbar — so the counts read
    // 2 x 2 complete. They are not a declaration count, and C—Y stays
    // undeclared, so the rails still separate.
    var co = [_]pb.EdgeId{4};
    try testing.expect(try runFiveOfSix(31, .{ .discharged = &co }));
}

test "a two-sided group whose heads are direction-invariant still separates" {
    // o--o at both ends: a glyph is present, but circle heads are
    // direction-invariant, so nothing blocks the leaf-to-leaf trace and the
    // complete cross set buys no more than it does for `---`. Same for x--x.
    // (<--> goes further: a member with directional ends on BOTH sides loses
    // the star licence itself — covered below.)
    const a = testing.allocator;
    for ([_][2]sg.ArrowEnd{
        .{ .circle, .circle },
        .{ .cross, .cross },
    }) |heads| {
        var fixture = twoByTwo();
        var row0 = [_]u32{ 0, 1 };
        var row1 = [_]u32{ 2, 3 };
        var layers = [_][]u32{ &row0, &row1 };
        var reversed = [_]sg.EdgeId{};
        const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
        const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 20, .w = 3 }, .{ .x = 10, .w = 3 }, .{ .x = 30, .w = 3 } };
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const aa = arena.allocator();
        const es = try aa.alloc(sg.Edge, fixture.edges.len);
        for (fixture.edges, es) |le, *e| e.* = .{
            .id = le.edge,
            .from = le.from,
            .to = le.to,
            .kind = .solid,
            .arrow_from = heads[0],
            .arrow_to = heads[1],
            .label = null,
        };
        const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = es, .clusters = &.{}, .classes = &.{}, .arena = null };
        const fans = try fan.detect(aa, graph, lg);
        try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
        try testing.expect(laneOfPivot(fans, .out, 0) != laneOfPivot(fans, .out, 1));
    }
}

test "a two-sided group of double-headed members loses the star licence outright" {
    // <--> permits both orientations, so no member blocks (L1's predicate):
    // the star may not share a rail at all — every peer stays private
    // instead of merely lane-separating.
    const a = testing.allocator;
    var fixture = twoByTwo();
    var row0 = [_]u32{ 0, 1 };
    var row1 = [_]u32{ 2, 3 };
    var layers = [_][]u32{ &row0, &row1 };
    var reversed = [_]sg.EdgeId{};
    const lg = mkLg(&fixture.nodes, &layers, &fixture.edges, &reversed);
    const geom = [_]Geom{ .{ .x = 0, .w = 3 }, .{ .x = 20, .w = 3 }, .{ .x = 10, .w = 3 }, .{ .x = 30, .w = 3 } };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const es = try aa.alloc(sg.Edge, fixture.edges.len);
    for (fixture.edges, es) |le, *e| e.* = .{
        .id = le.edge,
        .from = le.from,
        .to = le.to,
        .kind = .solid,
        .arrow_from = .open,
        .arrow_to = .open,
        .label = null,
    };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &.{}, .edges = es, .clusters = &.{}, .classes = &.{}, .arena = null };
    const fans = try fan.detect(aa, graph, lg);
    for (fans) |f| {
        try testing.expect(f.construction_star_violation);
        for (f.peers) |p| try testing.expect(!p.shared);
    }
    try fan_lanes.assignLanes(Geom, aa, graph, lg, &geom, fans, .{}, null);
}

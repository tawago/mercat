//! reach_vector_test.zig — vector-half V-D-REACH oracle tests
//! (P2v Step 6), part 1: pass vectors, defect vectors, the clustered
//! skip, and shared fixture helpers (pub, consumed by the split sibling
//! reach_vector_test2.zig). Painted halves and the clause-11
//! mismatch tag land with validate_raster in Step 9. Aggregated from
//! entry.zig's `test {}` block.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! sketch, sem_graph, parse, reach_vector, realized, permits.

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const planner = @import("permits.zig");
const jp = @import("realized.zig");
const vc = @import("reach_vector.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// -- Helpers -----------------------------------------------------------------

pub fn node(id: sg.NodeId, raw_id: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw_id, .label = raw_id, .shape = .rect, .classes = &.{}, .cluster = null };
}

pub fn edge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

pub fn graphOf(nodes: []const sg.Node, edges: []const sg.Edge) sg.SemGraph {
    return .{ .direction = .TD, .nodes = nodes, .edges = edges, .clusters = &.{}, .classes = &.{}, .arena = null };
}

pub fn nodeKeys(a: std.mem.Allocator, nodes: []const sg.Node) ![]const []const u8 {
    const keys = try a.alloc([]const u8, nodes.len);
    for (nodes) |n| keys[n.id] = n.raw_id;
    return keys;
}

pub fn path(id: sk.EdgeId, from: sk.NodeId, to: sk.NodeId, polyline: []const sk.Point) sk.EdgePath {
    return .{
        .id = id, .from = from, .to = to, .polyline = polyline,
        .port_from = .{ .node = from, .side = .south, .offset = 0 },
        .port_to = .{ .node = to, .side = .north, .offset = 0 },
        .arrow_from = .none, .arrow_to = .filled, .label = null, .kind = .solid,
    };
}

pub fn sketchOf(edges: []const sk.EdgePath, busbars: []const sk.BusBar) sk.Sketch {
    return .{
        .bbox = .{ .x = 0, .y = 0, .w = 40, .h = 16 }, .direction = .TD,
        .nodes = &.{}, .clusters = &.{}, .edges = edges, .busbars = busbars,
        .diagnostics = &.{}, .budget = .{ .max_width = 120, .rung = 0 },
    };
}

/// Attach a production-shaped realized plan (join_permits + realized over
/// the candidate's own geometry).
pub fn realized(a: std.mem.Allocator, g: sg.SemGraph, s: sk.Sketch, mesh: []const pb.MeshUnion) !sk.Sketch {
    const plan = (try planner.build(a, g, .joined)).plan;
    var out = s;
    out.joins = (try jp.realize(a, plan, s, mesh)).plan;
    return out;
}

pub fn tp(n: sk.NodeId, e: sk.EdgeId, side: pb.EndpointSide) pb.TerminalPort {
    return .{ .node = n, .edge = e, .endpoint_side = side, .port = 0 };
}

pub fn hasPair(pairs: []const pb.NodePair, s: sk.NodeId, t: sk.NodeId) bool {
    for (pairs) |p| if (p.source == s and p.target == t) return true;
    return false;
}

pub fn anyReachable(report: vc.Report, s: sk.NodeId, t: sk.NodeId) bool {
    for (report.components) |comp| if (hasPair(comp.reachable_pairs, s, t)) return true;
    return false;
}

pub fn zeroCounts(counts: vc.Counts) bool {
    return counts.ciTotal() == 0 and counts.skipped_clustered == 0;
}

// V-01 geometry: carve-out-admitted TD fan-out trunk S->{A,B,C}.
pub const fan_nodes = [_]sg.Node{ node(0, "S"), node(1, "A"), node(2, "B"), node(3, "C") };
pub const fan_edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 0, 3) };
pub const fan_stem = [_]sk.Point{ .{ .x = 10, .y = 2 }, .{ .x = 10, .y = 4 } };
pub fn fanTaps(rail_covers_all: bool) [3]sk.Tap {
    _ = rail_covers_all;
    return .{
        .{ .edge = 0, .node = 1, .at = .{ .x = 4, .y = 4 }, .landing = .{ .x = 4, .y = 6 } },
        .{ .edge = 1, .node = 2, .at = .{ .x = 10, .y = 4 }, .landing = .{ .x = 10, .y = 6 } },
        .{ .edge = 2, .node = 3, .at = .{ .x = 16, .y = 4 }, .landing = .{ .x = 16, .y = 6 } },
    };
}
pub fn fanBusBar(taps: []const sk.Tap, rail_hi: i32) sk.BusBar {
    return .{ .pivot = 0, .stem = &fan_stem, .rail = .{ .{ .x = 4, .y = 4 }, .{ .x = rail_hi, .y = 4 } }, .taps = taps, .kind = .solid, .role = .fan_out_rail };
}

test "V-D-REACH-01 (vector): admitted fan-out trunk is one component, Cartesian == declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const taps = fanTaps(true);
    const bbs = [_]sk.BusBar{fanBusBar(&taps, 16)};
    const g = graphOf(&fan_nodes, &fan_edges);
    const s = try realized(a, g, sketchOf(&.{}, &bbs), &.{});
    try expectEqual(@as(usize, 1), s.joins.selected_joins.len);

    const report = try vc.validate(a, s, try nodeKeys(a, &fan_nodes), .flat);
    try expect(zeroCounts(report.counts));
    try expectEqual(@as(usize, 1), report.components.len);
    const comp = report.components[0];
    try expectEqual(@as(usize, 3), comp.source_terminals.len);
    try expectEqual(@as(usize, 3), comp.target_terminals.len);
    try expectEqual(@as(usize, 3), comp.reachable_pairs.len);
    try expectEqual(@as(usize, 3), comp.declared_pairs_in_component.len);
    try expectEqual(@as(usize, 0), comp.extra_undeclared_pairs.len);
    try expectEqual(@as(usize, 0), comp.missing_declared_pairs.len);
    // §12.4 table shape: ids dense from 0; bridge_ids structurally empty.
    try expectEqual(@as(pb.ComponentId, 0), comp.id);
    try expectEqual(@as(usize, 0), comp.bridge_ids.len);
    try expectEqual(@as(usize, 1), comp.selected_join_ids.len);
}

test "V-D-REACH-02 (vector): admitted fan-in trunk is one component, 3x1 pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C"), node(3, "T") };
    const edges = [_]sg.Edge{ edge(0, 0, 3), edge(1, 1, 3), edge(2, 2, 3) };
    const stem = [_]sk.Point{ .{ .x = 10, .y = 8 }, .{ .x = 10, .y = 6 } };
    const taps = [_]sk.Tap{
        .{ .edge = 0, .node = 0, .at = .{ .x = 4, .y = 6 }, .landing = .{ .x = 4, .y = 4 } },
        .{ .edge = 1, .node = 1, .at = .{ .x = 10, .y = 6 }, .landing = .{ .x = 10, .y = 4 } },
        .{ .edge = 2, .node = 2, .at = .{ .x = 16, .y = 6 }, .landing = .{ .x = 16, .y = 4 } },
    };
    const bbs = [_]sk.BusBar{.{ .pivot = 3, .stem = &stem, .rail = .{ .{ .x = 4, .y = 6 }, .{ .x = 16, .y = 6 } }, .taps = &taps, .kind = .solid, .role = .fan_in_rail }};
    const s = try realized(a, graphOf(&nodes, &edges), sketchOf(&.{}, &bbs), &.{});
    try expectEqual(@as(usize, 1), s.joins.selected_joins.len);

    const report = try vc.validate(a, s, try nodeKeys(a, &nodes), .flat);
    try expect(zeroCounts(report.counts));
    try expectEqual(@as(usize, 1), report.components.len);
    try expectEqual(@as(usize, 3), report.components[0].source_terminals.len);
    try expectEqual(@as(usize, 3), report.components[0].reachable_pairs.len);
    try expectEqual(@as(usize, 0), report.components[0].extra_undeclared_pairs.len);
}

// K3,3 geometry: nine polylines fused on one rail row (y=4).
const k33_nodes = [_]sg.Node{
    node(0, "S1"), node(1, "S2"), node(2, "S3"),
    node(3, "T1"), node(4, "T2"), node(5, "T3"),
};
fn k33Graph(a: std.mem.Allocator) !struct { g: sg.SemGraph, paths: []sk.EdgePath } {
    var edges = try a.alloc(sg.Edge, 9);
    var paths = try a.alloc(sk.EdgePath, 9);
    const xs = [_]i32{ 2, 6, 10 };
    for (0..3) |si| {
        for (0..3) |ti| {
            const id: u32 = @intCast(si * 3 + ti);
            edges[id] = edge(id, @intCast(si), @intCast(3 + ti));
            const pts = try a.dupe(sk.Point, &.{
                .{ .x = xs[si], .y = 2 }, .{ .x = xs[si], .y = 4 },
                .{ .x = xs[ti], .y = 4 }, .{ .x = xs[ti], .y = 6 },
            });
            paths[id] = path(id, @intCast(si), @intCast(3 + ti), pts);
        }
    }
    return .{ .g = graphOf(&k33_nodes, edges), .paths = paths };
}

test "V-D-REACH-04(b) (vector): labeled exact-complete K3,3 union is ONE legal channel; unlabeled fires reach_unknown_continuation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const k33 = try k33Graph(a);
    const keys = try nodeKeys(a, &k33_nodes);
    const members = [_]pb.EdgeId{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const mu = [_]pb.MeshUnion{.{ .id = 0, .members = &members, .source_keys = &.{ "S1", "S2", "S3" }, .target_keys = &.{ "T1", "T2", "T3" } }};

    // Labeled: one exempt-mesh-union channel, Cartesian == declared, no tag.
    const labeled = try realized(a, k33.g, sketchOf(k33.paths, &.{}), &mu);
    try expectEqual(@as(usize, 1), labeled.joins.mesh_unions.len);
    const lr = try vc.validate(a, labeled, keys, .flat);
    try expect(zeroCounts(lr.counts));
    try expectEqual(@as(usize, 1), lr.components.len);
    try expectEqual(@as(usize, 9), lr.components[0].reachable_pairs.len);
    try expectEqual(@as(usize, 9), lr.components[0].declared_pairs_in_component.len);
    try expectEqual(@as(usize, 0), lr.components[0].extra_undeclared_pairs.len);

    // Same geometry UNLABELED: cross-owner collinear sharing, channels
    // stay separate — recorded provenance, never geometric inference.
    const unlabeled = try realized(a, k33.g, sketchOf(k33.paths, &.{}), &.{});
    try expectEqual(@as(usize, 0), unlabeled.joins.mesh_unions.len);
    const ur = try vc.validate(a, unlabeled, keys, .flat);
    try expect(ur.counts.unknown_continuation > 0);
    try expectEqual(@as(u32, 0), ur.counts.undeclared_pair);
    try expectEqual(@as(u32, 0), ur.counts.independent_joined);
    try expectEqual(@as(usize, 9), ur.components.len);
    for (ur.components) |comp| try expectEqual(@as(usize, 1), comp.reachable_pairs.len);
}

test "V-D-REACH-05 (vector): no node transit — A->B, B->C stay two components, (A,C) unreachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C") };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 1, 2) };
    const paths = [_]sk.EdgePath{
        path(0, 0, 1, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 } }),
        path(1, 1, 2, &.{ .{ .x = 2, .y = 8 }, .{ .x = 2, .y = 12 } }),
    };
    const s = try realized(a, graphOf(&nodes, &edges), sketchOf(&paths, &.{}), &.{});
    const report = try vc.validate(a, s, try nodeKeys(a, &nodes), .flat);
    try expect(zeroCounts(report.counts));
    try expectEqual(@as(usize, 2), report.components.len);
    for (report.components) |comp| try expectEqual(@as(usize, 1), comp.reachable_pairs.len);
    try expect(!anyReachable(report, 0, 2));
}

test "V-D-REACH-06 (vector): separate ports stay separate — equal-NodeId terminals add no link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, "S1"), node(1, "S2"), node(2, "T") };
    const edges = [_]sg.Edge{ edge(0, 0, 2), edge(1, 1, 2) };
    const paths = [_]sk.EdgePath{
        path(0, 0, 2, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 } }),
        path(1, 1, 2, &.{ .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 6 } }),
    };
    const s = try realized(a, graphOf(&nodes, &edges), sketchOf(&paths, &.{}), &.{});
    const report = try vc.validate(a, s, try nodeKeys(a, &nodes), .flat);
    try expect(zeroCounts(report.counts));
    try expectEqual(@as(usize, 2), report.components.len);
    for (report.components) |comp| try expectEqual(@as(usize, 1), comp.reachable_pairs.len);
}

test "V-D-REACH-09(b) (vector): declared edge with no ink and no terminals fires reach_missing_declared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C"), node(3, "D") };
    const paths = [_]sk.EdgePath{path(0, 0, 1, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 } })};
    var s = sketchOf(&paths, &.{});
    // Fault-injected drop: edge 1 (C->D) is declared in the plan but has
    // no geometry and no terminal records.
    s.joins = .{
        .memberships = &.{
            .{ .edge = 0, .source = null, .target = null },
            .{ .edge = 1, .source = null, .target = null },
        },
        .terminal_ports = &.{ tp(0, 0, .source_exit), tp(1, 0, .target_entry) },
    };
    const report = try vc.validate(a, s, try nodeKeys(a, &nodes), .flat);
    try expectEqual(@as(u32, 1), report.counts.missing_declared);
    try expectEqual(@as(u32, 0), report.counts.split_trace);
    try expectEqual(@as(usize, 1), report.missing_declared.len);
    try expectEqual(@as(u32, 1), report.missing_declared[0]); // membership rank
}

test "V-D-REACH-12: clustered input skips with a report-only count, no traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const paths = [_]sk.EdgePath{path(0, 0, 1, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 } })};
    var s = sketchOf(&paths, &.{});
    const frames = [_]sk.ClusterFrame{.{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .parent_id = null, .label = "G", .depth = 0 }};
    s.clusters = &frames;
    const report = try vc.validate(a, s, &.{}, .clustered);
    try expect(report.skipped_clustered);
    try expectEqual(@as(u32, 1), report.counts.skipped_clustered);
    try expectEqual(@as(u32, 0), report.counts.ciTotal());
    try expectEqual(@as(usize, 0), report.components.len);
}

test "F2: packed-candidate skip is distinct from the clustered-input skip" {
    // Same cluster-framed sketch, two ORIGINAL-input facts: a clustered
    // input records the registered RO skip; a flat input (frames are
    // synthetic packing chrome) records the NEW non-tag count — separate
    // fields, separate report flags, distinct serialized bytes (OPEN-8).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const paths = [_]sk.EdgePath{path(0, 0, 1, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 } })};
    var s = sketchOf(&paths, &.{});
    const frames = [_]sk.ClusterFrame{.{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .parent_id = null, .label = "G", .depth = 0 }};
    s.clusters = &frames;

    const clustered = try vc.validate(a, s, &.{}, .clustered);
    try expect(clustered.skipped_clustered and !clustered.skipped_packed);
    try expectEqual(@as(u32, 1), clustered.counts.skipped_clustered);
    try expectEqual(@as(u32, 0), clustered.counts.skipped_packed_candidate);

    const packed_skip = try vc.validate(a, s, &.{}, .flat);
    try expect(packed_skip.skipped_packed and !packed_skip.skipped_clustered);
    try expectEqual(@as(u32, 1), packed_skip.counts.skipped_packed_candidate);
    try expectEqual(@as(u32, 0), packed_skip.counts.skipped_clustered);
    try expectEqual(@as(u32, 0), packed_skip.counts.ciTotal()); // still a skip, not CI
    try expectEqual(@as(usize, 0), packed_skip.components.len); // no traversal

    const cb = try vc.serialize(a, clustered, &.{});
    const pkb = try vc.serialize(a, packed_skip, &.{});
    try expect(!std.mem.eql(u8, cb, pkb));
}

test "V-D-REACH-16 (vector half): strict orthogonal transversal crossing is legal and adds no link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C"), node(3, "D") };
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 2, 3) };
    const paths = [_]sk.EdgePath{
        path(0, 0, 1, &.{ .{ .x = 2, .y = 6 }, .{ .x = 10, .y = 6 } }),
        path(1, 2, 3, &.{ .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 10 } }),
    };
    const s = try realized(a, graphOf(&nodes, &edges), sketchOf(&paths, &.{}), &.{});
    const report = try vc.validate(a, s, try nodeKeys(a, &nodes), .flat);
    try expect(zeroCounts(report.counts)); // TSD §7.5 MAY: no tag, no link
    try expectEqual(@as(usize, 2), report.components.len);
}

test "V-D-REACH-17 (vector): duplicate trace — one declared edge as two disjoint polylines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B") };
    const paths = [_]sk.EdgePath{
        path(0, 0, 1, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 6 } }),
        path(0, 0, 1, &.{ .{ .x = 8, .y = 2 }, .{ .x = 8, .y = 6 } }),
    };
    var s = sketchOf(&paths, &.{});
    s.joins = .{
        .memberships = &.{.{ .edge = 0, .source = null, .target = null }},
        .terminal_ports = &.{ tp(0, 0, .source_exit), tp(1, 0, .target_entry) },
    };
    const report = try vc.validate(a, s, try nodeKeys(a, &nodes), .flat);
    try expectEqual(@as(u32, 1), report.counts.duplicate_trace);
    try expectEqual(@as(usize, 2), report.components.len);
}

test "V-D-REACH-18 (vector): broken trunk rail strands a member — reach_join_split + reach_split_trace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // V-01's trunk, but the rail stops at x=12 while member e2's tap sits
    // at x=16: the tap drop disconnects from the trunk.
    const taps = fanTaps(false);
    const bbs = [_]sk.BusBar{fanBusBar(&taps, 12)};
    const g = graphOf(&fan_nodes, &fan_edges);
    const s = try realized(a, g, sketchOf(&.{}, &bbs), &.{});
    try expectEqual(@as(usize, 1), s.joins.selected_joins.len);

    const keys = try nodeKeys(a, &fan_nodes);
    const report = try vc.validate(a, s, keys, .flat);
    try expectEqual(@as(u32, 1), report.counts.join_split);
    try expectEqual(@as(u32, 1), report.counts.split_trace);
    try expectEqual(@as(usize, 2), report.components.len);
    // The stranded declared pair (S,C) is recorded on the component
    // holding the source terminal.
    var missing_total: usize = 0;
    for (report.components) |comp| {
        missing_total += comp.missing_declared_pairs.len;
        for (comp.missing_declared_pairs) |p| {
            try expectEqual(@as(sk.NodeId, 0), p.source);
            try expectEqual(@as(sk.NodeId, 3), p.target);
        }
    }
    try expectEqual(@as(usize, 1), missing_total);
}

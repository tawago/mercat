//! reach_vector_test2.zig — vector-half V-D-REACH oracle tests,
//! part 2 (split sibling of reach_vector_test.zig for the 500-line
//! cap, mirroring realized_test2): controlled one-side plans (TEST
//! VECTORS only, never production — completing the reachability halves of
//! V-D-JOIN-SELECT-04/06/12 and V-D-DUAL-01/02 left open by Step 4), the
//! V-D-REACH-19(b) permutation pin, and the Counts↔registry pin.
//! Aggregated from entry.zig's `test {}` block.
//!
//! Allowed imports (tools/lint_imports.zig): std, prim, ledger,
//! sketch, sem_graph, parse, reach_vector, realized, permits,
//! reach_vector_test (shared fixture helpers).

const std = @import("std");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const pb = @import("../base/ledger.zig");
const vc = @import("reach_vector.zig");
const t1 = @import("reach_vector_test.zig");

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const node = t1.node;
const edge = t1.edge;
const nodeKeys = t1.nodeKeys;
const path = t1.path;
const sketchOf = t1.sketchOf;
const tp = t1.tp;
const anyReachable = t1.anyReachable;
const zeroCounts = t1.zeroCounts;

const c22_nodes = [_]sg.Node{ node(0, "S1"), node(1, "S2"), node(2, "T1"), node(3, "T2") };

fn controlledBundles(comptime members: []const pb.EdgeId, comptime ports: []const pb.TerminalPort, comptime memberships: []const pb.RealizedEdgeMembership) pb.RealizedBundles {
    return .{
        .selected_bundles = &.{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = members }},
        .memberships = memberships,
        .terminal_ports = ports,
    };
}

const c22_ports = [_]pb.TerminalPort{
    tp(0, 0, .source_exit), tp(2, 0, .target_entry),
    tp(0, 1, .source_exit), tp(3, 1, .target_entry),
    tp(1, 2, .source_exit), tp(3, 2, .target_entry),
};
const c22_ms = [_]pb.RealizedEdgeMembership{
    .{ .edge = 0, .source = null, .target = null },
    .{ .edge = 1, .source = null, .target = null },
    .{ .edge = 2, .source = null, .target = null },
};

test "V-D-REACH-07/13 (vector): 2x2 controlled source/target/neither plans pass; S2->T2 cannot reach T1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try nodeKeys(a, &c22_nodes);

    const fo_stem = [_]sk.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 4 } };
    const fo_taps = [_]sk.Tap{
        .{ .edge = 0, .node = 2, .at = .{ .x = 2, .y = 4 }, .landing = .{ .x = 2, .y = 8 } },
        .{ .edge = 1, .node = 3, .at = .{ .x = 8, .y = 4 }, .landing = .{ .x = 8, .y = 8 } },
    };
    const fo_bb = [_]sk.Rail{.{ .pivot = 0, .stem = &fo_stem, .crossbar = .{ .{ .x = 2, .y = 4 }, .{ .x = 8, .y = 4 } }, .taps = &fo_taps, .kind = .solid, .role = .fan_out_dropper }};
    const e2_path = [_]sk.EdgePath{path(2, 1, 3, &.{ .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 8 } })};
    var src_side = sketchOf(&e2_path, &fo_bb);
    src_side.bundles = controlledBundles(&.{ 0, 1 }, &c22_ports, &c22_ms);
    const sr = try vc.validate(a, src_side, keys, .flat);
    try expect(zeroCounts(sr.counts));
    try expectEqual(@as(usize, 2), sr.components.len);
    try expect(anyReachable(sr, 0, 2) and anyReachable(sr, 0, 3) and anyReachable(sr, 1, 3));
    try expect(!anyReachable(sr, 1, 2));

    const fi_stem = [_]sk.Point{ .{ .x = 8, .y = 10 }, .{ .x = 8, .y = 8 } };
    const fi_taps = [_]sk.Tap{
        .{ .edge = 1, .node = 0, .at = .{ .x = 2, .y = 8 }, .landing = .{ .x = 2, .y = 4 } },
        .{ .edge = 2, .node = 1, .at = .{ .x = 14, .y = 8 }, .landing = .{ .x = 14, .y = 4 } },
    };
    const fi_bb = [_]sk.Rail{.{ .pivot = 3, .stem = &fi_stem, .crossbar = .{ .{ .x = 2, .y = 8 }, .{ .x = 14, .y = 8 } }, .taps = &fi_taps, .kind = .solid, .role = .fan_in_dropper }};
    const e0_path = [_]sk.EdgePath{path(0, 0, 2, &.{ .{ .x = 20, .y = 2 }, .{ .x = 20, .y = 8 } })};
    var tgt_side = sketchOf(&e0_path, &fi_bb);
    tgt_side.bundles = controlledBundles(&.{ 1, 2 }, &c22_ports, &c22_ms);
    const tr = try vc.validate(a, tgt_side, keys, .flat);
    try expect(zeroCounts(tr.counts));
    try expectEqual(@as(usize, 2), tr.components.len);
    try expect(!anyReachable(tr, 1, 2));

    const all_paths = [_]sk.EdgePath{
        path(0, 0, 2, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 8 } }),
        path(1, 0, 3, &.{ .{ .x = 8, .y = 2 }, .{ .x = 8, .y = 8 } }),
        path(2, 1, 3, &.{ .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 8 } }),
    };
    var neither = sketchOf(&all_paths, &.{});
    neither.bundles = .{ .memberships = &c22_ms, .terminal_ports = &c22_ports };
    const nr = try vc.validate(a, neither, keys, .flat);
    try expect(zeroCounts(nr.counts));
    try expectEqual(@as(usize, 3), nr.components.len);
}

const dual_nodes = [_]sg.Node{ node(0, "S"), node(1, "X"), node(2, "A"), node(3, "B") };
const dual_ports = [_]pb.TerminalPort{
    tp(0, 0, .source_exit), tp(1, 0, .target_entry),
    tp(0, 1, .source_exit), tp(2, 1, .target_entry),
    tp(3, 2, .source_exit), tp(1, 2, .target_entry),
};
const dual_ms = [_]pb.RealizedEdgeMembership{
    .{ .edge = 0, .source = null, .target = null },
    .{ .edge = 1, .source = null, .target = null },
    .{ .edge = 2, .source = null, .target = null },
};

test "V-D-REACH-08/14 (vector): dual controlled source/target/neither plans pass; B cannot reach A" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try nodeKeys(a, &dual_nodes);

    const fo_stem = [_]sk.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 4 } };
    const fo_taps = [_]sk.Tap{
        .{ .edge = 0, .node = 1, .at = .{ .x = 2, .y = 4 }, .landing = .{ .x = 2, .y = 8 } },
        .{ .edge = 1, .node = 2, .at = .{ .x = 8, .y = 4 }, .landing = .{ .x = 8, .y = 8 } },
    };
    const fo_bb = [_]sk.Rail{.{ .pivot = 0, .stem = &fo_stem, .crossbar = .{ .{ .x = 2, .y = 4 }, .{ .x = 8, .y = 4 } }, .taps = &fo_taps, .kind = .solid, .role = .fan_out_dropper }};
    const e2_path = [_]sk.EdgePath{path(2, 3, 1, &.{ .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 8 } })};
    var src_side = sketchOf(&e2_path, &fo_bb);
    src_side.bundles = controlledBundles(&.{ 0, 1 }, &dual_ports, &dual_ms);
    const sr = try vc.validate(a, src_side, keys, .flat);
    try expect(zeroCounts(sr.counts));
    try expectEqual(@as(usize, 2), sr.components.len);
    try expect(!anyReachable(sr, 3, 2));

    const fi_stem = [_]sk.Point{ .{ .x = 8, .y = 10 }, .{ .x = 8, .y = 8 } };
    const fi_taps = [_]sk.Tap{
        .{ .edge = 0, .node = 0, .at = .{ .x = 2, .y = 8 }, .landing = .{ .x = 2, .y = 4 } },
        .{ .edge = 2, .node = 3, .at = .{ .x = 14, .y = 8 }, .landing = .{ .x = 14, .y = 4 } },
    };
    const fi_bb = [_]sk.Rail{.{ .pivot = 1, .stem = &fi_stem, .crossbar = .{ .{ .x = 2, .y = 8 }, .{ .x = 14, .y = 8 } }, .taps = &fi_taps, .kind = .solid, .role = .fan_in_dropper }};
    const e1_path = [_]sk.EdgePath{path(1, 0, 2, &.{ .{ .x = 20, .y = 2 }, .{ .x = 20, .y = 8 } })};
    var tgt_side = sketchOf(&e1_path, &fi_bb);
    tgt_side.bundles = controlledBundles(&.{ 0, 2 }, &dual_ports, &dual_ms);
    const tr = try vc.validate(a, tgt_side, keys, .flat);
    try expect(zeroCounts(tr.counts));
    try expectEqual(@as(usize, 2), tr.components.len);
    try expect(!anyReachable(tr, 3, 2));

    const all_paths = [_]sk.EdgePath{
        path(0, 0, 1, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 8 } }),
        path(1, 0, 2, &.{ .{ .x = 8, .y = 2 }, .{ .x = 8, .y = 8 } }),
        path(2, 3, 1, &.{ .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 8 } }),
    };
    var neither = sketchOf(&all_paths, &.{});
    neither.bundles = .{ .memberships = &dual_ms, .terminal_ports = &dual_ports };
    const nr = try vc.validate(a, neither, keys, .flat);
    try expect(zeroCounts(nr.counts));
    try expectEqual(@as(usize, 3), nr.components.len);
}

/// Membership at both ends (confluence theory, "The plan"): A→D is a member
/// of A's fan-out rail and of D's fan-in rail, joined by its own middle run.
/// Nodes A=0 B=1 C=2 D=3; edges e0 A→B, e1 A→D, e2 C→D.
const both_nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C"), node(3, "D") };
const both_ports = [_]pb.TerminalPort{
    tp(0, 0, .source_exit), tp(1, 0, .target_entry),
    tp(0, 1, .source_exit), tp(3, 1, .target_entry),
    tp(2, 2, .source_exit), tp(3, 2, .target_entry),
};
const both_a_stem = [_]sk.Point{ .{ .x = 10, .y = 2 }, .{ .x = 10, .y = 4 } };
const both_d_stem = [_]sk.Point{ .{ .x = 15, .y = 14 }, .{ .x = 15, .y = 12 } };
const both_mid = [_]sk.Point{ .{ .x = 20, .y = 6 }, .{ .x = 20, .y = 10 } };
const both_members_a = [_]pb.EdgeId{ 0, 1 };
const both_members_d = [_]pb.EdgeId{ 1, 2 };
const both_selected = [_]pb.SelectedBundle{
    .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &both_members_a },
    .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &both_members_d },
};
const both_ms = [_]pb.RealizedEdgeMembership{
    .{ .edge = 0, .source = .{ .selected = 0 }, .target = null },
    .{ .edge = 1, .source = .{ .selected = 0 }, .target = .{ .selected = 1 } },
    .{ .edge = 2, .source = null, .target = .{ .selected = 1 } },
};

fn bothSketch(leaf_head: sk.ArrowKind, pivot_head: sk.ArrowKind, taps_a: []sk.Tap, taps_d: []sk.Tap, rails: []sk.Rail, mid: []sk.EdgePath) sk.Sketch {
    taps_a[0] = .{ .edge = 0, .node = 1, .at = .{ .x = 10, .y = 4 }, .landing = .{ .x = 10, .y = 6 }, .arrow = leaf_head };
    taps_a[1] = .{ .edge = 1, .node = 3, .at = .{ .x = 20, .y = 4 }, .landing = .{ .x = 20, .y = 6 }, .arrow = leaf_head };
    taps_d[0] = .{ .edge = 2, .node = 2, .at = .{ .x = 10, .y = 12 }, .landing = .{ .x = 10, .y = 10 }, .arrow = .none };
    taps_d[1] = .{ .edge = 1, .node = 0, .at = .{ .x = 20, .y = 12 }, .landing = .{ .x = 20, .y = 10 }, .arrow = .none };
    rails[0] = .{ .pivot = 0, .stem = &both_a_stem, .crossbar = .{ .{ .x = 10, .y = 4 }, .{ .x = 20, .y = 4 } }, .taps = taps_a, .kind = .solid, .role = .fan_out_dropper, .pivot_arrow = .none };
    rails[1] = .{ .pivot = 3, .stem = &both_d_stem, .crossbar = .{ .{ .x = 10, .y = 12 }, .{ .x = 20, .y = 12 } }, .taps = taps_d, .kind = .solid, .role = .fan_in_rail, .pivot_arrow = pivot_head };
    mid[0] = path(1, 0, 3, &both_mid);
    mid[0].arrow_to = leaf_head;
    var s = sketchOf(mid, rails);
    s.bundles = .{ .selected_bundles = &both_selected, .memberships = &both_ms, .terminal_ports = &both_ports };
    return s;
}

test "membership at both ends: one-way members at both rails trace only the declared pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var taps_a: [2]sk.Tap = undefined;
    var taps_d: [2]sk.Tap = undefined;
    var rails: [2]sk.Rail = undefined;
    var mid: [1]sk.EdgePath = undefined;
    const s = bothSketch(.filled, .filled, &taps_a, &taps_d, &rails, &mid);
    const report = try vc.validate(a, s, try nodeKeys(a, &both_nodes), .flat);
    try expect(zeroCounts(report.counts));
    try expectEqual(@as(usize, 1), report.components.len);
    try expectEqual(@as(usize, 2), report.components[0].selected_bundle_ids.len);
    try expect(anyReachable(report, 0, 1));
    try expect(anyReachable(report, 0, 3));
    try expect(anyReachable(report, 2, 3));
    try expect(!anyReachable(report, 2, 1));
}

test "membership at both ends: arrow-free members let the leaf-to-leaf trace through, and it is undeclared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var taps_a: [2]sk.Tap = undefined;
    var taps_d: [2]sk.Tap = undefined;
    var rails: [2]sk.Rail = undefined;
    var mid: [1]sk.EdgePath = undefined;
    const s = bothSketch(.none, .none, &taps_a, &taps_d, &rails, &mid);
    const report = try vc.validate(a, s, try nodeKeys(a, &both_nodes), .flat);
    try expectEqual(@as(u32, 1), report.counts.undeclared_pair);
    try expect(anyReachable(report, 2, 1));
}

test "Counts fields mirror the registered reach_* tags (11 CI + 1 RO skip) plus the non-tag packed skip" {
    var n_fields: usize = 0;
    inline for (@typeInfo(vc.Counts).@"struct".fields) |f| {
        n_fields += 1;
        if (comptime std.mem.eql(u8, f.name, "skipped_packed_candidate")) {
            try expect(pb.tagByName("reach_" ++ f.name) == null);
            try expect(pb.tagByName(f.name) == null);
            continue;
        }
        const tag = pb.tagByName("reach_" ++ f.name) orelse
            return error.UnregisteredCountField;
        const expected_class: pb.DispositionClass =
            if (comptime std.mem.eql(u8, f.name, "skipped_clustered")) .report_only else .candidate_invalid;
        try expectEqual(expected_class, pb.classOf(tag));
    }
    try expectEqual(@as(usize, 13), n_fields);
}

//! reach_vector_test2.zig — vector-half V-D-REACH oracle tests,
//! part 2 (split sibling of reach_vector_test.zig for the 500-line
//! cap, mirroring realized_test2): §14.6 controlled one-side plans (TEST
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
const graphOf = t1.graphOf;
const nodeKeys = t1.nodeKeys;
const path = t1.path;
const sketchOf = t1.sketchOf;
const realized = t1.realized;
const tp = t1.tp;
const anyReachable = t1.anyReachable;
const zeroCounts = t1.zeroCounts;
const fan_nodes = t1.fan_nodes;
const fan_edges = t1.fan_edges;
const fanTaps = t1.fanTaps;
const fanBusBar = t1.fanBusBar;

// Controlled 2x2 fixture: S1->T1 (e0), S1->T2 (e1), S2->T2 (e2).
const c22_nodes = [_]sg.Node{ node(0, "S1"), node(1, "S2"), node(2, "T1"), node(3, "T2") };

fn controlledJoins(members: []const pb.EdgeId, ports: []const pb.TerminalPort, memberships: []const pb.RealizedEdgeMembership) pb.RealizedJoins {
    return .{
        .selected_joins = &.{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = members }},
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

test "V-D-REACH-07/13 (vector): §14.6 2x2 controlled source/target/neither plans pass; S2->T2 cannot reach T1" {
    // Completes the reachability halves of V-D-JOIN-SELECT-04/06/12
    // (controlled one-side selections are test-only, never production).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try nodeKeys(a, &c22_nodes);

    // (07) source-side: FO-S1 trunk {e0,e1}; e2 edge-owned.
    const fo_stem = [_]sk.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 4 } };
    const fo_taps = [_]sk.Tap{
        .{ .edge = 0, .node = 2, .at = .{ .x = 2, .y = 4 }, .landing = .{ .x = 2, .y = 8 } },
        .{ .edge = 1, .node = 3, .at = .{ .x = 8, .y = 4 }, .landing = .{ .x = 8, .y = 8 } },
    };
    const fo_bb = [_]sk.BusBar{.{ .pivot = 0, .stem = &fo_stem, .rail = .{ .{ .x = 2, .y = 4 }, .{ .x = 8, .y = 4 } }, .taps = &fo_taps, .kind = .solid, .role = .fan_out_rail }};
    const e2_path = [_]sk.EdgePath{path(2, 1, 3, &.{ .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 8 } })};
    var src_side = sketchOf(&e2_path, &fo_bb);
    src_side.joins = controlledJoins(&.{ 0, 1 }, &c22_ports, &c22_ms);
    const sr = try vc.validate(a, src_side, keys, .flat);
    try expect(zeroCounts(sr.counts));
    try expectEqual(@as(usize, 2), sr.components.len);
    try expect(anyReachable(sr, 0, 2) and anyReachable(sr, 0, 3) and anyReachable(sr, 1, 3));
    try expect(!anyReachable(sr, 1, 2)); // "S2->T2 ... cannot reach T1"

    // (13a) target-side: FI-T2 trunk {e1,e2}; e0 edge-owned.
    const fi_stem = [_]sk.Point{ .{ .x = 8, .y = 10 }, .{ .x = 8, .y = 8 } };
    const fi_taps = [_]sk.Tap{
        .{ .edge = 1, .node = 0, .at = .{ .x = 2, .y = 8 }, .landing = .{ .x = 2, .y = 4 } },
        .{ .edge = 2, .node = 1, .at = .{ .x = 14, .y = 8 }, .landing = .{ .x = 14, .y = 4 } },
    };
    const fi_bb = [_]sk.BusBar{.{ .pivot = 3, .stem = &fi_stem, .rail = .{ .{ .x = 2, .y = 8 }, .{ .x = 14, .y = 8 } }, .taps = &fi_taps, .kind = .solid, .role = .fan_in_rail }};
    const e0_path = [_]sk.EdgePath{path(0, 0, 2, &.{ .{ .x = 20, .y = 2 }, .{ .x = 20, .y = 8 } })};
    var tgt_side = sketchOf(&e0_path, &fi_bb);
    tgt_side.joins = controlledJoins(&.{ 1, 2 }, &c22_ports, &c22_ms);
    const tr = try vc.validate(a, tgt_side, keys, .flat);
    try expect(zeroCounts(tr.counts));
    try expectEqual(@as(usize, 2), tr.components.len);
    try expect(!anyReachable(tr, 1, 2));

    // (13b) neither: three edge-owned components (also production).
    const all_paths = [_]sk.EdgePath{
        path(0, 0, 2, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 8 } }),
        path(1, 0, 3, &.{ .{ .x = 8, .y = 2 }, .{ .x = 8, .y = 8 } }),
        path(2, 1, 3, &.{ .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 8 } }),
    };
    var neither = sketchOf(&all_paths, &.{});
    neither.joins = .{ .memberships = &c22_ms, .terminal_ports = &c22_ports };
    const nr = try vc.validate(a, neither, keys, .flat);
    try expect(zeroCounts(nr.counts));
    try expectEqual(@as(usize, 3), nr.components.len);
}

// Controlled dual fixture: S->X (e0), S->A (e1), B->X (e2).
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

test "V-D-REACH-08/14 (vector): §14.6 dual controlled source/target/neither plans pass; B cannot reach A" {
    // Completes the reachability halves of V-D-DUAL-01/02.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try nodeKeys(a, &dual_nodes);

    // (08) source-side: FO-S trunk {e0,e1}; e2 edge-owned.
    const fo_stem = [_]sk.Point{ .{ .x = 4, .y = 2 }, .{ .x = 4, .y = 4 } };
    const fo_taps = [_]sk.Tap{
        .{ .edge = 0, .node = 1, .at = .{ .x = 2, .y = 4 }, .landing = .{ .x = 2, .y = 8 } },
        .{ .edge = 1, .node = 2, .at = .{ .x = 8, .y = 4 }, .landing = .{ .x = 8, .y = 8 } },
    };
    const fo_bb = [_]sk.BusBar{.{ .pivot = 0, .stem = &fo_stem, .rail = .{ .{ .x = 2, .y = 4 }, .{ .x = 8, .y = 4 } }, .taps = &fo_taps, .kind = .solid, .role = .fan_out_rail }};
    const e2_path = [_]sk.EdgePath{path(2, 3, 1, &.{ .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 8 } })};
    var src_side = sketchOf(&e2_path, &fo_bb);
    src_side.joins = controlledJoins(&.{ 0, 1 }, &dual_ports, &dual_ms);
    const sr = try vc.validate(a, src_side, keys, .flat);
    try expect(zeroCounts(sr.counts));
    try expectEqual(@as(usize, 2), sr.components.len);
    try expect(!anyReachable(sr, 3, 2)); // "B->X ... cannot reach A"

    // (14a) target-side: FI-X trunk {e0,e2}; e1 edge-owned; S->X's source
    // end stays an independent port.
    const fi_stem = [_]sk.Point{ .{ .x = 8, .y = 10 }, .{ .x = 8, .y = 8 } };
    const fi_taps = [_]sk.Tap{
        .{ .edge = 0, .node = 0, .at = .{ .x = 2, .y = 8 }, .landing = .{ .x = 2, .y = 4 } },
        .{ .edge = 2, .node = 3, .at = .{ .x = 14, .y = 8 }, .landing = .{ .x = 14, .y = 4 } },
    };
    const fi_bb = [_]sk.BusBar{.{ .pivot = 1, .stem = &fi_stem, .rail = .{ .{ .x = 2, .y = 8 }, .{ .x = 14, .y = 8 } }, .taps = &fi_taps, .kind = .solid, .role = .fan_in_rail }};
    const e1_path = [_]sk.EdgePath{path(1, 0, 2, &.{ .{ .x = 20, .y = 2 }, .{ .x = 20, .y = 8 } })};
    var tgt_side = sketchOf(&e1_path, &fi_bb);
    tgt_side.joins = controlledJoins(&.{ 0, 2 }, &dual_ports, &dual_ms);
    const tr = try vc.validate(a, tgt_side, keys, .flat);
    try expect(zeroCounts(tr.counts));
    try expectEqual(@as(usize, 2), tr.components.len);
    try expect(!anyReachable(tr, 3, 2));

    // (14b) neither: three components, one pair each.
    const all_paths = [_]sk.EdgePath{
        path(0, 0, 1, &.{ .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 8 } }),
        path(1, 0, 2, &.{ .{ .x = 8, .y = 2 }, .{ .x = 8, .y = 8 } }),
        path(2, 3, 1, &.{ .{ .x = 14, .y = 2 }, .{ .x = 14, .y = 8 } }),
    };
    var neither = sketchOf(&all_paths, &.{});
    neither.joins = .{ .memberships = &dual_ms, .terminal_ports = &dual_ports };
    const nr = try vc.validate(a, neither, keys, .flat);
    try expect(zeroCounts(nr.counts));
    try expectEqual(@as(usize, 3), nr.components.len);
}


test "V-D-REACH-19(b) (vector): declaration/writer permutation yields identical report bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keys = try nodeKeys(a, &fan_nodes);

    // V-01's trunk with taps and edge declarations permuted.
    const taps_fwd = fanTaps(true);
    const taps_rev = [_]sk.Tap{ taps_fwd[2], taps_fwd[0], taps_fwd[1] };
    const edges_rev = [_]sg.Edge{ fan_edges[2], fan_edges[0], fan_edges[1] };
    const bbs_fwd = [_]sk.BusBar{fanBusBar(&taps_fwd, 16)};
    const bbs_rev = [_]sk.BusBar{fanBusBar(&taps_rev, 16)};
    const s_fwd = try realized(a, graphOf(&fan_nodes, &fan_edges), sketchOf(&.{}, &bbs_fwd), &.{});
    const s_rev = try realized(a, graphOf(&fan_nodes, &edges_rev), sketchOf(&.{}, &bbs_rev), &.{});
    const bytes_fwd = try vc.serialize(a, try vc.validate(a, s_fwd, keys, .flat), keys);
    const bytes_rev = try vc.serialize(a, try vc.validate(a, s_rev, keys, .flat), keys);
    try std.testing.expectEqualStrings(bytes_fwd, bytes_rev);

    // V-16's crossing graph with writer order permuted.
    const x_nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C"), node(3, "D") };
    const x_edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 2, 3) };
    const p0 = path(0, 0, 1, &.{ .{ .x = 2, .y = 6 }, .{ .x = 10, .y = 6 } });
    const p1 = path(1, 2, 3, &.{ .{ .x = 6, .y = 2 }, .{ .x = 6, .y = 10 } });
    const x_keys = try nodeKeys(a, &x_nodes);
    const sa = try realized(a, graphOf(&x_nodes, &x_edges), sketchOf(&.{ p0, p1 }, &.{}), &.{});
    const sb = try realized(a, graphOf(&x_nodes, &x_edges), sketchOf(&.{ p1, p0 }, &.{}), &.{});
    const ba = try vc.serialize(a, try vc.validate(a, sa, x_keys, .flat), x_keys);
    const bb = try vc.serialize(a, try vc.validate(a, sb, x_keys, .flat), x_keys);
    try std.testing.expectEqualStrings(ba, bb);

    // F1: ACTUAL sharing events under writer permutation. Three unlabeled
    // COLLINEARLY-overlapping polylines on one row (cross-owner sharing
    // that is no strict orthogonal transversal): every pair fires
    // reach_unknown_continuation, and both the within-event owner order
    // and the event-list order must come from canonical owner keys — the
    // report bytes are identical under any s.edges order. (The two halves
    // above produce ZERO sharing events, which is how the original escape
    // slipped through.)
    const o_nodes = [_]sg.Node{
        node(0, "A"), node(1, "B"), node(2, "C"),
        node(3, "D"), node(4, "E"), node(5, "F"),
    };
    const o_edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 2, 3), edge(2, 4, 5) };
    const q0 = path(0, 0, 1, &.{ .{ .x = 2, .y = 6 }, .{ .x = 10, .y = 6 } });
    const q1 = path(1, 2, 3, &.{ .{ .x = 6, .y = 6 }, .{ .x = 14, .y = 6 } });
    const q2 = path(2, 4, 5, &.{ .{ .x = 4, .y = 6 }, .{ .x = 12, .y = 6 } });
    const o_keys = try nodeKeys(a, &o_nodes);
    const g_fwd = graphOf(&o_nodes, &o_edges);
    const o_edges_rev = [_]sg.Edge{ o_edges[2], o_edges[0], o_edges[1] };
    const g_rev = graphOf(&o_nodes, &o_edges_rev);
    const sh_a = try realized(a, g_fwd, sketchOf(&.{ q0, q1, q2 }, &.{}), &.{});
    const sh_b = try realized(a, g_rev, sketchOf(&.{ q2, q0, q1 }, &.{}), &.{});
    const ra = try vc.validate(a, sh_a, o_keys, .flat);
    const rb = try vc.validate(a, sh_b, o_keys, .flat);
    try expectEqual(@as(u32, 3), ra.counts.unknown_continuation); // really fires
    try expectEqual(@as(usize, 3), ra.sharing.len);
    const sha_bytes = try vc.serialize(a, ra, o_keys);
    const shb_bytes = try vc.serialize(a, rb, o_keys);
    try std.testing.expectEqualStrings(sha_bytes, shb_bytes);
}

test "Counts fields mirror the registered reach_* tags (11 CI + 1 RO skip) plus the non-tag packed skip" {
    var n_fields: usize = 0;
    inline for (@typeInfo(vc.Counts).@"struct".fields) |f| {
        n_fields += 1;
        if (comptime std.mem.eql(u8, f.name, "skipped_packed_candidate")) {
            // F2: deliberately NON-tag — the 43-tag D-DISPOSITION registry
            // is pinned and must not grow for a report-only skip split.
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

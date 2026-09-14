//! ports_test.zig — unit vectors for the pure D-PORT allocator (P2v Step
//! 5): V-D-PORT-02 (allocator half), -03, -04, -06 (allocator half), -09
//! (unit half), -10, -11, -12 (unit half), clause-6 K-ordering vectors,
//! the clause-14 post-allocation check, and the clause-9 sizing helper.
//! Aggregated from entry.zig's test block (ports.zig has no production
//! call site until Step 7).

const std = @import("std");
const ports = @import("ports.zig");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");

fn mkNode(id: u32, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

fn mkEdge(id: u32, from: u32, to: u32) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

fn mkGraph(direction: sg.Direction, nodes: []const sg.Node, edges: []const sg.Edge) sg.SemGraph {
    return .{ .direction = direction, .nodes = nodes, .edges = edges, .clusters = &.{}, .classes = &.{}, .arena = null };
}

/// Independent solid no-label attachment (kind/arrow ordinals from the
/// pinned tables: solid=0, none=0, filled=2).
fn att(opposite: []const u8, es: pb.EndpointSide, edge_id: u32, center: i32) ports.Attachment {
    return .{
        .key = .{ .opposite = opposite, .endpoint_side = es, .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = null },
        .edge = edge_id,
        .opposite_center = center,
    };
}

fn assigned(result: ports.Allocation) ![]const ports.Assignment {
    return switch (result) {
        .assigned => |s| s,
        .failed => error.TestUnexpectedResult,
    };
}

fn failed(result: ports.Allocation) !ports.Failure {
    return switch (result) {
        .assigned => error.TestUnexpectedResult,
        .failed => |f| f,
    };
}

const no_candidate: ports.CandidateRef = .{};
const names = [_][]const u8{ "a", "b", "c", "d", "e", "f" };

test "V-D-PORT-03: offsets follow o_i = m-(p-1)+2i with pitch 2 and corners excluded on odd and even faces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var side_len: u32 = 3;
    while (side_len <= 13) : (side_len += 1) {
        const m = ports.midpoint(side_len);
        var p: u32 = 1;
        while (p <= (side_len -| 1) / 2 and p <= names.len) : (p += 1) {
            var atts: std.ArrayListUnmanaged(ports.Attachment) = .empty;
            for (names[0..p], 0..) |name, i|
                try atts.append(a, att(name, .source_exit, @intCast(i), 0));
            const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, side_len, atts.items));
            try std.testing.expectEqual(@as(usize, p), out.len);
            var sum: u32 = 0;
            for (out, 0..) |assignment, i| {
                try std.testing.expectEqual(@as(u32, @intCast(i)), assignment.ordinal);
                try std.testing.expectEqual(m - (p - 1) + 2 * @as(u32, @intCast(i)), assignment.offset);
                try std.testing.expect(assignment.offset >= 1);
                try std.testing.expect(assignment.offset <= side_len - 2);
                if (i > 0) try std.testing.expectEqual(out[i - 1].offset + 2, assignment.offset);
                sum += assignment.offset;
            }
            try std.testing.expectEqual(p * m, sum);
        }
    }
}

test "V-D-PORT-03: p=3 on a w=5 node demands w_min=7 and allocates offsets 1,3,5 with height untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!ports.satisfiable(5, 3));
    const dims = ports.demandDims(.{ .south = 3 });
    try std.testing.expectEqual(@as(u32, 7), dims.w_min);
    try std.testing.expectEqual(@as(u32, 1), dims.h_min);

    const atts = [_]ports.Attachment{
        att("A", .source_exit, 0, 0),
        att("B", .source_exit, 1, 0),
        att("C", .source_exit, 2, 0),
    };
    const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, dims.w_min, &atts));
    try std.testing.expectEqual(@as(u32, 3), ports.midpoint(7));
    try std.testing.expectEqual(@as(u32, 1), out[0].offset);
    try std.testing.expectEqual(@as(u32, 3), out[1].offset);
    try std.testing.expectEqual(@as(u32, 5), out[2].offset);
}

test "V-D-PORT-04: a singleton port is exactly today's midpoint floor(L/2)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u32{ 3, 5, 7, 10 }) |side_len| {
        const atts = [_]ports.Attachment{att("B", .source_exit, 0, 0)};
        const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, side_len, &atts));
        try std.testing.expectEqual(side_len / 2, out[0].offset);
    }
}

test "V-D-PORT-04: capacity boundary L=2p+1 allocates and L=2p fails typed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: u32 = 1;
    while (p <= 4) : (p += 1) {
        var atts: std.ArrayListUnmanaged(ports.Attachment) = .empty;
        for (names[0..p], 0..) |name, i|
            try atts.append(a, att(name, .source_exit, @intCast(i), 0));
        const ok = try assigned(try ports.allocate(a, no_candidate, 0, .south, 2 * p + 1, atts.items));
        try std.testing.expectEqual(@as(usize, p), ok.len);
        const fail = try failed(try ports.allocate(a, no_candidate, 0, .south, 2 * p, atts.items));
        try std.testing.expectEqual(pb.DiagnosticTag.port_capacity_exceeded, fail.capacity_exceeded.tag);
    }
}

test "V-D-PORT-10: clamped L=3 with p=2 emits port_capacity_exceeded with the full clause-12 payload and no allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var independent = att("X", .source_exit, 7, 0);
    independent.group = 3;
    const rail: ports.Attachment = .{
        .class = .rail_pivot,
        .key = .{ .opposite = "Y", .endpoint_side = .source_exit, .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = null },
        .edge = 8,
        .group = 5,
        .members = &.{ 8, 9 },
        .opposite_center = 4,
    };
    const candidate: ports.CandidateRef = .{ .candidate = 2, .rung = 1 };
    const fail = try failed(try ports.allocate(a, candidate, 1, .south, 3, &.{ independent, rail }));
    const payload = fail.capacity_exceeded;
    try std.testing.expectEqual(pb.DiagnosticTag.port_capacity_exceeded, payload.tag);
    try std.testing.expectEqual(@as(u32, 2), payload.candidate.candidate);
    try std.testing.expectEqual(@as(u8, 1), payload.candidate.rung);
    try std.testing.expectEqual(@as(pb.NodeId, 1), payload.node);
    try std.testing.expectEqual(sk.Dir4.south, payload.side);
    try std.testing.expectEqual(@as(u32, 2), payload.demand);
    try std.testing.expectEqual(@as(u32, 3), payload.available);
    try std.testing.expectEqualSlices(ports.AttachmentClass, &.{ .independent, .rail_pivot }, payload.classes);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 7, 8, 9 }, payload.edges);
    try std.testing.expectEqualSlices(pb.CandidateBundleId, &.{ 3, 5 }, payload.groups);
    try std.testing.expectEqualStrings(ports.decision_row_clause_12, payload.decision_row);
    try std.testing.expect(payload.reason.len > 0);
    try std.testing.expect(payload.expected_action.len > 0);
}

test "V-D-PORT-11: byte-identical K fails with port_key_collision naming D-DUPLICATE and freezing no order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const twin_a = att("B", .source_exit, 9, 0);
    const twin_b = att("B", .source_exit, 4, 0);
    const first = try failed(try ports.allocate(a, no_candidate, 0, .south, 9, &.{ twin_a, twin_b }));
    const second = try failed(try ports.allocate(a, no_candidate, 0, .south, 9, &.{ twin_b, twin_a }));
    for ([_]ports.Failure{ first, second }) |fail| {
        const payload = fail.key_collision;
        try std.testing.expectEqual(pb.DiagnosticTag.port_key_collision, payload.tag);
        try std.testing.expectEqualStrings("B", payload.key.opposite);
        try std.testing.expectEqualSlices(pb.EdgeId, &.{ 4, 9 }, payload.edges);
        try std.testing.expectEqualStrings("D-DUPLICATE", payload.deferred_to);
    }
}

test "V-D-PORT-02: attachment input permutation yields byte-identical assignments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_]ports.Attachment{
        att("a", .source_exit, 0, 1),
        att("b", .source_exit, 1, 1),
        att("c", .target_entry, 2, 5),
        att("d", .source_exit, 3, 9),
    };
    const perms = [_][4]usize{
        .{ 0, 1, 2, 3 },
        .{ 3, 2, 1, 0 },
        .{ 2, 0, 3, 1 },
    };
    const reference = try assigned(try ports.allocate(a, no_candidate, 0, .south, 9, &base));
    for (perms) |perm| {
        var shuffled: [4]ports.Attachment = undefined;
        for (perm, 0..) |src, i| shuffled[i] = base[src];
        const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, 9, &shuffled));
        try std.testing.expectEqual(reference.len, out.len);
        for (reference, out) |want, got| {
            try std.testing.expectEqual(want.attachment.edge, got.attachment.edge);
            try std.testing.expectEqual(want.ordinal, got.ordinal);
            try std.testing.expectEqual(want.offset, got.offset);
        }
    }
}

test "equal NodeId never coalesces: S1->T and S2->T get distinct entry ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const atts = [_]ports.Attachment{
        att("S2", .target_entry, 1, 5),
        att("S1", .target_entry, 0, 5),
    };
    const out = try assigned(try ports.allocate(a, no_candidate, 2, .north, 7, &atts));
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("S1", out[0].attachment.key.opposite);
    try std.testing.expectEqualStrings("S2", out[1].attachment.key.opposite);
    try std.testing.expectEqual(@as(u32, 2), out[0].offset);
    try std.testing.expectEqual(@as(u32, 4), out[1].offset);
}

test "clause-6 order: opposite center is primary, K breaks ties with no-label first and pinned ordinals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var far_labeled = att("n", .source_exit, 0, 10);
    far_labeled.key.label = "z";
    var near_dotted = att("n", .source_exit, 1, 2);
    near_dotted.key.kind = 1;
    const far_plain = att("n", .source_exit, 2, 10);
    var far_thick = att("n", .source_exit, 3, 10);
    far_thick.key.kind = 2;
    const far_entry = att("n", .target_entry, 4, 10);

    const atts = [_]ports.Attachment{ far_labeled, near_dotted, far_plain, far_thick, far_entry };
    const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, 11, &atts));
    const want_edges = [_]pb.EdgeId{ 1, 2, 0, 3, 4 };
    for (want_edges, out) |edge, assignment|
        try std.testing.expectEqual(@as(?pb.EdgeId, edge), assignment.attachment.edge);
    for (out, 0..) |assignment, i|
        try std.testing.expectEqual(@as(u32, 1 + 2 * @as(u32, @intCast(i))), assignment.offset);
}

test "V-D-PORT-12: a TD self-loop derives two typed terminals (east exit, north entry)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{mkNode(0, "X")};
    const edges = [_]sg.Edge{mkEdge(0, 0, 0)};
    const graph = mkGraph(.TD, &nodes, &edges);
    const derived = try ports.derive(a, graph, .{ .policy = .joined }, .{}, .TD, &.{});
    try std.testing.expectEqual(@as(usize, 2), derived.len);
    const exit = derived[0];
    const entry = derived[1];
    try std.testing.expectEqual(sk.Dir4.east, exit.side);
    try std.testing.expectEqual(pb.EndpointSide.source_exit, exit.attachment.key.endpoint_side);
    try std.testing.expectEqual(sk.Dir4.north, entry.side);
    try std.testing.expectEqual(pb.EndpointSide.target_entry, entry.attachment.key.endpoint_side);
    for (derived) |item| {
        try std.testing.expectEqual(@as(pb.NodeId, 0), item.node);
        try std.testing.expectEqualStrings("X", item.attachment.key.opposite);
        try std.testing.expectEqual(@as(?pb.EdgeId, 0), item.attachment.edge);
    }
    const lr = try ports.derive(a, graph, .{ .policy = .joined }, .{}, .LR, &.{});
    try std.testing.expectEqual(sk.Dir4.south, lr[0].side);
    try std.testing.expectEqual(sk.Dir4.south, lr[1].side);
    try std.testing.expectEqual(@as(u32, 2), ports.sideDemand(lr, 0).south);
}

test "V-D-PORT-09: reversed exit and entry both derive to east in TD and get distinct offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "M"), mkNode(1, "X"), mkNode(2, "Y") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 2, 0) };
    const graph = mkGraph(.TD, &nodes, &edges);
    const derived = try ports.derive(a, graph, .{ .policy = .joined }, .{}, .TD, &.{ 0, 1 });
    const demand = ports.sideDemand(derived, 0);
    try std.testing.expectEqual(@as(u32, 2), demand.east);
    try std.testing.expectEqual(@as(u32, 5), ports.demandDims(demand).h_min);
    const east = try ports.forSide(a, derived, 0, .east);
    const out = try assigned(try ports.allocate(a, no_candidate, 0, .east, 5, east));
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(pb.EndpointSide.source_exit, out[0].attachment.key.endpoint_side);
    try std.testing.expectEqual(pb.EndpointSide.target_entry, out[1].attachment.key.endpoint_side);
    try std.testing.expectEqual(@as(u32, 1), out[0].offset);
    try std.testing.expectEqual(@as(u32, 3), out[1].offset);
}

test "derivation: a committed group consumes one rail pivot attachment keyed by its smallest member K" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "S"), mkNode(1, "A"), mkNode(2, "B") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 0, 2) };
    const graph = mkGraph(.TD, &nodes, &edges);
    const groups = [_]pb.CandidateBundle{.{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 0, 1 } }};
    const plan: pb.BundlePermits = .{
        .policy = .joined,
        .groups = &groups,
        .memberships = &.{
            .{ .edge = 0, .source_group = 0, .target_group = null },
            .{ .edge = 1, .source_group = 0, .target_group = null },
        },
    };
    const bundles: pb.RealizedBundles = .{
        .selected_bundles = &.{.{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &.{ 0, 1 } }},
        .memberships = &.{
            .{ .edge = 0, .source = .{ .selected = 0 }, .target = null },
            .{ .edge = 1, .source = .{ .selected = 0 }, .target = null },
        },
    };
    const derived = try ports.derive(a, graph, plan, bundles, .TD, &.{});
    const south = try ports.forSide(a, derived, 0, .south);
    try std.testing.expectEqual(@as(usize, 1), south.len);
    try std.testing.expectEqual(ports.AttachmentClass.rail_pivot, south[0].class);
    try std.testing.expectEqualStrings("A", south[0].key.opposite);
    try std.testing.expectEqual(@as(?pb.EdgeId, 0), south[0].edge);
    try std.testing.expectEqual(@as(?pb.CandidateBundleId, 0), south[0].group);
    try std.testing.expectEqual(@as(usize, 2), south[0].members.len);
    try std.testing.expectEqual(@as(u32, 1), ports.sideDemand(derived, 1).north);
    try std.testing.expectEqual(@as(u32, 1), ports.sideDemand(derived, 2).north);
    const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, 7, south));
    try std.testing.expectEqual(@as(u32, 3), out[0].offset);
}

test "a fused union's leaf node exits through one shared attachment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "X"), mkNode(3, "Y") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 2), mkEdge(1, 0, 3), mkEdge(2, 1, 2), mkEdge(3, 1, 3) };
    const graph = mkGraph(.TD, &nodes, &edges);
    const groups = [_]pb.CandidateBundle{
        .{ .id = 0, .direction = .in, .pivot = 2, .members = &.{ 0, 2 } },
        .{ .id = 1, .direction = .in, .pivot = 3, .members = &.{ 1, 3 } },
    };
    const plan: pb.BundlePermits = .{ .policy = .joined, .groups = &groups, .memberships = &.{
        .{ .edge = 0, .source_group = null, .target_group = 0 },
        .{ .edge = 1, .source_group = null, .target_group = 1 },
        .{ .edge = 2, .source_group = null, .target_group = 0 },
        .{ .edge = 3, .source_group = null, .target_group = 1 },
    } };
    const bundles: pb.RealizedBundles = .{
        .selected_bundles = &.{
            .{ .id = 0, .proposal = 0, .candidate_bundle = 0, .members = &.{ 0, 2 } },
            .{ .id = 1, .proposal = 1, .candidate_bundle = 1, .members = &.{ 1, 3 } },
        },
        .memberships = &.{
            .{ .edge = 0, .source = null, .target = .{ .selected = 0 } },
            .{ .edge = 1, .source = null, .target = .{ .selected = 1 } },
            .{ .edge = 2, .source = null, .target = .{ .selected = 0 } },
            .{ .edge = 3, .source = null, .target = .{ .selected = 1 } },
        },
        .fused = &.{&.{ 0, 1, 2, 3 }},
    };
    const derived = try ports.derive(a, graph, plan, bundles, .TD, &.{});
    for ([2]u32{ 0, 1 }) |src| {
        const south = try ports.forSide(a, derived, src, .south);
        try std.testing.expectEqual(@as(usize, 1), south.len);
        try std.testing.expectEqual(ports.AttachmentClass.rail_pivot, south[0].class);
        try std.testing.expectEqualStrings("X", south[0].key.opposite);
        try std.testing.expectEqual(@as(usize, 2), south[0].members.len);
    }
    try std.testing.expectEqual(@as(u32, 1), ports.sideDemand(derived, 2).north);
    var lapsed = bundles;
    lapsed.fused = &.{};
    const per_edge = try ports.derive(a, graph, plan, lapsed, .TD, &.{});
    try std.testing.expectEqual(@as(usize, 2), (try ports.forSide(a, per_edge, 0, .south)).len);
}

test "graph edge-array permutation leaves derived allocation identical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "S"), mkNode(1, "A"), mkNode(2, "B"), mkNode(3, "C") };
    const fwd = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 0, 2), mkEdge(2, 0, 3) };
    const rev = [_]sg.Edge{ mkEdge(2, 0, 3), mkEdge(0, 0, 1), mkEdge(1, 0, 2) };
    var outs: [2][]const ports.Assignment = undefined;
    for ([2][]const sg.Edge{ &fwd, &rev }, 0..) |edges, i| {
        const graph = mkGraph(.TD, &nodes, edges);
        const derived = try ports.derive(a, graph, .{ .policy = .joined }, .{}, .TD, &.{});
        const south = try ports.forSide(a, derived, 0, .south);
        outs[i] = try assigned(try ports.allocate(a, no_candidate, 0, .south, 7, south));
    }
    try std.testing.expectEqual(outs[0].len, outs[1].len);
    for (outs[0], outs[1]) |want, got| {
        try std.testing.expectEqual(want.attachment.edge, got.attachment.edge);
        try std.testing.expectEqual(want.offset, got.offset);
    }
}

test "side conventions are frozen per direction for forward, reversed, and self-loop attachments" {
    const t = std.testing;
    try t.expectEqual(sk.Dir4.south, ports.forwardSide(.TD, .source_exit));
    try t.expectEqual(sk.Dir4.north, ports.forwardSide(.TD, .target_entry));
    try t.expectEqual(sk.Dir4.north, ports.forwardSide(.BT, .source_exit));
    try t.expectEqual(sk.Dir4.south, ports.forwardSide(.BT, .target_entry));
    try t.expectEqual(sk.Dir4.east, ports.forwardSide(.LR, .source_exit));
    try t.expectEqual(sk.Dir4.west, ports.forwardSide(.LR, .target_entry));
    try t.expectEqual(sk.Dir4.west, ports.forwardSide(.RL, .source_exit));
    try t.expectEqual(sk.Dir4.east, ports.forwardSide(.RL, .target_entry));
    try t.expectEqual(sk.Dir4.east, ports.reversedSide(.TD));
    try t.expectEqual(sk.Dir4.east, ports.reversedSide(.BT));
    try t.expectEqual(sk.Dir4.south, ports.reversedSide(.LR));
    try t.expectEqual(sk.Dir4.south, ports.reversedSide(.RL));
    try t.expectEqual(sk.Dir4.east, ports.selfLoopSide(.TD, .source_exit));
    try t.expectEqual(sk.Dir4.north, ports.selfLoopSide(.TD, .target_entry));
    try t.expectEqual(sk.Dir4.east, ports.selfLoopSide(.BT, .source_exit));
    try t.expectEqual(sk.Dir4.north, ports.selfLoopSide(.BT, .target_entry));
    try t.expectEqual(sk.Dir4.south, ports.selfLoopSide(.LR, .source_exit));
    try t.expectEqual(sk.Dir4.south, ports.selfLoopSide(.LR, .target_entry));
    try t.expectEqual(sk.Dir4.south, ports.selfLoopSide(.RL, .source_exit));
    try t.expectEqual(sk.Dir4.south, ports.selfLoopSide(.RL, .target_entry));
}

test "demandDims computes 2*max+1 per axis" {
    const t = std.testing;
    const empty = ports.demandDims(.{});
    try t.expectEqual(@as(u32, 1), empty.w_min);
    try t.expectEqual(@as(u32, 1), empty.h_min);
    const dims = ports.demandDims(.{ .north = 2, .south = 3, .east = 1 });
    try t.expectEqual(@as(u32, 7), dims.w_min);
    try t.expectEqual(@as(u32, 3), dims.h_min);
}

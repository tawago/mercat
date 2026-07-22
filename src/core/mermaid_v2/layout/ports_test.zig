//! ports_test.zig — unit vectors for the pure D-PORT allocator (P2v Step
//! 5): V-D-PORT-02 (allocator half), -03, -04, -06 (allocator half), -09
//! (unit half), -10, -11, -12 (unit half), clause-6 K-ordering vectors,
//! the clause-14 post-allocation check, and the clause-9 sizing helper.
//! Aggregated from entry.zig's test block (ports.zig has no production
//! call site until Step 7).

const std = @import("std");
const ports = @import("ports.zig");
const routing = @import("routing.zig");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");

// -- Fixture helpers ----------------------------------------------------------

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

// -- Offset formula (clause 7) -------------------------------------------------

test "V-D-PORT-03: offsets follow o_i = m-(p-1)+2i with pitch 2 and corners excluded on odd and even faces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var side_len: u32 = 3;
    while (side_len <= 13) : (side_len += 1) {
        const m = ports.midpoint(side_len);
        var p: u32 = 1;
        while (p <= ports.capacity(side_len) and p <= names.len) : (p += 1) {
            var atts: std.ArrayListUnmanaged(ports.Attachment) = .empty;
            for (names[0..p], 0..) |name, i|
                try atts.append(a, att(name, .source_exit, @intCast(i), 0));
            const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, side_len, atts.items));
            try std.testing.expectEqual(@as(usize, p), out.len);
            var sum: u32 = 0;
            for (out, 0..) |assignment, i| {
                try std.testing.expectEqual(@as(u32, @intCast(i)), assignment.ordinal);
                try std.testing.expectEqual(m - (p - 1) + 2 * @as(u32, @intCast(i)), assignment.offset);
                // Corners excluded on every face parity.
                try std.testing.expect(assignment.offset >= 1);
                try std.testing.expect(assignment.offset <= side_len - 2);
                if (i > 0) try std.testing.expectEqual(out[i - 1].offset + 2, assignment.offset);
                sum += assignment.offset;
            }
            // Centered on m: the offsets always average to the midpoint.
            try std.testing.expectEqual(p * m, sum);
        }
    }
}

test "V-D-PORT-03: p=3 on a w=5 node demands w_min=7 and allocates offsets 1,3,5 with height untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Node "S" (label width 1): today's w=5, capacity 2 < demand 3.
    try std.testing.expectEqual(@as(u32, 2), ports.capacity(5));
    try std.testing.expect(!ports.satisfiable(5, 3));
    const dims = ports.demandDims(.{ .south = 3 });
    try std.testing.expectEqual(@as(u32, 7), dims.w_min);
    // No east/west demand: the height minimum stays trivial (clause 9
    // takes the max against today's minima, so h is unchanged).
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

    // Anchor against the live p=1 producer: routing.perimeterPort.
    const placement: sk.NodePlacement = .{
        .id = 0,
        .rect = .{ .x = 0, .y = 0, .w = 7, .h = 3 },
        .shape = .rect,
        .lines = &.{},
        .cluster_id = null,
    };
    const south = routing.perimeterPort(placement, .TD, .out);
    const south_atts = [_]ports.Attachment{att("B", .source_exit, 0, 0)};
    const south_out = try assigned(try ports.allocate(a, no_candidate, 0, .south, placement.rect.w, &south_atts));
    try std.testing.expectEqual(south.offset, south_out[0].offset);
    const east = routing.perimeterPort(placement, .LR, .out);
    const east_atts = [_]ports.Attachment{att("B", .source_exit, 0, 0)};
    const east_out = try assigned(try ports.allocate(a, no_candidate, 0, .east, placement.rect.h, &east_atts));
    try std.testing.expectEqual(east.offset, east_out[0].offset);
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

// -- Failure surfaces (clauses 12-13) -------------------------------------------

test "V-D-PORT-10: clamped L=3 with p=2 emits port_capacity_exceeded with the full clause-12 payload and no allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var independent = att("X", .source_exit, 7, 0);
    independent.group = 3;
    const trunk: ports.Attachment = .{
        .class = .trunk_pivot,
        .key = .{ .opposite = "Y", .endpoint_side = .source_exit, .kind = 0, .arrow_from = 0, .arrow_to = 2, .label = null },
        .edge = 8,
        .group = 5,
        .members = &.{ 8, 9 },
        .opposite_center = 4,
    };
    const candidate: ports.CandidateRef = .{ .candidate = 2, .rung = 1 };
    const fail = try failed(try ports.allocate(a, candidate, 1, .south, 3, &.{ independent, trunk }));
    const payload = fail.capacity_exceeded;
    try std.testing.expectEqual(pb.DiagnosticTag.port_capacity_exceeded, payload.tag);
    try std.testing.expectEqual(@as(u32, 2), payload.candidate.candidate);
    try std.testing.expectEqual(@as(u8, 1), payload.candidate.rung);
    try std.testing.expectEqual(@as(pb.NodeId, 1), payload.node);
    try std.testing.expectEqual(sk.Dir4.south, payload.side);
    try std.testing.expectEqual(@as(u32, 2), payload.demand);
    try std.testing.expectEqual(@as(u32, 3), payload.available);
    // Group class per attachment, in the clause-6 recorded order.
    try std.testing.expectEqualSlices(ports.AttachmentClass, &.{ .independent, .trunk_pivot }, payload.classes);
    // EVERY involved edge id and branch group id on the side.
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 7, 8, 9 }, payload.edges);
    try std.testing.expectEqualSlices(pb.JoinGroupId, &.{ 3, 5 }, payload.groups);
    try std.testing.expectEqualStrings(ports.decision_row_clause_12, payload.decision_row);
    try std.testing.expect(payload.reason.len > 0);
    try std.testing.expect(payload.expected_action.len > 0);
}

test "V-D-PORT-11: byte-identical K fails with port_key_collision naming D-DUPLICATE and freezing no order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A→B declared twice, identical kind/arrows/label: byte-identical K.
    const twin_a = att("B", .source_exit, 9, 0);
    const twin_b = att("B", .source_exit, 4, 0);
    const first = try failed(try ports.allocate(a, no_candidate, 0, .south, 9, &.{ twin_a, twin_b }));
    const second = try failed(try ports.allocate(a, no_candidate, 0, .south, 9, &.{ twin_b, twin_a }));
    for ([_]ports.Failure{ first, second }) |fail| {
        const payload = fail.key_collision;
        try std.testing.expectEqual(pb.DiagnosticTag.port_key_collision, payload.tag);
        try std.testing.expectEqualStrings("B", payload.key.opposite);
        // Canonicalized inventory, NOT a port order: no order is frozen
        // between the twins (disposition deferred to D-DISPOSITION,
        // multiplicity to D-DUPLICATE).
        try std.testing.expectEqualSlices(pb.EdgeId, &.{ 4, 9 }, payload.edges);
        try std.testing.expectEqualStrings("D-DUPLICATE", payload.deferred_to);
    }
}

// -- Determinism and ordering (clauses 5-6) --------------------------------------

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
    // V-D-PORT-06 allocator half: two entries on ONE node, equal centers,
    // distinct K — MUST get two distinct cells, never one midpoint.
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
    near_dotted.key.kind = 1; // dotted, pinned ordinal 1
    const far_plain = att("n", .source_exit, 2, 10);
    var far_thick = att("n", .source_exit, 3, 10);
    far_thick.key.kind = 2; // thick, pinned ordinal 2
    const far_entry = att("n", .target_entry, 4, 10);

    const atts = [_]ports.Attachment{ far_labeled, near_dotted, far_plain, far_thick, far_entry };
    const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, 11, &atts));
    // Center 2 first; within center 10: endpoint_side (exit=0 < entry=1),
    // then kind ordinal, then no-label before label.
    const want_edges = [_]pb.EdgeId{ 1, 2, 0, 3, 4 };
    for (want_edges, out) |edge, assignment|
        try std.testing.expectEqual(@as(?pb.EdgeId, edge), assignment.attachment.edge);
    // Full house p=5 on L=11: offsets 1,3,5,7,9.
    for (out, 0..) |assignment, i|
        try std.testing.expectEqual(@as(u32, 1 + 2 * @as(u32, @intCast(i))), assignment.offset);
}

// -- Attachment-set derivation (clauses 3, 5, 10) --------------------------------

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
    // LR keeps the current pair: both terminals on south, still distinct.
    const lr = try ports.derive(a, graph, .{ .policy = .joined }, .{}, .LR, &.{});
    try std.testing.expectEqual(sk.Dir4.south, lr[0].side);
    try std.testing.expectEqual(sk.Dir4.south, lr[1].side);
    try std.testing.expectEqual(@as(u32, 2), ports.sideDemand(lr, 0).south);
}

test "V-D-PORT-09: reversed exit and entry both derive to east in TD and get distinct offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // M is source of one reversed edge and target of another: today both
    // land on ONE east cell (h/2); the allocator must split them.
    const nodes = [_]sg.Node{ mkNode(0, "M"), mkNode(1, "X"), mkNode(2, "Y") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 2, 0) };
    const graph = mkGraph(.TD, &nodes, &edges);
    const derived = try ports.derive(a, graph, .{ .policy = .joined }, .{}, .TD, &.{ 0, 1 });
    const demand = ports.sideDemand(derived, 0);
    try std.testing.expectEqual(@as(u32, 2), demand.east);
    // Height must grow to 2*2+1 = 5 (clause 9 helper).
    try std.testing.expectEqual(@as(u32, 5), ports.demandDims(demand).h_min);
    const east = try ports.forSide(a, derived, 0, .east);
    const out = try assigned(try ports.allocate(a, no_candidate, 0, .east, 5, east));
    try std.testing.expectEqual(@as(usize, 2), out.len);
    // endpoint_side is a K component, so exit and entry stay typed apart.
    try std.testing.expectEqual(pb.EndpointSide.source_exit, out[0].attachment.key.endpoint_side);
    try std.testing.expectEqual(pb.EndpointSide.target_entry, out[1].attachment.key.endpoint_side);
    try std.testing.expectEqual(@as(u32, 1), out[0].offset);
    try std.testing.expectEqual(@as(u32, 3), out[1].offset);
}

test "derivation: a committed group consumes one trunk pivot attachment keyed by its smallest member K" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "S"), mkNode(1, "A"), mkNode(2, "B") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 0, 2) };
    const graph = mkGraph(.TD, &nodes, &edges);
    const groups = [_]pb.JoinGroup{.{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 0, 1 } }};
    const plan: pb.JoinPermits = .{
        .policy = .joined,
        .groups = &groups,
        .memberships = &.{
            .{ .edge = 0, .source_group = 0, .target_group = null },
            .{ .edge = 1, .source_group = 0, .target_group = null },
        },
    };
    const joins: pb.RealizedJoins = .{
        .selected_joins = &.{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &.{ 0, 1 } }},
        .memberships = &.{
            .{ .edge = 0, .source = .{ .selected = 0 }, .target = null },
            .{ .edge = 1, .source = .{ .selected = 0 }, .target = null },
        },
    };
    const derived = try ports.derive(a, graph, plan, joins, .TD, &.{});
    // ONE pivot attachment on S south (not two member exits); ordinary
    // per-member entries at A and B.
    const south = try ports.forSide(a, derived, 0, .south);
    try std.testing.expectEqual(@as(usize, 1), south.len);
    try std.testing.expectEqual(ports.AttachmentClass.trunk_pivot, south[0].class);
    try std.testing.expectEqualStrings("A", south[0].key.opposite);
    try std.testing.expectEqual(@as(?pb.EdgeId, 0), south[0].edge);
    try std.testing.expectEqual(@as(?pb.JoinGroupId, 0), south[0].group);
    try std.testing.expectEqual(@as(usize, 2), south[0].members.len);
    try std.testing.expectEqual(@as(u32, 1), ports.sideDemand(derived, 1).north);
    try std.testing.expectEqual(@as(u32, 1), ports.sideDemand(derived, 2).north);
    // Clause 10: a trunk pivot alone on its side keeps the midpoint m —
    // today's BusBar stem geometry, the zero-output-change anchor.
    const out = try assigned(try ports.allocate(a, no_candidate, 0, .south, 7, south));
    try std.testing.expectEqual(@as(u32, 3), out[0].offset);
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

// -- Side conventions (clause 3) -------------------------------------------------

test "side conventions are frozen per direction for forward, reversed, and self-loop attachments" {
    const t = std.testing;
    // Forward: TD out=south/in=north; BT out=north/in=south;
    // LR out=east/in=west; RL out=west/in=east.
    try t.expectEqual(sk.Dir4.south, ports.forwardSide(.TD, .source_exit));
    try t.expectEqual(sk.Dir4.north, ports.forwardSide(.TD, .target_entry));
    try t.expectEqual(sk.Dir4.north, ports.forwardSide(.BT, .source_exit));
    try t.expectEqual(sk.Dir4.south, ports.forwardSide(.BT, .target_entry));
    try t.expectEqual(sk.Dir4.east, ports.forwardSide(.LR, .source_exit));
    try t.expectEqual(sk.Dir4.west, ports.forwardSide(.LR, .target_entry));
    try t.expectEqual(sk.Dir4.west, ports.forwardSide(.RL, .source_exit));
    try t.expectEqual(sk.Dir4.east, ports.forwardSide(.RL, .target_entry));
    // Reversed, exit and entry alike: TD/BT → east, LR/RL → south.
    try t.expectEqual(sk.Dir4.east, ports.reversedSide(.TD));
    try t.expectEqual(sk.Dir4.east, ports.reversedSide(.BT));
    try t.expectEqual(sk.Dir4.south, ports.reversedSide(.LR));
    try t.expectEqual(sk.Dir4.south, ports.reversedSide(.RL));
    // Self-loops: TD/BT east exit + north entry; LR/RL south pair.
    try t.expectEqual(sk.Dir4.east, ports.selfLoopSide(.TD, .source_exit));
    try t.expectEqual(sk.Dir4.north, ports.selfLoopSide(.TD, .target_entry));
    try t.expectEqual(sk.Dir4.east, ports.selfLoopSide(.BT, .source_exit));
    try t.expectEqual(sk.Dir4.north, ports.selfLoopSide(.BT, .target_entry));
    try t.expectEqual(sk.Dir4.south, ports.selfLoopSide(.LR, .source_exit));
    try t.expectEqual(sk.Dir4.south, ports.selfLoopSide(.LR, .target_entry));
    try t.expectEqual(sk.Dir4.south, ports.selfLoopSide(.RL, .source_exit));
    try t.expectEqual(sk.Dir4.south, ports.selfLoopSide(.RL, .target_entry));
}

// -- Departure clearance and post-allocation check (clauses 8, 14) ---------------

test "departure ownership: first off-node cell collinear with the port on all four sides" {
    const t = std.testing;
    const rect: sk.Rect = .{ .x = 10, .y = 20, .w = 5, .h = 3 };
    const north = ports.departureOwnership(rect, .north, 2);
    try t.expectEqual(sk.Point{ .x = 12, .y = 20 }, north.port_cell);
    try t.expectEqual(sk.Point{ .x = 12, .y = 19 }, north.departure_cell);
    const south = ports.departureOwnership(rect, .south, 2);
    try t.expectEqual(sk.Point{ .x = 12, .y = 22 }, south.port_cell);
    try t.expectEqual(sk.Point{ .x = 12, .y = 23 }, south.departure_cell);
    const west = ports.departureOwnership(rect, .west, 1);
    try t.expectEqual(sk.Point{ .x = 10, .y = 21 }, west.port_cell);
    try t.expectEqual(sk.Point{ .x = 9, .y = 21 }, west.departure_cell);
    const east = ports.departureOwnership(rect, .east, 1);
    try t.expectEqual(sk.Point{ .x = 14, .y = 21 }, east.port_cell);
    try t.expectEqual(sk.Point{ .x = 15, .y = 21 }, east.departure_cell);
    // Pitch-2 neighbours: departure cells sit 2 apart, never 4-adjacent.
    const d1 = ports.departureOwnership(rect, .south, 1).departure_cell;
    const d2 = ports.departureOwnership(rect, .south, 3).departure_cell;
    try t.expectEqual(@as(i32, 2), d2.x - d1.x);
    try t.expectEqual(d1.y, d2.y);
}

test "validateAssignments accepts clause-7 output and flags shared cells, departure breaches, and formula drift as port_coalesced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const atts = [_]ports.Attachment{
        att("a", .source_exit, 0, 0),
        att("b", .source_exit, 1, 0),
        att("c", .source_exit, 2, 0),
    };
    const good = try assigned(try ports.allocate(a, no_candidate, 0, .south, 9, &atts));
    try std.testing.expectEqual(@as(?ports.Coalesced, null), ports.validateAssignments(0, .south, 9, good));

    var mutated = try a.dupe(ports.Assignment, good);
    mutated[1].offset = mutated[0].offset; // two terminals on one cell
    const shared = ports.validateAssignments(0, .south, 9, mutated).?;
    try std.testing.expectEqual(pb.DiagnosticTag.port_coalesced, shared.tag);
    try std.testing.expectEqual(ports.CoalesceDetail.shared_cell, shared.detail);

    mutated = try a.dupe(ports.Assignment, good);
    mutated[1].offset = mutated[0].offset + 1; // 4-adjacent departure cells
    const breach = ports.validateAssignments(0, .south, 9, mutated).?;
    try std.testing.expectEqual(pb.DiagnosticTag.port_departure_conflict, breach.tag);
    try std.testing.expectEqual(ports.CoalesceDetail.departure_ownership, breach.detail);

    mutated = try a.dupe(ports.Assignment, good);
    for (mutated) |*assignment| assignment.offset -= 2; // 0,2,4: pitch holds, formula drifts
    const drift = ports.validateAssignments(0, .south, 9, mutated).?;
    try std.testing.expectEqual(ports.CoalesceDetail.offset_formula, drift.detail);
}

// -- Sizing helper (clause 9) -----------------------------------------------------

test "demandDims computes 2*max+1 per axis" {
    const t = std.testing;
    const empty = ports.demandDims(.{});
    try t.expectEqual(@as(u32, 1), empty.w_min);
    try t.expectEqual(@as(u32, 1), empty.h_min);
    const dims = ports.demandDims(.{ .north = 2, .south = 3, .east = 1 });
    try t.expectEqual(@as(u32, 7), dims.w_min);
    try t.expectEqual(@as(u32, 3), dims.h_min);
}

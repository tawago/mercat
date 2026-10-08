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
        .key_collision, .capacity_exceeded => error.TestUnexpectedResult,
    };
}

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
            const out = try assigned(try ports.allocate(a, side_len, atts.items));
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

test "demandDims needs 2*max+1 cells per axis, so p=3 does not fit a w=5 face" {
    const t = std.testing;
    try t.expect(!ports.satisfiable(5, 3));
    const empty = ports.demandDims(.{});
    try t.expectEqual(@as(u32, 1), empty.w_min);
    try t.expectEqual(@as(u32, 1), empty.h_min);
    const dims = ports.demandDims(.{ .north = 2, .south = 3, .east = 1 });
    try t.expectEqual(@as(u32, 7), dims.w_min);
    try t.expectEqual(@as(u32, 3), dims.h_min);
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
        const ok = try assigned(try ports.allocate(a, 2 * p + 1, atts.items));
        try std.testing.expectEqual(@as(usize, p), ok.len);
        try std.testing.expect(try ports.allocate(a, 2 * p, atts.items) == .capacity_exceeded);
    }
}

test "attachments whose keys are byte-identical collide whatever order they arrive in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const twin_a = att("B", .source_exit, 9, 0);
    const twin_b = att("B", .source_exit, 4, 0);
    try std.testing.expect(try ports.allocate(a, 9, &.{ twin_a, twin_b }) == .key_collision);
    try std.testing.expect(try ports.allocate(a, 9, &.{ twin_b, twin_a }) == .key_collision);
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
    const reference = try assigned(try ports.allocate(a, 9, &base));
    for (perms) |perm| {
        var shuffled: [4]ports.Attachment = undefined;
        for (perm, 0..) |src, i| shuffled[i] = base[src];
        const out = try assigned(try ports.allocate(a, 9, &shuffled));
        try std.testing.expectEqual(reference.len, out.len);
        for (reference, out) |want, got| {
            try std.testing.expectEqual(want.attachment.edge, got.attachment.edge);
            try std.testing.expectEqual(want.ordinal, got.ordinal);
            try std.testing.expectEqual(want.offset, got.offset);
        }
    }
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
    const out = try assigned(try ports.allocate(a, 11, &atts));
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
    const out = try assigned(try ports.allocate(a, 5, east));
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
        .selected_bundles = &.{.{ .id = 0, .candidate_bundle = 0, .members = &.{ 0, 1 } }},
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
    const out = try assigned(try ports.allocate(a, 7, south));
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
            .{ .id = 0, .candidate_bundle = 0, .members = &.{ 0, 2 } },
            .{ .id = 1, .candidate_bundle = 1, .members = &.{ 1, 3 } },
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

test "a plain forward arrival co-located with a self-loop terminal joins the side allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "D"), mkNode(1, "Z") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 1), mkEdge(1, 1, 1) };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const derived = try ports.derive(a, graph, .{ .policy = .joined }, .{}, .TD, &.{});
    try std.testing.expectEqual(@as(u32, 2), ports.sideDemand(derived, 1).north);
    const north = try ports.forSide(a, derived, 1, .north);
    var saw_arrival = false;
    var saw_self = false;
    for (north) |attachment| {
        if (attachment.edge == 0) saw_arrival = true;
        if (attachment.edge == 1) saw_self = true;
    }
    try std.testing.expect(saw_arrival and saw_self);
    const out = try assigned(try ports.allocate(a, 7, north));
    try std.testing.expect(out[0].offset != out[1].offset);
    try std.testing.expectEqual(@as(u32, 0), ports.sideDemand(derived, 0).south);
    const plain_edges = [_]sg.Edge{mkEdge(0, 0, 1)};
    const plain: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &plain_edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const plain_derived = try ports.derive(a, plain, .{ .policy = .joined }, .{}, .TD, &.{});
    try std.testing.expectEqual(@as(usize, 0), plain_derived.len);
}

test "V-D-PORT-06: realized Km1 fan-IN derives one north pivot attachment and keeps the merged terminal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ mkNode(0, "A"), mkNode(1, "B"), mkNode(2, "T") };
    const edges = [_]sg.Edge{ mkEdge(0, 0, 2), mkEdge(1, 1, 2) };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const groups = [_]pb.CandidateBundle{.{ .id = 0, .direction = .in, .pivot = 2, .members = &.{ 0, 1 } }};
    const permit_memberships = [_]pb.BundleMembership{
        .{ .edge = 0, .source_group = null, .target_group = 0 }, .{ .edge = 1, .source_group = null, .target_group = 0 },
    };
    const permit: pb.BundlePermits = .{ .policy = .joined, .groups = &groups, .memberships = &permit_memberships };
    const memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = .{ .selected = 0 } }, .{ .edge = 1, .source = null, .target = .{ .selected = 0 } },
    };
    const bundles: pb.RealizedBundles = .{
        .selected_bundles = &.{.{ .id = 0, .candidate_bundle = 0, .members = &.{ 0, 1 } }},
        .memberships = &memberships,
    };
    const derived = try ports.derive(a, graph, permit, bundles, .TD, &.{});
    const target = try ports.forSide(a, derived, 2, .north);
    try std.testing.expectEqual(@as(usize, 1), target.len);
    try std.testing.expectEqual(ports.AttachmentClass.rail_pivot, target[0].class);
    try std.testing.expectEqual(pb.EndpointSide.target_entry, target[0].key.endpoint_side);
    try std.testing.expectEqual(@as(usize, 2), target[0].members.len);
    const allocated = try assigned(try ports.allocate(a, 7, target));
    try std.testing.expectEqual(@as(usize, 1), allocated.len);
    try std.testing.expectEqual(@as(u32, 3), allocated[0].offset);

    for ([_]u32{ 0, 1 }) |src| {
        const exits = try ports.forSide(a, derived, src, .south);
        try std.testing.expectEqual(@as(usize, 1), exits.len);
        try std.testing.expectEqual(ports.AttachmentClass.independent, exits[0].class);
        try std.testing.expectEqual(pb.EndpointSide.source_exit, exits[0].key.endpoint_side);
    }
}

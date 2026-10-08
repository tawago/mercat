const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const coords = @import("../layout.zig");
const permits = @import("../ledger/permits.zig");
const ports = @import("ports.zig");
const port_plan = @import("port_plan.zig");

fn node(id: u32, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

fn edge(id: u32, to: u32, kind: sg.EdgeKind) sg.Edge {
    return .{ .id = id, .from = 0, .to = to, .kind = kind, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

fn testGraph(nodes: []const sg.Node, edges: []const sg.Edge) sg.SemGraph {
    return .{ .direction = .TD, .nodes = nodes, .edges = edges, .clusters = &.{}, .classes = &.{}, .arena = null };
}

fn productionLayout(a: std.mem.Allocator, g: sg.SemGraph) !sk.Sketch {
    const built = try permits.build(a, g, .joined);
    return coords.layout(a, g, .{
        .bundle_permits = &built.plan,
    });
}

fn pathById(s: sk.Sketch, id: pb.EdgeId) sk.EdgePath {
    for (s.edges) |path| if (path.id == id) return path;
    @panic("missing edge path");
}

fn expectPrivatePorts(s: sk.Sketch, ids: []const pb.EdgeId) !void {
    for (ids, 0..) |id, i| {
        const path = pathById(s, id);
        for (ids[0..i]) |prior_id| {
            const prior = pathById(s, prior_id);
            try std.testing.expect(!samePort(path.port_from, prior.port_from));
            try std.testing.expect(!samePort(path.port_to, prior.port_to));
        }
    }
}

fn samePort(a: sk.Port, b: sk.Port) bool {
    return a.node == b.node and a.side == b.side and a.offset == b.offset;
}

test "V-D-PORT-01: port_plan gives an unrealized mixed-kind 1x3 fan three pitch-2 ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "S"), node(1, "A"), node(2, "B"), node(3, "C") };
    const edges = [_]sg.Edge{ edge(0, 1, .solid), edge(1, 2, .dotted), edge(2, 3, .thick) };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const groups = [_]pb.CandidateBundle{.{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 0, 1, 2 } }};
    const memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } }, .target = null },
        .{ .edge = 1, .source = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } }, .target = null },
        .{ .edge = 2, .source = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } }, .target = null },
    };
    const bundles: pb.RealizedBundles = .{ .memberships = &memberships };
    const permit_memberships = [_]pb.BundleMembership{
        .{ .edge = 0, .source_group = 0, .target_group = null }, .{ .edge = 1, .source_group = 0, .target_group = null }, .{ .edge = 2, .source_group = 0, .target_group = null },
    };
    const permit: pb.BundlePermits = .{ .policy = .joined, .groups = &groups, .memberships = &permit_memberships };
    const derived = try ports.derive(a, graph, permit, bundles, .TD, &.{});
    const placements = [_]sk.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 0, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 10, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 20, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const plan = try port_plan.allocate(a, graph, &placements, derived, bundles);
    try std.testing.expectEqual(@as(u32, 1), plan.forEdge(0).?.source.offset);
    try std.testing.expectEqual(@as(u32, 3), plan.forEdge(1).?.source.offset);
    try std.testing.expectEqual(@as(u32, 5), plan.forEdge(2).?.source.offset);
}

test "port_plan midpoint keeps singleton terminal coordinates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = [_]sg.Node{ node(0, "S"), node(1, "T") };
    const edges = [_]sg.Edge{edge(0, 1, .solid)};
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const placements = [_]sk.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 0, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const plan = try port_plan.midpoint(arena.allocator(), graph, &placements);
    try std.testing.expectEqual(@as(u32, 3), plan.forEdge(0).?.source.offset);
    try std.testing.expectEqual(@as(u32, 2), plan.forEdge(0).?.target.offset);
}

test "a discharged edge claims no attachment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "S"), node(1, "A"), node(2, "B") };
    const edges = [_]sg.Edge{ edge(0, 1, .solid), edge(1, 2, .solid), .{ .id = 2, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null } };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const groups = [_]pb.CandidateBundle{
        .{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 0, 1 } },
        .{ .id = 1, .direction = .in, .pivot = 2, .members = &.{ 1, 2 } },
    };
    const ind0: pb.MembershipDisposition = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } };
    const ind1: pb.MembershipDisposition = .{ .independent = .{ .candidate_bundle = 1, .reason = .not_selected } };
    const memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = ind0, .target = null },
        .{ .edge = 1, .source = ind0, .target = ind1 },
        .{ .edge = 2, .source = null, .target = ind1 },
    };
    const permit_memberships = [_]pb.BundleMembership{
        .{ .edge = 0, .source_group = 0, .target_group = null },
        .{ .edge = 1, .source_group = 0, .target_group = 1 },
        .{ .edge = 2, .source_group = null, .target_group = 1 },
    };
    const permit: pb.BundlePermits = .{ .policy = .joined, .groups = &groups, .memberships = &permit_memberships };

    const with_ink: pb.RealizedBundles = .{ .memberships = &memberships };
    const discharged: pb.RealizedBundles = .{ .memberships = &memberships, .discharged = &.{2} };

    const all = try ports.derive(a, graph, permit, with_ink, .TD, &.{});
    const kept = try ports.withoutDischarged(a, all, discharged);
    try std.testing.expect(kept.len < all.len);
    for (kept) |item| try std.testing.expect((item.attachment.edge orelse 99) != 2);
}

test "duplicate private claims receive stable distinct source and target slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "S"), node(1, "A") };
    const forward = [_]sg.Edge{ edge(9, 1, .solid), edge(4, 1, .solid) };
    const reversed = [_]sg.Edge{ forward[1], forward[0] };
    var offsets: [2][4]u32 = undefined;
    for ([2][]const sg.Edge{ &forward, &reversed }, 0..) |edges, run| {
        const g = testGraph(&nodes, edges);
        const memberships = [_]pb.RealizedEdgeMembership{
            .{ .edge = 4, .source = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } }, .target = .{ .independent = .{ .candidate_bundle = 1, .reason = .not_selected } } },
            .{ .edge = 9, .source = .{ .independent = .{ .candidate_bundle = 0, .reason = .not_selected } }, .target = .{ .independent = .{ .candidate_bundle = 1, .reason = .not_selected } } },
        };
        const bundles: pb.RealizedBundles = .{ .memberships = &memberships };
        const groups = [_]pb.CandidateBundle{
            .{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 4, 9 } },
            .{ .id = 1, .direction = .in, .pivot = 1, .members = &.{ 4, 9 } },
        };
        const permit_memberships = [_]pb.BundleMembership{
            .{ .edge = 4, .source_group = 0, .target_group = 1 },
            .{ .edge = 9, .source_group = 0, .target_group = 1 },
        };
        const derived = try ports.derive(a, g, .{ .policy = .joined, .groups = &groups, .memberships = &permit_memberships }, bundles, .TD, &.{});
        const placements = [_]sk.NodePlacement{
            .{ .id = 0, .rect = .{ .x = 0, .y = 0, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
            .{ .id = 1, .rect = .{ .x = 0, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        };
        const plan = try port_plan.allocate(a, g, &placements, derived, bundles);
        offsets[run] = .{
            plan.forEdge(4).?.source.offset,
            plan.forEdge(9).?.source.offset,
            plan.forEdge(4).?.target.offset,
            plan.forEdge(9).?.target.offset,
        };
        try std.testing.expect(offsets[run][0] != offsets[run][1]);
        try std.testing.expect(offsets[run][2] != offsets[run][3]);
    }
    try std.testing.expectEqual(offsets[0], offsets[1]);
}

test "two and three identical arrows get private ports and face growth" {
    inline for (.{ 2, 3 }) |n| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nodes = [_]sg.Node{ node(0, "S"), node(1, "A") };
        var edges: [n]sg.Edge = undefined;
        for (&edges, 0..) |*item, i| item.* = edge(@intCast(i), 1, .solid);
        const g = testGraph(&nodes, &edges);
        const s = try productionLayout(a, g);
        try std.testing.expectEqual(@as(usize, n), s.edges.len);
        var ids: [n]pb.EdgeId = undefined;
        for (&ids, 0..) |*id, i| id.* = @intCast(i);
        try expectPrivatePorts(s, &ids);
        for (s.nodes) |placed| try std.testing.expect(placed.rect.w >= 2 * n + 1);
    }
}

test "labelled or unlabelled, a duplicate beside a distinct leaf stays private and the rest rail" {
    for ([_]?[]const u8{ "dup", null }) |label| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const nodes = [_]sg.Node{ node(0, "S"), node(1, "A"), node(2, "B") };
        var edges = [_]sg.Edge{ edge(0, 1, .solid), edge(1, 1, .solid), edge(2, 2, .solid) };
        edges[0].label = label;
        edges[1].label = label;
        const s = try productionLayout(a, testGraph(&nodes, &edges));
        try std.testing.expectEqual(@as(usize, 1), s.sharing.realized.selected_bundles.len);
        try expectPrivatePorts(s, &.{ 0, 1 });
        try expectPrivatePorts(s, &.{ 1, 2 });
        try std.testing.expect(samePort(pathById(s, 0).port_from, pathById(s, 2).port_from));
    }
}

test "bidirectional duplicate and self-loop keep independent endpoint identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "S"), node(1, "A") };
    var edges = [_]sg.Edge{ edge(0, 1, .solid), edge(1, 1, .solid), edge(2, 0, .solid) };
    edges[0].arrow_from = .filled;
    edges[1].arrow_from = .filled;
    edges[2].from = 0;
    const g = testGraph(&nodes, &edges);
    const s = try productionLayout(a, g);
    try expectPrivatePorts(s, &.{ 0, 1 });
    const loop = pathById(s, 2);
    try std.testing.expect(!samePort(loop.port_from, loop.port_to));
}

test "a fan with a long peer the plan did not select degrades to private routing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C") };
    const edges = [_]sg.Edge{
        edge(0, 1, .solid),
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        edge(2, 2, .thick),
    };
    const s = try productionLayout(a, testGraph(&nodes, &edges));
    for (s.rails) |rail| try std.testing.expect(rail.pivot != 0);
    for (s.edges) |path| try std.testing.expect(path.role != .member_stroke);
    try std.testing.expectEqual(sk.EdgeRole.forward, pathById(s, 2).role);
}

test "a decorated long fan-in member's stroke leaves its departure cell straight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C") };
    const edges = [_]sg.Edge{
        edge(0, 1, .solid),
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .filled, .arrow_to = .none, .label = null },
        .{ .id = 2, .from = 0, .to = 2, .kind = .solid, .arrow_from = .filled, .arrow_to = .none, .label = null },
    };
    const s = try productionLayout(a, testGraph(&nodes, &edges));
    const stroke = pathById(s, 2);
    try std.testing.expectEqual(sk.EdgeRole.member_stroke, stroke.role);
    try std.testing.expect(stroke.polyline.len >= 2);
    try std.testing.expect(stroke.polyline[1].y - stroke.polyline[0].y >= 2);
}

test "a long member of a fan-out and a fan-in gets continuing taps at both ends and a straight member stroke between them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "C") };
    const edges = [_]sg.Edge{
        edge(0, 1, .solid),
        .{ .id = 1, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null },
        edge(2, 2, .solid),
    };
    const s = try productionLayout(a, testGraph(&nodes, &edges));
    try std.testing.expectEqual(@as(usize, 2), s.rails.len);
    var out_tap: ?sk.Tap = null;
    var in_tap: ?sk.Tap = null;
    for (s.rails) |rail| for (rail.taps) |tap| if (tap.edge == 2 and tap.continues) {
        if (rail.pivot == 0) out_tap = tap;
        if (rail.pivot == 2) in_tap = tap;
    };
    const ot = out_tap orelse return error.MissingDepartureTap;
    const it = in_tap orelse return error.MissingArrivalTap;
    try std.testing.expectEqual(ot.at.y + 1, ot.landing.y);
    try std.testing.expectEqual(it.at.y - 1, it.landing.y);
    const stroke = pathById(s, 2);
    try std.testing.expectEqual(sk.EdgeRole.member_stroke, stroke.role);
    try std.testing.expectEqual(@as(usize, 2), stroke.polyline.len);
    try std.testing.expectEqual(ot.at.x, stroke.polyline[0].x);
    try std.testing.expectEqual(ot.at.y, stroke.polyline[0].y);
    try std.testing.expectEqual(it.at.x, stroke.polyline[1].x);
    try std.testing.expectEqual(it.at.y, stroke.polyline[1].y);
    for (s.edges) |e| try std.testing.expect(e.id != 0);
}

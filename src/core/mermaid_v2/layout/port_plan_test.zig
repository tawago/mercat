const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const sk = @import("../sketch.zig");
const ports = @import("ports.zig");
const port_plan = @import("port_plan.zig");
const sugiyama = @import("sugiyama.zig");

fn node(id: u32, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

fn edge(id: u32, to: u32, kind: sg.EdgeKind) sg.Edge {
    return .{ .id = id, .from = 0, .to = to, .kind = kind, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

test "V-D-PORT-01: port_plan gives an unrealized mixed-kind 1x3 fan three pitch-2 ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "S"), node(1, "A"), node(2, "B"), node(3, "C") };
    const edges = [_]sg.Edge{ edge(0, 1, .solid), edge(1, 2, .dotted), edge(2, 3, .thick) };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const groups = [_]pb.JoinGroup{.{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 0, 1, 2 } }};
    const memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = .{ .independent = .{ .permission_group = 0, .reason = .not_selected } }, .target = null },
        .{ .edge = 1, .source = .{ .independent = .{ .permission_group = 0, .reason = .not_selected } }, .target = null },
        .{ .edge = 2, .source = .{ .independent = .{ .permission_group = 0, .reason = .not_selected } }, .target = null },
    };
    const joins: pb.RealizedJoins = .{ .memberships = &memberships };
    const permit_memberships = [_]pb.JoinMembership{
        .{ .edge = 0, .source_group = 0, .target_group = null }, .{ .edge = 1, .source_group = 0, .target_group = null }, .{ .edge = 2, .source_group = 0, .target_group = null },
    };
    const permit: pb.JoinPermits = .{ .policy = .joined, .groups = &groups, .memberships = &permit_memberships };
    const derived = try ports.derive(a, graph, permit, joins, .TD, &.{});
    const placements = [_]sk.NodePlacement{
        .{ .id = 0, .rect = .{ .x = 10, .y = 0, .w = 7, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 1, .rect = .{ .x = 0, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 2, .rect = .{ .x = 10, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
        .{ .id = 3, .rect = .{ .x = 20, .y = 7, .w = 5, .h = 3 }, .shape = .rect, .lines = &.{}, .cluster_id = null },
    };
    const plan = try port_plan.allocate(a, graph, &placements, derived, joins, .{}, 0);
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

test "a co-realized edge claims no attachment and consumes no route lane" {
    // Edge 2 is discharged by an all-arrow-free rail: it is rendered by the
    // crossbar between the other two members' taps, so it must claim no
    // perimeter attachment and reserve no gap row of its own.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "S"), node(1, "A"), node(2, "B") };
    const edges = [_]sg.Edge{ edge(0, 1, .solid), edge(1, 2, .solid), .{ .id = 2, .from = 1, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .none, .label = null } };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    // out@S = {0,1} and in@B = {1,2}, both left independent — so the withheld
    // edge 2 DOES derive attachments, which is what the filter must remove.
    const groups = [_]pb.JoinGroup{
        .{ .id = 0, .direction = .out, .pivot = 0, .members = &.{ 0, 1 } },
        .{ .id = 1, .direction = .in, .pivot = 2, .members = &.{ 1, 2 } },
    };
    const ind0: pb.MembershipDisposition = .{ .independent = .{ .permission_group = 0, .reason = .not_selected } };
    const ind1: pb.MembershipDisposition = .{ .independent = .{ .permission_group = 1, .reason = .not_selected } };
    const memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = ind0, .target = null },
        .{ .edge = 1, .source = ind0, .target = ind1 },
        .{ .edge = 2, .source = null, .target = ind1 },
    };
    const permit_memberships = [_]pb.JoinMembership{
        .{ .edge = 0, .source_group = 0, .target_group = null },
        .{ .edge = 1, .source_group = 0, .target_group = 1 },
        .{ .edge = 2, .source_group = null, .target_group = 1 },
    };
    const permit: pb.JoinPermits = .{ .policy = .joined, .groups = &groups, .memberships = &permit_memberships };

    const with_ink: pb.RealizedJoins = .{ .memberships = &memberships };
    const discharged: pb.RealizedJoins = .{ .memberships = &memberships, .co_realized = &.{2} };

    const all = try ports.derive(a, graph, permit, with_ink, .TD, &.{});
    const kept = try port_plan.withoutCoRealized(a, all, discharged);
    try std.testing.expect(kept.len < all.len);
    for (kept) |item| try std.testing.expect((item.attachment.edge orelse 99) != 2);

    // Route lanes: only the sibling members of the still-independent group.
    var lg_nodes = [_]sugiyama.LayerNode{ .{ .real = 0 }, .{ .real = 1 }, .{ .real = 2 } };
    var row0 = [_]u32{0};
    var row1 = [_]u32{ 1, 2 };
    var layers = [_][]u32{ &row0, &row1 };
    var lg_edges = [_]sugiyama.LayerEdge{
        .{ .edge = 0, .from = 0, .to = 1, .reversed = false },
        .{ .edge = 1, .from = 0, .to = 2, .reversed = false },
    };
    const lg: sugiyama.LayeredGraph = .{ .nodes = &lg_nodes, .layers = &layers, .edges = &lg_edges, .reversed_edges = &.{}, .real_index = .empty, .arena = null };
    const lanes = try port_plan.planLanes(a, graph, lg, discharged);
    for (lanes.lanes) |l| try std.testing.expect(l.edge != 2);
}

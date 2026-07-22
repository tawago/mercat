const std = @import("std");
const pb = @import("../base/ledger.zig");
const sg = @import("../sem_graph.zig");
const ports = @import("ports.zig");

fn node(id: u32, raw: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw, .label = raw, .shape = .rect, .classes = &.{}, .cluster = null };
}

fn edge(id: u32, from: u32) sg.Edge {
    return .{ .id = id, .from = from, .to = 2, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

fn edgeTo(id: u32, from: u32, to: u32) sg.Edge {
    return .{ .id = id, .from = from, .to = to, .kind = .solid, .arrow_from = .none, .arrow_to = .filled, .label = null };
}

test "a plain forward arrival co-located with a self-loop terminal joins the side allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Z (id 1) carries a self-loop (TD entry on north) AND a foreign arrival
    // D->Z (also north). The arrival must join Z's north allocation so the two
    // terminals land on distinct pitch-2 cells instead of a shared midpoint
    // (the reach_unknown_continuation the excluded self-loop otherwise leaves).
    const nodes = [_]sg.Node{ node(0, "D"), node(1, "Z") };
    const edges = [_]sg.Edge{ edgeTo(0, 0, 1), edgeTo(1, 1, 1) };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const derived = try ports.derive(a, graph, .{ .policy = .joined }, .{}, .TD, &.{});
    // Z north hosts BOTH the self-loop entry (edge 1) and the D->Z arrival (edge 0).
    try std.testing.expectEqual(@as(u32, 2), ports.sideDemand(derived, 1).north);
    const north = try ports.forSide(a, derived, 1, .north);
    var saw_arrival = false;
    var saw_self = false;
    for (north) |att| {
        if (att.edge == 0) saw_arrival = true;
        if (att.edge == 1) saw_self = true;
    }
    try std.testing.expect(saw_arrival and saw_self);
    // Distinct pitch-2 offsets on a wide enough face → no shared cell.
    const out = switch (try ports.allocate(a, .{}, 1, .north, 7, north)) {
        .assigned => |items| items,
        .failed => return error.UnexpectedAllocationFailure,
    };
    try std.testing.expect(out[0].offset != out[1].offset);
    // D's exit (D south, no self-loop) is NOT pulled into the allocation.
    try std.testing.expectEqual(@as(u32, 0), ports.sideDemand(derived, 0).south);
    // Control: with NO self-loop, the plain arrival keeps its midpoint (absent
    // from the derived set) — the zero-change anchor is preserved.
    const plain_edges = [_]sg.Edge{edgeTo(0, 0, 1)};
    const plain: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &plain_edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const plain_derived = try ports.derive(a, plain, .{ .policy = .joined }, .{}, .TD, &.{});
    try std.testing.expectEqual(@as(usize, 0), plain_derived.len);
}

test "V-D-PORT-06: realized Km1 fan-IN derives one north pivot attachment and keeps the merged terminal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = [_]sg.Node{ node(0, "A"), node(1, "B"), node(2, "T") };
    const edges = [_]sg.Edge{ edge(0, 0), edge(1, 1) };
    const graph: sg.SemGraph = .{ .direction = .TD, .nodes = &nodes, .edges = &edges, .clusters = &.{}, .classes = &.{}, .arena = null };
    const groups = [_]pb.JoinGroup{.{ .id = 0, .direction = .in, .pivot = 2, .members = &.{ 0, 1 } }};
    const permit_memberships = [_]pb.JoinMembership{
        .{ .edge = 0, .source_group = null, .target_group = 0 }, .{ .edge = 1, .source_group = null, .target_group = 0 },
    };
    const permit: pb.JoinPermits = .{ .policy = .joined, .groups = &groups, .memberships = &permit_memberships };
    const memberships = [_]pb.RealizedEdgeMembership{
        .{ .edge = 0, .source = null, .target = .{ .selected = 0 } }, .{ .edge = 1, .source = null, .target = .{ .selected = 0 } },
    };
    const joins: pb.RealizedJoins = .{
        .selected_joins = &.{.{ .id = 0, .proposal = 0, .permission_group = 0, .members = &.{ 0, 1 } }},
        .memberships = &memberships,
    };
    const derived = try ports.derive(a, graph, permit, joins, .TD, &.{});
    const target = try ports.forSide(a, derived, 2, .north);
    try std.testing.expectEqual(@as(usize, 1), target.len);
    try std.testing.expectEqual(ports.AttachmentClass.trunk_pivot, target[0].class);
    try std.testing.expectEqual(pb.EndpointSide.target_entry, target[0].key.endpoint_side);
    try std.testing.expectEqual(@as(usize, 2), target[0].members.len);
    const allocated = switch (try ports.allocate(a, .{}, 2, .north, 7, target)) {
        .assigned => |items| items,
        .failed => return error.UnexpectedAllocationFailure,
    };
    try std.testing.expectEqual(@as(usize, 1), allocated.len);
    try std.testing.expectEqual(@as(u32, 3), allocated[0].offset);

    // V-D-PORT-16: the merged fan-in leaves ONE group-owned pivot on the
    // target AND per-member source exits on each source (the departure side
    // stays its own ordinary exit — never folded into the pivot).
    for ([_]u32{ 0, 1 }) |src| {
        const exits = try ports.forSide(a, derived, src, .south);
        try std.testing.expectEqual(@as(usize, 1), exits.len);
        try std.testing.expectEqual(ports.AttachmentClass.independent, exits[0].class);
        try std.testing.expectEqual(pb.EndpointSide.source_exit, exits[0].key.endpoint_side);
    }
}

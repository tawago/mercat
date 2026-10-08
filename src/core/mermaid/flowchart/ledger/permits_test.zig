const std = @import("std");
const sg = @import("../sem_graph.zig");
const pb = @import("../base/ledger.zig");
const planner = @import("permits.zig");

const nodes = [_]sg.Node{
    node(0, "A"),
    node(1, "B"),
    node(2, "C"),
    node(3, "D"),
    node(4, "X"),
};

fn node(id: sg.NodeId, raw_id: []const u8) sg.Node {
    return .{ .id = id, .raw_id = raw_id, .label = raw_id, .shape = .rect, .classes = &.{}, .cluster = null };
}

fn edge(id: sg.EdgeId, from: sg.NodeId, to: sg.NodeId) sg.Edge {
    return .{
        .id = id,
        .from = from,
        .to = to,
        .kind = .solid,
        .arrow_from = .none,
        .arrow_to = .filled,
        .label = null,
    };
}

fn graph(edges: []const sg.Edge) sg.SemGraph {
    return .{
        .direction = .TD,
        .nodes = &nodes,
        .edges = edges,
        .clusters = &.{},
        .classes = &.{},
        .arena = null,
    };
}

fn expectClean(allocator: std.mem.Allocator, g: sg.SemGraph, plan: pb.BundlePermits) !void {
    const report = try planner.validate(allocator, g, plan);
    try std.testing.expect(report.valid());
}

fn hasFinding(report: planner.ValidationReport, tag: planner.ValidationTag) bool {
    for (report.findings) |finding| if (finding.tag == tag) return true;
    return false;
}

fn membershipOf(plan: pb.BundlePermits, id: pb.EdgeId) ?pb.BundleMembership {
    for (plan.memberships) |membership| if (membership.edge == id) return membership;
    return null;
}

fn canonicalBytes(allocator: std.mem.Allocator, plan: pb.BundlePermits) ![]const u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    for (plan.groups) |group| {
        const header = try std.fmt.allocPrint(allocator, "g:{d}:{s}:{d}:", .{ group.id, @tagName(group.direction), group.pivot });
        try bytes.appendSlice(allocator, header);
        for (group.members) |member| {
            const item = try std.fmt.allocPrint(allocator, "{d},", .{member});
            try bytes.appendSlice(allocator, item);
        }
        try bytes.append(allocator, '\n');
    }
    for (plan.memberships) |membership| {
        const item = try std.fmt.allocPrint(
            allocator,
            "m:{d}:{any}:{any}\n",
            .{ membership.edge, membership.source_group, membership.target_group },
        );
        try bytes.appendSlice(allocator, item);
    }
    return try bytes.toOwnedSlice(allocator);
}

test "discovery groups fans by shared end, keeps parallel pairs, and leaves chains and self-loops independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const G = struct { dir: pb.BundleDirection, pivot: sg.NodeId, members: []const pb.EdgeId };
    const Row = struct {
        edges: []const sg.Edge,
        groups: ?[]const G = &.{},
        memberships: ?usize = null,
        independent: []const pb.EdgeId = &.{},
        dual: ?pb.EdgeId = null,
    };
    const rows = [_]Row{
        .{ .edges = &.{}, .memberships = 0 },
        .{ .edges = &.{edge(7, 0, 1)}, .memberships = 1, .independent = &.{7} },
        // Members come back in canonical order, not input order.
        .{ .edges = &.{ edge(8, 0, 2), edge(4, 0, 1) }, .groups = &.{.{ .dir = .out, .pivot = 0, .members = &.{ 4, 8 } }} },
        .{ .edges = &.{ edge(9, 2, 4), edge(3, 1, 4) }, .groups = &.{.{ .dir = .in, .pivot = 4, .members = &.{ 3, 9 } }} },
        .{ .edges = &.{ edge(11, 0, 4), edge(12, 0, 1), edge(13, 2, 4) }, .groups = null, .dual = 11 },
        .{ .edges = &.{ edge(0, 0, 1), edge(1, 1, 2), edge(2, 2, 3) }, .memberships = 3 },
        // A parallel pair is grouped at both ends, not deduped.
        .{ .edges = &.{ edge(2, 0, 1), edge(7, 0, 1) }, .groups = &.{
            .{ .dir = .out, .pivot = 0, .members = &.{ 2, 7 } },
            .{ .dir = .in, .pivot = 1, .members = &.{ 2, 7 } },
        } },
        // The self-loop leaves the fan-in before the size check, so no one-member group forms.
        .{ .edges = &.{ edge(0, 0, 4), edge(1, 4, 4) }, .memberships = 2, .independent = &.{ 0, 1 } },
    };
    for (rows) |row| {
        const g = graph(row.edges);
        const plan = (try planner.build(a, g, .joined)).plan;
        try expectClean(a, g, plan);
        if (row.groups) |want| {
            try std.testing.expectEqual(want.len, plan.groups.len);
            for (want, plan.groups) |w, got| {
                try std.testing.expectEqual(w.dir, got.direction);
                try std.testing.expectEqual(w.pivot, got.pivot);
                try std.testing.expectEqualSlices(pb.EdgeId, w.members, got.members);
            }
        }
        if (row.memberships) |n| try std.testing.expectEqual(n, plan.memberships.len);
        for (row.independent) |id| {
            const m = membershipOf(plan, id).?;
            try std.testing.expectEqual(@as(?pb.CandidateBundleId, null), m.source_group);
            try std.testing.expectEqual(@as(?pb.CandidateBundleId, null), m.target_group);
        }
        if (row.dual) |id| {
            const m = membershipOf(plan, id).?;
            try std.testing.expect(m.source_group != null and m.target_group != null);
        }
    }
}

test "V-D-EDGE-ID-05: edge-array permutation preserves canonical plan bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ordered = [_]sg.Edge{ edge(30, 0, 4), edge(10, 0, 1), edge(20, 2, 4), edge(40, 0, 3) };
    const shuffled = [_]sg.Edge{ ordered[2], ordered[0], ordered[3], ordered[1] };

    const left = try planner.build(a, graph(&ordered), .joined);
    const right = try planner.build(a, graph(&shuffled), .joined);
    try std.testing.expectEqualStrings(try canonicalBytes(a, left.plan), try canonicalBytes(a, right.plan));
    try expectClean(a, graph(&ordered), left.plan);
    try expectClean(a, graph(&shuffled), right.plan);
}

test "V-D-EDGE-ID-02: clustered graph returns empty plan and the skip marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = [_]sg.NodeId{ 1, 2 };
    const fan_edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2) };
    // An empty cluster, then a real fan whose leaves sit in the cluster.
    const cases = [_]struct { members: []const sg.NodeId, edges: []const sg.Edge }{
        .{ .members = &.{}, .edges = &.{} },
        .{ .members = &members, .edges = &fan_edges },
    };
    for (cases) |case| {
        const cluster = [_]sg.Cluster{
            .{ .id = 0, .raw_id = "S", .label = "S", .parent = null, .members = case.members, .sub_clusters = &.{} },
        };
        var clustered = graph(case.edges);
        clustered.clusters = &cluster;

        const result = try planner.build(a, clustered, .joined);
        try std.testing.expectEqual(pb.BundlePolicy.joined, result.plan.policy);
        try std.testing.expectEqual(pb.BundlePermits.Scope.skipped_clustered, result.plan.scope);
        try std.testing.expectEqual(@as(usize, 0), result.plan.groups.len);
        try std.testing.expectEqual(@as(usize, 0), result.plan.memberships.len);
        try std.testing.expect(result.report.bundle_permits_skipped_clustered);
        if (case.edges.len == 0) try expectClean(a, clustered, result.plan);
    }
}

test "V-D-JOIN-SELECT-14: self-loop exclusion does not annihilate real fan-in co-members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(0, 0, 4), edge(1, 1, 4), edge(2, 4, 4) };

    const result = try planner.build(a, graph(&edges), .joined);
    try std.testing.expectEqual(@as(usize, 1), result.plan.groups.len);
    const group = result.plan.groups[0];
    try std.testing.expectEqual(pb.BundleDirection.in, group.direction);
    try std.testing.expectEqual(@as(sg.NodeId, 4), group.pivot);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 0, 1 }, group.members);
    const self_loop = membershipOf(result.plan, 2).?;
    try std.testing.expectEqual(@as(?pb.CandidateBundleId, null), self_loop.source_group);
    try std.testing.expectEqual(@as(?pb.CandidateBundleId, null), self_loop.target_group);
    try expectClean(a, graph(&edges), result.plan);
}

test "validator rejects each structural invariant corruption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 3, 2) };
    const g = graph(&edges);
    const built = try planner.build(a, g, .joined);

    const short_members = [_]pb.EdgeId{0};
    var groups = try a.dupe(pb.CandidateBundle, built.plan.groups);
    groups[0].members = &short_members;
    var report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .group_too_small));
    try std.testing.expect(hasFinding(report, .membership_group_lacks_edge));

    groups = try a.dupe(pb.CandidateBundle, built.plan.groups);
    groups[0].pivot = 1;
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .member_pivot_mismatch));

    const reversed = [_]pb.EdgeId{ 1, 0 };
    groups = try a.dupe(pb.CandidateBundle, built.plan.groups);
    groups[0].members = &reversed;
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .members_not_canonical));

    const missing = built.plan.memberships[0 .. built.plan.memberships.len - 1];
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = built.plan.groups, .memberships = missing });
    try std.testing.expect(hasFinding(report, .membership_missing_edge));

    var memberships = try a.dupe(pb.BundleMembership, built.plan.memberships);
    memberships[0].source_group = 99;
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = built.plan.groups, .memberships = memberships });
    try std.testing.expect(hasFinding(report, .membership_group_missing));

    groups = try a.dupe(pb.CandidateBundle, built.plan.groups);
    const duplicate = [_]pb.EdgeId{ 0, 0 };
    groups[0].members = &duplicate;
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .group_duplicate_member));

    groups = try a.dupe(pb.CandidateBundle, built.plan.groups);
    std.mem.swap(pb.CandidateBundle, &groups[0], &groups[1]);
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .groups_not_canonical));
}

test "rail preparation salvages distinct leaves and rejects antiparallel or self-loop members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{
        edge(10, 0, 1), edge(11, 0, 1), edge(12, 0, 2),
        edge(13, 1, 0), edge(14, 0, 0),
    };
    const prepared = try planner.prepareRailMembers(a, graph(&edges), .out, 0, &.{ 10, 11, 12, 13, 14 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 12 }, prepared);

    const anti = try planner.prepareRailMembers(a, graph(&edges), .out, 0, &.{ 10, 13 });
    try std.testing.expectEqual(@as(usize, 0), anti.len);
    const loop = try planner.prepareRailMembers(a, graph(&edges), .out, 0, &.{ 10, 14 });
    try std.testing.expectEqual(@as(usize, 0), loop.len);
    const repeated = try planner.prepareRailMembers(a, graph(&edges), .out, 0, &.{ 10, 10, 12 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 12 }, repeated);

    var foreign_edges = [_]sg.Edge{ edge(20, 0, 1), edge(21, 2, 3) };
    const mixed_pivot = try planner.prepareRailMembers(a, graph(&foreign_edges), .out, 0, &.{ 20, 21 });
    try std.testing.expectEqual(@as(usize, 0), mixed_pivot.len);
}

test "rail preparation takes the pivot decoration with the most leaves, then the kind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var edges = [_]sg.Edge{ edge(10, 0, 1), edge(11, 0, 2), edge(12, 0, 3), edge(13, 0, 4), edge(14, 0, 1) };
    const local_nodes = [_]sg.Node{ node(0, "P"), node(1, "A"), node(2, "B"), node(3, "C"), node(4, "D") };
    var g = graph(&edges);
    g.nodes = &local_nodes;

    var prepared = try planner.prepareRailMembers(a, g, .out, 0, &.{ 10, 11, 12, 13 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 11, 12, 13 }, prepared);

    edges[2].kind = .dotted;
    edges[3].kind = .dotted;
    prepared = try planner.prepareRailMembers(a, g, .out, 0, &.{ 10, 11, 12, 13 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 11 }, prepared);
    prepared = try planner.prepareRailMembers(a, g, .out, 0, &.{ 13, 11, 12, 10 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 11 }, prepared);

    edges[2].kind = .solid;
    edges[3].kind = .solid;
    edges[2].arrow_from = .circle;
    edges[3].arrow_from = .circle;
    prepared = try planner.prepareRailMembers(a, g, .out, 0, &.{ 10, 11, 12, 13 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 11 }, prepared);

    edges[3].kind = .dotted;
    prepared = try planner.prepareRailMembers(a, g, .out, 0, &.{ 10, 11, 12, 13 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 11 }, prepared);
    prepared = try planner.prepareRailMembers(a, g, .out, 0, &.{ 13, 11, 12, 10 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 11 }, prepared);

    edges[3].kind = .solid;
    edges[4].arrow_from = .circle;
    edges[4].kind = .dotted;
    prepared = try planner.prepareRailMembers(a, g, .out, 0, &.{ 10, 11, 12, 13, 14 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 12, 13 }, prepared);
}

test "rail preparation ignores an invisible plurality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var edges = [_]sg.Edge{ edge(10, 0, 1), edge(11, 0, 2), edge(12, 0, 3), edge(13, 0, 4), edge(14, 0, 1) };
    edges[2].kind = .invisible;
    edges[3].kind = .invisible;
    edges[4].kind = .invisible;
    edges[2].arrow_from = .circle;
    edges[3].arrow_from = .cross;
    edges[4].arrow_from = .open;

    const prepared = try planner.prepareRailMembers(a, graph(&edges), .out, 0, &.{ 14, 13, 12, 11, 10 });
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 10, 11 }, prepared);
}

test "piece plan licenses a fan in piece-local ids; synthetic edges take no part" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 0, 3), edge(3, 4, 0) };
    edges[0].origin = 9;
    edges[1].origin = 5;
    edges[2].origin = 7;

    const result = try planner.buildPiece(a, graph(&edges));
    try std.testing.expectEqual(pb.BundlePermits.Scope.piece, result.plan.scope);
    try std.testing.expect(!result.plan.isFlat());
    try std.testing.expectEqual(@as(usize, 1), result.plan.groups.len);
    try std.testing.expectEqual(pb.BundleDirection.out, result.plan.groups[0].direction);
    try std.testing.expectEqual(@as(sg.NodeId, 0), result.plan.groups[0].pivot);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 0, 1, 2 }, result.plan.groups[0].members);
    try std.testing.expectEqual(@as(usize, 3), result.plan.memberships.len);
    for (result.plan.memberships) |m| {
        try std.testing.expect(m.edge <= 2);
    }
}

const std = @import("std");
const parse = @import("../parse.zig");
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

fn expectClean(allocator: std.mem.Allocator, g: sg.SemGraph, plan: pb.JoinPermits) !void {
    const report = try planner.validate(allocator, g, plan);
    try std.testing.expect(report.valid());
}

fn hasFinding(report: planner.ValidationReport, tag: planner.ValidationTag) bool {
    for (report.findings) |finding| if (finding.tag == tag) return true;
    return false;
}

fn canonicalBytes(allocator: std.mem.Allocator, plan: pb.JoinPermits) ![]const u8 {
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

test "TSD 14.1: zero or one edge produces no groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const empty = try planner.build(a, graph(&.{}), .joined);
    try std.testing.expectEqual(@as(usize, 0), empty.plan.groups.len);
    try std.testing.expectEqual(@as(usize, 0), empty.plan.memberships.len);
    try expectClean(a, graph(&.{}), empty.plan);

    const edges = [_]sg.Edge{edge(7, 0, 1)};
    const one = try planner.build(a, graph(&edges), .joined);
    try std.testing.expectEqual(@as(usize, 0), one.plan.groups.len);
    try std.testing.expectEqual(@as(usize, 1), one.plan.memberships.len);
    try std.testing.expectEqual(@as(?pb.JoinGroupId, null), one.plan.memberships[0].source_group);
    try std.testing.expectEqual(@as(?pb.JoinGroupId, null), one.plan.memberships[0].target_group);
    try expectClean(a, graph(&edges), one.plan);
}

test "TSD 6.2: two edges with one source produce one fan-out group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(8, 0, 2), edge(4, 0, 1) };

    const result = try planner.build(a, graph(&edges), .joined);
    try std.testing.expectEqual(@as(usize, 1), result.plan.groups.len);
    const group = result.plan.groups[0];
    try std.testing.expectEqual(pb.JoinDirection.out, group.direction);
    try std.testing.expectEqual(@as(sg.NodeId, 0), group.pivot);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 4, 8 }, group.members);
    try expectClean(a, graph(&edges), result.plan);
}

test "TSD 6.2: two edges with one target produce one fan-in group" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(9, 2, 4), edge(3, 1, 4) };

    const result = try planner.build(a, graph(&edges), .joined);
    try std.testing.expectEqual(@as(usize, 1), result.plan.groups.len);
    try std.testing.expectEqual(pb.JoinDirection.in, result.plan.groups[0].direction);
    try std.testing.expectEqual(@as(sg.NodeId, 4), result.plan.groups[0].pivot);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 3, 9 }, result.plan.groups[0].members);
    try expectClean(a, graph(&edges), result.plan);
}

test "TSD 14.1: one dual edge receives source and target memberships" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(11, 0, 4), edge(12, 0, 1), edge(13, 2, 4) };

    const result = try planner.build(a, graph(&edges), .joined);
    const lookup = planner.lookupMembership(result.plan, .{ .original = 11 });
    try std.testing.expect(lookup.diagnostic == null);
    try std.testing.expect(lookup.membership.?.source_group != null);
    try std.testing.expect(lookup.membership.?.target_group != null);
    try expectClean(a, graph(&edges), result.plan);
}

test "TSD 6.2: a pure chain produces no groups" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 1, 2), edge(2, 2, 3) };

    const result = try planner.build(a, graph(&edges), .joined);
    try std.testing.expectEqual(@as(usize, 0), result.plan.groups.len);
    try std.testing.expectEqual(@as(usize, 3), result.plan.memberships.len);
    try expectClean(a, graph(&edges), result.plan);
}

test "TSD 14.1: compact and separate source statements produce identical plans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const compact = try parse.parse(a, "flowchart TD\nA --> B & C\n");
    const separate = try parse.parse(a, "flowchart TD\nA --> B\nA --> C\n");

    const cp = try planner.build(a, compact, .joined);
    const sp = try planner.build(a, separate, .joined);
    try std.testing.expectEqualStrings(try canonicalBytes(a, cp.plan), try canonicalBytes(a, sp.plan));
    try expectClean(a, compact, cp.plan);
    try expectClean(a, separate, sp.plan);
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

test "duplicate canonical edge keys are counted and block later join selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(2, 0, 1), edge(7, 0, 1) };

    const result = try planner.build(a, graph(&edges), .joined);
    try std.testing.expectEqual(@as(u32, 1), result.report.duplicate_canonical_edge_keys);
    try std.testing.expect(result.report.join_select_duplicate_key_blocked);
    try std.testing.expectEqual(@as(usize, 2), result.plan.groups.len);
    try expectClean(a, graph(&edges), result.plan);
}

test "V-D-EDGE-ID-02: clustered graph returns empty plan and both skip markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cluster = [_]sg.Cluster{.{
        .id = 0,
        .raw_id = "cluster",
        .label = "cluster",
        .parent = null,
        .members = &.{},
        .sub_clusters = &.{},
    }};
    var clustered = graph(&.{});
    clustered.clusters = &cluster;

    const result = try planner.build(a, clustered, .joined);
    try std.testing.expectEqual(pb.JoinPolicy.joined, result.plan.policy);
    try std.testing.expectEqual(@as(usize, 0), result.plan.groups.len);
    try std.testing.expectEqual(@as(usize, 0), result.plan.memberships.len);
    try std.testing.expect(result.report.join_permits_skipped_clustered);
    try std.testing.expect(result.report.edgeid_scope_clustered_skipped);
    try expectClean(a, clustered, result.plan);
}

test "V-D-JOIN-SELECT-14: self-loop excluded from fan-in group leaves residual member independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Target-incidence union {P->Z, Z->Z} at shared target Z (node 4): one plain
    // fan-in member plus the self-loop (the frenzy DiagramTypes->ZILLIONS + self-loop shape).
    const edges = [_]sg.Edge{ edge(0, 0, 4), edge(1, 4, 4) };

    const result = try planner.build(a, graph(&edges), .joined);
    // Self-loop excluded at construction; residual single real member P->Z falls below
    // the two-member floor, so no >=2-member group forms.
    try std.testing.expectEqual(@as(usize, 0), result.plan.groups.len);
    // Both edges take null/null memberships and route independently.
    try std.testing.expectEqual(@as(usize, 2), result.plan.memberships.len);
    for (result.plan.memberships) |membership| {
        try std.testing.expectEqual(@as(?pb.JoinGroupId, null), membership.source_group);
        try std.testing.expectEqual(@as(?pb.JoinGroupId, null), membership.target_group);
    }
    try expectClean(a, graph(&edges), result.plan);

    // Determinism under member permutation: the two edges in both orders serialize identically.
    const swapped = [_]sg.Edge{ edge(1, 4, 4), edge(0, 0, 4) };
    const other = try planner.build(a, graph(&swapped), .joined);
    try std.testing.expectEqualStrings(
        try canonicalBytes(a, result.plan),
        try canonicalBytes(a, other.plan),
    );
    try expectClean(a, graph(&swapped), other.plan);
}

test "V-D-JOIN-SELECT-14: self-loop exclusion does not annihilate real fan-in co-members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Union {P->Z, Q->Z, Z->Z}: two plain fan-in members plus the self-loop.
    const edges = [_]sg.Edge{ edge(0, 0, 4), edge(1, 1, 4), edge(2, 4, 4) };

    const result = try planner.build(a, graph(&edges), .joined);
    // Exactly one group: fan-in at Z over the two real edges; self-loop id 2 absent.
    try std.testing.expectEqual(@as(usize, 1), result.plan.groups.len);
    const group = result.plan.groups[0];
    try std.testing.expectEqual(pb.JoinDirection.in, group.direction);
    try std.testing.expectEqual(@as(sg.NodeId, 4), group.pivot);
    try std.testing.expectEqualSlices(pb.EdgeId, &.{ 0, 1 }, group.members);
    // Self-loop membership stays (null, null).
    const self_loop = planner.lookupMembership(result.plan, .{ .original = 2 });
    try std.testing.expectEqual(@as(?pb.JoinGroupId, null), self_loop.membership.?.source_group);
    try std.testing.expectEqual(@as(?pb.JoinGroupId, null), self_loop.membership.?.target_group);
    try expectClean(a, graph(&edges), result.plan);
}

test "builder output always validates clean across discovery shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const sg.Edge{
        &.{},
        &.{edge(0, 0, 1)},
        &.{ edge(0, 0, 1), edge(1, 0, 2) },
        &.{ edge(0, 1, 4), edge(1, 2, 4) },
        &.{ edge(0, 0, 4), edge(1, 0, 1), edge(2, 2, 4) },
        // V-D-JOIN-SELECT-14: self-loop-bearing fan-in union stays clean.
        &.{ edge(0, 0, 4), edge(1, 1, 4), edge(2, 4, 4) },
    };
    for (cases) |edges| {
        const g = graph(edges);
        const result = try planner.build(a, g, .joined);
        try expectClean(a, g, result.plan);
    }
}

test "TSD 6.4: validator rejects each structural invariant corruption" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2), edge(2, 3, 2) };
    const g = graph(&edges);
    const built = try planner.build(a, g, .joined);

    const short_members = [_]pb.EdgeId{0};
    var groups = try a.dupe(pb.JoinGroup, built.plan.groups);
    groups[0].members = &short_members;
    var report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .group_too_small));
    try std.testing.expect(hasFinding(report, .membership_group_lacks_edge));

    groups = try a.dupe(pb.JoinGroup, built.plan.groups);
    groups[0].pivot = 1;
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .member_pivot_mismatch));

    const reversed = [_]pb.EdgeId{ 1, 0 };
    groups = try a.dupe(pb.JoinGroup, built.plan.groups);
    groups[0].members = &reversed;
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .members_not_canonical));

    const missing = built.plan.memberships[0 .. built.plan.memberships.len - 1];
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = built.plan.groups, .memberships = missing });
    try std.testing.expect(hasFinding(report, .membership_missing_edge));

    var memberships = try a.dupe(pb.JoinMembership, built.plan.memberships);
    memberships[0].source_group = 99;
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = built.plan.groups, .memberships = memberships });
    try std.testing.expect(hasFinding(report, .membership_group_missing));

    groups = try a.dupe(pb.JoinGroup, built.plan.groups);
    const duplicate = [_]pb.EdgeId{ 0, 0 };
    groups[0].members = &duplicate;
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .group_duplicate_member));

    groups = try a.dupe(pb.JoinGroup, built.plan.groups);
    std.mem.swap(pb.JoinGroup, &groups[0], &groups[1]);
    report = try planner.validate(a, g, .{ .policy = .joined, .groups = groups, .memberships = built.plan.memberships });
    try std.testing.expect(hasFinding(report, .groups_not_canonical));
}

test "V-D-EDGE-ID-03: unqualified local lookup returns no membership and RF tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const edges = [_]sg.Edge{ edge(0, 0, 1), edge(1, 0, 2) };
    const result = try planner.build(a, graph(&edges), .joined);

    const lookup = planner.lookupMembership(result.plan, .{ .unqualified_local = 0 });
    try std.testing.expect(lookup.membership == null);
    try std.testing.expectEqual(pb.DiagnosticTag.edgeid_unqualified_local_lookup, lookup.diagnostic.?);
    try std.testing.expectEqual(pb.DispositionClass.render_fatal, pb.classOf(lookup.diagnostic.?));
}

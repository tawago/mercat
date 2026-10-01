const std = @import("std");
const parse = @import("../parse.zig").parse;
const permits = @import("../ledger/permits.zig");
const bundle_commit = @import("bundle_commit.zig");
const pb = @import("../base/ledger.zig");

fn nodeId(graph: anytype, raw: []const u8) u32 {
    for (graph.nodes) |n| if (std.mem.eql(u8, n.raw_id, raw)) return n.id;
    unreachable;
}

fn edgeIdOf(graph: anytype, from: []const u8, to: []const u8) u32 {
    const f = nodeId(graph, from);
    const t = nodeId(graph, to);
    for (graph.edges) |e| if (e.from == f and e.to == t) return e.id;
    unreachable;
}

fn targetOf(bundles: anytype, edge: u32) ?@TypeOf(bundles.memberships[0].target) {
    for (bundles.memberships) |m| if (m.edge == edge) return m.target;
    return null;
}

test "an all-arrow-free fan with undeclared leaf pairs commits no rail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), bundles.discharged.len);
    for ([_][]const u8{ "A", "B", "C" }) |leaf| {
        const t = targetOf(bundles, edgeIdOf(graph, leaf, "Z")).?;
        try std.testing.expect(t.? == .independent);
    }
}

test "a directed fan is untouched by the closure licence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> Z\n  B --> Z\n  C --> Z\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);
}

test "a fully declared leaf clique keeps the rail and co-realizes its pair edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), bundles.discharged.len);
    try std.testing.expectEqual(edgeIdOf(graph, "A", "B"), bundles.discharged[0]);
    var fused = false;
    for (bundles.selected_bundles) |sj| {
        for (plan.groups) |g| if (g.id == sj.candidate_bundle and g.direction == .in and g.pivot == nodeId(graph, "Z")) {
            fused = true;
        };
    }
    try std.testing.expect(fused);
}

test "a labeled or decorated declaration cannot back a leaf pair" {
    const sources = [_][]const u8{
        "flowchart TD\n  A --- Z\n  B --- Z\n  A -- why --- B\n",
        "flowchart TD\n  A --- Z\n  B --- Z\n  A --> B\n",
        "flowchart TD\n  A --- Z\n  B --- Z\n  A -.- B\n",
    };
    const discharged = [_]usize{ 1, 0, 0 };
    for (sources, discharged) |source, want| {
        var arena2 = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena2.deinit();
        const a = arena2.allocator();
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});
        try std.testing.expectEqual(want, bundles.discharged.len);
    }
}

test "a reversed member does not hide a closure refusal behind a null disposition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  Z --- W\n  W --- Q\n  Q --- Z\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const reversed = [_]u32{edgeIdOf(graph, "Q", "Z")};
    const bundles = try bundle_commit.realize(a, graph, &plan, &reversed, &.{});

    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    for ([_][]const u8{ "A", "B" }) |leaf| {
        const t = targetOf(bundles, edgeIdOf(graph, leaf, "Z")).?;
        try std.testing.expect(t != null);
        try std.testing.expect(t.? == .independent);
    }
}

test "a clique whose pair edges are other rails' members keeps a rail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  Z --- A\n  Z --- B\n  Z --- C\n  A --- B\n  A --- C\n  B --- C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});

    try std.testing.expect(bundles.selected_bundles.len > 0);
    for (bundles.discharged, 0..) |co, i| {
        for (bundles.discharged[0..i]) |prev| try std.testing.expect(prev != co);
        for (bundles.selected_bundles) |sj| for (sj.members) |m| try std.testing.expect(m != co);
    }
}

test "a single fan with its own fully declared clique keeps the whole rail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n  A --- B\n  A --- C\n  B --- C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);
    const rail = bundles.selected_bundles[0];
    for (plan.groups) |g| if (g.id == rail.candidate_bundle) {
        try std.testing.expectEqual(pb.BundleDirection.in, g.direction);
        try std.testing.expectEqual(nodeId(graph, "Z"), g.pivot);
    };
    try std.testing.expectEqual(@as(usize, 3), rail.members.len);
    try std.testing.expectEqual(@as(usize, 3), bundles.discharged.len);
    for ([_][2][]const u8{ .{ "A", "B" }, .{ "A", "C" }, .{ "B", "C" } }) |pair| {
        const id = edgeIdOf(graph, pair[0], pair[1]);
        var found = false;
        for (bundles.discharged) |co| {
            if (co == id) found = true;
        }
        try std.testing.expect(found);
    }
}

test "two rails asserting one declared pair both refuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  A --- W\n  B --- W\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), bundles.discharged.len);
    for ([_][2][]const u8{ .{ "A", "Z" }, .{ "B", "Z" }, .{ "A", "W" }, .{ "B", "W" } }) |pair| {
        const t = targetOf(bundles, edgeIdOf(graph, pair[0], pair[1])).?;
        try std.testing.expect(t.? == .independent);
    }
}

test "one rail's pair survives when no second rail asserts it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  A --- W\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 1), bundles.discharged.len);
    try std.testing.expectEqual(edgeIdOf(graph, "A", "B"), bundles.discharged[0]);
}
test "a salvaged rail whose pair another rail also asserts is refused with it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n  A --- W\n  B --- W\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});

    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), bundles.discharged.len);
}

test "a complete bipartite of selected arrivals licenses one fused union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S1 --> M1\n  S1 --> M2\n  S1 --> M3\n" ++
        "  S2 --> M1\n  S2 --> M2\n  S2 --> M3\n" ++
        "  S3 --> M1\n  S3 --> M2\n  S3 --> M3\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 3), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 1), bundles.fused.len);
    try std.testing.expectEqual(@as(usize, 9), bundles.fused[0].len);
}

test "an incomplete bipartite of selected arrivals licenses no fused union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S1 --> M1\n  S1 --> M2\n  S1 --> M3\n" ++
        "  S2 --> M1\n  S2 --> M2\n  S2 --> M3\n" ++
        "  S3 --> M1\n  S3 --> M2\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});
    try std.testing.expect(bundles.selected_bundles.len >= 2);
    try std.testing.expectEqual(@as(usize, 1), bundles.fused.len);
    try std.testing.expectEqual(@as(usize, 6), bundles.fused[0].len);
    for (bundles.fused[0]) |id| {
        for (graph.edges) |e| if (e.id == id) {
            try std.testing.expect(e.to != nodeId(graph, "M3"));
        };
    }
}

test "a head at the source end never bundles a fused union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> C\n  B --> C\n  A <-- D\n  B <-- D\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), bundles.fused.len);
}

test "mixed stroke kinds never join a fused union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> C\n  B --> C\n  A -.-> D\n  B -.-> D\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), bundles.fused.len);
}

test "two disjoint complete unions chained by a shared source each fuse alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> C\n  A --> D\n  B --> C\n  B --> D\n" ++
        "  B --> F\n  B --> G\n  E --> F\n  E --> G\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 2), bundles.fused.len);
    try std.testing.expectEqual(@as(usize, 4), bundles.fused[0].len);
    try std.testing.expectEqual(@as(usize, 4), bundles.fused[1].len);
}

test "a near member selected at both ends keeps its arrival rail, a long member keeps both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> B\n  A --> C\n  B --> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const near = try bundle_commit.realize(a, graph, &plan, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), near.selected_bundles.len);
    const ac = edgeIdOf(graph, "A", "C");
    try std.testing.expect(targetOf(near, ac).?.? == .selected);
    for (near.memberships) |rm| if (rm.edge == ac) try std.testing.expect(rm.source.? == .independent);

    const long = [_]u32{ac};
    const both = try bundle_commit.realize(a, graph, &plan, &.{}, &long);
    try std.testing.expectEqual(@as(usize, 2), both.selected_bundles.len);
    for (both.memberships) |rm| if (rm.edge == ac) {
        try std.testing.expect(rm.source.? == .selected);
        try std.testing.expect(rm.target.? == .selected);
    };
}

test "a labeled long member keeps both its departure and its arrival bundle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> B\n  A -->|far| C\n  B --> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const ac = edgeIdOf(graph, "A", "C");
    const long = [_]u32{ac};
    const bundles = try bundle_commit.realize(a, graph, &plan, &.{}, &long);
    try std.testing.expectEqual(@as(usize, 2), bundles.selected_bundles.len);
    for (bundles.memberships) |rm| if (rm.edge == ac) {
        try std.testing.expect(rm.source.? == .selected);
        try std.testing.expect(rm.target.? == .selected);
    };
}

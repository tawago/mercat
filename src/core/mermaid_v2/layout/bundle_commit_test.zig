const std = @import("std");
const parse = @import("../parse.zig").parse;
const permits = @import("../ledger/permits.zig");
const select = @import("../select.zig");
const bundle_commit = @import("bundle_commit.zig");
const pb = @import("../base/ledger.zig");

fn nodeId(graph: anytype, raw: []const u8) u32 {
    for (graph.nodes) |n| if (std.mem.eql(u8, n.raw_id, raw)) return n.id;
    unreachable;
}

fn rawOf(graph: anytype, id: u32) []const u8 {
    for (graph.nodes) |n| if (n.id == id) return n.raw_id;
    unreachable;
}

/// The identity keys ("from->to" node raw_ids, in committed member order) of
/// the fan-IN rail at node `D`, or empty when there is no such rail.
fn railKeysAtD(a: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const graph = try parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const winner = try select.choose(a, graph, &plan, 94, false, false, .bridge);
    for (winner.sketch.bundles.selected_bundles) |sj| {
        for (plan.groups) |g| if (g.id == sj.candidate_bundle and g.direction == .in and g.pivot == nodeId(graph, "D")) {
            const out = try a.alloc([]const u8, sj.members.len);
            for (sj.members, out) |m, *slot| {
                for (graph.edges) |e| if (e.id == m) {
                    slot.* = try std.fmt.allocPrint(a, "{s}->{s}", .{ rawOf(graph, e.from), rawOf(graph, e.to) });
                };
            }
            return out;
        };
    }
    return &.{};
}

const reversed_fanin_source =
    "flowchart TD\n  A --> B\n  A --> C\n  B --> D\n  C --> D\n  D --> E\n  E --> F\n  F --> D\n";

test "N6 reversed: every candidate commits the forward-subset fan-in rail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, reversed_fanin_source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const set = try select.enumerateAll(a, graph, &plan, 94);
    var saw_fanin = false;
    for (set.merged) |candidate| {
        for (candidate.sketch.bundles.selected_bundles) |sj| {
            for (plan.groups) |g| if (g.id == sj.candidate_bundle and g.direction == .in and g.pivot == nodeId(graph, "D")) {
                saw_fanin = true;
                try std.testing.expectEqual(@as(usize, 2), sj.members.len);
            };
        }
    }
    try std.testing.expect(saw_fanin);
}

test "N6 floor: a single-forward-member reversed fan-in commits no rail" {
    const source = "flowchart TD\n  A --> G\n  G --> H\n  H --> I\n  I --> J\n  J --> H\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, source);
    const plan = (try permits.build(a, graph, .joined)).plan;
    const set = try select.enumerateAll(a, graph, &plan, 94);
    for (set.merged) |candidate| {
        for (candidate.sketch.bundles.selected_bundles) |sj| {
            for (plan.groups) |g| if (g.id == sj.candidate_bundle)
                try std.testing.expect(!(g.direction == .in and g.pivot == nodeId(graph, "H")));
        }
    }
}

test "forward-subset selection is deterministic under arrival declaration permutation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const swapped = "flowchart TD\n  A --> C\n  A --> B\n  C --> D\n  B --> D\n  D --> E\n  E --> F\n  F --> D\n";
    const k1 = try railKeysAtD(a, reversed_fanin_source);
    const k2 = try railKeysAtD(a, swapped);
    try std.testing.expectEqual(@as(usize, 2), k1.len);
    try std.testing.expectEqual(k1.len, k2.len);
    for (k1, k2) |x, y| try std.testing.expectEqualStrings(x, y);
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
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);

    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), bundles.discharged.len);
    try std.testing.expectEqual(@as(u32, 1), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 3), report.co_undeclared);
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
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);

    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 0), report.co_undeclared);
}

test "a fully declared leaf clique keeps the rail and co-realizes its pair edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);

    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
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
    // Z's arrival rail needs A—B as a bare backer and is refused in every
    // shape. In the first, A's departure rail {A—Z, A—B(labeled)} is a
    // separate candidate: its own pair Z—B is backed by the bare B—Z, so it
    // keeps and discharges B—Z — a labeled MEMBER is fine, a labeled BACKER
    // is not. The other two shapes mix decoration or kind at A, so no rail.
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
        var report: bundle_commit.Report = .{};
        const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);
        try std.testing.expectEqual(want, bundles.discharged.len);
        try std.testing.expectEqual(@as(u32, 1), report.rail_closure_undeclared);
    }
}

test "a reversed member does not hide a closure refusal behind a null disposition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  Z --- W\n  W --- Q\n  Q --- Z\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const reversed = [_]u32{edgeIdOf(graph, "Q", "Z")};
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &reversed, &.{}, &report);

    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(u32, 1), report.rail_closure_undeclared);
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
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);

    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 0), report.co_undeclared);
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
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);

    try std.testing.expectEqual(@as(u32, 0), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(u32, 0), report.co_undeclared);
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
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);

    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), bundles.discharged.len);
    // Four: Z's and W's arrival rails refuse each other over A—B, and the
    // two departure candidates carry their own verdicts now that every
    // candidate is judged — A's salvages (Z—W undeclared), B's refuses.
    try std.testing.expectEqual(@as(u32, 4), report.rail_closure_undeclared);
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
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);

    // One: A's departure candidate {A—Z, A—W, A—B} salvages (Z—W is
    // undeclared) before its near member A—Z yields to Z's arrival rail.
    try std.testing.expectEqual(@as(u32, 1), report.rail_closure_undeclared);
    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 1), bundles.discharged.len);
    try std.testing.expectEqual(edgeIdOf(graph, "A", "B"), bundles.discharged[0]);
}
test "a salvaged rail that then loses its pair is one refusal, not two" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n  A --- W\n  B --- W\n  A --- B\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    var report: bundle_commit.Report = .{};
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, &report);

    try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
    try std.testing.expectEqual(@as(usize, 0), bundles.discharged.len);
    // Z salvages once and is not counted again when it loses A—B to W; W
    // counts once. The departure candidates add their own two verdicts.
    try std.testing.expectEqual(@as(u32, 4), report.rail_closure_undeclared);
}

test "a complete bipartite of selected arrivals licenses one fused union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  S1 --> M1\n  S1 --> M2\n  S1 --> M3\n" ++
        "  S2 --> M1\n  S2 --> M2\n  S2 --> M3\n" ++
        "  S3 --> M1\n  S3 --> M2\n  S3 --> M3\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, null);
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
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, null);
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
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), bundles.fused.len);
}

test "mixed stroke kinds never join a fused union" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> C\n  B --> C\n  A -.-> D\n  B -.-> D\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 0), bundles.fused.len);
}

test "two disjoint complete unions chained by a shared source each fuse alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const graph = try parse(a, "flowchart TD\n  A --> C\n  A --> D\n  B --> C\n  B --> D\n" ++
        "  B --> F\n  B --> G\n  E --> F\n  E --> G\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 2), bundles.fused.len);
    try std.testing.expectEqual(@as(usize, 4), bundles.fused[0].len);
    try std.testing.expectEqual(@as(usize, 4), bundles.fused[1].len);
}

test "a near member selected at both ends keeps its arrival rail, a long member keeps both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A --> C is a member of A's departure {A->B, A->C} and of C's arrival
    // {A->C, B->C}. Near (no long edge named): the arrival keeps it and A's
    // departure, left with one member, builds no rail.
    const graph = try parse(a, "flowchart TD\n  A --> B\n  A --> C\n  B --> C\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const near = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{}, null);
    try std.testing.expectEqual(@as(usize, 1), near.selected_bundles.len);
    const ac = edgeIdOf(graph, "A", "C");
    try std.testing.expect(targetOf(near, ac).?.? == .selected);
    for (near.memberships) |rm| if (rm.edge == ac) try std.testing.expect(rm.source.? == .independent);

    // Long (A --> C spans two layers): both memberships stay selected.
    const long = [_]u32{ac};
    const both = try bundle_commit.buildReported(a, graph, &plan, &.{}, &long, null);
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
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &long, null);
    try std.testing.expectEqual(@as(usize, 2), bundles.selected_bundles.len);
    for (bundles.memberships) |rm| if (rm.edge == ac) {
        try std.testing.expect(rm.source.? == .selected);
        try std.testing.expect(rm.target.? == .selected);
    };
}

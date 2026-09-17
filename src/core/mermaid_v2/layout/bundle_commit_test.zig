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

test "an all-arrow-free fan commits no rail and every member routes on its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "flowchart TD\n  A --- Z\n  B --- Z\n  C --- Z\n",
        "flowchart TD\n  A --- Z\n  B --- Z\n  A --- B\n",
    }) |source| {
        const graph = try parse(a, source);
        const plan = (try permits.build(a, graph, .joined)).plan;
        const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{});
        try std.testing.expectEqual(@as(usize, 0), bundles.selected_bundles.len);
        for ([_][]const u8{ "A", "B" }) |leaf| {
            const t = targetOf(bundles, edgeIdOf(graph, leaf, "Z")).?;
            try std.testing.expect(t.? == .independent);
        }
    }

    // One directional end anywhere in the group keeps the rail.
    const graph = try parse(a, "flowchart TD\n  A --> Z\n  B --> Z\n  C --> Z\n");
    const plan = (try permits.build(a, graph, .joined)).plan;
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), bundles.selected_bundles.len);
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
    const near = try bundle_commit.buildReported(a, graph, &plan, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), near.selected_bundles.len);
    const ac = edgeIdOf(graph, "A", "C");
    try std.testing.expect(targetOf(near, ac).?.? == .selected);
    for (near.memberships) |rm| if (rm.edge == ac) try std.testing.expect(rm.source.? == .independent);

    // Long (A --> C spans two layers): both memberships stay selected.
    const long = [_]u32{ac};
    const both = try bundle_commit.buildReported(a, graph, &plan, &.{}, &long);
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
    const bundles = try bundle_commit.buildReported(a, graph, &plan, &.{}, &long);
    try std.testing.expectEqual(@as(usize, 2), bundles.selected_bundles.len);
    for (bundles.memberships) |rm| if (rm.edge == ac) {
        try std.testing.expect(rm.source.? == .selected);
        try std.testing.expect(rm.target.? == .selected);
    };
}
